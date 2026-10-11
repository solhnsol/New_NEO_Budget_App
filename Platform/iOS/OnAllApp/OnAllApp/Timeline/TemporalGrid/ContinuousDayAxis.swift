import CoreGraphics
import Foundation

/// The coordinate system of the continuous day space: days side by side on one infinite horizontal line, each exactly `dayWidth` wide, so day `d`
/// begins at `x = d · dayWidth`. The screen is a window onto it and `position` is a `Double` number of days: the day at the left edge of the window
/// (`position = 3.25` is a quarter of the way from day 3 to day 4). Nothing about a day is stored in the line: a day's content is looked up
/// by its index when it is drawn.
///
/// Time is shared by all the days on screen: one partition (the cells and what each stands for) that is itself `position`'s blend of the
/// partitions planned for the two windows around it. The horizontal progress `frac(position)` and the progress of that blend are the same number.
struct DayAxisGeometry: Equatable {
    var dayWidth: CGFloat
    /// How many whole days fit across the window.
    var visibleColumns = 2

    /// Where the left edge of day `day` is, in window coordinates, when the window is at `position`.
    func x(ofDay day: Double, at position: Double) -> CGFloat { CGFloat(day - position) * dayWidth }

    /// The position a horizontal drag of `translation` points leads to, from `start` (a drag to the left moves to later days).
    func position(startingAt start: Double, translation: CGFloat) -> Double { start - Double(translation / dayWidth) }

    /// The days that have any part on screen at `position`, as a closed range of indices. A position on a whole day shows exactly `visibleColumns` days.
    func visibleDays(at position: Double) -> ClosedRange<Int> {
        let first = Int(position.rounded(.down))
        let end = position + Double(visibleColumns)                       // the right edge, exclusive
        let last = max(first, Int(end.rounded(.up)) - 1)
        return first...last
    }

    /// Whole-day windows whose partitions the shared time needs at `position`: the one the position is in and, while between two, the next.
    func windows(at position: Double, bounds: ClosedRange<Int>) -> [Int] {
        let clamped = min(max(position, Double(bounds.lowerBound)), Double(bounds.upperBound))
        let first = Int(clamped.rounded(.down))
        return clamped - Double(first) < 1e-12 || first >= bounds.upperBound ? [first] : [first, first + 1]
    }

    /// The days whose content a partition plan reads at `position` (each window reads one day before its main day and two after).
    func planningDays(at position: Double, bounds: ClosedRange<Int>) -> ClosedRange<Int> {
        let windows = self.windows(at: position, bounds: bounds)
        return (windows[0] - 1)...((windows.last ?? windows[0]) + 2)
    }

    /// Days that have to be drawn: the visible ones. The days around them are only planned for, never drawn.
    func renderedDays(at position: Double) -> ClosedRange<Int> { visibleDays(at: position) }
}

/// The shared time partition at a horizontal position.
enum ContinuousDayAxis {
    /// `windowPartition(w)` is the partition planned for the window whose main day is `w` (cached by the caller). Between whole days it is the
    /// straight blend of the two around `position`; the same number moves the days sideways. No planning happens here.
    static func partition(at position: Double, bounds: ClosedRange<Int>, windowPartition: (Int) -> TemporalGridPartition) -> TemporalGridPartition {
        let clamped = min(max(position, Double(bounds.lowerBound)), Double(bounds.upperBound))
        let first = Int(clamped.rounded(.down))
        let fraction = clamped - Double(first)
        guard fraction >= 1e-12, first < bounds.upperBound else { return windowPartition(first) }
        return TemporalGridPartition.interpolated(from: windowPartition(first), to: windowPartition(first + 1), progress: fraction) ?? windowPartition(first)
    }

    struct AnchoredOffset: Equatable {
        let offset: CGFloat
        /// The grid had no room to put the time where it was (the ends of the day, or no scroll at 1×): the offset stopped at its limit.
        let clamped: Bool
        /// How far, in minutes, the time at the anchor point is from the anchor time after clamping (0 when not clamped).
        let residualMinutes: Double
    }

    /// The scroll offset that keeps `time` at `focal` (from the top of the viewport) on `partition` zoomed by `zoom`. Used when the days move under
    /// a zoomed view: the time at the middle of the screen stays put while what is drawn around it changes.
    static func anchoredOffset(time: Double, partition: TemporalGridPartition, zoom: CGFloat, viewport: CGFloat, focal: CGFloat) -> AnchoredOffset {
        let zoomed = partition.zoomed(viewportHeight: viewport, zoomScale: zoom)
        let wanted = zoomed.timeToY(time) - focal
        let offset = PinchZoomMath.clampedOffset(wanted, zoom: zoom, viewport: viewport)
        let clamped = abs(offset - wanted) > 1e-9
        return AnchoredOffset(offset: offset, clamped: clamped, residualMinutes: abs(zoomed.yToTime(offset + focal) - time))
    }

    /// The time at `focal` on `partition` zoomed by `zoom`, at scroll `offset`.
    static func time(atOffset offset: CGFloat, partition: TemporalGridPartition, zoom: CGFloat, viewport: CGFloat, focal: CGFloat) -> Double {
        partition.zoomed(viewportHeight: viewport, zoomScale: zoom).yToTime(offset + focal)
    }
}

/// The time held at the middle of the screen while the days move, and the position the scroll offset was last right for. One value, no clock.
///
/// While the days move, the offset follows the anchor time. When the person scrolls or pinches (they set the offset themselves) the old anchor
/// is no longer where they are looking, so the next step takes a new one from the offset they left, on the partition of the position the offset was
/// last right for. The same goes for the very first step. That is the whole reset rule.
struct AnchorState: Equatable {
    private(set) var time: Double?
    /// The position at which the scroll offset was last applied (or read).
    private(set) var position: Double

    init(position: Double) { self.position = position }

    /// The offset to apply when the window moves to `newPosition`. `currentOffset` is the offset on screen now; `userMoved` is true when the person
    /// changed the scroll or the zoom since the last step (so the anchor is taken again from where they left it).
    mutating func offset(
        forPosition newPosition: Double, currentOffset: CGFloat, userMoved: Bool, zoom: CGFloat, viewport: CGFloat, focal: CGFloat,
        partitionAt: (Double) -> TemporalGridPartition
    ) -> ContinuousDayAxis.AnchoredOffset {
        if time == nil || userMoved {
            time = ContinuousDayAxis.time(atOffset: currentOffset, partition: partitionAt(position), zoom: zoom, viewport: viewport, focal: focal)
        }
        let result = ContinuousDayAxis.anchoredOffset(time: time ?? 0, partition: partitionAt(newPosition), zoom: zoom, viewport: viewport, focal: focal)
        position = newPosition
        return result
    }

    /// The offset is not being applied now (the person has the scroll in their hand): keep the position the move has reached, and forget the anchor.
    mutating func release(at newPosition: Double) { position = newPosition; time = nil }
}
