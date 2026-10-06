import Foundation
import Testing
import NEOBudgetCore
import NEOBudgetInMemoryStorage

private struct RedTeamFixtures: Decodable {
    struct DirectionCase: Decodable {
        let kind: DraftEventKind
        let direction: TransactionDirection
        let input: RawNotification
    }
    struct AmountCase: Decodable {
        let outcome: String
        let amount: Int64?
        let input: RawNotification
    }
    let negative: [RawNotification]
    let directions: [DirectionCase]
    let amounts: [AmountCase]
}

private func redTeamFixtures() throws -> RedTeamFixtures {
    let url = try #require(Bundle.module.url(
        forResource: "redteam-parser-fixtures", withExtension: "json", subdirectory: "Fixtures"
    ))
    return try JSONDecoder().decode(RedTeamFixtures.self, from: Data(contentsOf: url))
}

private func redTeamParsingContext(version: String = "1") throws -> NotificationParsingContext {
    try NotificationParsingContext(
        timeZoneIdentifier: "Asia/Seoul",
        referenceTimeUnixMilliseconds: 1_800_000_000_000,
        parserID: "redteam",
        parserVersion: version
    )
}

private func redTeamAssemblyContext() throws -> CandidateAssemblyContext {
    try CandidateAssemblyContext(timeZoneIdentifier: "Asia/Seoul", policyVersion: "redteam-v1")
}

@Test func negativeCorpusNeverBecomesCandidate() throws {
    let parser = KoreanFinancialNotificationParser()
    for input in try redTeamFixtures().negative {
        let outcome = try parser.parse(input, context: redTeamParsingContext())
        guard case .notTransaction = outcome else {
            Issue.record("Negative fixture \(input.id) became \(outcome)")
            continue
        }
    }
}

@Test func directionIsExplicitForAccountNotifications() throws {
    let parser = KoreanFinancialNotificationParser()
    let assembler = DefaultTransactionCandidateAssembler()
    let accountID = AccountID(rawValue: "direction-bank")
    for fixture in try redTeamFixtures().directions {
        let outcome = try parser.parse(fixture.input, context: redTeamParsingContext())
        guard case let .candidate(draft) = outcome else {
            Issue.record("Direction fixture \(fixture.input.id) did not parse: \(outcome)")
            continue
        }
        #expect(draft.kind == fixture.kind)
        #expect(draft.direction == fixture.direction)
        if fixture.kind == .withdrawal {
            let candidate = try assembler.assemble(
                draft,
                resolution: .resolved(.account(accountID)),
                context: redTeamAssemblyContext()
            )
            #expect(candidate.status == .needsReview)
            #expect(candidate.issues == [.unsupportedEvent])
        }
    }
}

@Test func amountSelectionIsLabelBasedAndAmbiguityFailsClosed() throws {
    let parser = KoreanFinancialNotificationParser()
    for fixture in try redTeamFixtures().amounts {
        let outcome = try parser.parse(fixture.input, context: redTeamParsingContext())
        switch fixture.outcome {
        case "candidate":
            guard case let .candidate(draft) = outcome else {
                Issue.record("Amount fixture \(fixture.input.id) did not produce a draft: \(outcome)")
                continue
            }
            #expect(draft.amount.minorUnits == fixture.amount)
        case "amountUnparseable": #expect(outcome == .failed(.amountUnparseable))
        case "unsupportedCurrency": #expect(outcome == .failed(.unsupportedCurrency))
        case "amountAmbiguous": #expect(outcome == .failed(.amountAmbiguous))
        case "amountMissing": #expect(outcome == .failed(.amountMissing))
        default: Issue.record("Unknown expected outcome \(fixture.outcome)")
        }
    }
}

