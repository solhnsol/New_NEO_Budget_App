public struct LedgerConfiguration: Codable, Equatable, Sendable {
    public let accounts: [Account]
    public let creditInstruments: [CreditInstrument]

    public init(accounts: [Account] = [], creditInstruments: [CreditInstrument] = []) {
        self.accounts = accounts
        self.creditInstruments = creditInstruments
    }
}

public struct MonthlyBudgetSummary: Codable, Equatable, Sendable {
    public let expense: Money
    public let returns: Money
    public let netExpense: Money

    public init(expense: Money, returns: Money, netExpense: Money) {
        self.expense = expense
        self.returns = returns
        self.netExpense = netExpense
    }
}

public struct LedgerSnapshot: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let entries: [LedgerEntry]
    public let accountBalances: [AccountID: Money]
    public let outstandingLiabilities: [CreditInstrumentID: Money]
    public let monthlyBudgets: [BudgetMonth: MonthlyBudgetSummary]

    public init(
        revision: UInt64,
        entries: [LedgerEntry],
        accountBalances: [AccountID: Money],
        outstandingLiabilities: [CreditInstrumentID: Money],
        monthlyBudgets: [BudgetMonth: MonthlyBudgetSummary]
    ) {
        self.revision = revision
        self.entries = entries
        self.accountBalances = accountBalances
        self.outstandingLiabilities = outstandingLiabilities
        self.monthlyBudgets = monthlyBudgets
    }
}

public enum LedgerCommitResult: Equatable, Sendable {
    case committed(revision: UInt64)
    case alreadyCommitted(revision: UInt64)
}

public enum LedgerStorageError: Error, Equatable, Sendable {
    case conflictingEntry(LedgerEntryID)
    case staleRevision(expected: UInt64, actual: UInt64)
    case revisionOverflow
    case invalidConfiguration(LedgerValidationError)
    case invalidEntry(LedgerValidationError)
}

/// Atomic storage boundary for validated financial facts.
/// Failed commits must leave both the revision and every projection unchanged.
public protocol LedgerRepository {
    func snapshot() throws -> LedgerSnapshot
    mutating func commit(_ entry: LedgerEntry, expectedRevision: UInt64) throws -> LedgerCommitResult
}
