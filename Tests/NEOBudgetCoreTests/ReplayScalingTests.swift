import Foundation
import Testing
import NEOBudgetCore
import NEOBudgetInMemoryStorage

/// The ledger and the candidate store keep indexes so that replaying every received notification at startup costs time
/// in proportion to their number. These tests hold the indexes to what they stand for.
private let bank = AccountID(rawValue: "bank")
private let start: Int64 = 1_790_000_000_000

private func won(_ value: Int64) throws -> Money { try Money(minorUnits: value, currency: "KRW") }
private let october = try! BudgetMonth(year: 2026, month: 10)

@Test func aLedgerRolledBackToACheckpointIsAsItWasAndTakesTheSameEntriesAgain() throws {
    var ledger = try InMemoryLedgerRepository(configuration: LedgerConfiguration(accounts: [
        Account(id: bank, name: "생활비", kind: .bank, openingBalance: won(0))
    ]))
    let income = LedgerEntry(id: LedgerEntryID(rawValue: "income"), kind: .income, occurredAtUnixMilliseconds: 1,
                             postings: [Posting(accountID: bank, delta: try won(20_000))], evidenceIDs: ["raw-income"])
    let spend = LedgerEntry(id: LedgerEntryID(rawValue: "spend"), kind: .expense, occurredAtUnixMilliseconds: 2,
                            postings: [Posting(accountID: bank, delta: try won(-9_000))],
                            budgetImpact: BudgetImpact(kind: .expense, amount: try won(9_000), attributedMonth: october),
                            evidenceIDs: ["raw-spend"])
    _ = try ledger.commit(income, expectedRevision: 0)
    _ = try ledger.commit(spend, expectedRevision: 1)
    let before = try ledger.snapshot()
    let checkpoint = ledger.checkpoint()

    let refund = LedgerEntry(id: LedgerEntryID(rawValue: "refund"), kind: .adjustment, occurredAtUnixMilliseconds: 3,
                             postings: [Posting(accountID: bank, delta: try won(4_000))],
                             budgetImpact: BudgetImpact(kind: .return, amount: try won(4_000), attributedMonth: october),
                             adjustment: AdjustmentLink(originalEntryID: spend.id, reason: .refund), evidenceIDs: ["raw-refund"])
    let reversal = LedgerEntry(id: LedgerEntryID(rawValue: "reversal"), kind: .reversal, occurredAtUnixMilliseconds: 4,
                               postings: [Posting(accountID: bank, delta: try won(-20_000))], reverses: income.id)
    let later = LedgerEntry(id: LedgerEntryID(rawValue: "later"), kind: .expense, occurredAtUnixMilliseconds: 5,
                            postings: [Posting(accountID: bank, delta: try won(-1_000))],
                            budgetImpact: BudgetImpact(kind: .expense, amount: try won(1_000), attributedMonth: october))
    _ = try ledger.commit(refund, expectedRevision: 2)
    _ = try ledger.commit(reversal, expectedRevision: 3)
    _ = try ledger.commit(later, expectedRevision: 4)
    let after = try ledger.snapshot()
    #expect(after != before)

    ledger.rollback(to: checkpoint)
    #expect(try ledger.snapshot() == before)
    #expect(ledger.entry(withID: refund.id) == nil)
    #expect(ledger.entry(withID: spend.id) == spend)

    // Everything the undone entries used is free again: their IDs, their evidence, the room left on the purchase, the
    // income's one reversal. Committing them again gives the state they gave the first time.
    _ = try ledger.commit(refund, expectedRevision: 2)
    _ = try ledger.commit(reversal, expectedRevision: 3)
    _ = try ledger.commit(later, expectedRevision: 4)
    #expect(try ledger.snapshot() == after)
}

