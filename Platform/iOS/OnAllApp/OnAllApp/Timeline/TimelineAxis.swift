import CoreGraphics
import NEOBudgetCalendar

/// How minutes of the day map to vertical points. Piecewise linear, so some stretches can be drawn at full size and
/// others folded away. Pure and deterministic: it knows nothing about events beyond the anchor minutes it is given.
///
/// Two shapes are built from the same day:
/// - **browse**: keeps full size around anything that happens (event edges, transactions) and folds the long empty
///   stretches and the middle of very long events, so the whole day reads at a glance.
/// - **editing**: the browse axis with a small neighbourhood of each edge handle unfolded and enlarged, so a 15 minute
///   step is comfortably large to drag. Everything else, including the middle of a long event, keeps its browse shape,
///   so editing never unfolds the day. A fold draws no label: its length is not information the user needs.
struct TimelineAxis: Equatable {
    struct Segment: Equatable {
        let startMinute: Int
        let endMinute: Int
        let pointsPerMinute: CGFloat
        /// Drawn height. For a folded stretch this is at least the minimum fold height, so it stays visible.
        let height: CGFloat
        let isFolded: Bool

        var minutes: Int { endMinute - startMinute }
    }

    struct Parameters: Equatable {
        /// Points per minute where nothing is folded.
        var browseScale: CGFloat = 0.6
        var foldedScale: CGFloat = 0.06
        var minimumFoldedHeight: CGFloat = 18
        /// Minutes kept at full size on each side of an anchor.
        var padding: Int = 30
        /// A stretch shorter than this is not worth folding.
        var minimumFoldMinutes: Int = 60
        /// Points per minute in an enlarged zone: 15 minutes are 12 points, a comfortable step for a finger that is moving slowly.
        var editScale: CGFloat = 0.8
        /// Where an empty day keeps its full-size stretch.
        var emptyDayFocus: ClosedRange<Int> = (9 * 60)...(18 * 60)
        /// Minutes enlarged on each side of an edge handle.
        var handleRadius: Int = 90
        /// Minutes of transition on each side of an enlarged zone, drawn between browse scale and edit scale.
        var handleRamp: Int = 15
        var rampScale: CGFloat = 0.7
        /// Two enlarged zones closer than this are drawn as one.
        var zoneMergeGap: Int = 20

        /// The least height an event or a transaction card is drawn at, so nothing is lost in a folded stretch.
        var minimumItemHeight: CGFloat = 24
        /// The minutes around a transaction that are opened for its card.
        var markerWindowMinutes: Int = 40

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

    /// How many points one minute is drawn at, at `minute`. A boundary belongs to the later stretch; the end of the day to the last.
    func pointsPerMinute(atMinute minute: Int) -> CGFloat {
        guard let index = index(containingMinute: minute) else { return segments.first?.pointsPerMinute ?? 1 }
        return segments[index].pointsPerMinute
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

    /// The minute windows enlarged around edge handles at `handles` (event edges, or a minute being placed). Each handle
    /// gets `handleRadius` minutes on both sides, clamped to the day; windows that overlap or nearly touch become one.
    func handleZones(around handles: [Int], parameters: Parameters = .standard) -> [ClosedRange<Int>] {
        let zones = handles.sorted().map { handle in
            max(0, handle - parameters.handleRadius)...min(totalMinutes, handle + parameters.handleRadius)
        }
        var merged: [ClosedRange<Int>] = []
        for zone in zones where zone.upperBound > zone.lowerBound {
            if let last = merged.last, zone.lowerBound - last.upperBound <= parameters.zoneMergeGap {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, zone.upperBound)
            } else {
                merged.append(zone)
            }
        }
        return merged
    }

    /// This axis with the neighbourhood of each handle unfolded and drawn at `editScale`, each with a short ramp at
    /// `rampScale` on both sides so the change of size is gradual. The rest of the axis, including a long event's folded
    /// middle, is untouched, so the whole thing grows by a few hundred points at most however long the event is.
    func expandedLocally(around handles: [Int], parameters: Parameters = .standard) -> TimelineAxis {
        expandedLocally(windows: handleZones(around: handles, parameters: parameters), parameters: parameters)
    }

    /// The same for windows chosen by the caller, which need not be centred on their minute: a zone can be lopsided so that the
    /// side facing something that must stay in view grows less.
    func expandedLocally(windows zones: [ClosedRange<Int>], parameters: Parameters = .standard) -> TimelineAxis {
        var result = self
        for zone in zones {
            let ramp = max(0, zone.lowerBound - parameters.handleRamp)...min(totalMinutes, zone.upperBound + parameters.handleRamp)
            result = result.expanded(over: ramp, scale: parameters.rampScale)
        }
        for zone in zones { result = result.expanded(over: zone, scale: parameters.editScale) }
        return result
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
        browse(main: timeline, secondary: nil, parameters: parameters)
    }

