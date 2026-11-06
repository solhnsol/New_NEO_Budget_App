import CoreGraphics

/// How the screen is divided between the shared hour gutter and the day columns. Pure, so it is tested.
///
/// Two consecutive days sit side by side and share one vertical time axis: the same minute is at the same height in both. Each
/// day is laid out exactly as a single day would be, in a column of its own width, so everything that works inside one column
/// (stacking, transaction cards, handles) works unchanged and only needs to be told which column it is in.
struct DayColumns: Equatable {
    var count: Int = 2
    var gutterWidth: CGFloat = 60
    var trailingPadding: CGFloat = 6
    var totalWidth: CGFloat

    /// The width of one column, including its share of the trailing padding.
    var columnWidth: CGFloat { max(0, (totalWidth - gutterWidth) / CGFloat(max(1, count))) }

    /// The width a single day's layout is given: the gutter, one column, and the trailing padding. Positions inside it are the
    /// ones a lone day would have, shifted right by `originX(of:)`.
    var dayLayoutWidth: CGFloat { gutterWidth + columnWidth }

    /// How far a column's content is shifted right of the first column's.
    func originX(of index: Int) -> CGFloat { columnWidth * CGFloat(index) }

    /// The column a horizontal position falls in, clamped to the visible columns. The gutter belongs to the first.
    func column(atX x: CGFloat) -> Int {
        guard columnWidth > 0 else { return 0 }
        return min(max(Int(((x - gutterWidth) / columnWidth).rounded(.down)), 0), count - 1)
    }

    /// A point in grid coordinates as the single-day layout of its column sees it.
    func localPoint(_ point: CGPoint, column: Int) -> CGPoint { CGPoint(x: point.x - originX(of: column), y: point.y) }
}

/// What a horizontal swipe over the day columns does when the finger lifts. One day at a time: a swipe never skips a day however
/// fast it is, and a slow drag that has not gone far enough returns to where it started.
enum DaySwipe {
    /// The fraction of a column a drag must cover to turn the page by itself.
    static let distanceShare: CGFloat = 0.4
    /// Points per second above which a flick turns the page even over a short distance.
    static let flickVelocity: CGFloat = 450
    /// A drag must be at least this much more horizontal than vertical to be a swipe and not a scroll.
    static let horizontalDominance: CGFloat = 1.3

    /// +1 (towards the next day), -1 (the previous day) or 0 (stay).
    static func daysToMove(translation: CGFloat, velocity: CGFloat, columnWidth: CGFloat) -> Int {
        guard columnWidth > 0 else { return 0 }
        // Fingers move left to go to the next day.
        let direction = translation < 0 ? 1 : -1
        let far = abs(translation) >= columnWidth * distanceShare
        let flicked = abs(velocity) >= flickVelocity && (velocity < 0) == (translation < 0) && abs(translation) > 8
        return far || flicked ? direction : 0
    }

    /// Where the strip of columns rests after the swipe, relative to its resting place: a whole column either way, or back at 0.
    static func settledOffset(days: Int, columnWidth: CGFloat) -> CGFloat { CGFloat(-days) * columnWidth }

    /// The live offset of the strip while the finger drags: it follows the finger but never more than one column, so the day
    /// beyond the neighbour is never uncovered.
    static func liveOffset(translation: CGFloat, columnWidth: CGFloat) -> CGFloat { min(max(translation, -columnWidth), columnWidth) }

    /// Whether a drag that has just gone past the touch slop is a swipe: mostly sideways.
    static func isSwipe(velocity: CGPoint) -> Bool { abs(velocity.x) > abs(velocity.y) * horizontalDominance }
}
