import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// How a transaction line, an overflow and an event header look. They only draw what `DayRenderPlan` placed; no policy is decided here.
/// Fonts follow Dynamic Type through `scale` (the same number the layout engine was given), so the room it reserved is the room used.

enum AmountKindNames {
    static func name(_ kind: AmountKind) -> String {
        switch kind {
        case .spend: return "소비"
        case .income: return "수입"
        case .refund: return "환불"
        case .transfer: return "이체"
        }
    }
}

/// One transaction on its own line, at the time it happened. Its name and amount are ordinary text at full contrast: a transaction is
/// never drawn as if it were disabled. A link to an event is a small extra: a link mark, a dashed edge and a short label.
struct TransactionLineView: View {
    let item: DayRenderPlan.LineItem
    let scale: CGFloat

    var body: some View {
        let display = item.display
        let refund = display?.flow == .refund
        HStack(spacing: 4) {
            Image(systemName: item.link != nil ? "link" : (refund ? "arrow.uturn.backward" : "creditcard"))
                .font(.system(size: 9 * scale)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(display?.title ?? "거래").font(.system(size: 11 * scale)).foregroundStyle(.primary).lineLimit(1)
                if let label = item.linkedEventTitle {
                    Text("연결: \(label)").font(.system(size: 8 * scale)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            if let display {
                Text((refund ? "−" : "") + Formatting.money(display.amount.minorUnits, currency: display.amount.currency))
                    .font(.system(size: 12 * scale, weight: .semibold).monospacedDigit())
                    .foregroundStyle(refund ? Color.green : Color.primary)
                    .lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(width: item.frame.width, height: item.frame.height)
        .background(Color(.systemBackground).opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle().stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 0.75, dash: item.link != nil || (display?.isApproximate ?? false) ? [3, 2] : []))
                .frame(height: 0.75)
        }
        .overlay(alignment: .leading) {
            if item.link != nil { Rectangle().fill(Color.accentColor.opacity(0.7)).frame(width: 2) }
        }
        .offset(x: item.frame.minX, y: item.frame.minY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(item))
    }

    static func accessibilityText(_ item: DayRenderPlan.LineItem) -> String {
        guard let display = item.display else { return "거래" }
        var text = (display.flow == .refund ? "환불 " : "지출 ") + (display.title.map { $0 + " " } ?? "")
        text += Formatting.money(display.amount.minorUnits, currency: display.amount.currency)
        if let label = item.linkedEventTitle { text += ", 연결된 일정 \(label)" }
        return text
    }
}

/// Transaction lines that could not each have a line of their own. A small summary card, unlike an event: count first, the kinds when
/// there are several, a total only when the engine says it is one kind in one currency. It says nothing about the transactions belonging
/// together.
struct OverflowCardView: View {
    let item: DayRenderPlan.OverflowItem
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "ellipsis.rectangle").font(.system(size: 10 * scale)).foregroundStyle(.secondary)
            Text(Self.summary(item)).font(.system(size: 11 * scale, weight: .medium)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            Image(systemName: "chevron.right").font(.system(size: 8 * scale, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(width: item.frame.width, height: item.frame.height)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.45), lineWidth: 0.75))
        .offset(x: item.frame.minX, y: item.frame.minY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(item))
        .accessibilityHint("거래 목록을 엽니다")
    }

    /// "거래 5건", "거래 5건 · 소비 3 · 환불 2", and for one kind in one currency "소비 5건 · 12,300원".
    static func summary(_ item: DayRenderPlan.OverflowItem) -> String {
        let count = item.members.count
        if item.showsAmountTotal, let total = item.amountTotals.first {
            return "\(AmountKindNames.name(total.kind)) \(count)건 · " + Formatting.money(total.minorUnits, currency: total.currency)
        }
        if item.countsByKind.count > 1 {
            return "거래 \(count)건 · " + item.countsByKind.map { "\(AmountKindNames.name($0.kind)) \($0.count)" }.joined(separator: " ")
        }
        return "거래 \(count)건"
    }

    static func accessibilityText(_ item: DayRenderPlan.OverflowItem) -> String {
        "거래 \(item.members.count)건, " + item.countsByKind.map { "\(AmountKindNames.name($0.kind)) \($0.count)건" }.joined(separator: ", ")
    }
}

/// A title that moved out of its card, attached above the event's start. Paler than the card and set off by a rule, so it reads as
/// outside the event's time; the event's real start is the card's own top edge below it.
struct EventHeaderView: View {
    let block: EventBlock
    let rect: CGRect

    var body: some View {
        let color = Color(hex: block.calendarColorHex) ?? .accentColor
        HStack(spacing: 3) {
            if block.continuesFromPreviousDay { Image(systemName: "arrow.up").font(.system(size: 8)) }
            Text(block.title).font(.caption.weight(.semibold)).lineLimit(1)
            if block.isRecurringInstance { Image(systemName: "repeat").font(.system(size: 8)) }
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 6)
        .frame(width: rect.width, height: rect.height, alignment: .leading)
        .background(Color(.systemBackground))
        .background(color.opacity(0.10))
        .overlay(alignment: .leading) { Rectangle().fill(color.opacity(0.5)).frame(width: 3) }
        .overlay(alignment: .bottom) { Rectangle().fill(color).frame(height: 1) }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)             // the card it is attached to carries the same event for VoiceOver
    }
}

/// Three or more events on top of one another: one line naming them all, each reachable from it.
struct OverlapSummaryView: View {
    let summary: DayRenderPlan.Summary
    let scale: CGFloat
    let onSelect: (BlockID) -> Void

    var body: some View {
        Menu {
            ForEach(Array(summary.items.enumerated()), id: \.offset) { _, item in
                Button(item.title) { onSelect(item.id) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "square.on.square").font(.system(size: 9 * scale))
                Text("일정 \(summary.items.count)개 · " + summary.items.map(\.title).joined(separator: ", "))
                    .font(.system(size: 11 * scale, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .frame(width: summary.frame.width, height: summary.frame.height, alignment: .leading)
        }
        .offset(x: summary.frame.minX, y: summary.frame.minY)
        .accessibilityLabel("겹치는 일정 \(summary.items.count)개: " + summary.items.map(\.title).joined(separator: ", "))
        .accessibilityHint("일정을 고릅니다")
    }
}
