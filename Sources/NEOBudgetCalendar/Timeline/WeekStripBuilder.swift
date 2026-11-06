import NEOBudgetCore

/// One cell of the thin week strip above the day timeline.
public struct WeekStripDay: Equatable, Sendable {
    public let day: LocalDate
    /// Events (timed and all-day) that touch this day.
    public let eventCount: Int
    /// Transactions of this day with no portion allocated to an Activity (non-activity spending).
    public let unlinkedTransactionCount: Int
    /// Net spending of all of this day's transactions per currency.
    public let netSpend: [Money]
    /// The events that touch this day: all-day first, then by start. The month grid joins a multi-day event's days into one bar by `key`.
    public let events: [WeekStripEvent]
}

/// One event as the week strip and the month grid need it: enough to draw a bar or a dot, nothing more.
public struct WeekStripEvent: Equatable, Sendable {
    public let key: CalendarEventKey
    public let title: String
    public let isAllDay: Bool
    public let startUnixMilliseconds: Int64
    public let endUnixMilliseconds: Int64
    /// What was spent on the transactions linked to this event (known amounts, minor units of whatever currency; 0 when none). The month grid lists a past
    /// day's events by it.
    public var linkedSpend: Int64 = 0
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
        transactions: [TransactionMarker],
        reductions: [LedgerEntryID: Int64] = [:]
    ) -> [WeekStripDay] {
        let offset = ((day.weekday - firstWeekday) % 7 + 7) % 7
        let first = day.adding(days: -offset)
        let activityByEvent = life.activitiesByEvent()
        var spendByActivity: [ActivityID: Int64] = [:]
        for transaction in transactions where transaction.flow == .spend {
            for allocation in life.allocationSet(for: transaction.id)?.allocations ?? [] {
                if let id = allocation.activityID { spendByActivity[id, default: 0] += allocation.amount.knowledge.bounds.lower }
            }
        }
        return (0..<7).map { index in
            let current = first.adding(days: index)
            let bounds = timeZone.dayBounds(current)
            let dayEvents = events.filter { $0.time.overlaps(from: bounds.start, to: bounds.end, in: timeZone) }.map { event -> WeekStripEvent in
                switch event.time {
                case let .timed(range):
                    return WeekStripEvent(key: event.key, title: event.title, isAllDay: false, startUnixMilliseconds: range.startUnixMilliseconds, endUnixMilliseconds: range.endUnixMilliseconds, linkedSpend: activityByEvent[event.key].flatMap { spendByActivity[$0.id] } ?? 0)
                case let .allDay(range):
                    return WeekStripEvent(key: event.key, title: event.title, isAllDay: true, startUnixMilliseconds: timeZone.startOfDay(range.firstDay), endUnixMilliseconds: timeZone.startOfDay(range.lastDay.adding(days: 1)), linkedSpend: activityByEvent[event.key].flatMap { spendByActivity[$0.id] } ?? 0)
                }
            }.sorted { ($0.isAllDay ? 0 : 1, $0.startUnixMilliseconds, $0.title) < ($1.isAllDay ? 0 : 1, $1.startUnixMilliseconds, $1.title) }
            let eventCount = dayEvents.count
            let ledgerBounds = timeZone.ledgerDayBounds(current)
            let dayTransactions = transactions.filter {
                $0.occurredAtUnixMilliseconds >= ledgerBounds.start && $0.occurredAtUnixMilliseconds < ledgerBounds.end
            }
            var byCurrency: [String: Int64] = [:]
            for transaction in dayTransactions { byCurrency[transaction.amount.currency, default: 0] += transaction.signedMinorUnits - (transaction.flow == .spend ? min(reductions[transaction.id] ?? 0, transaction.amount.minorUnits) : 0) }
            return WeekStripDay(
                day: current,
                eventCount: eventCount,
                unlinkedTransactionCount: dayTransactions.filter { transaction in
                    !(life.allocationSet(for: transaction.id)?.allocations.contains { $0.activityID != nil } ?? false)
                }.count,
                netSpend: byCurrency.keys.sorted().compactMap { try? Money(minorUnits: byCurrency[$0] ?? 0, currency: $0) },
                events: dayEvents
            )
        }
    }
}
