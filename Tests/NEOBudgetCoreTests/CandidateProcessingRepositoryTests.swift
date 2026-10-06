import Testing
import NEOBudgetCore
import NEOBudgetInMemoryStorage

private let processingBankID = AccountID(rawValue: "bank-main")
private let processingSavingsID = AccountID(rawValue: "bank-savings")
private let processingCardID = CreditInstrumentID(rawValue: "card-main")

private func processingWon(_ minorUnits: Int64) throws -> Money {
    try Money(minorUnits: minorUnits, currency: "KRW")
}

private func processingMonth() throws -> BudgetMonth {
    try BudgetMonth(year: 2026, month: 10)
}

private func processingRepository() throws -> InMemoryCandidateProcessingRepository {
    try InMemoryCandidateProcessingRepository(configuration: LedgerConfiguration(
        accounts: [
            Account(
                id: processingBankID,
                name: "생활비",
                kind: .bank,
                openingBalance: processingWon(100_000)
            ),
            Account(
                id: processingSavingsID,
                name: "저축",
                kind: .bank,
                openingBalance: processingWon(50_000)
            )
        ],
        creditInstruments: [
            try CreditInstrument(id: processingCardID, name: "주 카드", currency: "KRW")
        ]
    ))
}

private func readyCashExpenseCandidate(
    candidateID: String = "candidate-expense",
    entryID: String = "entry-expense",
    evidenceIDs: [String] = ["raw-expense"],
    amount: Int64 = 10_000,
    accountID: AccountID = processingBankID
) throws -> TransactionCandidate {
    let entry = LedgerEntry(
        id: LedgerEntryID(rawValue: entryID),
        kind: .expense,
        occurredAtUnixMilliseconds: 1,
        postings: [Posting(accountID: accountID, delta: try processingWon(-amount))],
        budgetImpact: BudgetImpact(
            kind: .expense,
            amount: try processingWon(amount),
            attributedMonth: try processingMonth()
        ),
        evidenceIDs: evidenceIDs
    )
    return try TransactionCandidate(
        id: TransactionCandidateID(rawValue: candidateID),
        evidenceIDs: evidenceIDs,
        status: .ready,
        proposedEntry: entry,
        policyVersion: "candidate-v1"
    )
}

private func reviewCandidate(
    id: String = "candidate-review",
    evidenceID: String = "raw-review"
) throws -> TransactionCandidate {
    try TransactionCandidate(
        id: TransactionCandidateID(rawValue: id),
        evidenceIDs: [evidenceID],
        status: .needsReview,
        issues: [.ambiguousWithoutStrongIdentity],
        policyVersion: "candidate-v1"
    )
}

@Test func identicalCandidatePromotionIsIdempotent() throws {
    var repository = try processingRepository()
    let candidate = try readyCashExpenseCandidate()
    #expect(try repository.process(
        candidate,
        expectedCandidateRevision: 0,
        expectedLedgerRevision: 0
    ) == .promoted(candidateRevision: 1, ledgerRevision: 1))

    #expect(try repository.process(
        candidate,
        expectedCandidateRevision: 0,
        expectedLedgerRevision: 0
    ) == .alreadyPromoted(candidateRevision: 1, ledgerRevision: 1))

    let snapshot = try repository.processingSnapshot()
    let ninetyThousand = try processingWon(90_000)
    #expect(snapshot.candidates.count == 1)
    #expect(snapshot.ledger.entries.count == 1)
    #expect(snapshot.ledger.revision == 1)
    #expect(snapshot.ledger.accountBalances[processingBankID] == ninetyThousand)
}

@Test func promotionFailureRollsBackNewCandidateAndLedger() throws {
    var repository = try processingRepository()
    let unknown = AccountID(rawValue: "unknown")
    let invalid = try readyCashExpenseCandidate(accountID: unknown)

    #expect(try repository.process(
        invalid,
        expectedCandidateRevision: 0,
        expectedLedgerRevision: 0
    ) == .rejectedByLedger(candidateRevision: 1, ledgerRevision: 0, reason: .invalidEntry))

    let snapshot = try repository.processingSnapshot()
    #expect(snapshot.candidateRevision == 1)
    #expect(snapshot.candidates[invalid.id]?.candidate.status == .needsReview)
    #expect(snapshot.candidates[invalid.id]?.candidate.issues == [.promotionRejected])
    #expect(snapshot.candidates[invalid.id]?.promotionRejection == .invalidEntry)
    #expect(snapshot.ledger.revision == 0)
    #expect(snapshot.ledger.entries.isEmpty)
}

@Test func needsReviewCandidateIsStoredWithoutAutomaticPromotion() throws {
    var repository = try processingRepository()
    let candidate = try reviewCandidate()
    #expect(try repository.process(
        candidate,
        expectedCandidateRevision: 0,
        expectedLedgerRevision: 0
    ) == .stored(candidateRevision: 1))

    let snapshot = try repository.processingSnapshot()
    #expect(snapshot.candidates[candidate.id]?.candidate.status == .needsReview)
    #expect(snapshot.candidates[candidate.id]?.promotedEntryID == nil)
    #expect(snapshot.ledger.entries.isEmpty)
    #expect(snapshot.ledger.revision == 0)
}

