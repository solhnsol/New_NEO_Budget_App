import Foundation

/// 하루 시작 시각: transactions before this time count as the day before (default 04:00). Stored as minutes after midnight.
enum DayStartSetting {
    static let key = "ledger.dayStartMinutes"
    static let defaultMinutes = 4 * 60
    static let hours = Array(0...6)

    static func current(_ defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: key) == nil ? defaultMinutes : min(max(defaults.integer(forKey: key), 0), 6 * 60)
    }
}
