import Foundation
import NEOBudgetCalendar

/// A rule that looks at a transaction's original name (as the bank or card reported it) and, when it matches, renames and/or categorizes it for display.
/// Rules never touch the ledger; they are read when the list is built, so deleting a rule gives the original back.
///
/// The shape is deliberately open: a match is a name test (exact, contains, regex) and what it does is an ordered list of actions, so new kinds of
/// either can be added later (for example rules a model proposes) without changing what is already saved.
struct TransactionRule: Codable, Equatable, Identifiable {
    enum MatchMode: String, Codable, CaseIterable {
        case exact, contains, regex
    }

    enum Action: Codable, Equatable {
        /// The name shown becomes this, replacing whatever the earlier actions made of it.
        case setTitle(String)
        /// Edits the name as it stands: a plain text swap, or a regex swap where `with` may use `$1`-style groups. An empty `with` deletes the match.
        case replace(find: String, with: String, isRegex: Bool)
        case setCategory(CanonicalCategoryID)
        case addTags([String])
    }

    var id: String
    /// An optional label for the rule list ("교통 카드"); never used for matching.
    var label: String?
    var mode: MatchMode
    var pattern: String
    var actions: [Action]
    var isEnabled = true
    var createdAtUnixMilliseconds: Int64

    /// Whether the rule can ever match: it has something to look for and, for a regex, the pattern compiles.
    var isValid: Bool {
        let text = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        if mode == .regex, (try? NSRegularExpression(pattern: pattern)) == nil { return false }
        return actions.allSatisfy { action in
            if case let .replace(find, _, isRegex) = action {
                return !find.isEmpty && (!isRegex || (try? NSRegularExpression(pattern: find)) != nil)
            }
            return true
        }
    }

    func matches(_ title: String) -> Bool {
        guard isEnabled, isValid else { return false }
        switch mode {
        case .exact: return Self.normalize(title) == Self.normalize(pattern)
        case .contains: return Self.normalize(title).contains(Self.normalize(pattern))
        case .regex:
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return expression.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
        }
    }

    /// Lower rank is applied first, so the higher ones have the last word: exact over regex over contains, then the longer pattern, then the newer rule.
    fileprivate var rank: (Int, Int, Int64, String) {
        let modeRank: Int
        switch mode {
        case .contains: modeRank = 0
        case .regex: modeRank = 1
        case .exact: modeRank = 2
        }
        return (modeRank, pattern.count, createdAtUnixMilliseconds, id)
    }

    /// Case, surrounding space and runs of space do not matter when names are compared.
    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// What the rules decided for one name. A field is `nil` when no matching rule touched it.
struct RuleOutcome: Equatable {
    var title: String?
    var category: CanonicalCategoryID?
    var tags: [String] = []
}

struct TransactionRuleSet: Equatable {
    var rules: [TransactionRule] = []

    /// The matching rules, lowest priority first.
    func matching(_ title: String) -> [TransactionRule] {
        rules.filter { $0.matches(title) }.sorted { $0.rank < $1.rank }
    }

    /// Applies every matching rule in priority order: names are rewritten step by step, the last category set wins, tags are collected.
    /// `nil` when nothing matched or nothing changed.
    func outcome(forOriginalTitle original: String?) -> RuleOutcome? {
        guard let original, !original.isEmpty else { return nil }
        let matched = matching(original)
        guard !matched.isEmpty else { return nil }
        var working = original
        var outcome = RuleOutcome()
        for rule in matched {
            for action in rule.actions {
                switch action {
                case let .setTitle(title):
                    if let cleaned = TransactionOverride.clean(title) { working = cleaned }
                case let .replace(find, replacement, isRegex):
                    working = Self.replacing(find, with: replacement, isRegex: isRegex, in: working)
                case let .setCategory(category):
                    outcome.category = category
                case let .addTags(tags):
                    for tag in TransactionOverride.parseTags(tags.joined(separator: " ")) where !outcome.tags.contains(tag) { outcome.tags.append(tag) }
                }
            }
        }
        if working != original { outcome.title = working }
        return outcome.title == nil && outcome.category == nil && outcome.tags.isEmpty ? nil : outcome
    }

    /// How many of these names the rule would match: the preview when writing a rule.
    static func matchCount(_ rule: TransactionRule, in titles: [String]) -> Int {
        var enabled = rule
        enabled.isEnabled = true
        return titles.filter { enabled.matches($0) }.count
    }

    /// The text with the swap done; the text before when the swap would leave nothing.
    static func replacing(_ find: String, with replacement: String, isRegex: Bool, in text: String) -> String {
        let result: String
        if isRegex {
            guard let expression = try? NSRegularExpression(pattern: find, options: [.caseInsensitive]) else { return text }
            result = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        } else {
            result = text.replacingOccurrences(of: find, with: replacement, options: .caseInsensitive)
        }
        let cleaned = result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return cleaned.isEmpty ? text : cleaned
    }
}

/// One edit the user made, kept as data (what the name was, what they made of it). Nothing here changes how transactions look; it is the record
/// that rules, by hand or by a model, can later be drawn from.
struct TransactionEditRecord: Codable, Equatable, Identifiable {
    var id: String
    var transactionID: String
    var originalTitle: String?
    var title: String?
    var category: CanonicalCategoryID?
    var memo: String?
    var tags: [String] = []
    var atUnixMilliseconds: Int64
}
