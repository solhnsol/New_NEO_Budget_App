import NEOBudgetCalendar
import SwiftUI

/// How a transaction card looks and how much room it needs. Pure so it is tested.
///
/// A transaction is drawn at the time it happened, in the same column as the events. Whether it belongs to an event is a
/// separate fact (its allocations), shown as a quiet note and never as a different place on the screen or a warning colour.
enum TransactionCardPlan {
    static let height: CGFloat = 28
    /// The card takes most of the column, right-aligned, so the start of an event under it (its title) stays readable.
    static let preferredShare: CGFloat = 0.62
    /// Below this the amount no longer fits beside a title, so the card shows the amount alone.
    static let titleThreshold: CGFloat = 150
    /// The narrowest card: an icon and the largest amount a card is expected to show.
    static let minimumWidth: CGFloat = 112

    enum Style: Equatable {
        /// No allocation at all: ordinary spending that belongs to no event.
        case unlinked
        /// Some of it is allocated to events, some is not.
        case partlyLinked(eventCount: Int)
        /// Wholly allocated, but to an event that is not on this day's timeline.
        case linkedElsewhere(title: String?)
    }

    static func width(content: CGFloat) -> CGFloat {
        guard content > 0 else { return 0 }
        return min(content, max(minimumWidth, content * preferredShare))
    }

    static func showsTitle(width: CGFloat) -> Bool { width >= titleThreshold }

    static func style(for marker: TransactionMarkerItem) -> Style {
        let toActivities = marker.allocations.filter { $0.activityID != nil }
        if toActivities.isEmpty { return .unlinked }
        if !marker.isFullyAllocated { return .partlyLinked(eventCount: toActivities.count) }
        return .linkedElsewhere(title: toActivities.first?.activityTitle)
    }

    static func note(for style: Style) -> String? {
        switch style {
        case .unlinked: return nil
        case let .partlyLinked(count): return "일부 연결 \(count)건"
        case let .linkedElsewhere(title): return title.map { "연결: \($0)" } ?? "다른 일정에 연결"
        }
    }

    static func accessibilityText(_ marker: TransactionMarkerItem) -> String {
        let amount = Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency)
        var text = (marker.flow == .refund ? "환불 " : "지출 ") + (marker.title.map { $0 + " " } ?? "") + amount
        if let note = note(for: style(for: marker)) { text += ", " + note }
        return text
    }
}

struct TransactionCardView: View {
    let marker: TransactionMarkerItem
    let style: TransactionCardPlan.Style
    let showsTitle: Bool

    var body: some View {
        let refund = marker.flow == .refund
        let tint: Color = refund ? .green : .primary
        HStack(spacing: 4) {
            Image(systemName: refund ? "arrow.uturn.backward" : "creditcard")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if showsTitle {
                Text(marker.title ?? "거래").font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if TransactionCardPlan.note(for: style) != nil {
                Image(systemName: "link").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text((refund ? "−" : "") + Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(
            Color.secondary.opacity(0.35),
            style: StrokeStyle(lineWidth: 1, dash: marker.timePrecision == .approximate ? [3] : [])
        ))
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
    }
}
