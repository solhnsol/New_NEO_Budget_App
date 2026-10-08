import CoreGraphics
import NEOBudgetCalendar

/// How minutes of the day map to vertical points. Piecewise linear, so some stretches can be drawn at full size and
/// others folded away. Pure and deterministic: it knows nothing about events beyond the anchor minutes it is given.
///
/// Two shapes are built from the same day:
/// - **browse**: keeps full size around anything that happens (event edges, transactions) and folds the long empty
///   stretches and the middle of very long events, so the whole day reads at a glance.
/// - **editing**: the browse axis with the neighbourhood of one event unfolded and enlarged, so a 15 minute step is
///   comfortably large to drag.
struct TimelineAxis: Equatable {
    struct Segment: Equatable {
        let startMinute: Int
        let endMinute: Int
        let pointsPerMinute: CGFloat
        /// Drawn height. For a folded stretch this is at least the minimum fold height, so it can carry a label.
        let height: CGFloat
        let isFolded: Bool

        var minutes: Int { endMinute - startMinute }
    }

    struct Parameters: Equatable {
        /// Points per minute where nothing is folded.
        var browseScale: CGFloat = 0.6
        var foldedScale: CGFloat = 0.06
        var minimumFoldedHeight: CGFloat = 28
        /// Minutes kept at full size on each side of an anchor.
        var padding: Int = 30
        /// A stretch shorter than this is not worth folding.
        var minimumFoldMinutes: Int = 60
        /// Points per minute while editing. 15 minutes should be at least about 24 points.
        var editScale: CGFloat = 1.6
        /// Minutes unfolded on each side of the edited event.
        var editMargin: Int = 90
        /// Where an empty day keeps its full-size stretch.
        var emptyDayFocus: ClosedRange<Int> = (9 * 60)...(18 * 60)

        static let standard = Parameters()
    }

    let totalMinutes: Int
    let segments: [Segment]
    private let offsets: [CGFloat]

    init(totalMinutes: Int, segments: [Segment]) {
        self.totalMinutes = totalMinutes
        self.segments = segments
        var running: CGFloat = 0
        offsets = segments.map { segment in
            defer { running += segment.height }
            return running
        }
    }

    var height: CGFloat { (offsets.last ?? 0) + (segments.last?.height ?? 0) }

    /// A uniform axis, the shape the timeline had before it could fold.
    static func linear(totalMinutes: Int, pointsPerMinute: CGFloat) -> TimelineAxis {
        guard totalMinutes > 0 else { return TimelineAxis(totalMinutes: 0, segments: []) }
        return TimelineAxis(totalMinutes: totalMinutes, segments: [
            Segment(
                startMinute: 0, endMinute: totalMinutes, pointsPerMinute: pointsPerMinute,
                height: CGFloat(totalMinutes) * pointsPerMinute, isFolded: false
            )
        ])
    }

    // MARK: Mapping

    func y(minute: Int) -> CGFloat {
        guard let index = index(containingMinute: minute) else { return minute <= 0 ? 0 : height }
        let segment = segments[index]
        guard segment.minutes > 0 else { return offsets[index] }
        let fraction = CGFloat(min(max(minute, segment.startMinute), segment.endMinute) - segment.startMinute) / CGFloat(segment.minutes)
        return offsets[index] + fraction * segment.height
    }

    /// The nearest minute at a vertical position, clamped to the day. Inside a folded stretch one point is many
    /// minutes, so the answer is coarse there by design.
    func minute(atY y: CGFloat) -> Int {
        guard !segments.isEmpty else { return 0 }
        if y <= 0 { return 0 }
        if y >= height { return totalMinutes }
        var low = 0
        var high = segments.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        let segment = segments[low]
        guard segment.height > 0 else { return segment.startMinute }
        let fraction = (y - offsets[low]) / segment.height
        return segment.startMinute + Int((fraction * CGFloat(segment.minutes)).rounded())
    }

    func isFolded(minute: Int) -> Bool {
        guard let index = index(containingMinute: minute) else { return false }
        // The boundary between two stretches belongs to the unfolded one so its label stays visible.
        let segment = segments[index]
        if segment.isFolded, minute == segment.startMinute, index > 0, !segments[index - 1].isFolded { return false }
        return segment.isFolded
    }

    var foldedSegments: [Segment] { segments.filter(\.isFolded) }

    /// Whether `minute` is inside a fold or on its edge. A label drawn there would collide with the fold's own label.
    func isFoldedOrBordering(minute: Int) -> Bool {
        segments.contains { $0.isFolded && minute >= $0.startMinute && minute <= $0.endMinute }
    }

    func top(of segment: Segment) -> CGFloat { y(minute: segment.startMinute) }

