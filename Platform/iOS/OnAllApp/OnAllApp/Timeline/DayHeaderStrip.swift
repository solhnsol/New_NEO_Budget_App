import NEOBudgetCalendar
import SwiftUI

/// The day names above the columns, and each day's all-day events under its name. The strip slides with the days below it.
struct DayHeaderStrip: View {
    let strip: [StripDay]
    let today: LocalDate
    let swipeOffset: CGFloat
    let onSelect: (AllDayItem) -> Void

    private static let gutter: CGFloat = 60
    private static let labelHeight: CGFloat = 30
    private static let chipHeight: CGFloat = 22
    private static let maximumChips = 2

    var body: some View {
        // All days share a height so the columns line up whatever each one holds.
        let chips = min(strip.compactMap(\.timeline).map { $0.allDay.count }.max() ?? 0, Self.maximumChips + 1)
        let height = Self.labelHeight + CGFloat(chips) * (Self.chipHeight + 2) + (chips > 0 ? 4 : 0)
        GeometryReader { size in
            let columnWidth = max(0, (size.size.width - Self.gutter) / 2)
            // Cut at the gutter, like the days below, so a day sliding out never shows over the hour labels' column.
            ZStack(alignment: .topLeading) {
                ForEach(Array(strip.enumerated()), id: \.element.day) { position, entry in
                    DayHeaderCell(entry: entry, isToday: entry.day == today, onSelect: onSelect)
                        .frame(width: columnWidth, height: height, alignment: .topLeading)
                        .offset(x: columnWidth * CGFloat(position - 1) + swipeOffset)
                }
            }
            .frame(width: max(0, size.size.width - Self.gutter), height: height, alignment: .topLeading)
            .clipped()
            .offset(x: Self.gutter)
        }
        .frame(height: height)
    }
}

private struct DayHeaderCell: View {
    let entry: StripDay
    let isToday: Bool
    let onSelect: (AllDayItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("\(entry.day.day)")
                    .font(.callout.monospacedDigit().weight(.bold))
                    .foregroundStyle(isToday ? Color.white : Color.primary)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(isToday ? Color.accentColor : .clear, in: Circle())
                Text(Formatting.weekdayShort(entry.day)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(height: 30, alignment: .leading)
            .padding(.leading, 4)
            if let timeline = entry.timeline {
                ForEach(Array(timeline.allDay.prefix(2)), id: \.id) { item in
                    let color = Color(hex: item.calendarColorHex) ?? .accentColor
                    Button { onSelect(item) } label: {
                        Text(item.title).font(.caption2.weight(.medium)).lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                            .background(color.opacity(item.state == .eventMissing ? 0.10 : 0.22), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 2)
                    .accessibilityLabel("종일 일정 \(item.title)")
                }
                if timeline.allDay.count > 2 {
                    Text("+\(timeline.allDay.count - 2)개").font(.caption2).foregroundStyle(.secondary).padding(.leading, 6)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
