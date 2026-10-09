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

/// How a row leads out of the timeline: a dot at the moment it happened on the day's left edge and a thin line to the row's text, bending
/// when the text is not at that moment. The text then starts after a small margin, where the category icon (if classified) sits.
private enum LeaderLayout {
    static let dotSize: CGFloat = 4
    static let lineEnd: CGFloat = 12
    static let iconSlot: CGFloat = 11
    static let textGap: CGFloat = 2
    static func textStart(_ scale: CGFloat) -> CGFloat { (lineEnd + iconSlot + textGap) * scale }
}

private struct LeaderMark: View {
    /// How far above (negative) or below the row's middle the transaction really happened.
    let dy: CGFloat
    let height: CGFloat
    var dashed = false
    let scale: CGFloat

    var body: some View {
        let s = scale
        let start = CGPoint(x: LeaderLayout.dotSize / 2, y: height / 2 + dy)
        let end = CGPoint(x: LeaderLayout.lineEnd * s, y: height / 2)
        let bendX = abs(dy) > 1 ? 7 * s : end.x
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: start)
                path.addLine(to: CGPoint(x: bendX, y: start.y))
                path.addLine(to: CGPoint(x: bendX, y: end.y))
                path.addLine(to: end)
            }
            .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 0.75, lineJoin: .round, dash: dashed ? [2, 2] : []))
            Circle().fill(Color.secondary.opacity(0.8))
                .frame(width: LeaderLayout.dotSize * s, height: LeaderLayout.dotSize * s)
                .position(start)
        }
        .allowsHitTesting(false)
    }
}

private struct CategoryMark: View {
    let category: CanonicalCategoryID?
    let scale: CGFloat

    var body: some View {
        Group {
            if let symbol = CategoryIcon.symbol(for: category) {
                Image(systemName: symbol).font(.system(size: 10 * scale)).foregroundStyle(Color.secondary)
            } else {
                Color.clear
            }
        }
        .frame(width: LeaderLayout.iconSlot * scale)
    }
}

/// One transaction on its own line, at the time it happened, written like a line of the calendar's own text: a dot and a line out of the
/// timeline, then its name and its amount. Both are ordinary text at full contrast: a transaction is never drawn as if it were disabled.
struct TransactionLineView: View {
    let item: DayRenderPlan.LineItem
    let scale: CGFloat
    /// Where the day's own column begins (after the hour gutter): the line leads out from there.
    var edge: CGFloat = 60
    /// The row sits over an event: its text gets a thin halo in the page colour so it stays readable, and no background.
    var overEvent = false

    var body: some View {
        let display = item.display
        let refund = display?.flow == .refund
        HStack(spacing: 0) {
            Color.clear.frame(width: LeaderLayout.lineEnd * scale)
            CategoryMark(category: display?.categoryID, scale: scale)
            Color.clear.frame(width: LeaderLayout.textGap * scale)
            // The name and the amount; when the room left for the name is a sliver (a narrow column, large text) the amount stands alone.
            let amount = display.map { (refund ? "−" : "") + Formatting.money($0.amount.minorUnits, currency: $0.amount.currency) } ?? ""
            let nameRoom = item.frame.maxX - edge - 8 - LeaderLayout.textStart(scale) - 10 - CGFloat(amount.count) * 7 * scale - (item.link != nil ? 12 : 0)
            if nameRoom >= 30 * scale {
                if item.link != nil { Image(systemName: "link").font(.system(size: 8 * scale)).foregroundStyle(.secondary).padding(.trailing, 3) }
                Text(display?.title ?? "거래").font(.system(size: 11 * scale)).foregroundStyle(.primary).lineLimit(1)
            }
            Spacer(minLength: 2)
            amountText(display, refund: refund)
        }
        .padding(.trailing, 6)
        .halo(overEvent)
        .frame(width: item.frame.maxX - edge, height: item.frame.height, alignment: .leading)
        .overlay(alignment: .topLeading) {
            LeaderMark(dy: (item.anchorY ?? item.frame.midY) - item.frame.midY, height: item.frame.height, dashed: display?.isApproximate ?? false, scale: scale)
        }
        .offset(x: edge, y: item.frame.minY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(item))
    }

    @ViewBuilder
    private func amountText(_ display: DayRenderPlan.TransactionDisplay?, refund: Bool) -> some View {
        if let display {
            Text((refund ? "−" : "") + Formatting.money(display.amount.minorUnits, currency: display.amount.currency))
                .font(.system(size: 11 * scale, weight: .medium).monospacedDigit())
                .foregroundStyle(refund ? Color.green : Color.primary)
                .lineLimit(1).fixedSize()
        }
    }

