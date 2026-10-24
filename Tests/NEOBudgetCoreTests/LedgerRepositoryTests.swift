import Foundation
import Testing
import NEOBudgetCore
import NEOBudgetInMemoryStorage

private let bankID = AccountID(rawValue: "bank-main")
private let savingsID = AccountID(rawValue: "bank-savings")
private let cardID = CreditInstrumentID(rawValue: "card-main")

private func won(_ minorUnits: Int64) throws -> Money {
    try Money(minorUnits: minorUnits, currency: "KRW")
}

private func october() throws -> BudgetMonth {
    try BudgetMonth(year: 2026, month: 10)
}

private func repository() throws -> InMemoryLedgerRepository {
    try InMemoryLedgerRepository(configuration: LedgerConfiguration(
        accounts: [
            Account(id: bankID, name: "생활비", kind: .bank, openingBalance: won(100_000)),
            Account(id: savingsID, name: "저축", kind: .bank, openingBalance: won(50_000))
        ],
        creditInstruments: [
            try CreditInstrument(id: cardID, name: "주 카드", currency: "KRW")
        ]
    ))
}

private func cashExpense(id: String = "expense-cash", amount: Int64 = 10_000) throws -> LedgerEntry {
    LedgerEntry(
        id: LedgerEntryID(rawValue: id),
        kind: .expense,
        occurredAtUnixMilliseconds: 1_780_000_000_000,
        postings: [Posting(accountID: bankID, delta: try won(-amount))],
        budgetImpact: BudgetImpact(kind: .expense, amount: try won(amount), attributedMonth: try october()),
        evidenceIDs: ["notification-1"]
    )
}

@Test func moneyUsesValidatedExactMinorUnits() throws {
    #expect(throws: MoneyError.invalidCurrency("krw")) {
        try Money(minorUnits: 1, currency: "krw")
    }
    let maximum = try Money(minorUnits: .max, currency: "KRW")
    #expect(throws: MoneyError.overflow) {
        try maximum.adding(won(1))
    }
    let invalidEncodedMoney = Data(#"{"minorUnits":1,"currency":"krw"}"#.utf8)
    #expect(throws: MoneyError.invalidCurrency("krw")) {
        try JSONDecoder().decode(Money.self, from: invalidEncodedMoney)
    }
    let invalidEncodedMonth = Data(#"{"year":2026,"month":13}"#.utf8)
    #expect(throws: LedgerValidationError.invalidBudgetMonth(year: 2026, month: 13)) {
        try JSONDecoder().decode(BudgetMonth.self, from: invalidEncodedMonth)
    }
}

@Test func expenseFundingMustExactlyMatchBudgetImpact() throws {
    var ledger = try repository()
    let mismatch = LedgerEntry(
        id: LedgerEntryID(rawValue: "mismatch"), kind: .expense,
        occurredAtUnixMilliseconds: 1,
        postings: [Posting(accountID: bankID, delta: try won(-9_000))],
        budgetImpact: BudgetImpact(kind: .expense, amount: try won(10_000), attributedMonth: try october())
    )
    #expect(throws: LedgerStorageError.invalidEntry(.invalidEntryShape(kind: .expense))) {
        try ledger.commit(mismatch, expectedRevision: 0)
    }
    #expect(try ledger.snapshot().revision == 0)
}

@Test func cashExpenseChangesCashAndAttributedBudgetTogether() throws {
    var ledger = try repository()
    #expect(try ledger.commit(cashExpense(), expectedRevision: 0) == .committed(revision: 1))

    let snapshot = try ledger.snapshot()
    let month = try october()
    let zero = try won(0)
    let tenThousand = try won(10_000)
    let ninetyThousand = try won(90_000)
    #expect(snapshot.accountBalances[bankID] == ninetyThousand)
    #expect(snapshot.outstandingLiabilities[cardID] == zero)
    #expect(snapshot.monthlyBudgets[month]?.expense == tenThousand)
    #expect(snapshot.monthlyBudgets[month]?.netExpense == tenThousand)
}

