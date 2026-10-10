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
///     E1  very thin card, no text
///     E0  a thin line in the event's colour
///
/// Going down the order is: transactions, end time, start time, title. Every threshold is derived from real line heights (and so from
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
        /// Each thing begins to appear only once the one before it is fully there, so going down the title is the last to go.
        /// The start time sits on the title's line, so it needs that line and a little more.
        var startNeed: CGFloat { titleNeed + ramp }
        /// The end time has a line of its own at the bottom, clear of the title's.
        var endNeed: CGFloat { max(titleNeed + timeLine + 2 * padding, startNeed + ramp) }
        /// A count of linked transactions shares the end time's line.
        var summaryNeed: CGFloat { endNeed + ramp }
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

    var showsTitle: Bool { title > 0 }
    var showsStartTime: Bool { startTime > 0 }
    var showsEndTime: Bool { endTime > 0 }

    /// How much of `value` is there above `need`: 0 at the threshold, 1 a `ramp` higher.
    private static func appearing(_ value: CGFloat, over need: CGFloat, ramp: CGFloat) -> CGFloat {
        guard ramp > 0 else { return value >= need ? 1 : 0 }
        return min(1, max(0, (value - need) / ramp))
    }

    static func make(height: CGFloat, insideCount: Int = 0, metrics: Metrics = .standard()) -> EventPresentation {
        let ramp = metrics.ramp
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
        let capacity = max(0, Int(((height - metrics.reserved) / metrics.rowHeight).rounded(.down)))
        let rows = InlineAllocationPlan.make(allocationCount: insideCount, rowCapacity: capacity)
        let hasRows = rows.shown > 0 || rows.showsSummaryRow
        let summary = insideCount > 0 && !hasRows ? appearing(height, over: metrics.summaryNeed, ramp: ramp) : 0
        return EventPresentation(
            height: height, level: level, card: card,
            title: appearing(height, over: metrics.titleNeed, ramp: ramp),
            startTime: appearing(height, over: metrics.startNeed, ramp: ramp),
            endTime: endTime, transactionSummary: summary,
            transactions: hasRows ? appearing(height, over: metrics.detailNeed, ramp: ramp) : 0,
            shownRows: rows.shown, hiddenRows: rows.hidden, showsSummaryRow: rows.showsSummaryRow
        )
    }
}
