import Foundation
import Testing
import NEOBudgetCore
import NEOBudgetInMemoryStorage

private let woori = AccountID(rawValue: "woori")
private let tossBank = AccountID(rawValue: "toss-bank")
private let kakao = AccountID(rawValue: "kakao-wallet")
private let start: Int64 = 1_790_000_000_000

private func won(_ value: Int64) throws -> Money { try Money(minorUnits: value, currency: "KRW") }

/// One notification as it reaches the processing layer: a parsed draft, its resolved account, its source.
private struct Arrival {
    let id: String
    let kind: DraftEventKind
    let direction: TransactionDirection
    let amount: Int64
    let seconds: Int64
    let binding: ResolvedLedgerBinding?
    var counterpart: AccountID? = nil
    let source: String
    var name: String? = nil
}

private func repository() throws -> InMemoryCandidateProcessingRepository {
    try InMemoryCandidateProcessingRepository(configuration: LedgerConfiguration(accounts: [
        Account(id: woori, name: "생활비", kind: .bank, openingBalance: won(1_000_000)),
        Account(id: tossBank, name: "토스뱅크", kind: .bank, openingBalance: won(0)),
        Account(id: kakao, name: "카카오페이", kind: .prepaid, openingBalance: won(0))
    ]))
}

private func receive(_ arrival: Arrival, into repository: inout InMemoryCandidateProcessingRepository) throws -> CandidateProcessingResult {
    let draft = try TransactionCandidateDraft(
        rawNotificationID: "raw-" + arrival.id, parserID: "test", parserVersion: "1", ruleID: arrival.kind.rawValue,
        kind: arrival.kind, direction: arrival.direction, amount: won(arrival.amount),
        occurredAt: ObservedTimestamp(unixMilliseconds: start + arrival.seconds * 1000, precision: .second, source: .notificationTime),
        counterparty: arrival.direction == .outflow ? DraftCounterparty(merchantRaw: arrival.name) : DraftCounterparty(payeeRaw: arrival.name),
        confidence: .high
    )
    let resolution: AccountResolution = arrival.binding.map { .resolved($0) } ?? .unresolved(.unknownAccount)
    let candidate = try DefaultTransactionCandidateAssembler().assemble(draft, resolution: resolution, context: CandidateAssemblyContext(
        timeZoneIdentifier: "Asia/Seoul", transferCounterpartAccountID: arrival.counterpart, policyVersion: "assembly-v1"
    ))
    let observation = CorrelationObservation(candidateID: candidate.id, draft: draft, binding: arrival.binding,
                                             transferCounterpart: arrival.counterpart, source: arrival.source)
    let snapshot = try repository.processingSnapshot()
    return try repository.process(candidate, observation: observation, correlator: NotificationCorrelator(),
                                  expectedCandidateRevision: snapshot.candidateRevision, expectedLedgerRevision: snapshot.ledger.revision)
}

private func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    return items.indices.flatMap { index -> [[T]] in
        var rest = items
        let head = rest.remove(at: index)
        return permutations(rest).map { [head] + $0 }
    }
}

private struct Outcome: Equatable {
    let balances: [AccountID: Money]
    let budgets: [BudgetMonth: MonthlyBudgetSummary]
    let entryKinds: [LedgerEntry.Kind]
    let openReviews: Int
}

private func outcome(of order: [Arrival]) throws -> Outcome {
    var repository = try repository()
    for arrival in order { _ = try receive(arrival, into: &repository) }
    let snapshot = try repository.processingSnapshot()
    return Outcome(
        balances: snapshot.ledger.accountBalances,
        budgets: snapshot.ledger.monthlyBudgets,
        entryKinds: snapshot.ledger.entries.map(\.kind).sorted { $0.rawValue < $1.rawValue },
        openReviews: snapshot.candidates.values.filter { $0.promotedEntryID == nil && $0.corroborates == nil }.count
    )
}

@Test func aCheckCardPaymentReportedByThreeAppsIsSpentOnceInEveryOrder() throws {
    let arrivals = [
        Arrival(id: "toss", kind: .purchase, direction: .outflow, amount: 9_900, seconds: 0, binding: .account(woori), source: "toss", name: "가상상점"),
        Arrival(id: "card", kind: .purchase, direction: .outflow, amount: 9_900, seconds: 1, binding: .account(woori), source: "hyundai", name: "가상상점"),
        Arrival(id: "bank", kind: .withdrawal, direction: .outflow, amount: 9_900, seconds: 3, binding: .account(woori), source: "woori")
    ]
    for order in permutations(arrivals) {
        let result = try outcome(of: order)
        #expect(result.balances[woori] == (try won(990_100)))
        #expect(result.entryKinds == [.expense])
        #expect(result.openReviews == 0)
    }
}

@Test func aWithdrawalNoNotificationExplainsStaysInReview() throws {
    let result = try outcome(of: [Arrival(id: "bank", kind: .withdrawal, direction: .outflow, amount: 70_000, seconds: 0, binding: .account(woori), source: "woori")])
    #expect(result.entryKinds.isEmpty)
    #expect(result.openReviews == 1)
    #expect(result.balances[woori] == (try won(1_000_000)))
}

@Test func aTransferIsOneMoveInEveryOrderAndAnIncomeRecordedFirstIsReversed() throws {
    let arrivals = [
        Arrival(id: "out", kind: .transferOut, direction: .outflow, amount: 50_000, seconds: 0, binding: .account(woori), counterpart: tossBank, source: "woori"),
        Arrival(id: "in", kind: .deposit, direction: .inflow, amount: 50_000, seconds: 2, binding: .account(tossBank), source: "toss")
    ]
    for order in permutations(arrivals) {
        let result = try outcome(of: order)
        #expect(result.balances[woori] == (try won(950_000)))
        #expect(result.balances[tossBank] == (try won(50_000)))
        #expect(result.openReviews == 0)
    }
    // Deposit first: it was income until the outgoing leg arrived; the income stays and is reversed, not deleted.
    #expect(try outcome(of: arrivals.reversed()).entryKinds == [.income, .reversal, .transfer])
    #expect(try outcome(of: arrivals).entryKinds == [.transfer])
}

