import Foundation
import NEOBudgetCalendar
import NEOBudgetCore

/// What the user changed about a transaction for display: its name, category, memo and tags. The ledger entry and its amount are never touched;
/// this is read next to it (`LedgerList.sections(overrides:)`), so statements and card usage stay as the bank has them.
struct TransactionOverride: Codable, Equatable {
    var title: String?
    var category: CanonicalCategoryID?
    var memo: String?
    var tags: [String] = []

    var isEmpty: Bool { title == nil && category == nil && memo == nil && tags.isEmpty }

    /// A name or memo as typed, trimmed; `nil` when nothing is left.
    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Tags typed as "#데이트 #모임" or "데이트, 모임": trimmed, without the leading "#", no repeats, in the order typed.
    static func parseTags(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// The overrides by transaction, kept as one small file next to the app's data.
struct TransactionOverrideStore: Codable, Equatable {
    var byTransaction: [String: TransactionOverride] = [:]
    /// Transactions the user typed in because no notification came for them. They sit beside the ledger, never in it.
    var manual: [ManualTransaction] = []
    /// Name/category rules (`TransactionRule`), applied to every transaction whose original name they match.
    var rules: [TransactionRule] = []
    /// Every edit the user saved, newest last; data only, it changes nothing on screen.
    var edits: [TransactionEditRecord] = []

    init(byTransaction: [String: TransactionOverride] = [:], manual: [ManualTransaction] = [], rules: [TransactionRule] = [], edits: [TransactionEditRecord] = []) {
        self.byTransaction = byTransaction
        self.manual = manual
        self.rules = rules
        self.edits = edits
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        byTransaction = try values.decodeIfPresent([String: TransactionOverride].self, forKey: .byTransaction) ?? [:]
        manual = try values.decodeIfPresent([ManualTransaction].self, forKey: .manual) ?? []
        rules = try values.decodeIfPresent([TransactionRule].self, forKey: .rules) ?? []
        edits = try values.decodeIfPresent([TransactionEditRecord].self, forKey: .edits) ?? []
    }

    static let editLogLimit = 5_000

    /// Adds an edit to the log, dropping the oldest beyond the limit.
    mutating func record(_ edit: TransactionEditRecord) {
        edits.append(edit)
        if edits.count > Self.editLogLimit { edits.removeFirst(edits.count - Self.editLogLimit) }
    }

    /// The one place that decides what a transaction is called and filed under on the calendar: the user's own edit, else a rule, else the original.
    /// `title` is the original name the ledger has.
    func display(_ id: LedgerEntryID, title: String?, category: CanonicalCategoryID?) -> (title: String?, category: CanonicalCategoryID?) {
        let rule = ruleSet.outcome(forOriginalTitle: title)
        let edit = self[id]
        return (edit?.title ?? rule?.title ?? title, edit?.category ?? rule?.category ?? category)
    }

    var ruleSet: TransactionRuleSet { TransactionRuleSet(rules: rules) }

    /// The typed-in transactions as the list reads them.
    var manualMarkers: [TransactionMarker] {
        manual.compactMap { entry in
            guard let amount = try? Money(minorUnits: entry.amount, currency: "KRW") else { return nil }
            return TransactionMarker(
                id: LedgerEntryID(rawValue: entry.id), occurredAtUnixMilliseconds: entry.occurredAtUnixMilliseconds, amount: amount,
                flow: entry.isRefund ? .refund : .spend, title: entry.title, timePrecision: .exact
            )
        }
    }

    subscript(id: LedgerEntryID) -> TransactionOverride? {
        get { byTransaction[id.rawValue] }
        set { byTransaction[id.rawValue] = (newValue?.isEmpty ?? true) ? nil : newValue }
    }

    var lookup: [LedgerEntryID: TransactionOverride] {
        Dictionary(uniqueKeysWithValues: byTransaction.map { (LedgerEntryID(rawValue: $0.key), $0.value) })
    }

    static func load(from url: URL) -> TransactionOverrideStore {
        guard let data = try? Data(contentsOf: url), let store = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return store
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// A transaction typed in by hand: a positive amount in won, whether it is money coming back, and when it happened.
struct ManualTransaction: Codable, Equatable, Identifiable {
    static let idPrefix = "manual/"

    let id: String
    var title: String
    var amount: Int64
    var isRefund: Bool
    var occurredAtUnixMilliseconds: Int64

    var isManual: Bool { id.hasPrefix(Self.idPrefix) }
}
