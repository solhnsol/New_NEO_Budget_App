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
        guard allocationCount > 0 else { return InlineAllocationPlan(shown: 0, hidden: 0, showsSummaryRow: false, showsSummaryChip: false) }
        let free = blockHeight - verticalPadding - titleHeight - (showsTime ? timeHeight : 0)
        let rows = max(0, min(maximumRows, Int((free / rowHeight).rounded(.down))))
        if rows == 0 { return InlineAllocationPlan(shown: 0, hidden: 0, showsSummaryRow: false, showsSummaryChip: true) }
        if rows == 1 {
            if allocationCount == 1 { return InlineAllocationPlan(shown: 1, hidden: 0, showsSummaryRow: false, showsSummaryChip: false) }
            return InlineAllocationPlan(shown: 0, hidden: allocationCount, showsSummaryRow: true, showsSummaryChip: false)
        }
        // With room for the "+N" row too (three rows) two real transactions are shown; with two rows, one plus "+N".
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

/// The first line of an event card: its title and the small marks next to it. Drawn in a layer above all cards (see
/// `TimelineGridView`), so the card it belongs to can sit under another card without losing its title.
struct EventTitleLayer: View {
    let block: EventBlock
    let frame: CGRect
    let place: DayContentLayout.TitlePlacement
    /// Where the day's column ends, in the same coordinates as `frame`: the farthest a title that had to move may run.
    var columnRight: CGFloat = 0
    static let horizontalPadding: CGFloat = 6
    static let rowHeight: CGFloat = InlineAllocationPlan.titleHeight + 3

    /// Linked transactions of the card that are shown / summed up, so a card too short for rows still says how many there are.
    var shownRows = 0
    var hiddenRows = 0
    var scale: CGFloat = 1
    var zoneIdentifier = ""
    /// The title is kept shorter than the card, clear of a transaction line's text; the start time then has no place beside it.
    var maxTitleWidth: CGFloat?
    /// A transaction line is written where the start time would be.
    var startIsCovered = false

