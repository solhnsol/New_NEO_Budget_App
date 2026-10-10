import CoreGraphics

/// A whole minute of the day (0 ... 1440). Planned partitions have whole-minute boundaries; only an interpolated one may sit between.
typealias MinuteOfDay = Int

/// How the 24 hours of a day are cut into `slotCount` cells of the SAME height on screen. What changes from cell to cell is how much
/// time a cell stands for, not how tall it is. Inside a cell time maps linearly, so the whole mapping is piecewise linear, continuous
/// and strictly increasing: `timeToY` and `yToTime` are exact inverses of each other (up to floating point), at any zoom.
///
/// Pure value, no SwiftUI. Every day column shares the one partition, so the same time is at the same y in every column.
///
/// Boundaries are `Double` minutes so that a partition halfway between two others (see `interpolated`) keeps its exact position instead of
/// jumping from whole minute to whole minute. A planned partition has whole-minute boundaries (`wholeMinuteBoundaries`).
struct TemporalGridPartition: Equatable, Sendable {
    static let minutesPerDay = 24 * 60

    /// `slotCount + 1` minutes, `boundaries[0] == 0`, `boundaries.last == 1440`, strictly increasing.
    let boundaries: [Double]
    /// The height of the whole grid: `viewportHeight * zoomScale`. All cells are `totalHeight / slotCount` tall.
    let totalHeight: CGFloat

    var slotCount: Int { boundaries.count - 1 }
    var slotHeight: CGFloat { totalHeight / CGFloat(slotCount) }

    /// What is wrong with a candidate, or `nil` when it is a valid partition.
    static func violation(boundaries: [Double], totalHeight: CGFloat) -> String? {
        guard boundaries.count >= 2 else { return "needs at least one cell" }
        guard totalHeight > 0, totalHeight.isFinite else { return "total height must be positive" }
        guard boundaries.first == 0 else { return "first boundary must be 00:00" }
        guard boundaries.last == Double(minutesPerDay) else { return "last boundary must be 24:00" }
        for (a, b) in zip(boundaries, boundaries.dropFirst()) where !(b > a) { return "boundaries must strictly increase" }
        return nil
    }

    init?(boundaries: [Double], totalHeight: CGFloat) {
        guard Self.violation(boundaries: boundaries, totalHeight: totalHeight) == nil else { return nil }
        self.boundaries = boundaries
        self.totalHeight = totalHeight
    }

    init?(wholeMinutes: [MinuteOfDay], totalHeight: CGFloat) {
        self.init(boundaries: wholeMinutes.map(Double.init), totalHeight: totalHeight)
    }

    /// The same time cut into `slotCount` equal cells; the fallback when no better partition exists.
    static func uniform(slotCount: Int, totalHeight: CGFloat) -> TemporalGridPartition {
        let n = max(1, slotCount)
        // Whole minutes where 1440 divides evenly, otherwise spread the remainder so every cell is within a minute of equal.
        let bounds = (0...n).map { Double(($0 * minutesPerDay) / n) }
        return TemporalGridPartition(boundaries: bounds, totalHeight: totalHeight)!
    }

    // MARK: Cells

    func start(ofSlot slot: Int) -> Double { boundaries[slot] }
    func end(ofSlot slot: Int) -> Double { boundaries[slot + 1] }
    func minutes(inSlot slot: Int) -> Double { boundaries[slot + 1] - boundaries[slot] }
    func top(ofSlot slot: Int) -> CGFloat { CGFloat(slot) * slotHeight }

