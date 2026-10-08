import NEOBudgetCalendar
import SwiftUI

/// How many linked transactions fit inside an event block, and what to say about the rest. Pure, so it is tested.
/// A block's height reflects its time, so spending never makes it taller: past `maximumInline` rows (or when the
/// block is short) the remainder folds into "+N", and a block too small for any row shows one summary chip instead.
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

    static let maximumInline = 3
    static let titleHeight: CGFloat = 16
    static let timeHeight: CGFloat = 14
    static let rowHeight: CGFloat = 15
    static let verticalPadding: CGFloat = 6

    static func make(allocationCount: Int, blockHeight: CGFloat, showsTime: Bool) -> InlineAllocationPlan {
        guard allocationCount > 0 else { return InlineAllocationPlan(shown: 0, hidden: 0, showsSummaryRow: false, showsSummaryChip: false) }
        let free = blockHeight - verticalPadding - titleHeight - (showsTime ? timeHeight : 0)
        let rows = max(0, min(maximumInline, Int((free / rowHeight).rounded(.down))))
        if rows == 0 { return InlineAllocationPlan(shown: 0, hidden: 0, showsSummaryRow: false, showsSummaryChip: true) }
        if allocationCount <= rows { return InlineAllocationPlan(shown: allocationCount, hidden: 0, showsSummaryRow: false, showsSummaryChip: false) }
        if rows == 1 { return InlineAllocationPlan(shown: 0, hidden: allocationCount, showsSummaryRow: true, showsSummaryChip: false) }
        // One row is spent on "+N", so the others show real transactions.
        let shown = rows - 1
        return InlineAllocationPlan(shown: shown, hidden: allocationCount - shown, showsSummaryRow: false, showsSummaryChip: false)
    }

    static func showsTime(blockHeight: CGFloat) -> Bool { blockHeight >= 44 }
}

struct EventBlockView: View {
    let block: EventBlock
    let zoneIdentifier: String
    let height: CGFloat

    var body: some View {
        let color = Color(hex: block.calendarColorHex) ?? .accentColor
        let missing = block.state == .eventMissing
        let showsTime = InlineAllocationPlan.showsTime(blockHeight: height)
        let plan = InlineAllocationPlan.make(allocationCount: block.allocations.count, blockHeight: height, showsTime: showsTime)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if block.continuesFromPreviousDay { Image(systemName: "arrow.up").font(.system(size: 8)) }
                Text(block.title).font(.caption.weight(.semibold)).lineLimit(1)
                if block.isRecurringInstance { Image(systemName: "repeat").font(.system(size: 8)) }
                Spacer(minLength: 2)
                if plan.showsSummaryChip, let total = block.allocatedSpend.first {
                    SummaryChip(count: block.allocations.count, total: total)
                }
            }
            if showsTime {
                Text(Formatting.timeRange(block.startUnixMilliseconds, block.endUnixMilliseconds, zoneIdentifier: zoneIdentifier))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            ForEach(Array(block.allocations.prefix(plan.shown)), id: \.allocationID) { item in
                AllocationRow(item: item)
            }
            if plan.showsSummaryRow, let total = block.allocatedSpend.first {
                HStack(spacing: 3) {
                    Image(systemName: "creditcard").font(.system(size: 8))
                    Text("\(plan.hidden)건")
                    Spacer(minLength: 2)
                    Text(Formatting.aggregate(total)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                }
                .font(.system(size: 10)).foregroundStyle(Color.orange)
                .frame(height: InlineAllocationPlan.rowHeight - 2)
            } else if plan.hidden > 0 {
                Text("+\(plan.hidden)건").font(.system(size: 10).weight(.semibold)).foregroundStyle(.secondary)
                    .frame(height: InlineAllocationPlan.rowHeight - 2, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(missing ? 0.08 : 0.22), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2)) }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: missing ? [3] : [])))
        .opacity(missing ? 0.7 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var text = "\(block.title), \(Formatting.timeRange(block.startUnixMilliseconds, block.endUnixMilliseconds, zoneIdentifier: zoneIdentifier))"
        if !block.allocations.isEmpty { text += ", 연결된 거래 \(block.allocations.count)건" }
        return text
    }
}

/// One linked transaction inside its event: what it was and how much of it belongs here.
private struct AllocationRow: View {
    let item: AllocationItem

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: item.flow == .refund ? "arrow.uturn.backward" : "creditcard").font(.system(size: 8))
            Text(item.title ?? "거래").lineLimit(1)
            Spacer(minLength: 2)
            Text((item.flow == .refund ? "−" : "") + Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.system(size: 10))
        .foregroundStyle(item.flow == .refund ? Color.green : Color.orange)
        .frame(height: InlineAllocationPlan.rowHeight - 2)
    }
}

private struct SummaryChip: View {
    let count: Int
    let total: AmountAggregate

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "creditcard.fill").font(.system(size: 8))
            Text("\(count)건 \(Formatting.aggregate(total))").lineLimit(1).minimumScaleFactor(0.6)
        }
        .font(.system(size: 9).weight(.semibold))
        .foregroundStyle(Color.orange)
    }
}
