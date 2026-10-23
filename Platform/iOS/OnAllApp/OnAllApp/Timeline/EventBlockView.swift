import NEOBudgetCalendar
import SwiftUI

/// How many linked transactions a collapsed event block shows, and what it says about the rest. Pure, so it is tested.
///
/// Block height reflects time, so spending never makes a block taller. A collapsed block shows at most `maximumItems`
/// transactions (the largest ones; see `AllocationOrdering`), then one "+N건 · 합계" row. When the block is too short
/// for that, it falls back to a single summary row, and when it has no room for any row, to a chip in the title.
struct InlineAllocationPlan: Equatable {
    /// Allocations shown as rows, in order.
    let shown: Int
    /// Allocations folded into the "+N" row; 0 means no such row.
    let hidden: Int
    /// With room for a single row but several transactions, that one row is a summary ("4건 · 합계") rather than a
    /// lone "+4건" that names nothing.
    let showsSummaryRow: Bool
    /// A block with no room for rows still tells how many transactions are linked.
    let showsSummaryChip: Bool

    static let maximumItems = 2
    /// Two transactions plus the "+N" row.
    static let maximumRows = maximumItems + 1
    static let titleHeight: CGFloat = 16
    static let timeHeight: CGFloat = 14
    static let rowHeight: CGFloat = 15
    static let verticalPadding: CGFloat = 6

    static func make(allocationCount: Int, blockHeight: CGFloat, showsTime: Bool) -> InlineAllocationPlan {
        let free = blockHeight - verticalPadding - titleHeight - (showsTime ? timeHeight : 0)
        return make(allocationCount: allocationCount, rowCapacity: Int((free / rowHeight).rounded(.down)))
    }

    /// The same decision from the number of rows there is room for, however that was measured. `maximumRows` is how many rows (items and the "+N" row) a card
    /// may ever write: the collapsed block's three by default, more on a grid that lets a tall card show everything it holds.
    static func make(allocationCount: Int, rowCapacity: Int, maximumRows: Int = InlineAllocationPlan.maximumRows) -> InlineAllocationPlan {
        guard allocationCount > 0 else { return InlineAllocationPlan(shown: 0, hidden: 0, showsSummaryRow: false, showsSummaryChip: false) }
        let maximumItems = maximumRows - 1
        let rows = max(0, min(maximumRows, rowCapacity))
        if rows == 0 { return InlineAllocationPlan(shown: 0, hidden: 0, showsSummaryRow: false, showsSummaryChip: true) }
        if rows == 1 {
            if allocationCount == 1 { return InlineAllocationPlan(shown: 1, hidden: 0, showsSummaryRow: false, showsSummaryChip: false) }
            return InlineAllocationPlan(shown: 0, hidden: allocationCount, showsSummaryRow: true, showsSummaryChip: false)
        }
        // With room for the "+N" row too (the most rows) the most items are shown; with fewer rows, one fewer item than rows plus "+N".
        let itemRows = rows >= maximumRows ? maximumItems : rows
        if allocationCount <= itemRows && allocationCount <= maximumItems {
            return InlineAllocationPlan(shown: allocationCount, hidden: 0, showsSummaryRow: false, showsSummaryChip: false)
        }
        let shown = min(maximumItems, rows - 1)
        return InlineAllocationPlan(shown: shown, hidden: allocationCount - shown, showsSummaryRow: false, showsSummaryChip: false)
    }

    static func showsTime(blockHeight: CGFloat) -> Bool { blockHeight >= 44 }
}

/// The order linked transactions are listed in. Collapsed blocks lead with the largest; expanded blocks follow the day.
enum AllocationOrdering {
    /// The amount used for ranking, the best size there is: a settled or inferred amount, an estimate, or the least a
    /// range can be. Only a transaction with no amount at all ranks last.
    static func rankingAmount(_ item: AllocationItem) -> Int64 {
        switch item.allocatedAmount {
        case let .exact(value), let .inferred(value, _), let .estimated(value): return value
        case .range: return item.allocatedAmount.bounds.lower
        case .unknown: return 0
        }
    }

    static func byAmountDescending(_ items: [AllocationItem]) -> [AllocationItem] {
        items.sorted { lhs, rhs in
            let (left, right) = (rankingAmount(lhs), rankingAmount(rhs))
            if left != right { return left > right }
            return (lhs.occurredAtUnixMilliseconds, lhs.allocationID) < (rhs.occurredAtUnixMilliseconds, rhs.allocationID)
        }
    }