@Test func aCommitThatIsRejectedLeavesTheLedgerUntouched() throws {
    var ledger = try InMemoryLedgerRepository(configuration: LedgerConfiguration(accounts: [
        Account(id: bank, name: "생활비", kind: .bank, openingBalance: won(0))
    ]))
    let spend = LedgerEntry(id: LedgerEntryID(rawValue: "spend"), kind: .expense, occurredAtUnixMilliseconds: 1,
                            postings: [Posting(accountID: bank, delta: try won(-9_000))],
                            budgetImpact: BudgetImpact(kind: .expense, amount: try won(9_000), attributedMonth: october),
                            evidenceIDs: ["raw-spend"])
    _ = try ledger.commit(spend, expectedRevision: 0)
    let before = try ledger.snapshot()
    // Takes the evidence of the first entry, and over-refunds it: both are refused, and nothing of either remains.
    let tooMuch = LedgerEntry(id: LedgerEntryID(rawValue: "refund"), kind: .adjustment, occurredAtUnixMilliseconds: 2,
                              postings: [Posting(accountID: bank, delta: try won(10_000))],
                              budgetImpact: BudgetImpact(kind: .return, amount: try won(10_000), attributedMonth: october),
                              adjustment: AdjustmentLink(originalEntryID: spend.id, reason: .refund), evidenceIDs: ["raw-refund"])
    #expect(throws: LedgerStorageError.invalidEntry(.adjustmentExceedsOriginal(spend.id))) { try ledger.commit(tooMuch, expectedRevision: 1) }
    let reused = LedgerEntry(id: LedgerEntryID(rawValue: "other"), kind: .income, occurredAtUnixMilliseconds: 3,
                             postings: [Posting(accountID: bank, delta: try won(1_000))], evidenceIDs: ["raw-spend"])
    #expect(throws: LedgerStorageError.invalidEntry(.evidenceAlreadyUsed(id: "raw-spend", entryID: spend.id))) { try ledger.commit(reused, expectedRevision: 1) }
    #expect(try ledger.snapshot() == before)
    // The refund's own evidence was not claimed by the refused attempt.
    let fine = LedgerEntry(id: LedgerEntryID(rawValue: "refund"), kind: .adjustment, occurredAtUnixMilliseconds: 2,
                           postings: [Posting(accountID: bank, delta: try won(9_000))],
                           budgetImpact: BudgetImpact(kind: .return, amount: try won(9_000), attributedMonth: october),
                           adjustment: AdjustmentLink(originalEntryID: spend.id, reason: .refund), evidenceIDs: ["raw-refund"])
    #expect(try ledger.commit(fine, expectedRevision: 1) == .committed(revision: 2))
    #expect(try ledger.snapshot().monthlyBudgets[october]?.netExpense == (try won(0)))
}

// MARK: Candidate store indexes

private struct Arrival {
    let id: String
    let kind: DraftEventKind
    let amount: Int64
    let seconds: Int64
    let binding: ResolvedLedgerBinding?
    let source: String
}

private func receive(_ arrival: Arrival, into repository: inout InMemoryCandidateProcessingRepository) throws {
    let draft = try TransactionCandidateDraft(
        rawNotificationID: "raw-" + arrival.id, parserID: "test", parserVersion: "1", ruleID: arrival.kind.rawValue,
        kind: arrival.kind, direction: .outflow, amount: won(arrival.amount),
        occurredAt: ObservedTimestamp(unixMilliseconds: start + arrival.seconds * 1000, precision: .second, source: .notificationTime),
        counterparty: DraftCounterparty(merchantRaw: "가상상점"), confidence: .high
    )
    let resolution: AccountResolution = arrival.binding.map { .resolved($0) } ?? .unresolved(.unknownAccount)
    let candidate = try DefaultTransactionCandidateAssembler().assemble(draft, resolution: resolution, context: CandidateAssemblyContext(
        timeZoneIdentifier: "Asia/Seoul", transferCounterpartAccountID: nil, policyVersion: "assembly-v1"
    ))
    let observation = CorrelationObservation(candidateID: candidate.id, draft: draft, binding: arrival.binding, source: arrival.source)
    let revisions = try repository.revisions()
    _ = try repository.process(candidate, observation: observation, correlator: NotificationCorrelator(),
                               expectedCandidateRevision: revisions.candidate, expectedLedgerRevision: revisions.ledger)
}

private func freshRepository() throws -> InMemoryCandidateProcessingRepository {
    try InMemoryCandidateProcessingRepository(configuration: LedgerConfiguration(accounts: [
        Account(id: bank, name: "생활비", kind: .bank, openingBalance: won(1_000_000))
    ]))
}