    /// The cell a minute belongs to: a boundary belongs to the later cell, 24:00 to the last.
    func slot(containingMinute minute: Double) -> Int {
        if minute <= 0 { return 0 }
        if minute >= Double(Self.minutesPerDay) { return slotCount - 1 }
        var low = 0, high = slotCount - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if boundaries[mid] <= minute { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func slot(atY y: CGFloat) -> Int { min(slotCount - 1, max(0, Int((y / slotHeight).rounded(.down)))) }

    // MARK: Mapping

    /// Where a time is drawn. Clamped to the day. Exact for any `Double` minute: 17 minutes are 17 minutes, 4.25 are 4.25.
    func timeToY(_ minute: Double) -> CGFloat {
        let clamped = min(max(minute, 0), Double(Self.minutesPerDay))
        let slot = slot(containingMinute: clamped)
        let length = boundaries[slot + 1] - boundaries[slot]
        return CGFloat(slot) * slotHeight + CGFloat((clamped - boundaries[slot]) / length) * slotHeight
    }

    func timeToY(_ minute: MinuteOfDay) -> CGFloat { timeToY(Double(minute)) }

    /// The time at a vertical position, clamped to the grid. Inside a long cell one point is many minutes, so ask `minutesPerPoint(...)`
    /// before trusting the last digit.
    func yToTime(_ y: CGFloat) -> Double {
        if y <= 0 { return 0 }
        if y >= totalHeight { return Double(Self.minutesPerDay) }
        let slot = slot(atY: y)
        let fraction = Double((y - CGFloat(slot) * slotHeight) / slotHeight)
        return boundaries[slot] + fraction * (boundaries[slot + 1] - boundaries[slot])
    }

    /// How many minutes one point stands for in the cell at `minute` (the coarseness of a touch there).
    func minutesPerPoint(atMinute minute: Double) -> Double { minutes(inSlot: slot(containingMinute: minute)) / Double(slotHeight) }

    /// The height of a span of time, from the y of its two ends: never from any text.
    func height(from start: Double, to end: Double) -> CGFloat { timeToY(end) - timeToY(start) }

    // MARK: Zoom

    /// The same cells and the same times, every cell taller by the same ratio. `zoomScale >= 1` and `totalHeight = viewportHeight * zoomScale`.
    func zoomed(viewportHeight: CGFloat, zoomScale: CGFloat) -> TemporalGridPartition {
        TemporalGridPartition(boundaries: boundaries, totalHeight: viewportHeight * max(1, zoomScale))!
    }

    // MARK: Interpolation

    /// The partition `progress` of the way from `from` to `to`: each boundary moves in a straight line, and nothing is rounded.
    /// The lines of the grid stay where they are (`slotHeight` is shared), the times under them slide. Because both ends are strictly
    /// increasing, so is every blend, and no cell gets shorter than the shorter of its two ends.
    static func interpolated(from: TemporalGridPartition, to: TemporalGridPartition, progress: Double) -> TemporalGridPartition? {
        guard from.slotCount == to.slotCount, from.totalHeight == to.totalHeight else { return nil }
        let p = min(max(progress, 0), 1)
        let blended = zip(from.boundaries, to.boundaries).map { (1 - p) * $0 + p * $1 }
        // Pin the ends exactly: (1-p)*0 + p*0 and (1-p)*1440 + p*1440 are exact only up to rounding.
        var pinned = blended
        pinned[0] = 0
        pinned[pinned.count - 1] = Double(minutesPerDay)
        return TemporalGridPartition(boundaries: pinned, totalHeight: from.totalHeight)
    }

    // MARK: Whole minutes and the existing axis

    var wholeMinuteBoundaries: [MinuteOfDay]? {
        let whole = boundaries.map { Int($0.rounded()) }
        return zip(whole, boundaries).allSatisfy { Double($0) == $1 } ? whole : nil
    }

    /// The partition as the existing `TimelineAxis` (whole-minute segments), to pass as `AllocationInput.fixedAxis` or to
    /// `TimelineGeometry(axis:)`.
    ///
    /// **Exact for a planned partition.** `TimelineAxis` keeps `Int` minutes in `Segment` and takes `Int` minutes in `y(minute:)`. A
    /// partition between two others has fractional boundaries, which that contract cannot hold: they are rounded to the nearest minute,
    /// so the axis can be off by up to half a minute's height (`maximumError`), and it moves in steps of a minute's height as the
    /// progress changes. That is why the interpolation here is done on the partition itself, in `Double`, and the adapter is only for
    /// code that needs the old type at rest. To keep precision through `TimelineAxis` it would need `Double` minutes in `Segment`
    /// (or an integer unit finer than a minute, such as 1/60), which is a change to a contract the whole timeline uses.
    func timelineAxis() -> (axis: TimelineAxis, isExact: Bool, maximumError: CGFloat) {
        var rounded = boundaries.map { Int($0.rounded()) }
        rounded[0] = 0
        rounded[rounded.count - 1] = Self.minutesPerDay
        var error: CGFloat = 0
        for index in 0..<slotCount {
            let ppm = slotHeight / CGFloat(boundaries[index + 1] - boundaries[index])
            error = max(error, CGFloat(abs(Double(rounded[index]) - boundaries[index])) * ppm)
        }
        var segments: [TimelineAxis.Segment] = []
        for index in 0..<slotCount where rounded[index + 1] > rounded[index] {
            let minutes = rounded[index + 1] - rounded[index]
            segments.append(TimelineAxis.Segment(
                startMinute: rounded[index], endMinute: rounded[index + 1], pointsPerMinute: slotHeight / CGFloat(minutes), height: slotHeight, isFolded: false
            ))
        }
        return (TimelineAxis(totalMinutes: Self.minutesPerDay, segments: segments), error == 0 && segments.count == slotCount, error)
    }
}

// MARK: How a compressed cell is drawn

/// How much time one cell stands for, as the compression rail beside the hour labels draws it (a candidate look, not a final design). The
/// grid lines themselves are the same for every cell; only the rail says that a cell is compressed.
enum SlotCompression: Int, Comparable, CaseIterable, Sendable {
    /// One hour or less: a continuous line.
    case continuous
    /// More than one hour, up to three: a faint dotted line.
    case dotted
    /// More than three hours: a fold pattern.
    case folded

    static func < (lhs: SlotCompression, rhs: SlotCompression) -> Bool { lhs.rawValue < rhs.rawValue }

    init(minutes: Double) {
        switch minutes {
        case ...60.0001: self = .continuous
        case ...180.0001: self = .dotted
        default: self = .folded
        }
    }

    /// Whether the cell writes the time range it covers (its end, and for how long) beside its start.
    var showsRange: Bool { self >= .dotted }

    /// How visible the start and the end labels of the two ends of a change are, at `progress` 0 ... 1: the first day's fade out
    /// over the first half and the second's fade in over the second half, so they are never both on screen and the middle of a change shows
    /// no time label. Only the two planned (whole minute) partitions are ever labelled; a time in between is never written.
    static func labelOpacities(progress: Double) -> (from: Double, to: Double) {
        (min(1, max(0, 1 - 2 * progress)), min(1, max(0, 2 * progress - 1)))
    }
}
