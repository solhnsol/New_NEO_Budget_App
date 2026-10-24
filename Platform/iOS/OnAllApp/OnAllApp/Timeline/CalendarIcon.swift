import Foundation
import NEOBudgetCalendar

/// The icon of a calendar: the one the reader picked in settings, else a guess from the calendar's name.
enum CalendarIcon {
    /// What the picker offers, in the order it shows them.
    static let choices: [String] = [
        "calendar", "house", "person.2", "graduationcap", "briefcase", "dumbbell", "airplane", "flag",
        "heart", "cart", "fork.knife", "cup.and.saucer", "book", "gamecontroller", "music.note", "pawprint",
    ]

    private static let rules: [(words: [String], symbol: String)] = [
        (["학교", "수업", "강의", "공부", "학업"], "graduationcap"),
        (["약속", "모임", "친구", "데이트", "가족"], "person.2"),
        (["일상", "생활", "개인", "집"], "house"),
        (["회사", "업무", "직장", "알바", "근무", "일정"], "briefcase"),
        (["운동", "헬스", "건강"], "dumbbell"),
        (["여행", "휴가"], "airplane"),
        (["구독", "공휴일", "휴일", "기념일", "생일"], "flag"),
    ]

    static func guess(forCalendar title: String?) -> String {
        guard let title else { return "calendar" }
        return rules.first { rule in rule.words.contains { title.contains($0) } }?.symbol ?? "calendar"
    }

    /// The symbol to draw: the picked one, else the guess.
    static func symbol(picked: String?, title: String?) -> String { picked ?? guess(forCalendar: title) }
}

/// The icons picked in settings, by calendar. Kept on the device; the calendar itself has nowhere to hold one.
struct CalendarIconStore: Equatable {
    private(set) var picked: [String: String] = [:]

    func symbol(for id: CalendarID) -> String? { picked[id.rawValue] }

    mutating func set(_ symbol: String?, for id: CalendarID) { picked[id.rawValue] = symbol }

    static func load(key: String, defaults: UserDefaults = .standard) -> CalendarIconStore {
        guard let data = defaults.data(forKey: key), let picked = try? JSONDecoder().decode([String: String].self, from: data) else { return CalendarIconStore() }
        return CalendarIconStore(picked: picked)
    }

    func save(key: String, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(picked), forKey: key)
    }
}
