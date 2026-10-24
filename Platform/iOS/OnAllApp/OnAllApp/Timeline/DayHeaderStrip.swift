import NEOBudgetCalendar
import SwiftUI

/// The day names above the columns, and each day's all-day events under its name: a band over the grid, like a spreadsheet's column titles, with a
/// rule between the columns and one under the band. The strip slides with the days below it.
struct DayHeaderStrip: View {
    let strip: [StripDay]
    let today: LocalDate
    let swipeOffset: CGFloat
    let onSelect: (AllDayItem) -> Void

    private static let gutter: CGFloat = 60
    private static let labelHeight: CGFloat = 30
    /// Always the same height, whatever the days hold. A header that grows or shrinks with the all-day events of the days around
    /// would move the whole grid up or down at the moment a swipe lands on such a day. The all-day event sits on the day's own line, so
    /// there is no room kept for it below.
    static let height: CGFloat = labelHeight + 6

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
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 0.5) }
    }
}

private struct DayHeaderCell: View {
    let entry: StripDay
    let isToday: Bool
    let onSelect: (AllDayItem) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("\(entry.day.day)")
                .font(.system(.callout, weight: .bold).monospacedDigit())
                .foregroundStyle(isToday ? Color.white : Theme.textPrimary)
                .frame(minWidth: 26, minHeight: 26)
                .background(isToday ? Theme.accent : .clear, in: Circle())
            Text(Formatting.weekdayShort(entry.day)).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            // The day's all-day event beside its name (the first; the rest are in the "+N" menu).
            if let timeline = entry.timeline, let first = timeline.allDay.first {
                chip(first)
                if timeline.allDay.count > 1 {
                    Menu {
                        ForEach(Array(timeline.allDay.dropFirst()), id: \.id) { item in Button(item.title) { onSelect(item) } }
                    } label: {
                        Text("+\(timeline.allDay.count - 1)").font(.system(.caption2, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 5).frame(minHeight: 22)
                    }
                    .accessibilityLabel("종일 일정 \(timeline.allDay.count - 1)개 더 보기")
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, Theme.Space.s).padding(.trailing, Theme.Space.s - 2)
        .frame(maxHeight: .infinity, alignment: .center)
        // The rule between this day's column and the one before it.
        .overlay(alignment: .leading) { Rectangle().fill(Theme.divider).frame(width: 0.5) }
        .accessibilityElement(children: .contain)
    }

    private func chip(_ item: AllDayItem) -> some View {
        let color = Color(hex: item.calendarColorHex) ?? Theme.accent
        return Button { onSelect(item) } label: {
            Text(item.title).font(.system(.caption, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(color.opacity(item.state == .eventMissing ? 0.10 : 0.22), in: RoundedRectangle(cornerRadius: Theme.Radius.small - 2, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("종일 일정 \(item.title)")
    }
}

/// What the top bars (month, week strip, column titles) sit on: the screen's own color over a blur, so it reads as the grid's color while what scrolled
/// up under it still shows through.
struct TopBarBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // The dark material lifts black to gray, so in dark it is used lightly and the screen's own black carries the color. The color is mostly opaque; the blur only hints at what is under it.
        let dark = scheme == .dark
        ZStack {
            Rectangle().fill(.ultraThinMaterial).opacity(dark ? 0.3 : 1)
            Rectangle().fill(Color(.systemBackground).opacity(dark ? 0.88 : 0.82))
        }
    }
}
