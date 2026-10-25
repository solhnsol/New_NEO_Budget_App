import NEOBudgetCalendar

/// One day of the calendar read as a list instead of a grid: the all-day events, then the events and the stretches of ordinary life between them, in
/// the order they happen. A stretch with transactions no event holds is one "일상" group, so every transaction sits inside some box. Pure, so it is
/// tested; `DayListView` draws it.
struct DayListPlan: Equatable {
    enum Item: Equatable, Identifiable {
        case allDay(AllDayItem)
        case event(EventBlock)
        /// The transactions of one stretch between events that no activity wholly holds (they may still be partly linked).
        case daily(DailyGroup)

        var id: String {
            switch self {
            case let .allDay(item): "allday/" + item.id.rawValue
            case let .event(block): "event/" + block.id.rawValue
            case let .daily(group): "daily/" + group.id
            }
        }
    }

    /// The ordinary life between two events (or the day's edges): its transactions, and the stretch of the day it covers, in whole minutes from the
    /// start of the day. `fromMinute` is where the event before ended (0 at the day's start), `toMinute` where the one after begins (the day's end).
    struct DailyGroup: Equatable {
        let markers: [TransactionMarkerItem]
        let fromMinute: Int
        let toMinute: Int
        var id: String { markers.first?.transactionID.rawValue ?? "" }
    }

    let items: [Item]

    static func make(_ timeline: DayTimeline) -> DayListPlan {
        let blocks = timeline.blocks.sorted { ($0.startMinute, $0.id.rawValue) < ($1.startMinute, $1.id.rawValue) }
        let markers = timeline.markers.sorted { ($0.positionMinute, $0.transactionID.rawValue) < ($1.positionMinute, $1.transactionID.rawValue) }
        // Transactions are cut into stretches wherever an event begins between two of them; each stretch is one 일상 group.
        var stretches: [[TransactionMarkerItem]] = []
        var open: [TransactionMarkerItem] = []
        for marker in markers {
            if let last = open.last, blocks.contains(where: { $0.startMinute > last.positionMinute && $0.startMinute <= marker.positionMinute }) {
                stretches.append(open)
                open = []
            }
            open.append(marker)
        }
        if !open.isEmpty { stretches.append(open) }
        let groups: [(minute: Int, item: Item)] = stretches.map { stretch in
            let first = stretch[0].positionMinute
            let last = stretch[stretch.count - 1].positionMinute
            let from = blocks.filter { $0.startMinute <= first }.map(\.endMinute).max().map { min($0, first) } ?? 0
            let to = blocks.filter { $0.startMinute > last }.map(\.startMinute).min() ?? timeline.totalMinutes
            return (first, .daily(DailyGroup(markers: stretch, fromMinute: from, toMinute: max(to, last))))
        }
        let timed: [(minute: Int, rank: Int, tie: String, item: Item)] =
            blocks.map { ($0.startMinute, 0, $0.id.rawValue, .event($0)) } + groups.map { ($0.minute, 1, $0.item.id, $0.item) }
        let ordered = timed.sorted { ($0.minute, $0.rank, $0.tie) < ($1.minute, $1.rank, $1.tie) }.map(\.item)
        let allDay = timeline.allDay.sorted { $0.id < $1.id }.map(Item.allDay)
        return DayListPlan(items: allDay + ordered)
    }
}