@Test func aKakaoChargeAndItsBankWithdrawalAreOneMoveInEveryOrder() throws {
    let arrivals = [
        Arrival(id: "charge", kind: .walletTopUp, direction: .inflow, amount: 30_000, seconds: 0, binding: .account(kakao), counterpart: woori, source: "kakaopay"),
        Arrival(id: "bank", kind: .withdrawal, direction: .outflow, amount: 30_000, seconds: 1, binding: .account(woori), source: "woori")
    ]
    for order in permutations(arrivals) {
        let result = try outcome(of: order)
        #expect(result.balances[woori] == (try won(970_000)))
        #expect(result.balances[kakao] == (try won(30_000)))
        #expect(result.entryKinds == [.transfer])
        #expect(result.openReviews == 0)
    }
}

@Test func aRefundWithoutAReferenceWaitsWithSuggestionsAndChangesNothing() throws {
    var repository = try repository()
    _ = try receive(Arrival(id: "buy", kind: .purchase, direction: .outflow, amount: 15_000, seconds: 0, binding: .account(woori), source: "hyundai", name: "가상상점"), into: &repository)
    let before = try repository.processingSnapshot().ledger
    #expect(try receive(Arrival(id: "refund", kind: .deposit, direction: .inflow, amount: 15_000, seconds: 86_400, binding: .account(woori), source: "woori", name: "가상상점"), into: &repository)
            == .stored(candidateRevision: 2))
    let snapshot = try repository.processingSnapshot()
    #expect(snapshot.ledger == before)
    let stored = try #require(snapshot.candidates.values.first { $0.candidate.sourceDraft?.rawNotificationID == "raw-refund" })
    #expect(stored.candidate.issues == [.possibleReturnOfEarlierPurchase])
    #expect(stored.suggestions.map(\.rule) == [.refundSuggestion])
}

@Test func repeatingANotificationKeepsTheFirstDecision() throws {
    var repository = try repository()
    let card = Arrival(id: "card", kind: .purchase, direction: .outflow, amount: 9_900, seconds: 0, binding: .account(woori), source: "hyundai")
    let bank = Arrival(id: "bank", kind: .withdrawal, direction: .outflow, amount: 9_900, seconds: 1, binding: .account(woori), source: "woori")
    _ = try receive(card, into: &repository)
    guard case .corroborated = try receive(bank, into: &repository) else { Issue.record("expected corroborated"); return }
    let snapshot = try repository.processingSnapshot()
    guard case .corroborated = try receive(bank, into: &repository) else { Issue.record("expected corroborated again"); return }
    #expect(try receive(card, into: &repository) == .alreadyPromoted(candidateRevision: snapshot.candidateRevision, ledgerRevision: snapshot.ledger.revision))
    #expect(try repository.processingSnapshot() == snapshot)
}

@Test func aReversalUndoesOneIncomeExactlyOnceAndNothingElse() throws {
    var ledger = try InMemoryLedgerRepository(configuration: LedgerConfiguration(accounts: [
        Account(id: woori, name: "생활비", kind: .bank, openingBalance: won(0))
    ]))
    let income = LedgerEntry(id: LedgerEntryID(rawValue: "income"), kind: .income, occurredAtUnixMilliseconds: 1,
                             postings: [Posting(accountID: woori, delta: try won(20_000))], evidenceIDs: ["raw-income"])
    let spend = LedgerEntry(id: LedgerEntryID(rawValue: "spend"), kind: .expense, occurredAtUnixMilliseconds: 2,
                            postings: [Posting(accountID: woori, delta: try won(-5_000))],
                            budgetImpact: BudgetImpact(kind: .expense, amount: try won(5_000), attributedMonth: try BudgetMonth(year: 2026, month: 10)),
                            evidenceIDs: ["raw-spend"])
    _ = try ledger.commit(income, expectedRevision: 0)
    _ = try ledger.commit(spend, expectedRevision: 1)
    func reversal(_ id: String, of target: String, _ amount: Int64) throws -> LedgerEntry {
        LedgerEntry(id: LedgerEntryID(rawValue: id), kind: .reversal, occurredAtUnixMilliseconds: 3,
                    postings: [Posting(accountID: woori, delta: try won(amount))], reverses: LedgerEntryID(rawValue: target))
    }
    #expect(throws: LedgerStorageError.invalidEntry(.reversalTargetInvalid(LedgerEntryID(rawValue: "spend")))) {
        try ledger.commit(try reversal("r0", of: "spend", 5_000), expectedRevision: 2)
    }
    #expect(throws: LedgerStorageError.invalidEntry(.reversalTargetInvalid(LedgerEntryID(rawValue: "income")))) {
        try ledger.commit(try reversal("r0", of: "income", -10_000), expectedRevision: 2)
    }
    #expect(try ledger.commit(try reversal("r1", of: "income", -20_000), expectedRevision: 2) == .committed(revision: 3))
    #expect(throws: LedgerStorageError.invalidEntry(.alreadyReversed(LedgerEntryID(rawValue: "income")))) {
        try ledger.commit(try reversal("r2", of: "income", -20_000), expectedRevision: 3)
    }
    #expect(try ledger.snapshot().accountBalances[woori] == (try won(-5_000)))
}
