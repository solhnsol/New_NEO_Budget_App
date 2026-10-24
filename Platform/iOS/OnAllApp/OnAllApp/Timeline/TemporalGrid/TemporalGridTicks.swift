import CoreGraphics

/// One whole hour of the shared time axis, as it is drawn at this instant.
struct HourAxisState: Equatable {
    let hour: Int
    /// The real y of the hour on the partition being drawn (`timeToY(hour · 60)`), whatever is shown.
    let y: CGFloat
    /// 0 ... 1: how much of the tick there is.
    let tickOpacity: Double
    /// Where the label's centre is (the first label is held at the top edge, the last at the bottom edge).
    let labelCentre: CGFloat
    /// 0 ... 1: how much of the label there is. Never more than the tick's.
    let labelOpacity: Double
    /// 0 ... 1: how much the hour is a line of the grid (a cell boundary) rather than only an hour with room. Set by `fixedGridLayout`, else 0.
    var gridWeight: Double = 0
}

/// The hour ticks and labels of the time axis. Where an hour is drawn and whether it is drawn are two separate things:
///
///   - **where**: always the partition's own y of that hour, at the zoom and between the days it is at that instant;
///   - **whether**: a fixed order of importance of the 25 hours (noon, then the quarters of the day, then ever finer), and an hour is shown only as
///     far as the space *at that instant* leaves between it and every hour more important than it: no room, no tick (a tick closer than `tickGap`)
///     and no label (closer than the label's height plus a margin). Between "no room" and "room" the opacity goes smoothly from 0 to 1 over a ramp
///     of points.
///
/// Nothing else takes part: no zoom thresholds, no remembered sets, no timers. So a tick or a label that has room is there, zooming in grows the
/// room continuously (everything scales together) and brings ticks and labels in, zooming out takes them away along the very same path, and between
/// two days the ticks slide with the partition while the opacities follow the changing gaps. Ticks are never merged and no range is summarised;
/// an hour without room is simply left out. Pure.
enum HourAxis {
    /// Most important first. Fixed: it does not depend on the partition, the zoom or the day.
    static let importance: [Int] = [0, 24, 12, 6, 18, 3, 9, 15, 21, 2, 4, 8, 10, 14, 16, 20, 22, 1, 5, 7, 11, 13, 17, 19, 23]

    struct Metrics: Equatable {
        var labelHeight: CGFloat
        var labelMargin: CGFloat = 4
        /// Points over which a label goes from absent to whole once there is room for it.
        var labelRamp: CGFloat = 8
        var tickGap: CGFloat = 5
        var tickRamp: CGFloat = 4

        /// The label font's line height at `scale` (the axis keeps the labels readable, but not larger than `maximumScale`: the axis column is a fixed width).
        init(textScale: CGFloat = 1) {
            labelHeight = ceil(10 * min(max(textScale, 1), Self.maximumScale) * 1.2)
        }
        static let maximumScale: CGFloat = 1.4
        var labelFontSize: CGFloat { labelHeight / 1.2 }
        var labelGap: CGFloat { labelHeight + labelMargin }
    }

    /// 0 at `edge`, 1 at `edge + ramp`, smooth between.
    static func smooth(_ value: CGFloat, over ramp: CGFloat) -> Double {
        guard ramp > 0 else { return value > 0 ? 1 : 0 }
        let t = Double(min(max(value / ramp, 0), 1))
        return t * t * (3 - 2 * t)
    }

    /// The 25 hours (00 ... 24) on `partition` as drawn now. `first`: hours that go before every other in the order of importance (keeping their
    /// own order), such as the hours a fixed grid draws a line across the days at, so their labels are the ones that keep their room.
    static func layout(partition: TemporalGridPartition, metrics: Metrics, first: Set<Int> = []) -> [HourAxisState] {
        let importance = first.isEmpty ? Self.importance : Self.importance.filter { first.contains($0) } + Self.importance.filter { !first.contains($0) }
        let total = partition.totalHeight
        let half = metrics.labelHeight / 2
        let y = (0...24).map { partition.timeToY(Double($0 * 60)) }
        let centre: [CGFloat] = (0...24).map { $0 == 0 ? half : ($0 == 24 ? total - half : y[$0]) }
        var result: [HourAxisState] = []
        for hour in 0...24 {
            let rank = importance.firstIndex(of: hour) ?? 24
            var tick = 1.0, label = 1.0
            for other in importance.prefix(rank) {
                tick = min(tick, smooth(abs(y[hour] - y[other]) - metrics.tickGap, over: metrics.tickRamp))
                label = min(label, smooth(abs(centre[hour] - centre[other]) - metrics.labelGap, over: metrics.labelRamp))
            }
            // A label that would be cut by the top or bottom edge of the axis fades out as it gets there (the first and last are held inside it).
            if hour != 0 && hour != 24 {
                label = min(label, smooth(y[hour], over: half), smooth(total - y[hour], over: half))
            }
            result.append(HourAxisState(hour: hour, y: y[hour], tickOpacity: tick, labelCentre: centre[hour], labelOpacity: min(label, tick)))
        }
        return result
    }

    /// 1 when the whole hour is a boundary of the partition, down to 0 five minutes away from every boundary.
    static func gridWeight(hour: Int, partition: TemporalGridPartition) -> Double {
        let nearest = partition.boundaries.map { abs($0 - Double(hour * 60)) }.min() ?? 5
        return max(0, 1 - nearest / 5)
    }

    /// The hours of a fixed grid: those on a cell boundary go first in the order of importance. A partition between two days is NOT laid out as
    /// one: which hours are boundaries and which hours have room are decisions that flip at a point, and between days far apart in shape the boundaries
    /// sweep over the hours, so deciding on the blended partition made labels pop in and out, swap bold and gray, and jump to another winner when the order
    /// changed. Each end is laid out as it is at rest and every number of the hour (y, label centre, opacities, grid weight) is the straight blend of the
    /// two ends' with the same progress as the cards' y: a label slides with its card, fades to its value at the other day and never pops. At 0 and 1,
    /// and for a planned partition, it is exactly the layout at rest.
    static func fixedGridLayout(partition: TemporalGridPartition, metrics: Metrics) -> [HourAxisState] {
        guard let blend = partition.blend else {
            let weights = (0...24).map { gridWeight(hour: $0, partition: partition) }
            let first = Set((0...24).filter { weights[$0] >= 0.5 })
            var states = layout(partition: partition, metrics: metrics, first: first)
            for hour in 0...24 { states[hour].gridWeight = weights[hour] }
            return states
        }
        let a = fixedGridLayout(partition: blend.from, metrics: metrics)
        let b = fixedGridLayout(partition: blend.to, metrics: metrics)
        let p = blend.progress, cp = CGFloat(p)
        func mix(_ x: Double, _ y: Double) -> Double { (1 - p) * x + p * y }
        return zip(a, b).map { x, y in
            HourAxisState(
                hour: x.hour, y: (1 - cp) * x.y + cp * y.y, tickOpacity: mix(x.tickOpacity, y.tickOpacity),
                labelCentre: (1 - cp) * x.labelCentre + cp * y.labelCentre, labelOpacity: mix(x.labelOpacity, y.labelOpacity),
                gridWeight: mix(x.gridWeight, y.gridWeight)
            )
        }
    }
}
