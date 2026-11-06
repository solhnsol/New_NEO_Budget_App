import CoreGraphics
import NEOBudgetCalendar

/// What a day's drawing needs to know about time on the vertical axis: where a minute is, which minute a height is, and the few constants of the
/// column the day is drawn in. It is the seam between the day layout (`DayRenderPlan`, the edit planner) and *how* the axis is shaped:
/// today a piecewise linear axis that folds and enlarges (`TimelineGeometry`), later a fixed grid of equal-height cells (`TemporalAxisMapping`).
/// Neither the plan nor the planner knows which one it has.
///
/// Minutes are minutes of the day axis the caller chose (elapsed minutes since the day's start for `TimelineGeometry`; see `DayWallClock` for the
/// wall-clock axis policy of the grid). `exact` variants take and give fractional minutes, for an axis that is itself between two states.
protocol TimeAxisMapping {
    var totalMinutes: Int { get }
    /// The height of everything: the y of the end of the day.
    var contentHeight: CGFloat { get }
    /// Space on the left for hour labels.
    var gutterWidth: CGFloat { get }
    var trailingPadding: CGFloat { get }
    var columnSpacing: CGFloat { get }
    /// A block never draws shorter than this, however small its time is on the axis.
    var minimumBlockHeight: CGFloat { get }

    func y(minute: Int) -> CGFloat
    /// The nearest minute at a vertical position, clamped to the day.
    func minute(atY y: CGFloat) -> Int

    func y(exactMinute: Double) -> CGFloat
    func exactMinute(atY y: CGFloat) -> Double

    /// Where a span that ends (exclusively) at `minute` ends on the axis. The same as `y(minute:)` on every axis whose minutes map one to one onto the axis;
    /// an axis that maps another clock onto its own (`ElapsedMinuteAxisMapping`) answers differently at a daylight-saving transition, where the end of the last
    /// minute covered is not the start of the minute after it.
    func y(endMinute minute: Int) -> CGFloat

    /// Where the span `[start, end)` ends on the axis. For an axis with one-to-one minutes it is `y(endMinute: end)`; across a repeated hour it is the furthest the
    /// span reaches (`DayWallClock.wallRange`), which is not necessarily where its last minute is.
    func y(bottomOfSpanFrom start: Int, to end: Int) -> CGFloat

    /// Whether a height can be turned back into **the one instant it came from**. `minute(atY:)` is always the nearest minute of the axis' own domain, but on an
    /// axis where two instants share a position (the repeated hour of a fall-back day) it can name only the first of them. **Whatever turns a position into a time
    /// that is saved (moving, resizing, creating) must refuse an axis for which this is `false`**; reading, hit-testing and display may use `minute(atY:)` freely.
    var preservesInstantIdentity: Bool { get }
}

extension TimeAxisMapping {
    func y(endMinute minute: Int) -> CGFloat { y(minute: minute) }
    func y(bottomOfSpanFrom start: Int, to end: Int) -> CGFloat { y(endMinute: end) }
    var preservesInstantIdentity: Bool { true }
    func y(exactMinute minute: Double) -> CGFloat { y(minute: Int(minute.rounded())) }
    func exactMinute(atY y: CGFloat) -> Double { Double(minute(atY: y)) }

    /// The width of the day's content column: everything of a day (events, transactions) is laid out in it.
    func contentWidth(totalWidth: CGFloat) -> CGFloat { max(0, totalWidth - gutterWidth - trailingPadding) }

    /// An expanded block takes the whole column (it opens over its neighbours); otherwise it keeps its stacking insets.
    /// The top and bottom are exactly where the event's time puts them.
    func blockFrame(_ block: EventBlock, totalWidth: CGFloat, expanded: Bool = false, insets: CardInsets = .zero) -> CGRect {
        let available = contentWidth(totalWidth: totalWidth)
        let used = expanded ? CardInsets.zero : insets
        let top = y(minute: block.displayStartMinute)
        let bottom = y(bottomOfSpanFrom: block.displayStartMinute, to: block.displayEndMinute)
        return CGRect(
            x: gutterWidth + used.left,
            y: top,
            width: max(0, available - used.left - used.right - columnSpacing),
            height: max(minimumBlockHeight, bottom - top - 1)
        )
    }
}

extension TimelineGeometry: TimeAxisMapping {}