    private func index(containingMinute minute: Int) -> Int? {
        guard !segments.isEmpty, minute >= 0, minute <= totalMinutes else { return nil }
        // The last segment whose start is not after `minute`; a minute on a boundary belongs to the later segment.
        var low = 0
        var high = segments.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segments[mid].startMinute <= minute { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: Browse

    /// Keeps `padding` minutes at full size around each anchor and folds the stretches between that are at least
    /// `minimumFoldMinutes` long. A day with no anchors keeps `emptyDayFocus` and folds the rest.
    static func browse(totalMinutes: Int, anchors: [Int], parameters: Parameters = .standard) -> TimelineAxis {
        guard totalMinutes > 0 else { return TimelineAxis(totalMinutes: 0, segments: []) }
        let points = Set(anchors.map { min(max($0, 0), totalMinutes) })
        // Kept stretches around every anchor, merged where they touch. A day with nothing on it keeps its whole
        // working-hours focus at full size rather than treating the two ends as anchors.
        var kept: [(start: Int, end: Int)] = []
        if points.isEmpty {
            let focus = parameters.emptyDayFocus
            kept = [(start: max(0, focus.lowerBound - parameters.padding), end: min(totalMinutes, focus.upperBound + parameters.padding))]
        }
        for anchor in points.sorted() {
            let interval = (start: max(0, anchor - parameters.padding), end: min(totalMinutes, anchor + parameters.padding))
            if let last = kept.last, interval.start <= last.end {
                kept[kept.count - 1] = (last.start, max(last.end, interval.end))
            } else {
                kept.append(interval)
            }
        }
        // Everything else, in order, as (start, end, folded?). Short leftovers stay at full size.
        var pieces: [(start: Int, end: Int, folded: Bool)] = []
        var cursor = 0
        func addGap(to end: Int) {
            guard end > cursor else { return }
            pieces.append((cursor, end, end - cursor >= parameters.minimumFoldMinutes))
        }
        for interval in kept {
            addGap(to: interval.start)
            pieces.append((interval.start, interval.end, false))
            cursor = interval.end
        }
        addGap(to: totalMinutes)

        // Merge neighbours that ended up with the same treatment.
        var merged: [(start: Int, end: Int, folded: Bool)] = []
        for piece in pieces {
            if let last = merged.last, last.folded == piece.folded {
                merged[merged.count - 1] = (last.start, piece.end, last.folded)
            } else {
                merged.append(piece)
            }
        }
        return TimelineAxis(totalMinutes: totalMinutes, segments: merged.map { piece in
            if piece.folded {
                let natural = CGFloat(piece.end - piece.start) * parameters.foldedScale
                return Segment(
                    startMinute: piece.start, endMinute: piece.end, pointsPerMinute: parameters.foldedScale,
                    height: max(parameters.minimumFoldedHeight, natural), isFolded: true
                )
            }
            return Segment(
                startMinute: piece.start, endMinute: piece.end, pointsPerMinute: parameters.browseScale,
                height: CGFloat(piece.end - piece.start) * parameters.browseScale, isFolded: false
            )
        })
    }

    // MARK: Editing

    /// The minute window that gets unfolded and enlarged around an edited range.
    func editWindow(around range: ClosedRange<Int>, parameters: Parameters = .standard) -> ClosedRange<Int> {
        max(0, range.lowerBound - parameters.editMargin)...min(totalMinutes, range.upperBound + parameters.editMargin)
    }

    /// This axis with `window` unfolded and drawn at `scale`. Stretches outside the window keep their shape.
    func expanded(over window: ClosedRange<Int>, scale: CGFloat) -> TimelineAxis {
        guard totalMinutes > 0, window.upperBound > window.lowerBound else { return self }
        var result: [Segment] = []
        var insertedWindow = false
        for segment in segments {
            if segment.endMinute <= window.lowerBound || segment.startMinute >= window.upperBound {
                if segment.startMinute >= window.upperBound, !insertedWindow {
                    result.append(Self.windowSegment(window, scale))
                    insertedWindow = true
                }
                result.append(segment)
                continue
            }
            // Overlaps the window: keep the part before and after, replace the middle.
            if segment.startMinute < window.lowerBound {
                result.append(Self.cut(segment, from: segment.startMinute, to: window.lowerBound))
            }
            if !insertedWindow {
                result.append(Self.windowSegment(window, scale))
                insertedWindow = true
            }
            if segment.endMinute > window.upperBound {
                result.append(Self.cut(segment, from: window.upperBound, to: segment.endMinute))
            }
        }
        if !insertedWindow { result.append(Self.windowSegment(window, scale)) }
        return TimelineAxis(totalMinutes: totalMinutes, segments: result)
    }

    private static func windowSegment(_ window: ClosedRange<Int>, _ scale: CGFloat) -> Segment {
        Segment(
            startMinute: window.lowerBound, endMinute: window.upperBound, pointsPerMinute: scale,
            height: CGFloat(window.upperBound - window.lowerBound) * scale, isFolded: false
        )
    }

    private static func cut(_ segment: Segment, from start: Int, to end: Int) -> Segment {
        let fraction = CGFloat(end - start) / CGFloat(max(1, segment.minutes))
        return Segment(
            startMinute: start, endMinute: end, pointsPerMinute: segment.pointsPerMinute,
            height: segment.height * fraction, isFolded: segment.isFolded
        )
    }
}

extension TimelineAxis {
    /// The browse axis for a day: full size around event edges and transactions, folded elsewhere.
    static func browse(for timeline: DayTimeline, parameters: Parameters = .standard) -> TimelineAxis {
        var anchors: [Int] = []
        for block in timeline.blocks { anchors += [block.startMinute, block.endMinute] }
        anchors += timeline.markers.map(\.positionMinute)
        return browse(totalMinutes: timeline.totalMinutes, anchors: anchors, parameters: parameters)
    }
}
