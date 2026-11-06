/// How one week of the month grid (or the open week strip) draws its events: bars that run across the days of a multi-day event, in at most `lanes`
/// rows, and for what does not fit, the calendars to show as dots under them. Pure, so it is tested here and drawn in the app.
public struct MonthWeekLayout: Equatable, Sendable {
    public struct Bar: Equatable, Sendable {
        public let event: WeekStripEvent
        /// Columns 0...6 of the week, inclusive.
        public let firstColumn: Int
        public let lastColumn: Int
        public let lane: Int
    }

    public let bars: [Bar]
    /// Per column: the events that got no bar, in order.
    public let overflow: [[WeekStripEvent]]

    /// `week` is the seven days in column order.
    public init(week: [WeekStripDay], lanes: Int = 2) {
        var spans: [CalendarEventKey: (event: WeekStripEvent, first: Int, last: Int)] = [:]
        for (column, day) in week.enumerated() {
            for event in day.events {
                if let span = spans[event.key] { spans[event.key] = (span.event, span.first, column) } else { spans[event.key] = (event, column, column) }
            }
        }
        // Longest first from the left edge, so a run across the week keeps one lane and the short ones stack under it.
        let ordered = spans.values.sorted {
            ($0.first, $1.last - $1.first, $0.event.isAllDay ? 0 : 1, $0.event.startUnixMilliseconds, $0.event.title)
                < ($1.first, $0.last - $0.first, $1.event.isAllDay ? 0 : 1, $1.event.startUnixMilliseconds, $1.event.title)
        }
        var laneEnds = [Int](repeating: -1, count: lanes)
        var bars: [Bar] = []
        var overflow = [[WeekStripEvent]](repeating: [], count: week.count)
        for span in ordered {
            if let lane = laneEnds.firstIndex(where: { $0 < span.first }) {
                laneEnds[lane] = span.last
                bars.append(Bar(event: span.event, firstColumn: span.first, lastColumn: span.last, lane: lane))
            } else {
                for column in span.first...span.last { overflow[column].append(span.event) }
            }
        }
        for column in overflow.indices { overflow[column].sort { ($0.isAllDay ? 0 : 1, $0.startUnixMilliseconds) < ($1.isAllDay ? 0 : 1, $1.startUnixMilliseconds) } }
        self.bars = bars
        self.overflow = overflow
    }
}
