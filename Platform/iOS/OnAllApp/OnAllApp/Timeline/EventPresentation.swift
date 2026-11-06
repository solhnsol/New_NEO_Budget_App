import CoreGraphics
import Foundation

/// How one event is drawn at the height the shared axis gives it. The one place where height decides what is shown; nothing else
/// (not whether a day is moving, not how many other events there are) changes what an event looks like.
///
/// An event is the same event at every height. As its height shrinks the things inside it go in a fixed order, and the card thins
/// into a line in its own colour:
///
///     E4  card, title, start and end time, linked transactions as rows
///     E3  card, title, start and end time, linked transactions only as a count (or not at all)
///     E2  low card, title (the start time goes first as it gets lower, then the end time)
///     E1  thin card: the title in small type inside the card while there is room for a small line, then no text
///     E0  a thin line in the event's colour
///
/// Going down the order is: transactions, end time, start time, title, small title. A card too thin for its title never gets a tab or
/// header above it: the title gets smaller inside the card, and below the small line's height it is gone (the card is still touched and
/// opened as the event). Every threshold is derived from real line heights (and so from
/// Dynamic Type), and each thing fades in over `ramp` points above its threshold, so no level boundary is a jump. The start and end
/// of the event are never moved to fit text: only what is written changes.
struct EventPresentation: Equatable {
    enum Level: Int, Comparable, CaseIterable {
        case line = 0, sliver, low, summary, detail
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
        /// "E0" … "E4", the names the product rules use.
        var name: String { "E\(rawValue)" }
    }

    /// The measured sizes the thresholds come from.
    struct Metrics: Equatable {
        var titleLine: CGFloat
        var timeLine: CGFloat
        var rowHeight: CGFloat
        var padding: CGFloat
        /// Below this a card is only a line; above `cardHeight` it is fully a card.
        var lineHeight: CGFloat = 4
        var cardHeight: CGFloat = 9
        var ramp: CGFloat

        /// The sizes at the standard text size, grown with `scale`.
        static func standard(scale: CGFloat = 1) -> Metrics {
            Metrics(titleLine: 15 * scale, timeLine: 11 * scale, rowHeight: 15 * scale, padding: 2 * scale, ramp: 6 * scale)
        }

        /// From real font line heights (see `TextMeasurer.presentationMetrics`).
        static func measured(titleLine: CGFloat, timeLine: CGFloat, rowLine: CGFloat, scale: CGFloat) -> Metrics {
            Metrics(titleLine: titleLine, timeLine: timeLine, rowHeight: rowLine + 2 * scale, padding: 2 * scale, ramp: 6 * scale)
        }

        /// Room for one line of title.
        var titleNeed: CGFloat { titleLine + 2 * padding }
        /// The small title's type, against the title's (see `EventTitleLayer`).
        static let compactShare: CGFloat = 0.7
        /// Room for the title in small type: a card thinner than the title's line but at least this tall writes it small.
        var compactNeed: CGFloat { CardStyle.current.isApple ? 9 : (titleLine * Self.compactShare).rounded(.up) + padding }
        /// Each thing begins to appear only once the one before it is fully there, so going down the title is the last to go.
        /// The start time sits on the title's line, so it needs that line and a little more.
        var startNeed: CGFloat { titleNeed + ramp }
        /// The end time has a line of its own at the bottom, clear of the title's.
        var endNeed: CGFloat { max(titleNeed + timeLine + 2 * padding, startNeed + ramp) }
        /// A count of linked transactions shares the end time's line.
        /// Apple's card writes the time range under the title, so the count's pill waits for a second line below it.
        var summaryNeed: CGFloat { endNeed + ramp + (CardStyle.current.isApple ? 12 : 0) }
        /// What the card keeps free below the title for the end time's line.
        var reserved: CGFloat { endNeed }
        /// Room for the first transaction row.
        var detailNeed: CGFloat { reserved + rowHeight }
    }

    let height: CGFloat
    let level: Level
    /// 0 … 1: how much of a card (tinted fill and outline) there is; the rest is the colour of the line. The same view throughout.
    let card: CGFloat
    /// 0 … 1 each: how much of that text is shown.
    let title: CGFloat
    /// 0 … 1: the title in small type, for a card too thin for the title. It gives way to the title as the card gets tall enough for it.
    var compactTitle: CGFloat = 0
    /// 0 … 1: how far a card too thin for even the small title has become a dot (its name is written beside it, like a transaction's chip). 0 from the
    /// height that has room for the small title, 1 at the height of a line, so a card shrinks into the dot as it thins and grows out of it as it thickens.
    var dot: CGFloat = 0
    let startTime: CGFloat
    let endTime: CGFloat
    /// The count of linked transactions ("거래 N건"), when the rows do not fit.
    let transactionSummary: CGFloat
    /// The transactions as rows.
    let transactions: CGFloat
    /// How many rows there are room for: how many transactions are written, and how many are folded into "그 외".
    let shownRows: Int
    let hiddenRows: Int
    /// The last row summarises all (room for one row only, with several transactions).
    let showsSummaryRow: Bool
    /// 0 … 1 each: how much of the row at that index is there. A row fades in over `ramp` above the height that has room for it, as the title and the times do, so a
    /// card growing taller writes one more row without a jump. The first row is the stack's own (`transactions`).
    let rowReveals: [CGFloat]

