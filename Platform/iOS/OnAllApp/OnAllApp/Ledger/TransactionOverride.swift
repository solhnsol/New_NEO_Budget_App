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
