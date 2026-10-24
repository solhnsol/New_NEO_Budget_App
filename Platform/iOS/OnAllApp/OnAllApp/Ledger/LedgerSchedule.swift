import NEOBudgetCalendar
import NEOBudgetCore

/// One line of the schedule-style ledger for a day: an activity with the transactions that went to it, or a transaction no activity holds.
enum LedgerScheduleItem: Identifiable, Equatable {
    struct Group: Equatable {
        let activityID: ActivityID
        let title: String
        let time: EventTimeRange?
        let entries: [LedgerListEntry]

        /// Net spending of the group's transactions (refunds and settlements already taken off).
        var totalMinorUnits: Int64 { entries.reduce(0) { $0 + $1.signedNetMinorUnits } }
        var currency: String { entries.first?.transaction.amount.currency ?? "KRW" }
    }

    case activity(Group)
    case loose(LedgerListEntry)

    var id: String {
        switch self {
        case let .activity(group): "activity/" + group.activityID.rawValue
        case let .loose(entry): "entry/" + entry.id.rawValue
        }
    }
}

/// Arranges a day's ledger entries the way the calendar shows the day: activities as cards holding their transactions, the rest as plain lines,
/// all in the order things happened. A transaction split over several activities goes under the first of them (its first allocation).
enum LedgerSchedule {
    static func items(_ section: LedgerDaySection, zone: DisplayTimeZone) -> [LedgerScheduleItem] {
        var order: [ActivityID] = []
        var grouped: [ActivityID: (title: String, time: EventTimeRange?, entries: [LedgerListEntry])] = [:]
        var keyed: [(key: Int64, tie: String, item: LedgerScheduleItem)] = []

        for entry in section.entries {
            guard let portion = entry.portions.first(where: { $0.activityID != nil }), let id = portion.activityID else {
                keyed.append((entry.transaction.occurredAtUnixMilliseconds, entry.id.rawValue, .loose(entry)))
                continue
            }
            if grouped[id] == nil {
                order.append(id)
                grouped[id] = (portion.activityTitle ?? "일정", portion.activityTime, [])
            }
            grouped[id]?.entries.append(entry)
        }
        for id in order {
            guard let value = grouped[id] else { continue }
            let entries = value.entries.sorted { $0.transaction.occurredAtUnixMilliseconds < $1.transaction.occurredAtUnixMilliseconds }
            let key = start(of: value.time, zone: zone) ?? entries.first?.transaction.occurredAtUnixMilliseconds ?? 0
            keyed.append((key, id.rawValue, .activity(.init(activityID: id, title: value.title, time: value.time, entries: entries))))
        }
        return keyed.sorted { ($0.key, $0.tie) < ($1.key, $1.tie) }.map(\.item)
    }

    /// The first instant of a timed or all-day range.
    static func start(of time: EventTimeRange?, zone: DisplayTimeZone) -> Int64? {
        switch time {
        case let .timed(range)?: range.startUnixMilliseconds
        case let .allDay(range)?: zone.startOfDay(range.firstDay)
        case nil: nil
        }
    }

    /// A week's day totals for the strip: net spending per day, per the first currency of the day.
    static func dayTotal(_ section: LedgerDaySection?) -> Int64? {
        section?.totals.first?.minorUnits
    }

    /// "4.9만" for round-ish ten-thousands, "1,990" below that, "-" for nothing.
    static func compactAmount(_ won: Int64?) -> String {
        guard let won, won != 0 else { return "-" }
        let magnitude = abs(won)
        let sign = won < 0 ? "+" : ""
        if magnitude >= 10_000 {
            let tenths = (magnitude * 10 + 5_000) / 10_000
            let text = tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
            return sign + text + "만"
        }
        return sign + Formatting.grouped(magnitude)
    }
}
