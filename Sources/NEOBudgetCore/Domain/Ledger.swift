public struct AccountID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct CreditInstrumentID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct LedgerEntryID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum MoneyError: Error, Equatable, Sendable {
    case invalidCurrency(String)
    case overflow
}

/// An exact amount in the currency's smallest unit. Floating-point money is never used.
public struct Money: Codable, Hashable, Sendable {
    public let minorUnits: Int64
    public let currency: String

    public init(minorUnits: Int64, currency: String) throws {
        guard currency.utf8.count == 3,
              currency.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else {
            throw MoneyError.invalidCurrency(currency)
        }
        self.minorUnits = minorUnits
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey {
        case minorUnits
        case currency
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minorUnits: values.decode(Int64.self, forKey: .minorUnits),
            currency: values.decode(String.self, forKey: .currency)
        )
    }

    public func adding(_ other: Money) throws -> Money {
        guard currency == other.currency else {
            throw LedgerValidationError.currencyMismatch(expected: currency, actual: other.currency)
        }
        let (sum, overflow) = minorUnits.addingReportingOverflow(other.minorUnits)
        guard !overflow else { throw MoneyError.overflow }
        return try Money(minorUnits: sum, currency: currency)
    }

    public func negated() throws -> Money {
        let (value, overflow) = minorUnits.multipliedReportingOverflow(by: -1)
        guard !overflow else { throw MoneyError.overflow }
        return try Money(minorUnits: value, currency: currency)
    }
}

public struct BudgetMonth: Codable, Hashable, Sendable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) throws {
        guard (1...12).contains(month) else {
            throw LedgerValidationError.invalidBudgetMonth(year: year, month: month)
        }
        self.year = year
        self.month = month
    }

    private enum CodingKeys: String, CodingKey {
        case year
        case month
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            year: values.decode(Int.self, forKey: .year),
            month: values.decode(Int.self, forKey: .month)
        )
    }
}

public struct Account: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bank
        case cash
        case prepaid
    }

    public let id: AccountID
    public let name: String
    public let kind: Kind
    public let openingBalance: Money
    public let isActive: Bool

    public init(id: AccountID, name: String, kind: Kind, openingBalance: Money, isActive: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.openingBalance = openingBalance
        self.isActive = isActive
    }
}

public struct CreditInstrument: Codable, Equatable, Sendable {
    public let id: CreditInstrumentID
    public let name: String
    public let currency: String
    public let isActive: Bool

    public init(id: CreditInstrumentID, name: String, currency: String, isActive: Bool = true) throws {
        _ = try Money(minorUnits: 0, currency: currency)
        self.id = id
        self.name = name
        self.currency = currency
        self.isActive = isActive
    }
}

/// A signed change to money already held in an account.
public struct Posting: Codable, Equatable, Sendable {
    public let accountID: AccountID
    public let delta: Money

    public init(accountID: AccountID, delta: Money) {
        self.accountID = accountID
        self.delta = delta
    }
}

/// A signed change to an unpaid card obligation. Positive creates debt; negative settles it.
public struct LiabilityChange: Codable, Equatable, Sendable {
    public let instrumentID: CreditInstrumentID
    public let delta: Money

    public init(instrumentID: CreditInstrumentID, delta: Money) {
        self.instrumentID = instrumentID
        self.delta = delta
    }
}

/// Consumption reporting is intentionally independent from the date cash moved.
public struct BudgetImpact: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case expense
        case `return`
    }

    public let kind: Kind
    public let amount: Money
    public let attributedMonth: BudgetMonth

    public init(kind: Kind, amount: Money, attributedMonth: BudgetMonth) {
        self.kind = kind
        self.amount = amount
        self.attributedMonth = attributedMonth
    }
}

public struct AdjustmentLink: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case cancellation
        case refund
    }

    public let originalEntryID: LedgerEntryID
    public let reason: Reason

    public init(originalEntryID: LedgerEntryID, reason: Reason) {
        self.originalEntryID = originalEntryID
        self.reason = reason
    }
}

public struct LedgerEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case expense
        case income
        case transfer
        case cardPayment
        case adjustment
    }

    public let id: LedgerEntryID
    public let kind: Kind
    public let occurredAtUnixMilliseconds: Int64
    public let postings: [Posting]
    public let liabilityChanges: [LiabilityChange]
    public let budgetImpact: BudgetImpact?
    public let adjustment: AdjustmentLink?
    public let evidenceIDs: [String]

    public init(
        id: LedgerEntryID,
        kind: Kind,
        occurredAtUnixMilliseconds: Int64,
        postings: [Posting] = [],
        liabilityChanges: [LiabilityChange] = [],
        budgetImpact: BudgetImpact? = nil,
        adjustment: AdjustmentLink? = nil,
        evidenceIDs: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.occurredAtUnixMilliseconds = occurredAtUnixMilliseconds
        self.postings = postings
        self.liabilityChanges = liabilityChanges
        self.budgetImpact = budgetImpact
        self.adjustment = adjustment
        self.evidenceIDs = evidenceIDs
    }
}

public enum LedgerValidationError: Error, Equatable, Sendable {
    case invalidBudgetMonth(year: Int, month: Int)
    case invalidCurrency(String)
    case arithmeticOverflow
    case emptyIdentifier(entity: String)
    case duplicateIdentifier(entity: String, id: String)
    case unknownAccount(AccountID)
    case unknownCreditInstrument(CreditInstrumentID)
    case inactiveAccount(AccountID)
    case inactiveCreditInstrument(CreditInstrumentID)
    case currencyMismatch(expected: String, actual: String)
    case zeroDelta(entity: String)
    case invalidEntryShape(kind: LedgerEntry.Kind)
    case invalidBudgetImpact
    case originalEntryNotFound(LedgerEntryID)
    case adjustmentTargetIsNotExpense(LedgerEntryID)
    case adjustmentMonthMismatch
    case adjustmentExceedsOriginal(LedgerEntryID)
    case evidenceAlreadyUsed(id: String, entryID: LedgerEntryID)
}