@Test func reinputOfAlreadyStoredCandidateIsIdempotent() throws {
    var repository = try processingRepository()
    let candidate = try reviewCandidate()
    _ = try repository.process(
        candidate,
        expectedCandidateRevision: 0,
        expectedLedgerRevision: 0
    )
    #expect(try repository.process(
        candidate,
        expectedCandidateRevision: 0,
        expectedLedgerRevision: 99
    ) == .alreadyStored(candidateRevision: 1))
    #expect(try repository.processingSnapshot().candidateRevision == 1)
}

@Test func complementaryRawNotificationsPromoteOneFinancialEntry() throws {
    var repository = try processingRepository()
    let partial = try TransactionCandidate(
        id: TransactionCandidateID(rawValue: "candidate-expense"),
        evidenceIDs: ["raw-bank"],
        status: .waitingForEvidence,
        issues: [.parserUncertain],
        policyVersion: "candidate-v1"
    )
    _ = try repository.process(
        partial,
        expectedCandidateRevision: 0,
        expectedLedgerRevision: 0
    )

    let candidate = try readyCashExpenseCandidate(
        evidenceIDs: ["raw-bank", "raw-wallet"]
    )
    _ = try repository.process(
        candidate,
        expectedCandidateRevision: 1,
        expectedLedgerRevision: 0
    )

    let snapshot = try repository.processingSnapshot()
    #expect(snapshot.candidateRevision == 2)
    let month = try processingMonth()
    let tenThousand = try processingWon(10_000)
    #expect(snapshot.ledger.entries.count == 1)
    #expect(snapshot.ledger.entries[0].evidenceIDs == ["raw-bank", "raw-wallet"])
    #expect(snapshot.ledger.monthlyBudgets[month]?.netExpense == tenThousand)
}

@Test func refundTransferAndCardPaymentCandidatesPromoteWithCorrectEffects() throws {
    var repository = try processingRepository()
    let cashPurchase = try readyCashExpenseCandidate(
        candidateID: "candidate-cash",
        entryID: "entry-cash",
        evidenceIDs: ["raw-cash"],
        amount: 40_000
    )
    _ = try repository.process(cashPurchase, expectedCandidateRevision: 0, expectedLedgerRevision: 0)

    let refundEntry = LedgerEntry(
        id: LedgerEntryID(rawValue: "entry-refund"),
        kind: .adjustment,
        occurredAtUnixMilliseconds: 2,
        postings: [Posting(accountID: processingBankID, delta: try processingWon(15_000))],
        budgetImpact: BudgetImpact(
            kind: .return,
            amount: try processingWon(15_000),
            attributedMonth: try processingMonth()
        ),
        adjustment: AdjustmentLink(originalEntryID: cashPurchase.proposedEntry!.id, reason: .refund),
        evidenceIDs: ["raw-refund"]
    )
    let refund = try TransactionCandidate(
        id: TransactionCandidateID(rawValue: "candidate-refund"),
        evidenceIDs: refundEntry.evidenceIDs,
        status: .ready,
        proposedEntry: refundEntry,
        policyVersion: "candidate-v1"
    )
    _ = try repository.process(refund, expectedCandidateRevision: 1, expectedLedgerRevision: 1)

    let transferEntry = LedgerEntry(
        id: LedgerEntryID(rawValue: "entry-transfer"),
        kind: .transfer,
        occurredAtUnixMilliseconds: 3,
        postings: [
            Posting(accountID: processingBankID, delta: try processingWon(-10_000)),
            Posting(accountID: processingSavingsID, delta: try processingWon(10_000))
        ],
        evidenceIDs: ["raw-transfer"]
    )
    let transfer = try TransactionCandidate(
        id: TransactionCandidateID(rawValue: "candidate-transfer"),
        evidenceIDs: transferEntry.evidenceIDs,
        status: .ready,
        proposedEntry: transferEntry,
        policyVersion: "candidate-v1"
    )
    _ = try repository.process(transfer, expectedCandidateRevision: 2, expectedLedgerRevision: 2)

    let cardPurchaseEntry = LedgerEntry(
        id: LedgerEntryID(rawValue: "entry-card-purchase"),
        kind: .expense,
        occurredAtUnixMilliseconds: 4,
        liabilityChanges: [LiabilityChange(
            instrumentID: processingCardID,
            delta: try processingWon(20_000)
        )],
        budgetImpact: BudgetImpact(
            kind: .expense,
            amount: try processingWon(20_000),
            attributedMonth: try processingMonth()
        ),
        evidenceIDs: ["raw-card-purchase"]
    )
    let cardPurchase = try TransactionCandidate(
        id: TransactionCandidateID(rawValue: "candidate-card-purchase"),
        evidenceIDs: cardPurchaseEntry.evidenceIDs,
        status: .ready,
        proposedEntry: cardPurchaseEntry,
        policyVersion: "candidate-v1"
    )
    _ = try repository.process(cardPurchase, expectedCandidateRevision: 3, expectedLedgerRevision: 3)

    let cardPaymentEntry = LedgerEntry(
        id: LedgerEntryID(rawValue: "entry-card-payment"),
        kind: .cardPayment,
        occurredAtUnixMilliseconds: 5,
        postings: [Posting(accountID: processingBankID, delta: try processingWon(-20_000))],
        liabilityChanges: [LiabilityChange(
            instrumentID: processingCardID,
            delta: try processingWon(-20_000)
        )],
        evidenceIDs: ["raw-card-payment"]
    )
    let cardPayment = try TransactionCandidate(
        id: TransactionCandidateID(rawValue: "candidate-card-payment"),
        evidenceIDs: cardPaymentEntry.evidenceIDs,
        status: .ready,
        proposedEntry: cardPaymentEntry,
        policyVersion: "candidate-v1"
    )
    _ = try repository.process(cardPayment, expectedCandidateRevision: 4, expectedLedgerRevision: 4)

    let snapshot = try repository.processingSnapshot()
    let month = try processingMonth()
    let fortyFiveThousand = try processingWon(45_000)
    let sixtyThousand = try processingWon(60_000)
    let zero = try processingWon(0)
    let fifteenThousand = try processingWon(15_000)
    #expect(snapshot.candidateRevision == 5)
    #expect(snapshot.ledger.revision == 5)
    #expect(snapshot.ledger.accountBalances[processingBankID] == fortyFiveThousand)
    #expect(snapshot.ledger.accountBalances[processingSavingsID] == sixtyThousand)
    #expect(snapshot.ledger.outstandingLiabilities[processingCardID] == zero)
    #expect(snapshot.ledger.monthlyBudgets[month]?.expense == sixtyThousand)
    #expect(snapshot.ledger.monthlyBudgets[month]?.returns == fifteenThousand)
    #expect(snapshot.ledger.monthlyBudgets[month]?.netExpense == fortyFiveThousand)
}