@Test func crossProviderSamePurchaseCannotDoublePromote() throws {
    let cardID = CreditInstrumentID(rawValue: "shared-card")
    let amount = try Money(minorUnits: 7_000, currency: "KRW")
    let timestamp = ObservedTimestamp(unixMilliseconds: 1_790_000_000_000, precision: .second, source: .text)
    func draft(_ rawID: String, _ scope: String) throws -> TransactionCandidateDraft {
        try TransactionCandidateDraft(
            rawNotificationID: rawID,
            parserID: "test", parserVersion: "1", ruleID: "purchase",
            kind: .purchase, direction: .outflow, amount: amount, occurredAt: timestamp,
            evidence: [DraftEvidence(kind: .approvalNumber, strength: .scoped, value: "87654321", scope: scope)],
            confidence: .high
        )
    }
    let assembler = DefaultTransactionCandidateAssembler()
    let context = try redTeamAssemblyContext()
    let cardCandidate = try assembler.assemble(
        draft("raw-card", "app.card"), resolution: .resolved(.creditInstrument(cardID)), context: context
    )
    let payCandidate = try assembler.assemble(
        draft("raw-pay", "app.pay"), resolution: .resolved(.creditInstrument(cardID)), context: context
    )
    var repository = try InMemoryCandidateProcessingRepository(configuration: LedgerConfiguration(
        creditInstruments: [try CreditInstrument(id: cardID, name: "공용 카드", currency: "KRW")]
    ))
    _ = try repository.process(cardCandidate, expectedCandidateRevision: 0, expectedLedgerRevision: 0)
    #expect(try repository.process(payCandidate, expectedCandidateRevision: 1, expectedLedgerRevision: 1) ==
            .stored(candidateRevision: 2))
    let snapshot = try repository.processingSnapshot()
    #expect(snapshot.ledger.entries.count == 1)
    #expect(snapshot.candidates[payCandidate.id]?.candidate.issues == [.ambiguousWithoutStrongIdentity])
}

@Test func reusedApprovalNumberForDifferentPurchasesIsNeverDropped() throws {
    let cardID = CreditInstrumentID(rawValue: "reuse-card")
    let timestamp = ObservedTimestamp(unixMilliseconds: 1_790_000_000_000, precision: .second, source: .text)
    func candidate(_ rawID: String, amount: Int64) throws -> TransactionCandidate {
        let draft = try TransactionCandidateDraft(
            rawNotificationID: rawID,
            parserID: "test", parserVersion: "1", ruleID: "purchase",
            kind: .purchase, direction: .outflow,
            amount: Money(minorUnits: amount, currency: "KRW"), occurredAt: timestamp,
            evidence: [DraftEvidence(kind: .approvalNumber, strength: .scoped, value: "12345678", scope: "app.card")],
            confidence: .high
        )
        return try DefaultTransactionCandidateAssembler().assemble(
            draft, resolution: .resolved(.creditInstrument(cardID)), context: redTeamAssemblyContext()
        )
    }
    var repository = try InMemoryCandidateProcessingRepository(configuration: LedgerConfiguration(
        creditInstruments: [try CreditInstrument(id: cardID, name: "재사용 카드", currency: "KRW")]
    ))
    _ = try repository.process(try candidate("reuse-a", amount: 5_000), expectedCandidateRevision: 0, expectedLedgerRevision: 0)
    #expect(try repository.process(
        candidate("reuse-b", amount: 9_000), expectedCandidateRevision: 1, expectedLedgerRevision: 1
    ) == .promoted(candidateRevision: 2, ledgerRevision: 2))
    #expect(try repository.processingSnapshot().ledger.entries.count == 2)
}

