import NEOBudgetCalendar
import SwiftUI

/// The week above the timeline, behaving like the system calendar's. The two days on screen sit in one capsule with a filled circle on the
/// first; the circle is black (white in dark mode), or the accent colour when that day is today.
///
/// It does not follow the finger. While the timeline is swiped, `pendingShift` (-1, 0 or +1) says which day the swipe would land on, and
/// the strip changes only when that changes (the screen gives a tap of haptic feedback then): the circle fades out where it was and
/// fades in on the new day, and the capsule moves after it as a liquid, its left end (hidden under the circle) quickly and its right end
/// a little later, with a spring. A day picked by tapping does the same.
struct WeekStripView: View {
    let week: [WeekStripDay]
    let selected: LocalDate
    let today: LocalDate
    /// The days on screen are two: the first, and the one after it.
    var showsNextDay = true
    /// Where a swipe in progress would land, relative to `selected`.
    var pendingShift = 0
    let onSelect: (LocalDate) -> Void

    private static let numberRow: CGFloat = 36
    private static let ball: CGFloat = 32

    /// The capsule's two ends, in days from the start of the week. They are driven separately so the right end can lag the left.
    @State private var leading: CGFloat = 0
    @State private var trailing: CGFloat = 0
    @State private var seeded = false

    private var position: Int? { week.firstIndex { $0.day == selected }.map { $0 + pendingShift } }

    var body: some View {
        let position = position
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(week, id: \.day) { cell in
                    Text(Formatting.weekdayShort(cell.day)).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            ZStack {
                highlight(position: position)
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.element.day) { index, cell in
                        Button { onSelect(cell.day) } label: {
                            Text("\(cell.day.day)")
                                .font(.callout.monospacedDigit().weight(role(of: index, position: position) == .none ? .regular : .bold))
                                .foregroundStyle(numberColor(index, cell.day, position: position))
                                .animation(.easeOut(duration: 0.15), value: position)
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
        .onAppear { seed(position) }
        .onChange(of: position) { _, new in move(to: new) }
        .onChange(of: week.map(\.day)) { _, _ in seed(self.position) }
    }

    private enum Role { case none, first, second }

    private func role(of index: Int, position: Int?) -> Role {
        guard let position else { return .none }
        if index == position { return .first }
        if showsNextDay, index == position + 1 { return .second }
        return .none
    }

    private func isShown(_ day: LocalDate) -> Bool { day == selected || (showsNextDay && day == selected.adding(days: 1)) }

    private func seed(_ position: Int?) {
        guard let position else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { leading = CGFloat(position); trailing = CGFloat(position) }
        seeded = true
    }

    /// The circle changes day at once (it fades, below); the capsule's left end follows it quickly and its right end a moment later.
    private func move(to position: Int?) {
        guard let position else { return }
        guard seeded else { return seed(position) }
        withAnimation(.easeOut(duration: 0.12)) { leading = CGFloat(position) }
        withAnimation(.interpolatingSpring(stiffness: 190, damping: 15)) { trailing = CGFloat(position) }
    }

    /// The capsule and the circle. The capsule starts at the circle's centre, so its rounded left end is under the circle and only
    /// the right end shows.
    private func highlight(position: Int?) -> some View {
        GeometryReader { geometry in
            let cell = geometry.size.width / CGFloat(max(1, week.count))
            let ball = Self.ball
            ZStack(alignment: .topLeading) {
                if showsNextDay, position != nil {
                    let start = (leading + 0.5) * cell
                    // At the end of the week the capsule stops at the strip's edge, rounded, instead of being cut off flat.
                    let end = min((trailing + 2) * cell - 4, geometry.size.width - 2)
                    Capsule().fill(Color(.systemFill))
                        .frame(width: max(ball, end - start), height: ball)
                        .offset(x: start, y: (Self.numberRow - ball) / 2)
                }
                if let position {
                    Circle().fill(circleColor(for: position))
                        .frame(width: ball, height: ball)
                        .offset(x: (CGFloat(position) + 0.5) * cell - ball / 2, y: (Self.numberRow - ball) / 2)
                        .id(position)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.7)), removal: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.16), value: position)
        }
        .allowsHitTesting(false)
    }

    private func dayAt(_ position: Int) -> LocalDate? { week.indices.contains(position) ? week[position].day : nil }

    private func circleColor(for position: Int) -> Color {
        dayAt(position) == today ? Color.accentColor : Color.primary
    }

    private func numberColor(_ index: Int, _ day: LocalDate, position: Int?) -> Color {
        switch role(of: index, position: position) {
        case .first: return day == today ? .white : Color(.systemBackground)
        case .second: return .secondary
        case .none: return day == today ? Color.accentColor : .primary
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
