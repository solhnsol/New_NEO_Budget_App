import NEOBudgetCalendar
import SwiftUI

/// The event bars of one week of the month grid (also the open week strip): one bar per event, running across its days, in the calendar's colour.
/// A bar that is still to come is solid with white text; one that is over is a pale tint with dark text. Drawn over the week's cells, it takes
/// no touches: the cell under it is the day's button.
struct MonthWeekBars: View {
    let layout: MonthWeekLayout
    let color: (CalendarID) -> Color

    nonisolated static let laneHeight: CGFloat = 16
    nonisolated static let laneGap: CGFloat = 2
    nonisolated static let lanes = 2
    /// The room the bars take under the day number.
    nonisolated static let height: CGFloat = CGFloat(lanes) * (laneHeight + laneGap)

    var body: some View {
        GeometryReader { proxy in
            let cell = proxy.size.width / 7
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            ForEach(layout.bars, id: \.event.key) { bar in
                let tint = color(bar.event.key.calendarID)
                let over = bar.event.endUnixMilliseconds <= now
                Text(bar.event.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(over ? Theme.textSecondary : Color.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(width: CGFloat(bar.lastColumn - bar.firstColumn + 1) * cell - 2, height: Self.laneHeight, alignment: .leading)
                    .background(over ? tint.opacity(0.22) : tint, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .offset(x: CGFloat(bar.firstColumn) * cell + 1, y: CGFloat(bar.lane) * (Self.laneHeight + Self.laneGap))
            }
        }
        .frame(height: Self.height)
        .allowsHitTesting(false)
    }
}

/// Up to three small dots, one per event, in its calendar's colour: the week strip's "something is on this day", and in the month the events that
/// got no bar.
struct EventDots: View {
    let events: [WeekStripEvent]
    let color: (CalendarID) -> Color

    nonisolated static let height: CGFloat = 9

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, event in
                Circle().fill(color(event.key.calendarID)).frame(width: 5, height: 5)
            }
        }
        .frame(height: Self.height)
    }
}

extension AppModel {
    /// A calendar's colour as drawn on bars and dots; a calendar with none (or unknown) takes the accent.
    func calendarColor(_ id: CalendarID) -> Color {
        Color(hex: calendars.first { $0.id == id }?.colorHex) ?? Theme.accent
    }
}
