import NEOBudgetCore

/// One cell of the thin week strip above the day timeline.
public struct WeekStripDay: Equatable, Sendable {
    public let day: LocalDate
    /// Events (timed and all-day) that touch this day.
    public let eventCount: Int
    /// Transactions of this day with no Activity (non-activity spending).
    public let unlinkedTransactionCount: Int
    /// Net spending of all of this day's transactions per currency.
    public let netSpend: [Money]
}

/// Builds the seven days around a selected day. Pure, like the day timeline.
public enum WeekStripBuilder {
    /// `firstWeekday` uses 0 = Sunday … 6 = Saturday.
    public static func build(
        containing day: LocalDate,
        firstWeekday: Int = 0,
        timeZone: DisplayTimeZone,
        events: [CalendarEvent],
        life: LifeState,
        transactions: [TransactionMarker]
    ) -> [WeekStripDay] {
        let offset = ((day.weekday - firstWeekday) % 7 + 7) % 7
        let first = day.adding(days: -offset)
        return (0..<7).map { index in
            let current = first.adding(days: index)
            let bounds = timeZone.dayBounds(current)
            let eventCount = events.filter { $0.time.overlaps(from: bounds.start, to: bounds.end, in: timeZone) }.count
            let dayTransactions = transactions.filter {
                $0.occurredAtUnixMilliseconds >= bounds.start && $0.occurredAtUnixMilliseconds < bounds.end
            }
            var byCurrency: [String: Int64] = [:]
            for transaction in dayTransactions { byCurrency[transaction.amount.currency, default: 0] += transaction.signedMinorUnits }
            return WeekStripDay(
                day: current,
                eventCount: eventCount,
                unlinkedTransactionCount: dayTransactions.filter { life.link(for: $0.id) == nil }.count,
                netSpend: byCurrency.keys.sorted().compactMap { try? Money(minorUnits: byCurrency[$0] ?? 0, currency: $0) }
            )
        }
    }
}