    static func byTime(_ items: [AllocationItem]) -> [AllocationItem] {
        items.sorted { ($0.occurredAtUnixMilliseconds, $0.allocationID) < ($1.occurredAtUnixMilliseconds, $1.allocationID) }
    }
}

/// "합계" for a block's linked transactions without ever mixing currencies or looking more certain than it is.
/// Refunds subtract. Only what is settled counts toward the number; anything unsettled is said out loud.
enum LinkedTotal {
    static func text(spend: [AmountAggregate], refunds: [AmountAggregate]) -> String? {
        let currencies = Set(spend.map(\.currency) + refunds.map(\.currency)).sorted()
        let parts: [String] = currencies.compactMap { currency in
            let spent = spend.first { $0.currency == currency }
            let returned = refunds.first { $0.currency == currency }
            let net = (spent?.knownMinorUnits ?? 0) - (returned?.knownMinorUnits ?? 0)
            let unresolved = (spent?.unresolvedCount ?? 0) + (returned?.unresolvedCount ?? 0)
            let amount = Formatting.money(net, currency: currency)
            if unresolved == 0 { return amount }
            return net == 0 ? "금액 미정 \(unresolved)건" : "\(amount) 외 미정 \(unresolved)건"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The first line of an event card: its title and the start time beside it. Drawn in a layer above all cards (see `TimelineGridView`),
/// so the card it belongs to can sit under another card without losing its title. How much of each there is comes from the card's
/// `EventPresentation`; the text never changes size or place for it, it only fades in.
struct EventTitleLayer: View {
    let block: EventBlock
    let frame: CGRect
    let place: DayContentLayout.TitlePlacement
    /// Where the day's column ends, in the same coordinates as `frame`: the farthest a title that had to move may run.
    var columnRight: CGFloat = 0
    static let horizontalPadding: CGFloat = 6
    static let rowHeight: CGFloat = InlineAllocationPlan.titleHeight + 3

    var scale: CGFloat = 1
    var zoneIdentifier = ""
    var presentation = EventPresentation.make(height: 1000)
    /// The title is kept shorter than the card, clear of a transaction line's text; the start time then has no place beside it.
    var maxTitleWidth: CGFloat?
    /// The title and the time together fit the card's width.
    var startFits = true
    /// A transaction line is written where the start time would be.
    var startIsCovered = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if presentation.title > 0 { fullTitle }
            if presentation.compactTitle > 0 { compactTitle }
        }
    }

    /// A card too thin for the title writes it in small type, in the middle of the card's height and cut at the card's width; nothing about it
    /// moves aside for another title (there is no room in a thin card to move it to).
    private var compactTitle: some View {
        let size = 12 * EventPresentation.Metrics.compactShare * scale
        let line = ceil(size * 1.25)
        return Text(block.title)
            .font(.system(size: size, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, Self.horizontalPadding)
            .frame(width: max(0, frame.width), height: line, alignment: .leading)
            .opacity(presentation.compactTitle)
            .offset(x: frame.minX, y: frame.minY + (frame.height - line) / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var fullTitle: some View {
        HStack(spacing: 3) {
            if block.continuesFromPreviousDay { Image(systemName: "arrow.up").font(.system(size: 8)) }
            Text(block.title).font(.caption.weight(.semibold)).lineLimit(1)
            if block.isRecurringInstance { Image(systemName: "repeat").font(.system(size: 8)) }
            Spacer(minLength: 2)
            // The start, in the top right corner; a title that has been moved aside leaves it out rather than crowd the line.
            if startFits, !startIsCovered, maxTitleWidth == nil, !block.continuesFromPreviousDay, !zoneIdentifier.isEmpty, place.dx == 0, place.dy == 0, !place.overflows {
                CornerTime(text: Formatting.shortClock(block.startUnixMilliseconds, zoneIdentifier: zoneIdentifier), scale: scale)
                    .opacity(presentation.startTime)
            }
        }
        .padding(.horizontal, Self.horizontalPadding).padding(.top, 3)
        .frame(width: max(0, min(place.overflows ? columnRight - frame.minX - place.dx : frame.width - place.dx, maxTitleWidth.map { $0 + 2 * Self.horizontalPadding } ?? .infinity)), height: (InlineAllocationPlan.titleHeight + 3) * scale, alignment: .leading)
        .opacity(presentation.title)
        .offset(x: frame.minX + place.dx, y: frame.minY + place.dy)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An event's card: its colour, its linked transactions that happened within its time, the end time, and nothing else. The title and
/// start are drawn in a layer above all cards (`EventTitleLayer`). It is one view at every height: as the card gets lower its fill and
/// outline give way to the colour of the line it ends up as, and the text inside fades by `presentation`; nothing is swapped.
struct EventBlockView: View {
    let block: EventBlock
    let height: CGFloat
    /// How far down the title is drawn (see `DayContentLayout.titlePlacements`); the rows below follow it.
    var titleOffset: CGFloat = 0
    var rows: [AllocationItem] = []
    var presentation = EventPresentation.make(height: 1000)
    var scale: CGFloat = 1
    /// The title is in a header above the card: the card's own top edge is then drawn firmly, as the real start.
    var hasHeader = false
    var zoneIdentifier = ""
    var endIsCovered = false
    var startIsCovered = false
    @Environment(\.colorScheme) private var colorScheme
    /// Where each shown row's transaction really happened, in the card's own coordinates (from its top): its leader bends from there.
    var anchors: [CGFloat] = []
    /// The stack's padding and spacing, which `DayRenderPlan.rowsFrame` also places the rows by.
    static let verticalPadding: CGFloat = 3
    static let rowSpacing: CGFloat = 1

    var body: some View {
        let color = Color(hex: block.calendarColorHex) ?? Theme.accent
        let missing = block.state == .eventMissing
        let card = presentation.card
        let tint = colorScheme == .dark ? 0.30 : 0.22
        let shownRows = presentation.shownRows
        let hiddenRows = presentation.hiddenRows
        let total = LinkedTotal.text(spend: block.allocatedSpend, refunds: block.allocatedRefunds)
        // With a header above it, the card's top corners are square: the header's own corners are the pair's, and its sides continue
        // straight down into the card's, so the two read as one event.
        let radius = min(10, height / 2)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: hasHeader ? 0 : radius, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: hasHeader ? 0 : radius
        )
        let titleRow = hasHeader ? 2 : InlineAllocationPlan.titleHeight * scale + titleOffset
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            // The title itself is in `EventTitleLayer` (or the header); this keeps its room.
            Color.clear.frame(height: titleRow)
            ForEach(Array(rows.prefix(shownRows).enumerated()), id: \.element.allocationID) { index, item in
                // The row's own middle, from the card's top, as the stack below lays it out.
                let rowHeight = (InlineAllocationPlan.rowHeight - 2) * scale
                let middle = Self.verticalPadding + titleRow + Self.rowSpacing + CGFloat(index) * (rowHeight + Self.rowSpacing) + rowHeight / 2
                AllocationRow(item: item, scale: scale, anchorDy: anchors.indices.contains(index) ? anchors[index] - middle : nil)
                    .opacity(index == 0 ? 1 : presentation.rowReveal(index))
            }
            if presentation.showsSummaryRow, let total {
                MoreRow(label: "거래 \(rows.count)건", total: total, color: .primary, scale: scale)
            } else if hiddenRows > 0 && shownRows > 0 {
                MoreRow(label: "그 외 \(hiddenRows)건", total: nil, color: .secondary, scale: scale).opacity(presentation.moreReveal)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, Self.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // However little height there is, the card is exactly that tall: what is inside is cut off, never what gives the card its size.
        .frame(height: max(0, height), alignment: .top)
        .clipped()
        .opacity(presentation.transactions)
        .background(color.opacity((missing ? 0.08 : tint) * card), in: shape)
        .background(Color(.systemBackground).opacity(card), in: shape)
        // The colour of the line it thins into: solid when the card is only a line, gone when it is a card (the stripe stays).
        .background(color.opacity(1 - card), in: shape)
        // The left stripe is only the line the card thins into; a full card is one tinted fill, with no stripe and no outline.
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: min(3, max(1, height))).opacity(1 - card) }
        .overlay(alignment: .bottom) {
            // The last line: how many transactions the event holds (where there is no room for rows) on the left, the end time on the
            // right. The count gives way to the time, never the other way round.
            HStack(spacing: 6) {
                if presentation.transactionSummary > 0 {
                    SummaryCount(count: rows.count, total: total, scale: scale).opacity(presentation.transactionSummary)
                }
                Spacer(minLength: 0)
                if !block.continuesToNextDay, !endIsCovered, !zoneIdentifier.isEmpty {
                    CornerTime(text: Formatting.shortClock(block.endUnixMilliseconds, zoneIdentifier: zoneIdentifier), scale: scale)
                        .opacity(presentation.endTime)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 4 * scale)
        }
        .overlay(alignment: .topTrailing) {
            // The header has no time of its own: the start is in this card's top right corner.
            if hasHeader, !startIsCovered, !block.continuesFromPreviousDay, !zoneIdentifier.isEmpty {
                CornerTime(text: Formatting.shortClock(block.startUnixMilliseconds, zoneIdentifier: zoneIdentifier), scale: scale)
                    .padding(.horizontal, 6).padding(.top, 5 * scale)
                    .opacity(presentation.startTime)
            }
        }
        .overlay(alignment: .top) { if hasHeader { Rectangle().fill(color).frame(height: 2) } }
        .overlay { if missing { shape.stroke(color.opacity(0.5 * card), style: StrokeStyle(lineWidth: 1, dash: [3])) } }
        .opacity(missing ? 0.7 : 1)
        .clipShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var text = block.title
        if !block.allocations.isEmpty { text += ", 연결된 거래 \(block.allocations.count)건" }
        return text
    }
}

/// "거래 3건 · 12,300원" as one pill; the count alone where the total does not fit.
private struct SummaryCount: View {
    let count: Int
    let total: String?
    var scale: CGFloat = 1

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if let total { pill("거래 \(count)건 · \(total)") }
            pill("거래 \(count)건")
            Color.clear.frame(width: 0)
        }
    }

    /// A white pill on the card (a step up from it, in the dark too), so the total reads as one thing to touch.
    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11 * scale, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary).lineLimit(1).fixedSize()
            .padding(.horizontal, 9 * scale).padding(.vertical, 3 * scale)
            .background(Theme.surface, in: Capsule())
    }
}

/// One linked transaction inside its event: what it was and how much of it belongs here.
private struct AllocationRow: View {
    let item: AllocationItem
    var scale: CGFloat = 1
    /// How far from this row's middle the transaction really happened (up or down); `nil` when unknown.
    var anchorDy: CGFloat?

