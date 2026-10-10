import CoreGraphics

/// Which written things of a day fit without touching anything else. Pure geometry on a `GridDayPlacement`: it hides text (never a card, a
/// line or a dot), keeps every identity, and decides in one fixed order, so the same placement always gives the same plan:
///
///   1. event titles, in time order (a title that would run into one already written is left out; its card stays),
///   2. transaction texts (left out where they would run into a written title or another text),
///   3. an event's time range (left out where it would run into anything written).
///
/// It is the only analysis done for text and it is a few rectangle tests per day, run when the partition changes.
struct GridTransactionCluster: Equatable {
    /// Every transaction the cluster stands for, in time order: none is dropped.
    let ids: [String]
    let minutes: [Int]
    let amounts: [Int64?]
    /// The y the dot or the count is drawn at.
    let y: CGFloat
    /// A single transaction whose text fits.
    let textShown: Bool
    var count: Int { ids.count }
}

struct GridTextPlan: Equatable {
    let titlesShown: Set<String>
    let timesShown: Set<String>
    let clusters: [GridTransactionCluster]
    /// Every written rectangle, for testing that nothing written touches anything else written.
    let writtenRects: [CGRect]
}

enum GridTextLayout {
    /// Dots closer than this (centre to centre) are one count.
    static let dotSpacing: CGFloat = 9
    static let maximumClusterHeight: CGFloat = 28
    private static let gap: CGFloat = 1

    static func titleWidth(_ title: String, scale: CGFloat) -> CGFloat { CGFloat(title.count) * 12.5 * scale + 12 * scale }
    static func amountText(_ minorUnits: Int64?) -> String { minorUnits.map { "₩" + $0.formatted() } ?? "₩—" }
    static func amountWidth(_ minorUnits: Int64?, scale: CGFloat) -> CGFloat { CGFloat(amountText(minorUnits).count) * 6.3 * scale + 10 * scale }

    static func resolve(entities: GridDayEntities, placement: GridDayPlacement, columnWidth: CGFloat, scale: CGFloat) -> GridTextPlan {
        var written: [CGRect] = []
        func free(_ rect: CGRect) -> Bool { !written.contains { $0.insetBy(dx: -gap, dy: -gap).intersects(rect) } }
        let eventByID = Dictionary(entities.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cardRight = columnWidth - 26

        var titles: Set<String> = []
        for event in placement.events where event.presentation.title > 0 {
            guard let source = eventByID[event.id] else { continue }
            let left = 4 + CGFloat(source.indent) * 10
            let right = cardRight - (source.pullsInOnRight ? 8 : 0)
            let rect = CGRect(x: left, y: event.top + 2 * scale, width: min(titleWidth(source.title, scale: scale), right - left), height: 15 * scale)
            if free(rect) { written.append(rect); titles.insert(event.id) }
        }

        // Transactions: one cluster per run of dots that would touch.
        let independent = placement.independent
        var groups: [[GridTransactionPlacement]] = []
        for transaction in independent {
            // A run is also never taller than `maximumClusterHeight`, so one count does not stand for a long stretch of time.
            if let first = groups.last?.first, let last = groups.last?.last, transaction.y - last.y < dotSpacing, transaction.y - first.y < maximumClusterHeight { groups[groups.count - 1].append(transaction) } else { groups.append([transaction]) }
        }
        var clusters: [GridTransactionCluster] = []
        for group in groups {
            var shown = false
            let y = group.map(\.y).reduce(0, +) / CGFloat(group.count)
            if group.count == 1, let only = group.first, only.reveal >= 1 {
                let width = amountWidth(only.minorUnits, scale: scale)
                let right = columnWidth - 16
                let rect = CGRect(x: right - width, y: only.y - 6 * scale, width: width, height: 12 * scale)
                if free(rect) { written.append(rect); shown = true }
            }
            clusters.append(GridTransactionCluster(ids: group.map(\.id), minutes: group.map(\.minute), amounts: group.map(\.minorUnits), y: y, textShown: shown))
        }

        var times: Set<String> = []
        for event in placement.events where event.presentation.endTime >= 1 {
            guard let source = eventByID[event.id], source.groupSize == 1 else { continue }
            let rect = CGRect(x: 4, y: event.bottom - 13 * scale, width: 78 * scale, height: 11 * scale)
            if free(rect) { written.append(rect); times.insert(event.id) }
        }
        return GridTextPlan(titlesShown: titles, timesShown: times, clusters: clusters, writtenRects: written)
    }
}
