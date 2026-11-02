import Foundation

// The day a payment counts for in budgets and analysis (docs: records/20261102-분석-예산-탭-설계.md §12.4).
// The ledger date and time are never changed; this only decides which day the money was "spent" on.

/// A timed event that runs past midnight (a gathering that ends at 04:00). All-day events never qualify.
public struct OvernightEvent: Equatable, Sendable {
    public let startDate: LocalDate
    public let endDate: LocalDate
    public let durationMinutes: Int
    public let isAllDay: Bool

    public init(startDate: LocalDate, endDate: LocalDate, durationMinutes: Int, isAllDay: Bool) {
        self.startDate = startDate
        self.endDate = endDate
        self.durationMinutes = durationMinutes
        self.isAllDay = isAllDay
    }
}

public struct ConsumptionDateRule: Equatable, Sendable {
    /// Payments before this minute of the day count for the day before. 0 turns the rule off. Settings allow 0–6 hours.
    public var cutoffMinutes: Int
    public var groupOvernightEvents: Bool
    /// Longer events (a trip) are not pulled onto their first day, or daily totals would break.
    public var maxEventMinutes: Int

    public init(cutoffMinutes: Int = 120, groupOvernightEvents: Bool = true, maxEventMinutes: Int = 12 * 60) {
        self.cutoffMinutes = min(max(cutoffMinutes, 0), 6 * 60)
        self.groupOvernightEvents = groupOvernightEvents
        self.maxEventMinutes = maxEventMinutes
    }
}

public enum ConsumptionDate {
    /// 1. A payment inside a qualifying overnight event counts on the event's start day.
    /// 2. Otherwise a payment before the cutoff counts on the previous day.
    /// 3. No time of day: the ledger date.
    public static func resolve(date: LocalDate, minuteOfDay: Int?, event: OvernightEvent? = nil, rule: ConsumptionDateRule = ConsumptionDateRule()) -> LocalDate {
        if rule.groupOvernightEvents, let event, !event.isAllDay, event.endDate > event.startDate, event.durationMinutes <= rule.maxEventMinutes,
           date >= event.startDate, date <= event.endDate {
            return event.startDate
        }
        if let minuteOfDay, minuteOfDay < rule.cutoffMinutes { return date.adding(days: -1) }
        return date
    }
}