@Test func rawIdentityAndRetryRemainStableAcrossParserVersions() throws {
    let accountID = AccountID(rawValue: "stable-bank")
    let raw = RawNotification(
        id: "stable-raw",
        source: NotificationSource(applicationIdentifier: "fixture.card"),
        capturedAtUnixMilliseconds: 1_790_000_000_000,
        notificationAtUnixMilliseconds: 1_790_000_000_000,
        title: "승인",
        body: "5,000원\n승인번호 STABLE"
    )
    let parser = KoreanFinancialNotificationParser()
    guard case let .candidate(v1Draft) = try parser.parse(raw, context: redTeamParsingContext(version: "1")),
          case let .candidate(v2Draft) = try parser.parse(raw, context: redTeamParsingContext(version: "2")) else {
        Issue.record("Expected drafts")
        return
    }
    let assembler = DefaultTransactionCandidateAssembler()
    let v1 = try assembler.assemble(v1Draft, resolution: .resolved(.account(accountID)), context: redTeamAssemblyContext())
    let v2 = try assembler.assemble(v2Draft, resolution: .resolved(.account(accountID)), context: redTeamAssemblyContext())
    #expect(v1.id == v2.id)
    #expect(v1.proposedEntry == v2.proposedEntry)
    var repository = try InMemoryCandidateProcessingRepository(configuration: LedgerConfiguration(accounts: [
        Account(id: accountID, name: "안정 계좌", kind: .bank, openingBalance: Money(minorUnits: 100_000, currency: "KRW"))
    ]))
    _ = try repository.process(v1, expectedCandidateRevision: 0, expectedLedgerRevision: 0)
    #expect(try repository.process(v2, expectedCandidateRevision: 0, expectedLedgerRevision: 0) ==
            .alreadyPromoted(candidateRevision: 1, ledgerRevision: 1))
}

@Test func budgetMonthFollowsOccurredAtInUserTimeZone() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Seoul"))
    let date = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 10, day: 31, hour: 23, minute: 58
    )))
    let draft = try TransactionCandidateDraft(
        rawNotificationID: "month-boundary",
        parserID: "test", parserVersion: "1", ruleID: "purchase",
        kind: .purchase, direction: .outflow,
        amount: Money(minorUnits: 5_000, currency: "KRW"),
        occurredAt: ObservedTimestamp(
            unixMilliseconds: Int64(date.timeIntervalSince1970 * 1_000), precision: .minute, source: .text
        ),
        confidence: .high
    )
    let candidate = try DefaultTransactionCandidateAssembler().assemble(
        draft,
        resolution: .resolved(.account(AccountID(rawValue: "month-bank"))),
        context: CandidateAssemblyContext(timeZoneIdentifier: "Asia/Seoul", policyVersion: "processed-in-november")
    )
    let october = try BudgetMonth(year: 2026, month: 10)
    #expect(candidate.proposedEntry?.budgetImpact?.attributedMonth == october)
}

@Test func permanentLedgerRejectionIsStoredForReviewAndRetryIsTyped() throws {
    let unknown = AccountID(rawValue: "unknown-account")
    let money = try Money(minorUnits: 10_000, currency: "KRW")
    let october = try BudgetMonth(year: 2026, month: 10)
    let entry = LedgerEntry(
        id: LedgerEntryID(rawValue: "invalid-entry"),
        kind: .expense,
        occurredAtUnixMilliseconds: 1,
        postings: [Posting(accountID: unknown, delta: try money.negated())],
        budgetImpact: BudgetImpact(kind: .expense, amount: money, attributedMonth: october),
        evidenceIDs: ["invalid-raw"]
    )
    let candidate = try TransactionCandidate(
        id: TransactionCandidateID(rawValue: "invalid-candidate"),
        evidenceIDs: entry.evidenceIDs,
        status: .ready,
        proposedEntry: entry,
        policyVersion: "test"
    )
    var repository = try InMemoryCandidateProcessingRepository(configuration: LedgerConfiguration())
    let rejection = CandidateProcessingResult.rejectedByLedger(
        candidateRevision: 1, ledgerRevision: 0, reason: .invalidEntry
    )
    #expect(try repository.process(candidate, expectedCandidateRevision: 0, expectedLedgerRevision: 0) == rejection)
    #expect(try repository.process(candidate, expectedCandidateRevision: 0, expectedLedgerRevision: 0) == rejection)
    let snapshot = try repository.processingSnapshot()
    #expect(snapshot.ledger.entries.isEmpty)
    #expect(snapshot.ledger.revision == 0)
    #expect(snapshot.candidates[candidate.id]?.candidate.status == .needsReview)
    #expect(snapshot.candidates[candidate.id]?.candidate.issues == [.promotionRejected])
    #expect(snapshot.candidates[candidate.id]?.promotionRejection == .invalidEntry)
}