    static func accessibilityText(_ item: DayRenderPlan.LineItem) -> String {
        guard let display = item.display else { return "거래" }
        var text = (display.flow == .refund ? "환불 " : "지출 ") + (display.title.map { $0 + " " } ?? "")
        text += Formatting.money(display.amount.minorUnits, currency: display.amount.currency)
        if let label = item.linkedEventTitle { text += ", 연결된 일정 \(label)" }
        return text
    }
}

/// Transaction lines that could not each have a line of their own, written the same way: a dot and a line out of the timeline, "거래 5건",
/// and under it only the total when it is one kind in one currency (else the kinds). It says nothing about the transactions belonging together.
struct OverflowCardView: View {
    let item: DayRenderPlan.OverflowItem
    let scale: CGFloat
    var edge: CGFloat = 60
    var overEvent = false

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: LeaderLayout.textStart(scale))
            // One line of text: "거래 N건 · 합계". When the whole line does not fit, the count alone is shown, never a cut-off number.
            ViewThatFits(in: .horizontal) {
                Text(Self.summary(item)).fixedSize()
                Text(Self.countOnly(item)).minimumScaleFactor(0.5)
            }
            .font(.system(size: 11 * scale, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 2)
        }
        .padding(.trailing, 6)
        .halo(overEvent)
        .frame(width: item.frame.maxX - edge, height: item.frame.height, alignment: .leading)
        .overlay(alignment: .topLeading) {
            LeaderMark(dy: (item.anchorY ?? item.frame.midY) - item.frame.midY, height: item.frame.height, scale: scale)
        }
        .offset(x: edge, y: item.frame.minY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(item))
        .accessibilityHint("거래 목록을 엽니다")
    }

    /// The total under the count, or the kinds when there is no single total.
    static func secondLine(_ item: DayRenderPlan.OverflowItem) -> String? {
        if item.showsAmountTotal, let total = item.amountTotals.first { return Formatting.money(total.minorUnits, currency: total.currency) }
        if item.countsByKind.count > 1 { return item.countsByKind.map { "\(AmountKindNames.name($0.kind)) \($0.count)" }.joined(separator: " ") }
        return nil
    }

    /// "거래 5건", "거래 5건 · 소비 3 · 환불 2", and for one kind in one currency "소비 5건 · 12,300원".
    static func summary(_ item: DayRenderPlan.OverflowItem) -> String {
        let count = item.members.count
        if item.showsAmountTotal, let total = item.amountTotals.first {
            return "거래 \(count)건 · " + Formatting.money(total.minorUnits, currency: total.currency)
        }
        if item.countsByKind.count > 1 {
            return "거래 \(count)건 · " + item.countsByKind.map { "\(AmountKindNames.name($0.kind)) \($0.count)" }.joined(separator: " ")
        }
        return "거래 \(count)건"
    }

    static func countOnly(_ item: DayRenderPlan.OverflowItem) -> String { "거래 \(item.members.count)건" }

    static func accessibilityText(_ item: DayRenderPlan.OverflowItem) -> String {
        "거래 \(item.members.count)건, " + item.countsByKind.map { "\(AmountKindNames.name($0.kind)) \($0.count)건" }.joined(separator: ", ")
    }
}

/// A title that moved out of its card, attached above the event's start. Paler than the card and set off by a rule, so it reads as
/// outside the event's time; the event's real start is the card's own top edge below it.
struct EventHeaderView: View {
    let block: EventBlock
    let rect: CGRect
    var zoneIdentifier = ""

    var body: some View {
        let color = Color(hex: block.calendarColorHex) ?? .accentColor
        HStack(spacing: 3) {
            if block.continuesFromPreviousDay { Image(systemName: "arrow.up").font(.system(size: 8)) }
            Text(block.title).font(.caption.weight(.semibold)).lineLimit(1)
            if block.isRecurringInstance { Image(systemName: "repeat").font(.system(size: 8)) }
            Spacer(minLength: 2)
            if !block.continuesFromPreviousDay, !zoneIdentifier.isEmpty { CornerTime(text: Formatting.shortClock(block.startUnixMilliseconds, zoneIdentifier: zoneIdentifier)) }
        }
        .padding(.horizontal, 6)
        .frame(width: rect.width, height: rect.height, alignment: .leading)
        .background(Color(.systemBackground))
        .background(color.opacity(0.10))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .overlay(alignment: .bottom) { Rectangle().fill(color).frame(height: 1) }
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6).stroke(color.opacity(0.5), lineWidth: 1))
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

extension View {
    /// A thin outline of the page colour around text that sits over something coloured, so it stays readable without a background.
    @ViewBuilder
    fileprivate func halo(_ on: Bool) -> some View {
        if on {
            self.shadow(color: Color(.systemBackground).opacity(0.9), radius: 0.8).shadow(color: Color(.systemBackground).opacity(0.9), radius: 0.8)
        } else {
            self
        }
    }
}
