import NEOBudgetCalendar
import SwiftUI

/// The week above the timeline. The two days on screen are held in one pill, as in the system calendar: the first day in a filled
/// circle, the second beside it inside the same capsule. The pill follows a swipe on the timeline continuously (`swipeDays` is how far
/// the days have moved, in days, positive towards the next day) and glides when a day is picked by tapping.
struct WeekStripView: View {
    let week: [WeekStripDay]
    let selected: LocalDate
    /// The days on screen are two: `selected` and the one after it.
    var showsNextDay = true
    /// How far a swipe has carried the days, in days. 0 at rest.
    var swipeDays: CGFloat = 0
    let onSelect: (LocalDate) -> Void

    private static let numberRow: CGFloat = 36

    var body: some View {
        let selectedIndex = week.firstIndex { $0.day == selected }
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(week, id: \.day) { cell in
                    Text(Formatting.weekdayShort(cell.day)).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            ZStack {
                if let selectedIndex { pill(selectedIndex: selectedIndex) }
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.element.day) { index, cell in
                        Button { onSelect(cell.day) } label: {
                            Text("\(cell.day.day)")
                                .font(.callout.monospacedDigit().weight(emphasis(of: index, selectedIndex: selectedIndex) > 0 ? .bold : .regular))
                                .foregroundStyle(numberColor(index, selectedIndex: selectedIndex))
                                .frame(maxWidth: .infinity, minHeight: Self.numberRow)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(cell.day.month)월 \(cell.day.day)일, 일정 \(cell.eventCount)건")
                        .accessibilityAddTraits(isShown(cell.day) ? .isSelected : [])
                    }
                }
            }
            .frame(height: Self.numberRow)
            .clipped()
            HStack(spacing: 0) {
                ForEach(week, id: \.day) { cell in
                    HStack(spacing: 3) {
                        Circle().fill(cell.eventCount > 0 ? Color.accentColor : .clear).frame(width: 5, height: 5)
                        Circle().fill(cell.unlinkedTransactionCount > 0 ? Color.orange : .clear).frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func isShown(_ day: LocalDate) -> Bool { day == selected || (showsNextDay && day == selected.adding(days: 1)) }

    /// The capsule over the two days and the filled circle on the first, positioned by the selected day plus however far a swipe has
    /// carried them. The capsule's own move is animated only when the selection changes; a swipe moves it with the finger.
    private func pill(selectedIndex: Int) -> some View {
        GeometryReader { geometry in
            let cell = geometry.size.width / CGFloat(max(1, week.count))
            let x = (CGFloat(selectedIndex) + swipeDays) * cell
            ZStack(alignment: .leading) {
                if showsNextDay {
                    Capsule().fill(Color(.systemFill)).frame(width: cell * 2 - 4, height: Self.numberRow - 2)
                }
                Circle().fill(Color.accentColor).frame(width: Self.numberRow - 4, height: Self.numberRow - 4)
                    .offset(x: (cell - (Self.numberRow - 4)) / 2 - 1)
            }
            .frame(width: cell * 2, alignment: .leading)
            .offset(x: x + 2, y: 1)
            .animation(.snappy(duration: 0.3), value: selected)
        }
        .allowsHitTesting(false)
    }

    /// 1 for the number sitting on the filled circle, 0.5 for the second day inside the capsule, 0 otherwise. Judged on how near the
    /// circle is, so a number turns white only once the circle is really under it and stays readable while the pill is moving.
    private func emphasis(of index: Int, selectedIndex: Int?) -> CGFloat {
        guard let selectedIndex else { return 0 }
        let position = CGFloat(selectedIndex) + swipeDays
        if abs(CGFloat(index) - position) < 0.3 { return 1 }
        if showsNextDay, abs(CGFloat(index) - (position + 1)) < 0.7 { return 0.5 }
        return 0
    }

    private func numberColor(_ index: Int, selectedIndex: Int?) -> Color {
        switch emphasis(of: index, selectedIndex: selectedIndex) {
        case 1: return .white
        case 0.5: return .secondary
        default: return .primary
        }
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
