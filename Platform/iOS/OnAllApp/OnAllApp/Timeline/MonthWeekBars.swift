import NEOBudgetCalendar
import SwiftUI

/// The event bars of one week of the month grid (also the open week strip): one bar per event, running across its days, in the calendar's colour.
/// A bar that is still to come is solid with white text; one that is over is a pale tint with dark text. Drawn over the week's cells, it takes
/// no touches: the cell under it is the day's button.
struct MonthWeekBars: View {
    let layout: MonthWeekLayout
    let color: (CalendarID) -> Color

    nonisolated static let laneHeight: CGFloat = 13
    nonisolated static let laneGap: CGFloat = 2
    nonisolated static let lanes = 2
    /// The room the bars take under the day number.
    /// The bars start 4 below the day number's row (the design: bars at 40, number row 36).
    nonisolated static let top: CGFloat = 4
    nonisolated static let height: CGFloat = top + CGFloat(lanes) * (laneHeight + laneGap)

    var body: some View {
        GeometryReader { proxy in
            let cell = proxy.size.width / 7
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            ForEach(layout.bars, id: \.event.key) { bar in
                let tint = color(bar.event.key.calendarID)
                let over = bar.event.endUnixMilliseconds <= now
                Text(bar.event.title)
                    .font(.onAll(size: 10))
                    .foregroundStyle(over ? Theme.textPrimary : Color.white)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
                    .frame(width: CGFloat(bar.lastColumn - bar.firstColumn + 1) * cell - 2, height: Self.laneHeight, alignment: .leading)
                    .background(over ? tint.opacity(0.22) : tint, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .offset(x: CGFloat(bar.firstColumn) * cell + 1, y: Self.top + CGFloat(bar.lane) * (Self.laneHeight + Self.laneGap))
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

    /// One dot per calendar (the design: unique colours, at most three).
    static func uniqueCalendars(_ events: [WeekStripEvent]) -> [CalendarID] {
        var seen: [CalendarID] = []
        for event in events where !seen.contains(event.key.calendarID) { seen.append(event.key.calendarID) }
        return Array(seen.prefix(3))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.uniqueCalendars(events).enumerated()), id: \.offset) { _, id in
                Circle().fill(color(id)).frame(width: 5, height: 5)
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

/// The red dot at the top right of a day's number: money came in that day (the design: 6pt, 9pt right of the number's centre, 3pt from the cell's top).
/// `y` is its centre in the view it is drawn over.
struct IncomeDot: View {
    let show: Bool
    var y: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            Circle().fill(Theme.income).frame(width: 6, height: 6).position(x: proxy.size.width / 2 + 12, y: y).opacity(show ? 1 : 0)
        }
        .allowsHitTesting(false)
    }
}

/// What a day shows under its marks. Closed: what was spent, in one line. Open (the month): what came in (red) above what was spent (blue), 10pt lines.
struct AmountLines: View {
    let spent: String?
    let income: String?
    /// 0 closed, 1 open.
    let open: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            Text(spent ?? " ")
                .font(.onAll(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.accent)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(height: MonthUnfold.spendRow).opacity(1 - open)
            VStack(spacing: 0) {
                if let income { Text(income).foregroundStyle(Theme.income).frame(height: 12) }
                if let spent { Text(spent).foregroundStyle(Theme.accent).frame(height: 12) }
            }
            .font(.onAll(size: 10, weight: .medium).monospacedDigit()).lineLimit(1)
            .opacity(open)
        }
        .frame(height: MonthUnfold.spendRow, alignment: .bottom)
    }
}