@Test func cardExpenseChangesLiabilityAndBudgetWithoutMovingCash() throws {
    let entry = LedgerEntry(
        id: LedgerEntryID(rawValue: "expense-card"),
        kind: .expense,
        occurredAtUnixMilliseconds: 1_780_000_000_000,
        liabilityChanges: [LiabilityChange(instrumentID: cardID, delta: try won(20_000))],
        budgetImpact: BudgetImpact(kind: .expense, amount: try won(20_000), attributedMonth: try october())
    )
    var ledger = try repository()
    _ = try ledger.commit(entry, expectedRevision: 0)

    let snapshot = try ledger.snapshot()
    let month = try october()
    let twentyThousand = try won(20_000)
    let hundredThousand = try won(100_000)
    #expect(snapshot.accountBalances[bankID] == hundredThousand)
    #expect(snapshot.outstandingLiabilities[cardID] == twentyThousand)
    #expect(snapshot.monthlyBudgets[month]?.netExpense == twentyThousand)
}

@Test func cardPaymentMovesCashAndLiabilityButDoesNotAddConsumption() throws {
    var ledger = try repository()
    let purchase = LedgerEntry(
        id: LedgerEntryID(rawValue: "purchase"), kind: .expense,
        occurredAtUnixMilliseconds: 1,
        liabilityChanges: [LiabilityChange(instrumentID: cardID, delta: try won(30_000))],
        budgetImpact: BudgetImpact(kind: .expense, amount: try won(30_000), attributedMonth: try october())
    )
    _ = try ledger.commit(purchase, expectedRevision: 0)
    let payment = LedgerEntry(
        id: LedgerEntryID(rawValue: "payment"), kind: .cardPayment,
        occurredAtUnixMilliseconds: 2,
        postings: [Posting(accountID: bankID, delta: try won(-30_000))],
        liabilityChanges: [LiabilityChange(instrumentID: cardID, delta: try won(-30_000))]
    )
    _ = try ledger.commit(payment, expectedRevision: 1)

    let snapshot = try ledger.snapshot()
    let month = try october()
    let seventyThousand = try won(70_000)
    let zero = try won(0)
    let thirtyThousand = try won(30_000)
    #expect(snapshot.accountBalances[bankID] == seventyThousand)
    #expect(snapshot.outstandingLiabilities[cardID] == zero)
    #expect(snapshot.monthlyBudgets[month]?.netExpense == thirtyThousand)
}

@Test func transferMustBalanceAndNeverTouchesBudget() throws {
    var ledger = try repository()
    let transfer = LedgerEntry(
        id: LedgerEntryID(rawValue: "transfer"), kind: .transfer,
        occurredAtUnixMilliseconds: 1,
        postings: [
            Posting(accountID: bankID, delta: try won(-25_000)),
            Posting(accountID: savingsID, delta: try won(25_000))
        ]
    )
    _ = try ledger.commit(transfer, expectedRevision: 0)
    let snapshot = try ledger.snapshot()
    let seventyFiveThousand = try won(75_000)
    #expect(snapshot.accountBalances[bankID] == seventyFiveThousand)
    #expect(snapshot.accountBalances[savingsID] == seventyFiveThousand)
    #expect(snapshot.monthlyBudgets.isEmpty)

    let unbalanced = LedgerEntry(
        id: LedgerEntryID(rawValue: "bad-transfer"), kind: .transfer,
        occurredAtUnixMilliseconds: 2,
        postings: [
            Posting(accountID: bankID, delta: try won(-1_000)),
            Posting(accountID: savingsID, delta: try won(900))
        ]
    )
    #expect(throws: LedgerStorageError.invalidEntry(.invalidEntryShape(kind: .transfer))) {
        try ledger.commit(unbalanced, expectedRevision: 1)
    }
    #expect(try ledger.snapshot().revision == 1)
}

