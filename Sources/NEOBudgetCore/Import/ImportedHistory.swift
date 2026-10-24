import Foundation

public enum ImportedHistoryError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidTimeZone(String)
    case invalidDate(String)
}

/// What kind of money holder an imported account is. A card is the only one that is a liability.
public enum ImportedAccountKind: String, Codable, Sendable {
    case bank
    case prepaid
    case card
}

public struct ImportedAccount: Codable, Equatable, Sendable {
    public let name: String
    public let kind: ImportedAccountKind
    /// Actual's "on budget" flag. An off-budget account is still imported; a transfer into one is what Actual asks the
    /// user to categorise.
    public let onBudget: Bool
    /// The balance Actual showed when the file was made (a card's is negative). Only used to check the import.
    public let balance: Int64?

    public init(name: String, kind: ImportedAccountKind, onBudget: Bool = true, balance: Int64? = nil) {
        self.name = name
        self.kind = kind
        self.onBudget = onBudget
        self.balance = balance
    }

    private enum CodingKeys: String, CodingKey {
        case name, kind, balance
        case onBudget = "on_budget"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: values.decode(String.self, forKey: .name),
            kind: values.decodeIfPresent(ImportedAccountKind.self, forKey: .kind) ?? .bank,
            onBudget: values.decodeIfPresent(Bool.self, forKey: .onBudget) ?? true,
            balance: values.decodeIfPresent(Int64.self, forKey: .balance)
        )
    }
}

/// One Actual transaction, in the shape Actual's `list_transactions` returns it (children of a split are separate rows,
/// the parent is not). Whole won, expense negative.
public struct ImportedTransaction: Codable, Equatable, Sendable {
    public let id: String
    /// `YYYY-MM-DD`. Actual keeps no time of day.
    public let date: String
    public let account: String
    public let amount: Int64
    public let payee: String?
    public let category: String?
    public let notes: String?
    /// The name the notification carried. For a settlement deposit it can be a person's name and is never read.
    public let importedPayee: String?
    /// `→ 계좌` on the sending side, `← 계좌` on the receiving side.
    public let transfer: String?

    public init(
        id: String, date: String, account: String, amount: Int64, payee: String? = nil, category: String? = nil,
        notes: String? = nil, importedPayee: String? = nil, transfer: String? = nil
    ) {
        self.id = id
        self.date = date
        self.account = account
        self.amount = amount
        self.payee = payee
        self.category = category
        self.notes = notes
        self.importedPayee = importedPayee
        self.transfer = transfer
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, account, amount, payee, category, notes, transfer
        case importedPayee = "imported_payee"
    }
}

/// The file the phone is given (`imported-history.json`): an Actual Budget ledger as Actual has it, with no OnAll policy
/// applied. Real financial data: it lives only on the device and in the project's private files, never in git.
/// `ActualImportPlanner` decides what each row means for OnAll.
public struct ImportedHistory: Codable, Equatable, Sendable {
    public static let supportedVersion = 1

    public let version: Int
    public let source: String
    public let timeZone: String
    /// `YYYY-MM-DD`, the last day this file covers. Live notifications from the next day 00:00 on are the ledger's own;
    /// earlier ones are already in these rows (`docs/actual-budget-import.md`, Q4).
    public let through: String
    public let accounts: [ImportedAccount]
    public let transactions: [ImportedTransaction]

    public init(
        version: Int = ImportedHistory.supportedVersion, source: String = "actual", timeZone: String = "Asia/Seoul",
        through: String, accounts: [ImportedAccount], transactions: [ImportedTransaction]
    ) {
        self.version = version
        self.source = source
        self.timeZone = timeZone
        self.through = through
        self.accounts = accounts
        self.transactions = transactions
    }

    public static func decode(_ data: Data) throws -> ImportedHistory {
        let history = try JSONDecoder().decode(ImportedHistory.self, from: data)
        guard history.version == supportedVersion else { throw ImportedHistoryError.unsupportedVersion(history.version) }
        _ = try history.cutoverUnixMilliseconds()
        return history
    }

    /// The first instant the live notifications count: the day after `through`, 00:00 in the history's zone.
    public func cutoverUnixMilliseconds() throws -> Int64 {
        let day = try Self.startOfDay(through, zone: timeZone)
        guard let next = Self.calendar(zone: timeZone).date(byAdding: .day, value: 1, to: day) else {
            throw ImportedHistoryError.invalidDate(through)
        }
        return Int64((next.timeIntervalSince1970 * 1_000).rounded())
    }

    /// Noon of `date` in the history's zone: Actual keeps only the day, and noon keeps it the same day in any nearby zone.
    func noonUnixMilliseconds(of date: String) throws -> Int64 {
        let start = try Self.startOfDay(date, zone: timeZone)
        return Int64((start.timeIntervalSince1970 * 1_000).rounded()) + 12 * 3_600_000
    }

    static func calendar(zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func startOfDay(_ date: String, zone: String) throws -> Date {
        guard TimeZone(identifier: zone) != nil else { throw ImportedHistoryError.invalidTimeZone(zone) }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, date.count == 10 else { throw ImportedHistoryError.invalidDate(date) }
        let calendar = calendar(zone: zone)
        guard let result = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.dateComponents([.year, .month, .day], from: result) == DateComponents(year: parts[0], month: parts[1], day: parts[2]) else {
            throw ImportedHistoryError.invalidDate(date)
        }
        return result
    }
}