    /// The axis two days on screen share: **one** minute-to-height mapping, shaped by the main day and only *assisted* by the
    /// secondary one. "Main" says which day the screen is centred on, nothing about how important either day's events are.
    ///
    /// - The main day sets the compression exactly as if it were alone: full size around its events and transactions, folded
    ///   elsewhere.
    /// - The secondary day adds a minimum. Where one of its events or transactions falls in a stretch the main day folded, that
    ///   stretch is opened just enough for the item to be drawn at a readable height (`Parameters.minimumItemHeight`), and no more:
    ///   never to full size unless that is what the item needs. Where the main day already shows the time at a useful size,
    ///   nothing is added.
    /// - The height of each stretch is therefore the larger of what the main day asks and what the secondary day needs.
    static func browse(main: DayTimeline, secondary: DayTimeline?, parameters: Parameters = .standard) -> TimelineAxis {
        var anchors: [Int] = []
        for block in main.blocks { anchors += [block.startMinute, block.endMinute] }
        anchors += main.markers.map(\.positionMinute)
        let base = browse(totalMinutes: main.totalMinutes, anchors: anchors, parameters: parameters)
        guard let secondary else { return base }
        return base.assisted(by: needs(of: secondary, parameters: parameters), parameters: parameters)
    }

    /// A stretch of minutes that must be drawn at least `height` points tall.
    struct Need: Equatable {
        let start: Int
        let end: Int
        let height: CGFloat
    }

    /// What a day's items need to stay readable: an event its minimum block height over its own minutes, a transaction a card's
    /// worth of height around its time.
    static func needs(of timeline: DayTimeline, parameters: Parameters = .standard) -> [Need] {
        var result: [Need] = []
        for block in timeline.blocks {
            // Browse size is the most a minute is ever given, so a short event is asked for the minutes that make its height at that scale.
            let reach = Int((parameters.minimumItemHeight / parameters.browseScale).rounded(.up))
            result.append(Need(
                start: block.displayStartMinute, end: min(timeline.totalMinutes, max(block.displayEndMinute, block.displayStartMinute + reach)),
                height: parameters.minimumItemHeight
            ))
        }
        for marker in timeline.markers {
            let window = parameters.markerWindowMinutes / 2
            result.append(Need(
                start: max(0, marker.positionMinute - window), end: min(timeline.totalMinutes, marker.positionMinute + window),
                height: parameters.minimumItemHeight
            ))
        }
        return result
    }

    /// This axis with its folded stretches opened where `needs` ask. A stretch that is not folded is left alone (it is already at
    /// browse size, the most this axis ever gives a minute).
    func assisted(by needs: [Need], parameters: Parameters = .standard) -> TimelineAxis {
        guard !needs.isEmpty else { return self }
        var result: [Segment] = []
        for segment in segments {
            guard segment.isFolded else { result.append(segment); continue }
            result += Self.open(segment, for: needs, parameters: parameters)
        }
        return TimelineAxis(totalMinutes: totalMinutes, segments: result)
    }

    private static func open(_ segment: Segment, for needs: [Need], parameters: Parameters) -> [Segment] {
        // The scale each need asks for inside this fold, as stretches clipped to it.
        var asks: [(start: Int, end: Int, scale: CGFloat)] = needs.compactMap { need in
            let start = max(need.start, segment.startMinute), end = min(need.end, segment.endMinute)
            guard end > start else { return nil }
            // Asked of its whole span, even where only part of it is in this fold, so a long event is not squeezed to its fold edge.
            let span = CGFloat(max(1, need.end - need.start))
            let scale = min(parameters.browseScale, max(parameters.foldedScale, need.height / span))
            return (start, end, scale)
        }.sorted { $0.start < $1.start }
        guard !asks.isEmpty else { return [segment] }

        // Merge stretches that touch or are closer than a fold is worth, and stretches left over at the fold's edges.
        var merged: [(start: Int, end: Int, scale: CGFloat)] = []
        for ask in asks {
            if let last = merged.last, ask.start - last.end < parameters.minimumFoldMinutes {
                merged[merged.count - 1] = (last.start, max(last.end, ask.end), max(last.scale, ask.scale))
            } else {
                merged.append(ask)
            }
        }
        asks = merged
        if asks[0].start - segment.startMinute < parameters.minimumFoldMinutes { asks[0].start = segment.startMinute }
        if segment.endMinute - asks[asks.count - 1].end < parameters.minimumFoldMinutes { asks[asks.count - 1].end = segment.endMinute }

        var pieces: [Segment] = []
        var cursor = segment.startMinute
        func folded(_ start: Int, _ end: Int) -> Segment {
            Segment(
                startMinute: start, endMinute: end, pointsPerMinute: parameters.foldedScale,
                height: max(parameters.minimumFoldedHeight, CGFloat(end - start) * parameters.foldedScale), isFolded: true
            )
        }
        for ask in asks {
            if ask.start > cursor { pieces.append(folded(cursor, ask.start)) }
            pieces.append(Segment(
                startMinute: ask.start, endMinute: ask.end, pointsPerMinute: ask.scale,
                height: CGFloat(ask.end - ask.start) * ask.scale, isFolded: false
            ))
            cursor = ask.end
        }
        if cursor < segment.endMinute { pieces.append(folded(cursor, segment.endMinute)) }
        return pieces
    }
}
