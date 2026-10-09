import NEOBudgetCalendar
import SwiftUI

struct WeekStripView: View {
    let week: [WeekStripDay]
    let selected: LocalDate
    /// The days on screen are two: `selected` and the one after it, so the strip shows both, as the system calendar does.
    var showsNextDay = true
    let onSelect: (LocalDate) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(week, id: \.day) { cell in
                Button { onSelect(cell.day) } label: {
                    VStack(spacing: 4) {
                        Text(Formatting.weekdayShort(cell.day)).font(.caption2).foregroundStyle(.secondary)
                        let isFirst = cell.day == selected
                        let isSecond = showsNextDay && cell.day == selected.adding(days: 1)
                        Text("\(cell.day.day)")
                            .font(.callout.monospacedDigit().weight(isFirst || isSecond ? .bold : .regular))
                            .frame(width: 32, height: 32)
                            .background(isFirst ? Color.accentColor : isSecond ? Color.accentColor.opacity(0.18) : .clear, in: Circle())
                            .foregroundStyle(isFirst ? Color.white : isSecond ? Color.accentColor : Color.primary)
                        HStack(spacing: 3) {
                            Circle().fill(cell.eventCount > 0 ? Color.accentColor : .clear).frame(width: 5, height: 5)
                            Circle().fill(cell.unlinkedTransactionCount > 0 ? Color.orange : .clear).frame(width: 5, height: 5)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(cell.day.month)월 \(cell.day.day)일, 일정 \(cell.eventCount)건")
                .accessibilityAddTraits(cell.day == selected || (showsNextDay && cell.day == selected.adding(days: 1)) ? .isSelected : [])
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