    var body: some View {
        let total = LinkedTotal.text(spend: block.allocatedSpend, refunds: block.allocatedRefunds)
        HStack(spacing: 3) {
            if block.continuesFromPreviousDay { Image(systemName: "arrow.up").font(.system(size: 8)) }
            Text(block.title).font(.caption.weight(.semibold)).lineLimit(1)
            if block.isRecurringInstance { Image(systemName: "repeat").font(.system(size: 8)) }
            Spacer(minLength: 2)
            // A card with no room for rows says how many transactions it holds in plain text on the title's line, and then has no start
            // time beside it: the title and the transactions come first.
            let summarises = shownRows == 0 && hiddenRows > 0 && total != nil
            if summarises, let total {
                ViewThatFits(in: .horizontal) {
                    Text("거래 \(hiddenRows)건 · \(total)").fixedSize()
                    Text("거래 \(hiddenRows)건").fixedSize()
                    Color.clear.frame(width: 0)
                }
                .font(.system(size: 9 * scale)).foregroundStyle(.secondary).lineLimit(1)
            }
            // The start, in the top right corner; a title that has been moved aside leaves it out rather than crowd the line.
            if !summarises, !startIsCovered, maxTitleWidth == nil, !block.continuesFromPreviousDay, !zoneIdentifier.isEmpty, place.dx == 0, place.dy == 0, !place.overflows {
                CornerTime(text: Formatting.shortClock(block.startUnixMilliseconds, zoneIdentifier: zoneIdentifier))
            }
        }
        .padding(.horizontal, Self.horizontalPadding).padding(.top, 3)
        .frame(width: max(0, min(place.overflows ? columnRight - frame.minX - place.dx : frame.width - place.dx, maxTitleWidth.map { $0 + 2 * Self.horizontalPadding } ?? .infinity)), height: (InlineAllocationPlan.titleHeight + 3) * scale, alignment: .leading)
        .offset(x: frame.minX + place.dx, y: frame.minY + place.dy)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An event's card: its colour, its linked transactions that happened within its time, and nothing else. The title is drawn in a layer
/// above all cards (`EventTitleLayer`), and the start and end times are not repeated here: the hour axis beside the card already
/// says them. Which rows show, and how many are summed up, is the layout engine's decision.
struct EventBlockView: View {
    let block: EventBlock
    let height: CGFloat
    /// How far down the title is drawn (see `DayContentLayout.titlePlacements`); the rows below follow it.
    var titleOffset: CGFloat = 0
    var rows: [AllocationItem] = []
    var shownRows = 0
    var hiddenRows = 0
    var scale: CGFloat = 1
    /// The title is in a header above the card: the card's own top edge is then drawn firmly, as the real start.
    var hasHeader = false
    var zoneIdentifier = ""
    var endIsCovered = false
    var startIsCovered = false

    var body: some View {
        let color = Color(hex: block.calendarColorHex) ?? .accentColor
        let missing = block.state == .eventMissing
        // With a header above it, the card's top corners are square: the header's own corners are the pair's, and its sides continue
        // straight down into the card's, so the two read as one event.
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: hasHeader ? 0 : 6, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: hasHeader ? 0 : 6
        )
        VStack(alignment: .leading, spacing: 1) {
            // The title itself is in `EventTitleLayer` (or the header); this keeps its room.
            Color.clear.frame(height: hasHeader ? 2 : (InlineAllocationPlan.titleHeight * scale + titleOffset))
            ForEach(Array(rows.prefix(shownRows)), id: \.allocationID) { item in
                AllocationRow(item: item, scale: scale)
            }
            if hiddenRows > 0 && shownRows > 0 {
                MoreRow(label: "그 외 \(hiddenRows)건", total: nil, color: .secondary, scale: scale)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(missing ? 0.08 : 0.22), in: shape)
        .background(Color(.systemBackground), in: shape)
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .overlay(alignment: .bottomTrailing) {
            // The end, in the bottom right corner, when the rows above leave the room.
            let rowsUsed = CGFloat(shownRows + (hiddenRows > 0 && shownRows > 0 ? 1 : 0)) * InlineAllocationPlan.rowHeight * scale
            let used = (hasHeader ? 2 : InlineAllocationPlan.titleHeight * scale + titleOffset) + rowsUsed + 6
            if !block.continuesToNextDay, !endIsCovered, !zoneIdentifier.isEmpty, height - used >= 12 * scale {
                CornerTime(text: Formatting.shortClock(block.endUnixMilliseconds, zoneIdentifier: zoneIdentifier), scale: scale)
                    .padding(.horizontal, 6).padding(.bottom, 5 * scale)
            }
        }
        .overlay(alignment: .topTrailing) {
            // The header has no time of its own: the start is in this card's top right corner.
            if hasHeader, !startIsCovered, !block.continuesFromPreviousDay, !zoneIdentifier.isEmpty {
                CornerTime(text: Formatting.shortClock(block.startUnixMilliseconds, zoneIdentifier: zoneIdentifier), scale: scale)
                    .padding(.horizontal, 6).padding(.top, 5 * scale)
            }
        }
        .overlay(alignment: .top) { if hasHeader { Rectangle().fill(color).frame(height: 2) } }
        .overlay(shape.stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: missing ? [3] : [])))
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

/// One linked transaction inside its event: what it was and how much of it belongs here.
private struct AllocationRow: View {
    let item: AllocationItem
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 6) {
            Text(item.title ?? "거래").lineLimit(1)
            Spacer(minLength: 2)
            Text((item.flow == .refund ? "−" : "") + Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.system(size: 10 * scale))
        .foregroundStyle(item.flow == .refund ? Color.green : Color.primary)          // a transaction keeps full contrast
        .frame(height: (InlineAllocationPlan.rowHeight - 2) * scale)
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
