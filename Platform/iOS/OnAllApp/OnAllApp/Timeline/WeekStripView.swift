import NEOBudgetCalendar
import SwiftUI

struct WeekStripView: View {
    let week: [WeekStripDay]
    let selected: LocalDate
    let onSelect: (LocalDate) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(week, id: \.day) { cell in
                Button { onSelect(cell.day) } label: {
                    VStack(spacing: 4) {
                        Text(Formatting.weekdayShort(cell.day)).font(.caption2).foregroundStyle(.secondary)
                        Text("\(cell.day.day)")
                            .font(.callout.monospacedDigit().weight(cell.day == selected ? .bold : .regular))
                            .frame(width: 32, height: 32)
                            .background(cell.day == selected ? Color.accentColor : .clear, in: Circle())
                            .foregroundStyle(cell.day == selected ? Color.white : Color.primary)
                        HStack(spacing: 3) {
                            Circle().fill(cell.eventCount > 0 ? Color.accentColor : .clear).frame(width: 5, height: 5)
                            Circle().fill(cell.unlinkedTransactionCount > 0 ? Color.orange : .clear).frame(width: 5, height: 5)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(cell.day.month)월 \(cell.day.day)일, 일정 \(cell.eventCount)건")
                .accessibilityAddTraits(cell.day == selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

struct AllDayRow: View {
    let items: [AllDayItem]
    let onSelect: (AllDayItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.id) { item in
                    let color = Color(hex: item.calendarColorHex) ?? .accentColor
                    Button { onSelect(item) } label: {
                        Text(item.title)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(color.opacity(item.state == .eventMissing ? 0.10 : 0.22), in: Capsule())
                            .overlay(Capsule().stroke(color, style: StrokeStyle(lineWidth: 1, dash: item.state == .eventMissing ? [3] : [])))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("종일 일정 \(item.title)")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}