    var body: some View {
        // Inside an event the moment does not matter, so there is no line out of the timeline: the transaction is a white bar under the
        // title (never over it) with the category icon, the name and the amount, the amount bold so it reads first.
        HStack(spacing: 0) {
            CategoryMark(category: item.categoryID, scale: scale)
            Color.clear.frame(width: LeaderLayout.textGap * scale)
            Text(item.title ?? "거래").lineLimit(1)
            Spacer(minLength: 2)
            Text((item.flow == .refund ? "−" : "") + Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency))
                .font(.system(size: 10 * scale, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(item.flow == .refund ? Theme.accent : Theme.textPrimary)
        }
        .font(.system(size: 10 * scale))
        .foregroundStyle(Theme.textPrimary)          // a transaction keeps full contrast
        .padding(.leading, 3 * scale).padding(.trailing, 6 * scale)
        .frame(height: (InlineAllocationPlan.rowHeight - 2) * scale)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6 * scale, style: .continuous))
    }
}

/// "+2건 · 합계 12,300원": what the rows above do not show, and everything together.
private struct MoreRow: View {
    let label: String
    let total: String?
    let color: Color
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 3) {
            Color.clear.frame(width: (LeaderLayout.lineEnd - 6 + LeaderLayout.iconSlot + LeaderLayout.textGap) * scale - 3)
            Text(label).font(.system(size: 10 * scale).weight(.semibold))
            Spacer(minLength: 2)
            if let total {
                Text("합계 \(total)").font(.system(size: 10 * scale)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(color)
        .frame(height: (InlineAllocationPlan.rowHeight - 2) * scale)
    }
}

/// A start or end time on an event's corner: small, quiet, never the thing that wraps.
struct CornerTime: View {
    let text: String
    var scale: CGFloat = 1

    var body: some View {
        Text(text).font(.system(size: 9 * scale)).monospacedDigit().foregroundStyle(Color.secondary.opacity(0.7)).lineLimit(1).fixedSize()
    }
}
