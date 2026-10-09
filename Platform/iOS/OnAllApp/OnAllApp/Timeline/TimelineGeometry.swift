import CoreGraphics
import NEOBudgetCalendar

/// Pure layout math for the day timeline: minutes to points and back. No SwiftUI, so it is unit-tested.
/// Block size reflects time only, never money.
struct TimelineGeometry: Equatable {
    /// Minutes to points. Uniform for `init(totalMinutes:pointsPerMinute:)`, folded and enlarged for `init(axis:)`. While the
    /// axis changes shape this is the shape it is changing to, and `y(minute:)` is a blend towards it.
    var axis: TimelineAxis
    /// The shape the axis is changing from, and how far along the change is (0 = still that shape, 1 = arrived).
    private var blendFrom: TimelineAxis?
    private var blendAmount: CGFloat = 1
    var totalMinutes: Int { axis.totalMinutes }
    /// Space on the left for hour labels.
    var gutterWidth: CGFloat = 60
    /// Space on the right for transaction markers.
    var markerRailWidth: CGFloat = 76
    var columnSpacing: CGFloat = 2
    /// A block never draws shorter than this, however folded the axis is, so it stays readable and tappable.
    var minimumBlockHeight: CGFloat = 24

    init(totalMinutes: Int, pointsPerMinute: CGFloat = 1.2) {
        axis = .linear(totalMinutes: totalMinutes, pointsPerMinute: pointsPerMinute)
    }

    init(axis: TimelineAxis) {
        self.axis = axis
    }

    /// One frame of an axis changing shape. Every position (blocks, handles, hour marks, folds, markers, the preview) is
    /// asked of this one value, so they all move together; there is no second animation to keep in step. Time `m` is drawn at
    /// `from.y(m) + (to.y(m) - from.y(m)) * progress`.
    init(from: TimelineAxis, to: TimelineAxis, progress: CGFloat) {
        axis = to
        blendFrom = from
        blendAmount = min(max(progress, 0), 1)
    }

    /// The scale of the unfolded part of the axis. Only meaningful as a nominal size (for example a minimum height).
    var pointsPerMinute: CGFloat { axis.segments.first(where: { !$0.isFolded })?.pointsPerMinute ?? axis.segments.first?.pointsPerMinute ?? 1 }

    /// The height of the scrolled content. While the axis changes shape it never shrinks below where it started: the scroll
    /// view holds its position until the change ends, and content that gets shorter under it would push the scroll position
    /// (UIKit clamps an offset that has run past the end), moving everything by the wrong amount. The new height arrives at the
    /// same moment as the scroll shift, when the change ends.
    var contentHeight: CGFloat {
        guard let from = blendFrom else { return axis.height }
        return max(from.height, axis.height)
    }

    func y(minute: Int) -> CGFloat {
        guard let from = blendFrom else { return axis.y(minute: minute) }
        let start = from.y(minute: minute)
        return start + (axis.y(minute: minute) - start) * blendAmount
    }

    /// The nearest minute at a vertical position, clamped to the day.
    func minute(atY y: CGFloat) -> Int { axis.minute(atY: y) }

    /// An expanded block takes the whole width (it opens over its neighbours); otherwise it keeps its overlap column.
    func blockFrame(_ block: EventBlock, totalWidth: CGFloat, expanded: Bool = false) -> CGRect {
        let available = max(0, totalWidth - gutterWidth - markerRailWidth)
        let columns = expanded ? 1 : CGFloat(max(1, block.layout.columnCount))
        let columnWidth = available / columns
        let top = y(minute: block.displayStartMinute)
        let bottom = y(minute: block.displayEndMinute)
        return CGRect(
            x: gutterWidth + columnWidth * CGFloat(expanded ? 0 : block.layout.column),
            y: top,
            width: max(0, columnWidth - columnSpacing),
            height: max(minimumBlockHeight, bottom - top - 1)
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

    /// One mark per elapsed hour that is not inside or touching a folded stretch. `elapsedMinute` is the position in the day, `wallHour` the clock hour shown,
    /// which differs from the elapsed hour after a daylight-saving transition.
    struct HourMark: Equatable {
        let elapsedMinute: Int
        let wallHour: Int
        /// 1 unless the mark exists in only one of the two shapes of a change in progress, then it fades.
        var opacity: CGFloat = 1
    }

    func hourMarks(dayStartUnixMilliseconds: Int64, zone: DisplayTimeZone) -> [HourMark] {
        func marks(in axis: TimelineAxis) -> Set<Int> {
            Set(stride(from: 0, to: axis.totalMinutes, by: 60).filter { !axis.isFoldedOrBordering(minute: $0) })
        }
        let arriving = marks(in: axis)
        let leaving = blendFrom.map(marks(in:)) ?? arriving
        return arriving.union(leaving).sorted().map { elapsed in
            let instant = dayStartUnixMilliseconds + Int64(elapsed) * 60_000
            let opacity: CGFloat = arriving.contains(elapsed) && leaving.contains(elapsed) ? 1
                : arriving.contains(elapsed) ? blendAmount : 1 - blendAmount
            return HourMark(elapsedMinute: elapsed, wallHour: zone.minuteOfDay(of: instant) / 60, opacity: opacity)
        }
    }

    /// A stretch drawn folded. During a change a fold that only one shape has fades in or out.
    struct FoldMark: Equatable {
        let startMinute: Int
        let endMinute: Int
        var opacity: CGFloat = 1
    }

    var foldMarks: [FoldMark] {
        func range(_ segment: TimelineAxis.Segment) -> ClosedRange<Int> { segment.startMinute...segment.endMinute }
        let arriving = axis.foldedSegments.map(range)
        let leaving = blendFrom.map { $0.foldedSegments.map(range) } ?? arriving
        var result: [FoldMark] = []
        for fold in arriving {
            let both = leaving.contains(fold)
            result.append(FoldMark(startMinute: fold.lowerBound, endMinute: fold.upperBound, opacity: both ? 1 : blendAmount))
        }
        for fold in leaving where !arriving.contains(fold) {
            result.append(FoldMark(startMinute: fold.lowerBound, endMinute: fold.upperBound, opacity: 1 - blendAmount))
        }
        return result
    }
}