@Test func theRecordsNearATimeIncludeWhateverCorroboratesThemEvenFromOutsideTheWindow() throws {
    var repository = try freshRepository()
    // The card payment, and the bank withdrawal of it nine minutes later, which is recorded as its evidence.
    try receive(Arrival(id: "card", kind: .purchase, amount: 9_900, seconds: 0, binding: .account(bank), source: "card"), into: &repository)
    try receive(Arrival(id: "bank", kind: .withdrawal, amount: 9_900, seconds: 540, binding: .account(bank), source: "bank"), into: &repository)
    let snapshot = try repository.processingSnapshot()
    let corroborating = snapshot.candidates.values.filter { $0.corroborates != nil }
    #expect(corroborating.count == 1)

    let radius: Int64 = 600_000
    // Ten minutes before the card payment: it is in reach, its withdrawal (19 minutes away) is not, but it comes along.
    let records = try repository.correlationRecords(near: start - 590_000, within: radius)
    #expect(Set(records.map(\.candidateID)) == Set(snapshot.candidates.keys))
    // Far from both: nothing.
    #expect(try repository.correlationRecords(near: start + 86_400_000, within: radius).isEmpty)
    // Between them, nothing is lost either.
    #expect(try repository.correlationRecords(near: start + 270_000, within: radius).count == 2)
}

@Test func everyStoredCandidateIsFoundByItsNotificationAndByItsTime() throws {
    var repository = try freshRepository()
    for index in 0..<120 {
        let kind: DraftEventKind = index % 3 == 0 ? .withdrawal : .purchase
        try receive(Arrival(id: "n\(index)", kind: kind, amount: Int64(1_000 + (index % 7) * 500), seconds: Int64(index) * 97,
                            binding: .account(bank), source: index % 2 == 0 ? "bank" : "card"), into: &repository)
    }
    let snapshot = try repository.processingSnapshot()
    #expect(snapshot.candidates.count == 120)
    for (id, stored) in snapshot.candidates {
        let draft = try #require(stored.candidate.sourceDraft)
        let found = try repository.storedCandidate(ofNotification: draft.rawNotificationID, eventIndex: draft.eventIndex)
        #expect(found == stored)
        #expect(repository.storedCandidate(id) == stored)
        let record = try #require(stored.correlationRecord)
        let near = try repository.correlationRecords(near: record.draft.occurredAt.unixMilliseconds, within: 0)
        #expect(near.contains { $0.candidateID == id })
    }
    #expect(try repository.storedCandidate(ofNotification: "raw-absent", eventIndex: 0) == nil)
    #expect(try repository.revisions().candidate == snapshot.candidateRevision)
    #expect(try repository.revisions().ledger == snapshot.ledger.revision)
}

@Test func theNotificationsAnIntakeLedgerKnowsAreFoundByIDAndNeverTakenTwice() throws {
    let decoder = ShortcutNotificationDecoder(timeZone: TimeZone(identifier: "Asia/Seoul")!)
    func note(_ index: Int) throws -> RawNotification {
        let fields = ["app": "우리WON뱅킹", "title": "", "subtitle": "",
                      "body": "[Web발신]\n우리 출금 \(1_000 + index * 100)원 1002-123-456*** 잔액 1,234,000원 10/02 19:\(String(format: "%02d", index)):20",
                      "timestamp": "Oct 2, 2026 at 7:\(String(format: "%02d", index)):30 PM"]
        let text = String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
        return try decoder.decode(text, receivedAtUnixMilliseconds: 1_790_936_040_000)[0]
    }
    let notifications = try (0..<30).map(note)
    var ledger = try IntakeLedger(notifications: [], setup: IntakeSetup(), intake: NotificationIntake(timeZoneIdentifier: "Asia/Seoul"))
    #expect(try ledger.receive(Array(notifications.prefix(20))).count == 20)
    // Ten more, with five that are already known (twice in one batch, too).
    let second = Array(notifications[15..<30]) + [notifications[29]]
    #expect(try ledger.receive(second).count == 10)
    #expect(ledger.notifications.map(\.id) == notifications.map(\.id))
    for notification in notifications {
        if case .failed = ledger.status(of: notification.id) { Issue.record("no outcome for \(notification.id)") }
    }
    #expect(ledger.status(of: "never-received") == .failed)
}