    /// 0 … 1: how much of the "그 외 N건" row there is. It sits in the slot after the last row written, so when a taller card writes one more row it would jump a slot down;
    /// instead it fades out over the `ramp` below the height that adds the row and fades in again in its new slot, never moving while it is seen.
    let moreReveal: CGFloat

    func rowReveal(_ index: Int) -> CGFloat { rowReveals.indices.contains(index) ? rowReveals[index] : 1 }

    var showsTitle: Bool { title > 0 }
    /// Some title is written inside the card, in either size.
    var writesTitle: Bool { title > 0 || compactTitle > 0 }
    var showsStartTime: Bool { startTime > 0 }
    var showsEndTime: Bool { endTime > 0 }

    /// How much of `value` is there above `need`: 0 at the threshold, 1 a `ramp` higher.
    private static func appearing(_ value: CGFloat, over need: CGFloat, ramp: CGFloat) -> CGFloat {
        guard ramp > 0 else { return value >= need ? 1 : 0 }
        return min(1, max(0, (value - need) / ramp))
    }

    /// How many rows of room it takes before `count` transactions are written as rows (the "+N" row takes a slot of its own until everything fits), so a row's fade starts
    /// at the height it first appears at, not before.
    private static func rowsNeeded(toShow count: Int, of total: Int, maximumRows: Int) -> Int {
        (1...max(1, maximumRows)).first { InlineAllocationPlan.make(allocationCount: total, rowCapacity: $0, maximumRows: maximumRows).shown >= count } ?? maximumRows
    }

    /// `maximumRows`: the most rows a card writes for its transactions, however tall (the collapsed block's three unless the grid shows more).
    /// `rowRoom`: how far down the card its rows may go, when less than its height (a card drawn over it, an event inside it, begins there): the rows are
    /// written from that room, everything else from the height.
    static func make(
        height: CGFloat, insideCount: Int = 0, metrics: Metrics = .standard(), maximumRows: Int = InlineAllocationPlan.maximumRows, rowRoom: CGFloat? = nil
    ) -> EventPresentation {
        let ramp = metrics.ramp
        let rowsHeight = min(height, rowRoom ?? height)
        let level: Level
        switch height {
        case ..<metrics.lineHeight: level = .line
        case ..<metrics.titleNeed: level = .sliver
        case ..<metrics.summaryNeed: level = .low
        case ..<metrics.detailNeed: level = .summary
        default: level = .detail
        }
        let card = min(1, max(0, (height - metrics.lineHeight) / max(0.001, metrics.cardHeight - metrics.lineHeight)))
        let endTime = appearing(height, over: metrics.endNeed, ramp: ramp)
        // Rows come after the title and the end time's line.
        let capacity = max(0, Int(((rowsHeight - metrics.reserved) / metrics.rowHeight).rounded(.down)))
        let rows = InlineAllocationPlan.make(allocationCount: insideCount, rowCapacity: capacity, maximumRows: maximumRows)
        let hasRows = rows.shown > 0 || rows.showsSummaryRow
        let summary = insideCount > 0 && !hasRows ? appearing(height, over: metrics.summaryNeed, ramp: ramp) : 0
        var more: CGFloat = 1
        if rows.hidden > 0, rows.shown > 0 {
            let next = (capacity + 1...max(capacity + 1, maximumRows)).first { InlineAllocationPlan.make(allocationCount: insideCount, rowCapacity: $0, maximumRows: maximumRows).shown > rows.shown }
            let leaving = next.map { 1 - appearing(rowsHeight, over: metrics.reserved + CGFloat($0) * metrics.rowHeight - ramp, ramp: ramp) } ?? 1
            let arriving = rows.shown > 1 ? appearing(rowsHeight, over: metrics.reserved + CGFloat(rowsNeeded(toShow: rows.shown, of: insideCount, maximumRows: maximumRows) ) * metrics.rowHeight, ramp: ramp) : 1
            more = min(leaving, arriving)
        }
        let title = appearing(height, over: metrics.titleNeed, ramp: ramp)
        return EventPresentation(
            height: height, level: level, card: card,
            title: title, compactTitle: appearing(height, over: metrics.compactNeed, ramp: ramp) * (1 - title),
            dot: min(1, max(0, (metrics.compactNeed - height) / max(0.001, metrics.compactNeed - metrics.lineHeight))),
            startTime: appearing(height, over: metrics.startNeed, ramp: ramp),
            endTime: endTime, transactionSummary: summary,
            transactions: hasRows ? appearing(rowsHeight, over: metrics.detailNeed, ramp: ramp) : 0,
            shownRows: rows.shown, hiddenRows: rows.hidden, showsSummaryRow: rows.showsSummaryRow,
            rowReveals: (0..<rows.shown).map { appearing(rowsHeight, over: metrics.reserved + CGFloat(rowsNeeded(toShow: $0 + 1, of: insideCount, maximumRows: maximumRows)) * metrics.rowHeight, ramp: ramp) },
            moreReveal: more
        )
    }
}
