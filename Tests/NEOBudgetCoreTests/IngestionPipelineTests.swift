import Testing
import NEOBudgetCore
import NEOBudgetInMemoryStorage

@Test func assembledReadyCandidateUsesAtomicProcessorAndIsIdempotent() throws {
    let accountID = AccountID(rawValue: "pipeline-bank")
    let money = try Money(minorUnits: 5_000, currency: "KRW")
    let draft = try TransactionCandidateDraft(
        rawNotificationID: "pipeline-raw",
        parserID: "test",
        parserVersion: "1",
        ruleID: "purchase",
        kind: .purchase,
        direction: .outflow,
        amount: money,
        occurredAt: ObservedTimestamp(unixMilliseconds: 1, precision: .second, source: .notificationTime),
        confidence: .high
    )
    let context = try CandidateAssemblyContext(
        timeZoneIdentifier: "Asia/Seoul",
        policyVersion: "assembly-v1"
    )
    let candidate = try DefaultTransactionCandidateAssembler().assemble(
        draft,
        resolution: .resolved(.account(accountID)),
        context: context
    )
    var repository = try InMemoryCandidateProcessingRepository(configuration: LedgerConfiguration(accounts: [
        Account(
            id: accountID,
            name: "생활비",
            kind: .bank,
            openingBalance: Money(minorUnits: 100_000, currency: "KRW")
        )
    ]))
    #expect(try repository.process(candidate, expectedCandidateRevision: 0, expectedLedgerRevision: 0) ==
            .promoted(candidateRevision: 1, ledgerRevision: 1))
    #expect(try repository.process(candidate, expectedCandidateRevision: 0, expectedLedgerRevision: 0) ==
            .alreadyPromoted(candidateRevision: 1, ledgerRevision: 1))
    #expect(try repository.processingSnapshot().ledger.entries.count == 1)
}
