import NEOBudgetCalendar

/// Which days must already be read when the window of days is somewhere between two days, and how far ahead of a move to read them.
///
/// A window whose first day is `D` shows `D ... D+1` and plans for `D-1 ... D+2` (the day before, the two shown, the day after). Between two days (position `p`,
/// `floor(p) < p < floor(p) + 1`) both windows `floor(p)` and `floor(p) + 1` are in use, so the days needed are `floor(p) - 1 ... floor(p) + 3`. A move that is heading
/// for day `t` (a flight, or a swipe that was let go) needs everything between where it is and `t`. These are **epoch days** (`LocalDate.daysSinceUnixEpoch`) as
/// `Double`/`Int`, the same unit `DayMoveModel` positions are in when its bounds are epoch days.
///
/// The **hop** is how many days one swipe may carry the window from the day that is selected. Browse starts at **1** (a swipe never skips a day, as now). The cache keeps
/// `hop + 1` days beyond the required ones on each side (one more than the window can be carried, so a drag a little past the last day still has its days), and a move
/// that has come to rest reads ahead to fill that margin, so the next move already finds its days there. A drag is limited to `hop` days from the selected day
/// (`clampedPosition`), which is what keeps every position inside what is kept.
struct DayPrefetchPolicy: Equatable {
    var maximumHop = 1

    static let browse = DayPrefetchPolicy()

    /// The cache policy that holds every day a window within `maximumHop` days of the selected one can need.
    var cachePolicy: DayCachePolicy {
        let margin = maximumHop + 1
        var policy = DayCachePolicy.standard
        policy.margin = margin
        policy.capacity = (policy.before + policy.after + 1) + 2 * margin + 4
        return policy
    }

    /// How many days beyond the required ones to read ahead at rest (`AppModel.loadMissing(extra:)`).
    var readAhead: Int { maximumHop + 1 }

    /// The days needed at `position`, and on the way to `target` if there is one.
    static func neededDays(position: Double, target: Int? = nil) -> ClosedRange<Int> {
        let low = min(position, target.map(Double.init) ?? position)
        let high = max(position, target.map(Double.init) ?? position)
        return (Int(low.rounded(.down)) - 1)...(Int(high.rounded(.up)) + 2)
    }

    /// A position held to `maximumHop` days either side of the selected day.
    func clampedPosition(_ position: Double, selected: Int) -> Double {
        min(max(position, Double(selected - maximumHop)), Double(selected + maximumHop))
    }
}
