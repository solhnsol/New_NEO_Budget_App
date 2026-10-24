import NEOBudgetCalendar

/// One day of the calendar read as a list instead of a grid: the all-day events, then the events and the transactions no event holds, in the
/// order they happen. Pure, so it is tested; `DayListView` draws it.
struct DayListPlan: Equatable {
    enum Item: Equatable, Identifiable {
        case allDay(AllDayItem)
        case event(EventBlock)
        /// A transaction of the day that no activity wholly holds (it may still be partly linked).
        case marker(TransactionMarkerItem)

        var id: String {
            switch self {
            case let .allDay(item): "allday/" + item.id.rawValue
            case let .event(block): "event/" + block.id.rawValue
            case let .marker(marker): "marker/" + marker.transactionID.rawValue
            }
        }
    }

    let items: [Item]

    static func make(_ timeline: DayTimeline) -> DayListPlan {
        let timed: [(minute: Int, rank: Int, tie: String, item: Item)] =
            timeline.blocks.map { ($0.startMinute, 0, $0.id.rawValue, .event($0)) }
            + timeline.markers.map { ($0.positionMinute, 1, $0.transactionID.rawValue, .marker($0)) }
        let ordered = timed.sorted { ($0.minute, $0.rank, $0.tie) < ($1.minute, $1.rank, $1.tie) }.map(\.item)
        let allDay = timeline.allDay.sorted { $0.id < $1.id }.map(Item.allDay)
        return DayListPlan(items: allDay + ordered)
    }
}