@Test func approvalNumberLabelDoesNotMatchOriginalApprovalNumber() throws {
    func evidence(_ id: String, _ body: String) throws -> [DraftEvidenceKind: String] {
        let raw = RawNotification(
            id: id,
            source: NotificationSource(applicationIdentifier: "fixture.card"),
            capturedAtUnixMilliseconds: 1_790_000_000_000,
            notificationAtUnixMilliseconds: 1_790_000_000_000,
            title: "승인취소",
            body: body
        )
        guard case let .candidate(draft) = try KoreanFinancialNotificationParser()
            .parse(raw, context: redTeamParsingContext()) else {
            Issue.record("Expected a cancellation draft for \(id)")
            return [:]
        }
        return Dictionary(draft.evidence.map { ($0.kind, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    // Original label first: its line must not satisfy the current-approval label.
    let originalFirst = try evidence("label-original-first", "10,000원 취소\n원승인번호 O1\n승인번호 C1")
    #expect(originalFirst[.approvalNumber] == "C1")
    #expect(originalFirst[.originalApprovalReference] == "O1")

    let currentFirst = try evidence("label-current-first", "10,000원 취소\n승인번호 C1\n원승인번호 O1")
    #expect(currentFirst[.approvalNumber] == "C1")
    #expect(currentFirst[.originalApprovalReference] == "O1")

    // Only the original number is present: no current approval number may be invented from it.
    let originalOnly = try evidence("label-original-only", "10,000원 취소\n원승인번호 O1")
    #expect(originalOnly[.approvalNumber] == nil)
    #expect(originalOnly[.originalApprovalReference] == "O1")

    // Both labels on one line: the current label after the original number is still found.
    let sameLine = try evidence("label-same-line", "10,000원 취소\n원승인번호 O1 승인번호 C1")
    #expect(sameLine[.approvalNumber] == "C1")
}

@Test func evidenceOwnerTreatsEquivalentPromotedEntryAsRetry() throws {
    let accountID = AccountID(rawValue: "retry-bank")
    let money = try Money(minorUnits: 5_000, currency: "KRW")
    let january = try BudgetMonth(year: 1970, month: 1)
    let entry = LedgerEntry(
        id: LedgerEntryID(rawValue: "retry-entry"),
        kind: .expense,
        occurredAtUnixMilliseconds: 1,
        postings: [Posting(accountID: accountID, delta: try money.negated())],
        budgetImpact: BudgetImpact(kind: .expense, amount: money, attributedMonth: january),
        evidenceIDs: ["retry-raw"]
    )
    func candidate(_ id: String) throws -> TransactionCandidate {
        try TransactionCandidate(
            id: TransactionCandidateID(rawValue: id), evidenceIDs: entry.evidenceIDs,
            status: .ready, proposedEntry: entry, policyVersion: "test"
        )
    }
    var repository = try InMemoryCandidateProcessingRepository(configuration: LedgerConfiguration(accounts: [
        Account(id: accountID, name: "재시도 계좌", kind: .bank, openingBalance: Money(minorUnits: 100_000, currency: "KRW"))
    ]))
    let first = try candidate("retry-candidate-a")
    _ = try repository.process(first, expectedCandidateRevision: 0, expectedLedgerRevision: 0)
    #expect(try repository.process(
        candidate("retry-candidate-b"), expectedCandidateRevision: 1, expectedLedgerRevision: 1
    ) == .duplicate(existingCandidateID: first.id, candidateRevision: 1, ledgerRevision: 1))
    #expect(try repository.processingSnapshot().ledger.entries.count == 1)
}
