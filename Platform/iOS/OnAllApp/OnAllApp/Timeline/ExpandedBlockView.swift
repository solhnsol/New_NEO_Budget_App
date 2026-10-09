import NEOBudgetCalendar
import SwiftUI

/// What an expanded event block says, and how tall that needs to be. Pure so it is tested. The block's time axis is
/// enlarged until the block is this tall, which is how "expanding" opens the event's inside to its own timeline.
enum ExpandedBlockPlan {
    static let padding: CGFloat = 8
    static let titleHeight: CGFloat = 20
    static let timeHeight: CGFloat = 16
    static let metaRowHeight: CGFloat = 18
    static let sectionGap: CGFloat = 8
    static let transactionHeaderHeight: CGFloat = 18
    static let transactionRowHeight: CGFloat = 22

    struct MetaRow: Equatable {
        let label: String
        let value: String
    }

    /// The facts shown under the title. The calendar is always there; the rest appear when the Activity has them. An
    /// Activity with nothing yet says so, which is also where inline editing will later attach.
    static func metaRows(for block: EventBlock) -> [MetaRow] {
        var rows: [MetaRow] = []
        if let calendar = block.calendarTitle { rows.append(MetaRow(label: "캘린더", value: calendar)) }
        guard let activity = block.activity else {
            rows.append(MetaRow(label: "활동", value: "아직 정보가 없습니다"))
            return rows
        }
        let display = activity.display
        if let type = display.typeName { rows.append(MetaRow(label: "유형", value: type)) }
        if let area = display.areaName { rows.append(MetaRow(label: "장소", value: area)) }
        if !display.participantNames.isEmpty { rows.append(MetaRow(label: "참여자", value: participants(display.participantNames))) }
        if !display.tagNames.isEmpty { rows.append(MetaRow(label: "태그", value: display.tagNames.joined(separator: " "))) }
        if display == .empty { rows.append(MetaRow(label: "활동", value: "아직 정보가 없습니다")) }
        return rows
    }

    /// "나, 가영 외 2명": a short line, never a wrapped paragraph.
    static func participants(_ names: [String]) -> String {
        let shown = 2
        guard names.count > shown else { return names.joined(separator: ", ") }
        return names.prefix(shown).joined(separator: ", ") + " 외 \(names.count - shown)명"
    }

    static func height(for block: EventBlock) -> CGFloat {
        var height = padding * 2 + titleHeight + timeHeight + sectionGap + CGFloat(metaRows(for: block).count) * metaRowHeight
        if !block.allocations.isEmpty {
            height += sectionGap + transactionHeaderHeight + CGFloat(block.allocations.count) * transactionRowHeight
        }
        return height
    }
}

/// An event opened in place: its meaning in words, then every linked transaction in the order it happened. Shown at
/// the block's own position; there is no new screen. Nothing here edits; changing titles, people or types comes later.
struct ExpandedBlockView: View {
    let block: EventBlock
    let zoneIdentifier: String
    /// Opens the event's info sheet (type, place, people, transactions).
    var onEditInfo: (() -> Void)?

    var body: some View {
        let color = Color(hex: block.calendarColorHex) ?? .accentColor
        let missing = block.state == .eventMissing
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(block.title).font(.subheadline.weight(.bold)).lineLimit(1)
                if block.isRecurringInstance { Image(systemName: "repeat").font(.system(size: 10)) }
                if !block.isEditable { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if let onEditInfo {
                    Button(action: onEditInfo) { Label("정보", systemImage: "square.and.pencil").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .accessibilityLabel("활동 정보 편집")
                }
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(height: ExpandedBlockPlan.titleHeight)
            Text(Formatting.timeRange(block.startUnixMilliseconds, block.endUnixMilliseconds, zoneIdentifier: zoneIdentifier)
                 + (missing ? " · 캘린더에서 삭제됨" : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .frame(height: ExpandedBlockPlan.timeHeight, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ExpandedBlockPlan.metaRows(for: block), id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Text(row.value).font(.system(size: 12)).lineLimit(1)
                    }
                    .frame(height: ExpandedBlockPlan.metaRowHeight, alignment: .leading)
                }
            }
            .padding(.top, ExpandedBlockPlan.sectionGap)
            if !block.allocations.isEmpty { transactions }
            Spacer(minLength: 0)
        }
        .padding(ExpandedBlockPlan.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2)) }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(block.title), 펼쳐짐. 탭하면 접습니다.")
    }

    private var transactions: some View {
        let total = LinkedTotal.text(spend: block.allocatedSpend, refunds: block.allocatedRefunds)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("거래 \(block.allocations.count)건", systemImage: "creditcard").font(.system(size: 11).weight(.semibold))
                Spacer(minLength: 4)
                if let total { Text("합계 \(total)").font(.system(size: 11).weight(.semibold)).monospacedDigit() }
            }
            .foregroundStyle(Color.orange)
            .frame(height: ExpandedBlockPlan.transactionHeaderHeight)
            ForEach(AllocationOrdering.byTime(block.allocations), id: \.allocationID) { item in
                HStack(spacing: 6) {
                    Text(timeLabel(item)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                    Text(item.title ?? "거래").font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text((item.flow == .refund ? "−" : "") + Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency))
                        .font(.system(size: 12)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(item.flow == .refund ? Color.green : Color.primary)
                .frame(height: ExpandedBlockPlan.transactionRowHeight)
            }
        }
        .padding(.top, ExpandedBlockPlan.sectionGap)
    }

    /// The time of day, or the date when the payment was on another day.
    private func timeLabel(_ item: AllocationItem) -> String {
        guard item.occursOnSelectedDay else { return Formatting.shortDate(item.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier) }
        return Formatting.time(item.occurredAtUnixMilliseconds, zoneIdentifier: zoneIdentifier)
    }
}
