import CoreGraphics
import Foundation

/// The hour ticks of the shared time axis and which of their labels are written, at every zoom.
///
/// There is a tick at every whole hour, at the real y of that hour (`partition.timeToY(hour * 60)`), drawn on the axis only: nothing is added
/// inside the grid. Which hours are *labelled* is decided once for a partition from the heights it has at zoom 1, as an order of priority and
/// the zoom at which each label first fits, so that:
///
///   - the grid's own boundaries come first (they are whole hours too), then the other hours one at a time, each the one farthest (in y) from
///     every label chosen so far, which spreads the additions evenly over the day;
///   - a label is written from the zoom at which it clears its neighbours by the font height plus a margin; the labels written at a zoom are
///     always a prefix of that order, so zooming in only ever adds labels and zooming out removes them in the opposite order: nothing
///     flickers, and no two written labels ever touch.
///
/// Distances scale with the zoom, so the order itself does not depend on it. Pure and deterministic.
struct HourTickPlan: Equatable {
    static let hours = Array(0...24)

    /// Hours in the order their labels are added.
    let order: [Int]
    /// The zoom (≥ 1) from which the label of each hour in `order` is written.
    let requiredZoom: [Double]
    /// The y-spacing a label needs: its line height plus a margin.
    let minimumGap: CGFloat
    let labelHeight: CGFloat

    /// How much zoom it takes for a label to go from nothing to fully written once it fits.
    static let rampZoom = 0.15

    static func labelLineHeight(fontSize: CGFloat = 10) -> CGFloat { ceil(fontSize * 1.2) }

    /// `partition` at zoom 1 (its `totalHeight` is the viewport). `labelHeight` is the font's line height, `margin` the clear space kept between two labels.
    ///
    /// A label is centred on its hour's y, except the first and the last, which are held inside the axis (00:00 at the top edge, 24:00 at the bottom
    /// edge). So at zoom z the centre of hour h is `y(h)·z`, of 00:00 `labelHeight/2` and of 24:00 `total·z − labelHeight/2`: each affine in z, and a pair
    /// of labels needs the zoom at which their centres are a gap apart. A label that would be cut off by the edge of the axis waits for the zoom where it is not.
    static func make(partition: TemporalGridPartition, labelHeight: CGFloat = labelLineHeight(), margin: CGFloat = 4) -> HourTickPlan {
        let gap = labelHeight + margin
        let total = partition.totalHeight
        let half = labelHeight / 2
        func y(_ hour: Int) -> CGFloat { partition.timeToY(Double(hour * 60)) }
        /// Centre offset beyond `y·z`: the first label is held at the top, the last at the bottom.
        func offset(_ hour: Int) -> CGFloat { hour == 0 ? half : (hour == 24 ? -half : 0) }
        /// The zoom from which an hour's label is whole inside the axis.
        func insideZoom(_ hour: Int) -> Double {
            if hour == 0 || hour == 24 { return 1 }
            return Double(max(half / max(y(hour), 0.0001), half / max(total - y(hour), 0.0001)))
        }
        /// The zoom from which two labels are a gap apart.
        func pairZoom(_ a: Int, _ b: Int) -> Double {
            let (upper, lower) = y(a) <= y(b) ? (a, b) : (b, a)
            let distance = y(lower) - y(upper)
            let shift = offset(lower) - offset(upper)         // the lower centre is distance·z + shift below the upper one
            return distance > 0 ? Double((gap - shift) / distance) : .infinity
        }
        let boundaryHours = Set(partition.boundaries.compactMap { $0.truncatingRemainder(dividingBy: 60) == 0 ? Int($0 / 60) : nil })
        var order: [Int] = []
        var zooms: [Double] = []
        var running = 1.0

        func add(_ hour: Int) {
            running = max(running, insideZoom(hour))
            for other in order { running = max(running, pairZoom(other, hour)) }
            order.append(hour)
            zooms.append(running)
        }
        func farthest(from candidates: [Int]) -> Int? {
            var best: (hour: Int, distance: CGFloat)?
            for hour in candidates {
                let distance = order.map { abs(y($0) - y(hour)) }.min() ?? .infinity
                if best == nil || distance > best!.distance + 1e-9 || (abs(distance - best!.distance) <= 1e-9 && hour < best!.hour) { best = (hour, distance) }
            }
            return best?.hour
        }
        var boundaries = hours.filter(boundaryHours.contains)
        while let next = farthest(from: boundaries) { add(next); boundaries.removeAll { $0 == next } }
        var others = hours.filter { !boundaryHours.contains($0) }
        while let next = farthest(from: others) { add(next); others.removeAll { $0 == next } }
        return HourTickPlan(order: order, requiredZoom: zooms, minimumGap: gap, labelHeight: labelHeight)
    }

    /// Where a written label's centre is at `zoom`, for a partition made at zoom 1 with this plan.
    func centre(hour: Int, y: CGFloat, totalHeight: CGFloat, zoom: Double) -> CGFloat {
        let z = CGFloat(zoom)
        if hour == 0 { return labelHeight / 2 }
        if hour == 24 { return totalHeight * z - labelHeight / 2 }
        return y * z
    }

    /// 0 ... 1: how much of the label of `hour` is written at `zoom`. A label starts to appear at the zoom where it fits and is whole a ramp later.
    func opacity(hour: Int, zoom: Double) -> Double {
        guard let index = order.firstIndex(of: hour) else { return 0 }
        let required = requiredZoom[index]
        if required <= 1 + 1e-9 { return zoom >= 1 ? 1 : 0 }       // fits at the smallest size: always written
        return min(1, max(0, (zoom - required) / Self.rampZoom))
    }

    /// The hours with any of their label written at `zoom`.
    func labelled(zoom: Double) -> [Int] {
        order.indices.filter { zoom >= requiredZoom[$0] }.map { order[$0] }.sorted()
    }

    /// The hours written in full at `zoom`.
    func fullyLabelled(zoom: Double) -> [Int] { hoursSorted { opacity(hour: $0, zoom: zoom) >= 1 } }

    private func hoursSorted(_ include: (Int) -> Bool) -> [Int] { order.filter(include).sorted() }
}
