import CoreGraphics
import NEOBudgetCalendar

/// Pure layout math for the day timeline: minutes to points and back. No SwiftUI, so it is unit-tested.
/// Block size reflects time only, never money.
struct TimelineGeometry: Equatable {
    var pointsPerMinute: CGFloat
    var totalMinutes: Int
    /// Space on the left for hour labels.
    var gutterWidth: CGFloat = 60
    /// Space on the right for transaction markers.
    var markerRailWidth: CGFloat = 76
    var columnSpacing: CGFloat = 2

    init(totalMinutes: Int, pointsPerMinute: CGFloat = 1.2) {
        self.totalMinutes = totalMinutes
        self.pointsPerMinute = pointsPerMinute
    }

    var contentHeight: CGFloat { CGFloat(totalMinutes) * pointsPerMinute }

    func y(minute: Int) -> CGFloat { CGFloat(minute) * pointsPerMinute }

    /// The nearest minute at a vertical position, clamped to the day.
    func minute(atY y: CGFloat) -> Int {
        max(0, min(totalMinutes, Int((y / pointsPerMinute).rounded())))
    }

    func blockFrame(_ block: EventBlock, totalWidth: CGFloat) -> CGRect {
        let available = max(0, totalWidth - gutterWidth - markerRailWidth)
        let columns = CGFloat(max(1, block.layout.columnCount))
        let columnWidth = available / columns
        let top = y(minute: block.displayStartMinute)
        let bottom = y(minute: block.displayEndMinute)
        return CGRect(
            x: gutterWidth + columnWidth * CGFloat(block.layout.column),
            y: top,
            width: max(0, columnWidth - columnSpacing),
            height: max(0, bottom - top - 1)
        )
    }

    /// Vertical positions for markers so labels never overlap: each marker sits at its own minute unless that
    /// would be closer than `minimumSpacing` to the marker above it, then it is pushed down. Result order matches
    /// the input order.
    func markerYPositions(minutes: [Int], minimumSpacing: CGFloat = 22) -> [CGFloat] {
        let order = minutes.indices.sorted { (minutes[$0], $0) < (minutes[$1], $1) }
        var result = [CGFloat](repeating: 0, count: minutes.count)
        var previous: CGFloat?
        for index in order {
            var position = y(minute: minutes[index])
            if let previous, position < previous + minimumSpacing { position = previous + minimumSpacing }
            result[index] = position
            previous = position
        }
        return result
    }

    /// One mark per elapsed hour. `elapsedMinute` is the position in the day, `wallHour` the clock hour shown,
    /// which differs from the elapsed hour after a daylight-saving transition.
    struct HourMark: Equatable {
        let elapsedMinute: Int
        let wallHour: Int
    }

    func hourMarks(dayStartUnixMilliseconds: Int64, zone: DisplayTimeZone) -> [HourMark] {
        stride(from: 0, to: totalMinutes, by: 60).map { elapsed in
            let instant = dayStartUnixMilliseconds + Int64(elapsed) * 60_000
            return HourMark(elapsedMinute: elapsed, wallHour: zone.minuteOfDay(of: instant) / 60)
        }
    }
}
