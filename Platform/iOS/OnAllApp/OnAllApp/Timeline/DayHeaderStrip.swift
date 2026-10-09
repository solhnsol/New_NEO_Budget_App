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
    /// Always the same height, whatever the days hold. A header that grows or shrinks with the all-day events of the days around
    /// would move the whole grid up or down at the moment a swipe lands on such a day.
    static let height: CGFloat = labelHeight + chipHeight + 6

    var body: some View {
        let height = Self.height
        GeometryReader { size in
            let columnWidth = max(0, (size.size.width - Self.gutter) / 2)
            // Cut at the gutter, like the days below, so a day sliding out never shows over the hour labels' column.
            ZStack(alignment: .topLeading) {
                ForEach(strip, id: \.day) { entry in
                let position = entry.day.daysSinceUnixEpoch - (strip.count > 1 ? strip[1].day.daysSinceUnixEpoch : entry.day.daysSinceUnixEpoch) + 1
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
            if let timeline = entry.timeline, let first = timeline.allDay.first {
                HStack(spacing: 4) {
                    chip(first)
                    if timeline.allDay.count > 1 {
                        Menu {
                            ForEach(Array(timeline.allDay.dropFirst()), id: \.id) { item in Button(item.title) { onSelect(item) } }
                        } label: {
                            Text("+\(timeline.allDay.count - 1)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).frame(minHeight: 22)
                        }
                        .accessibilityLabel("종일 일정 \(timeline.allDay.count - 1)개 더 보기")
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func chip(_ item: AllDayItem) -> some View {
        let color = Color(hex: item.calendarColorHex) ?? .accentColor
        return Button { onSelect(item) } label: {
            Text(item.title).font(.caption2.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(color.opacity(item.state == .eventMissing ? 0.10 : 0.22), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("종일 일정 \(item.title)")
    }
}