@Test func staleCandidateAndLedgerRevisionsAreRejectedWithoutMutation() throws {
    var repository = try processingRepository()
    let review = try reviewCandidate()
    _ = try repository.process(review, expectedCandidateRevision: 0, expectedLedgerRevision: 0)

    let otherReview = try reviewCandidate(id: "other", evidenceID: "raw-other")
    #expect(throws: CandidateProcessingError.staleCandidateRevision(expected: 0, actual: 1)) {
        try repository.process(otherReview, expectedCandidateRevision: 0, expectedLedgerRevision: 0)
    }

    let ready = try readyCashExpenseCandidate()
    #expect(throws: CandidateProcessingError.staleLedgerRevision(expected: 1, actual: 0)) {
        try repository.process(ready, expectedCandidateRevision: 1, expectedLedgerRevision: 1)
    }
    let snapshot = try repository.processingSnapshot()
    #expect(snapshot.candidateRevision == 1)
    #expect(snapshot.candidates.count == 1)
    #expect(snapshot.ledger.revision == 0)
}

@Test func failedLedgerWriteAfterStoredReviewRestoresOriginalCandidate() throws {
    var repository = try processingRepository()
    let review = try reviewCandidate()
    _ = try repository.process(review, expectedCandidateRevision: 0, expectedLedgerRevision: 0)

    let unknown = AccountID(rawValue: "unknown")
    let invalidReady = try readyCashExpenseCandidate(
        candidateID: review.id.rawValue,
        evidenceIDs: review.evidenceIDs,
        accountID: unknown
    )
    #expect(try repository.process(
        invalidReady,
        expectedCandidateRevision: 1,
        expectedLedgerRevision: 0
    ) == .rejectedByLedger(candidateRevision: 2, ledgerRevision: 0, reason: .invalidEntry))

    let snapshot = try repository.processingSnapshot()
    #expect(snapshot.candidateRevision == 2)
    #expect(snapshot.candidates[review.id]?.candidate == review)
    #expect(snapshot.candidates[review.id]?.promotedEntryID == nil)
    #expect(snapshot.candidates[review.id]?.promotionRejection == .invalidEntry)
    #expect(snapshot.ledger.entries.isEmpty)
}

@Test func candidateEvidenceCannotBeClaimedTwice() throws {
    var repository = try processingRepository()
    let first = try reviewCandidate(id: "first", evidenceID: "raw-shared")
    _ = try repository.process(first, expectedCandidateRevision: 0, expectedLedgerRevision: 0)
    let second = try reviewCandidate(id: "second", evidenceID: "raw-shared")
    #expect(throws: CandidateProcessingError.evidenceAlreadyClaimed(
        id: "raw-shared",
        candidateID: first.id
    )) {
        try repository.process(second, expectedCandidateRevision: 1, expectedLedgerRevision: 0)
    }
    #expect(try repository.processingSnapshot().candidates.count == 1)
}