@Test func refundCashDateAndOriginalBudgetMonthAreIndependent() throws {
    var ledger = try repository()
    let original = try cashExpense(id: "original", amount: 40_000)
    _ = try ledger.commit(original, expectedRevision: 0)

    let refund = LedgerEntry(
        id: LedgerEntryID(rawValue: "refund"), kind: .adjustment,
        occurredAtUnixMilliseconds: 1_790_000_000_000,
        postings: [Posting(accountID: bankID, delta: try won(15_000))],
        budgetImpact: BudgetImpact(kind: .return, amount: try won(15_000), attributedMonth: try october()),
        adjustment: AdjustmentLink(originalEntryID: original.id, reason: .refund)
    )
    _ = try ledger.commit(refund, expectedRevision: 1)

    let snapshot = try ledger.snapshot()
    let month = try october()
    let seventyFiveThousand = try won(75_000)
    let fortyThousand = try won(40_000)
    let fifteenThousand = try won(15_000)
    let twentyFiveThousand = try won(25_000)
    #expect(snapshot.accountBalances[bankID] == seventyFiveThousand)
    #expect(snapshot.monthlyBudgets[month]?.expense == fortyThousand)
    #expect(snapshot.monthlyBudgets[month]?.returns == fifteenThousand)
    #expect(snapshot.monthlyBudgets[month]?.netExpense == twentyFiveThousand)
}

@Test func overRefundIsRejectedWithoutChangingState() throws {
    var ledger = try repository()
    let original = try cashExpense(id: "original", amount: 10_000)
    _ = try ledger.commit(original, expectedRevision: 0)
    let excessive = LedgerEntry(
        id: LedgerEntryID(rawValue: "refund"), kind: .adjustment,
        occurredAtUnixMilliseconds: 2,
        postings: [Posting(accountID: bankID, delta: try won(10_001))],
        budgetImpact: BudgetImpact(kind: .return, amount: try won(10_001), attributedMonth: try october()),
        adjustment: AdjustmentLink(originalEntryID: original.id, reason: .refund)
    )
    #expect(throws: LedgerStorageError.invalidEntry(.adjustmentExceedsOriginal(original.id))) {
        try ledger.commit(excessive, expectedRevision: 1)
    }

    let snapshot = try ledger.snapshot()
    let ninetyThousand = try won(90_000)
    #expect(snapshot.revision == 1)
    #expect(snapshot.entries == [original])
    #expect(snapshot.accountBalances[bankID] == ninetyThousand)
}

@Test func commitIsIdempotentByStrongIDAndOptimisticallyLocked() throws {
    var ledger = try repository()
    let original = try cashExpense()
    #expect(try ledger.commit(original, expectedRevision: 0) == .committed(revision: 1))
    #expect(try ledger.commit(original, expectedRevision: 0) == .alreadyCommitted(revision: 1))

    let conflict = try cashExpense(id: original.id.rawValue, amount: 9_000)
    #expect(throws: LedgerStorageError.conflictingEntry(original.id)) {
        try ledger.commit(conflict, expectedRevision: 1)
    }
    #expect(throws: LedgerStorageError.staleRevision(expected: 0, actual: 1)) {
        try ledger.commit(cashExpense(id: "second"), expectedRevision: 0)
    }
    #expect(try ledger.snapshot().entries == [original])
}

@Test func unknownAccountCannotCreateAProjection() throws {
    var ledger = try repository()
    let unknown = AccountID(rawValue: "unknown")
    let entry = LedgerEntry(
        id: LedgerEntryID(rawValue: "unknown-account"), kind: .expense,
        occurredAtUnixMilliseconds: 1,
        postings: [Posting(accountID: unknown, delta: try won(-1_000))],
        budgetImpact: BudgetImpact(kind: .expense, amount: try won(1_000), attributedMonth: try october())
    )
    #expect(throws: LedgerStorageError.invalidEntry(.unknownAccount(unknown))) {
        try ledger.commit(entry, expectedRevision: 0)
    }
    #expect(try ledger.snapshot().revision == 0)
}

@Test func evidenceCannotBeConsumedByTwoLedgerEntries() throws {
    var ledger = try repository()
    let first = try cashExpense(id: "first", amount: 1_000)
    _ = try ledger.commit(first, expectedRevision: 0)
    let second = try cashExpense(id: "second", amount: 2_000)
    #expect(throws: LedgerStorageError.invalidEntry(
        .evidenceAlreadyUsed(id: "notification-1", entryID: first.id)
    )) {
        try ledger.commit(second, expectedRevision: 1)
    }
    #expect(try ledger.snapshot().entries == [first])
}
