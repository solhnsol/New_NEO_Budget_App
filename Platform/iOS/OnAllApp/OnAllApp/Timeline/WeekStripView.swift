import NEOBudgetCalendar
import SwiftUI

/// The week above the timeline, behaving like the system calendar's.
///
/// The strip is a continuous run of days (the week on screen and the one either side), and what is on screen is a window onto it. The two
/// days being shown sit in one capsule with a filled circle on the first (black, or the accent colour on today). The capsule keeps its
/// length: at the end of a week it simply runs on into the next week's days, out of sight to the right.
///
/// It does not follow the finger. While the timeline is swiped, `pendingShift` says which day the swipe would land on, and the strip changes
/// when that changes: the circle fades out where it was and grows in on the new day from its centre, and the capsule follows as a liquid
/// (its left end, under the circle, quickly; its right end a moment later). If that day is in another week, the strip pages over to it at
/// the same time, so the circle and capsule move with the days. Swiping the strip itself changes the week.
struct WeekStripView: View {
    let cells: [LocalDate: WeekStripDay]
    let selected: LocalDate
    let today: LocalDate
    /// The days on screen are two: the first, and the one after it.
    var showsNextDay = true
    /// Where a swipe in progress would land, relative to `selected`, in days.
    var pendingShift = 0
    let onSelect: (LocalDate) -> Void
    /// A swipe on the strip itself: -1 for the previous week, +1 for the next.
    var onPage: (Int) -> Void = { _ in }

    private static let numberRow: CGFloat = 36
    private static let ball: CGFloat = 32
    private static let weeksShown = 3

    /// The capsule's two ends as day numbers (days since the epoch), driven separately so the right end can lag the left.
    @State private var leading: Double = 0
    @State private var trailing: Double = 0
    /// The day (as a number) at the strip's left edge. Everything is placed by its own day number against this one value, so the strip can
    /// page between weeks, and be re-based when a swipe lands on a new week, without anything having to move.
    @State private var viewOffset: Double = 0
    /// Where the circle is (a day number). Changed with its own animation, apart from the paging and the capsule.
    @State private var ball: Int = 0
    @State private var seeded = false
    /// The circle that has just left a day: it keeps following that day as it slides away, fading, so it never leaves an afterimage.
    @State private var ghosts: [Ghost] = []
    @State private var ballID = UUID()
    /// While a finger is dragging the strip, the strip follows it directly (no animation); on release it eases to the page it settles on.
    @State private var dragging = false
    @State private var stripWidth: CGFloat = 0

    private struct Ghost: Identifiable { let id = UUID(); let day: Int; let isToday: Bool }

    private var weekStart: LocalDate { selected.adding(days: -selected.weekday) }
    private var position: Int { selected.daysSinceUnixEpoch + pendingShift }
    /// The first day of the week the circle is in: where the strip's left edge should be.
    private var pageStart: Int { position - LocalDate(daysSinceUnixEpoch: position).weekday }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { column in
                    Text(Formatting.weekdayShort(weekStart.adding(days: column))).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            GeometryReader { geometry in
                let cell = geometry.size.width / 7
                let _ = updateWidth(geometry.size.width)
                // A fixed run of days around the week being shown: the one it is leaving and the one it is going to are always both in it, so
                // paging moves cells that are already there (no day appears or disappears in the middle of the move).
                // The run of days is anchored to the selected week, which only changes when a swipe lands; the page being shown moves inside
                // it. Every day (and the capsule) is placed by its own day number against `viewOffset` alone, so when a swipe lands and the
                // run is re-based on the new week, no day that exists moves: only days far outside the window come and go.
                let low = weekStart.daysSinceUnixEpoch - 14
                let high = low + 42
                ZStack(alignment: .topLeading) {
                    capsule(cell: cell)
                    // One interpolated value places every day, so no two days can be caught at different points of the move.
                    InterpolatedView(value: viewOffset) { offset in
                        ZStack(alignment: .topLeading) {
                            circles(cell: cell, offset: offset)
                            ForEach(low..<high, id: \.self) { number in
                                dayCell(LocalDate(daysSinceUnixEpoch: number), cell: cell)
                                    .offset(x: (CGFloat(number) - CGFloat(offset)) * cell)
                            }
                        }
                    }
                    .animation(dragging ? nil : .snappy(duration: 0.34), value: viewOffset)
                }
                .frame(width: geometry.size.width, height: Self.numberRow + 9, alignment: .topLeading)
            }
            .frame(height: Self.numberRow + 9)
            .clipped()
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        dragging = true
                        // The strip is held and dragged: the neighbouring weeks come into view with the finger.
                        let cell = max(1, stripWidth / 7)
                        viewOffset = Double(pageStart) - Double(max(-stripWidth, min(stripWidth, value.translation.width)) / cell)
                    }
                    .onEnded { value in
                        guard dragging else { return }
                        dragging = false
                        let width = max(1, stripWidth)
                        let flick = abs(value.velocity.width) > 500 && (value.velocity.width < 0) == (value.translation.width < 0)
                        let far = abs(value.translation.width) > width * 0.3
                        if far || flick, abs(value.translation.width) > 8 {
                            // The page changes with the day the strip's selection moves to (see `move`).
                            onPage(value.translation.width < 0 ? 1 : -1)
                        } else {
                            viewOffset = Double(pageStart)
                        }
                    }
            )
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .onAppear { seed() }
        .onChange(of: position) { _, _ in move() }
    }

    private enum Role { case none, first, second }

    private func role(of day: LocalDate) -> Role {
        let number = day.daysSinceUnixEpoch
        if number == ball { return .first }
        if showsNextDay, number == ball + 1 { return .second }
        return .none
    }

    private func isShown(_ day: LocalDate) -> Bool { day == selected || (showsNextDay && day == selected.adding(days: 1)) }

    private func seed() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { leading = Double(position); trailing = Double(position); viewOffset = Double(pageStart); ball = position }
        seeded = true
    }

    /// The circle changes day at once; the capsule's left end follows it, and its right end a moment later, which is what makes it stretch
    /// like a liquid. The paging, the circle and the capsule each have their own animation, set where they are drawn.
    private func move() {
        guard seeded else { return seed() }
        let target = position
        viewOffset = Double(pageStart)
        if ball != target {
            let ghost = Ghost(day: ball, isToday: ball == today.daysSinceUnixEpoch)
            ghosts.append(ghost)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                ghosts.removeAll { $0.id == ghost.id }
            }
        }
        ballID = UUID()
        ball = target
        leading = Double(target)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(45))
            trailing = Double(target)
        }
    }

    /// The capsule starts at the circle's centre, so its rounded left end is under the circle, and it is always two days long: past the
    /// end of the week it runs on into the next week's days, which are simply not on screen.
    @ViewBuilder
    private func capsule(cell: CGFloat) -> some View {
        if showsNextDay {
            InterpolatedView(value: leading) { lead in
                InterpolatedView(value: trailing) { trail in
                    InterpolatedView(value: viewOffset) { offset in
                        let start = (CGFloat(lead) - CGFloat(offset) + 0.5) * cell
                        let end = (CGFloat(trail) - CGFloat(offset) + 2) * cell - 4
                        Capsule().fill(Color(.systemFill))
                            .frame(width: max(Self.ball, end - start), height: Self.ball)
                            .offset(x: start, y: (Self.numberRow - Self.ball) / 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .animation(dragging ? nil : .interpolatingSpring(stiffness: 190, damping: 19), value: viewOffset)
                }
                .animation(.interpolatingSpring(stiffness: 190, damping: 19), value: trailing)
            }
            .animation(.interpolatingSpring(stiffness: 190, damping: 19), value: leading)
        }
    }

    private func updateWidth(_ width: CGFloat) {
        if abs(stripWidth - width) > 0.5 { DispatchQueue.main.async { stripWidth = width } }
    }

    /// The circle on the first day and the ones that have just left. They are placed like the days, by day number against the same
    /// interpolated offset, so a circle that is fading out keeps sliding with its day.
    private func circles(cell: CGFloat, offset: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(ghosts) { ghost in
                FadingBall(color: ghost.isToday ? .accentColor : .primary, size: Self.ball)
                    .offset(x: (CGFloat(ghost.day) - CGFloat(offset)) * cell + (cell - Self.ball) / 2, y: (Self.numberRow - Self.ball) / 2)
            }
            GrowingBall(color: ball == today.daysSinceUnixEpoch ? .accentColor : .primary, size: Self.ball)
                .id(ballID)
                .offset(x: (CGFloat(ball) - CGFloat(offset)) * cell + (cell - Self.ball) / 2, y: (Self.numberRow - Self.ball) / 2)
        }
    }

    private func dayCell(_ day: LocalDate, cell: CGFloat) -> some View {
        let info = cells[day]
        let role = role(of: day)
        return VStack(spacing: 0) {
            ZStack {
                Button { onSelect(day) } label: {
                    Text("\(day.day)")
                        .font(.callout.monospacedDigit().weight(role == .none ? .regular : .bold))
                        .foregroundStyle(numberColor(role, day))
                        .frame(maxWidth: .infinity, minHeight: Self.numberRow)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(day.month)월 \(day.day)일, 일정 \(info?.eventCount ?? 0)건")
                .accessibilityAddTraits(isShown(day) ? .isSelected : [])
            }
            .frame(height: Self.numberRow)
            HStack(spacing: 3) {
                Circle().fill((info?.eventCount ?? 0) > 0 ? Color.accentColor : .clear).frame(width: 5, height: 5)
                Circle().fill((info?.unlinkedTransactionCount ?? 0) > 0 ? Color.orange : .clear).frame(width: 5, height: 5)
            }
            .frame(height: 9)
        }
        .frame(width: cell)
    }

    private func numberColor(_ role: Role, _ day: LocalDate) -> Color {
        switch role {
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

/// Draws `content` from a number that SwiftUI interpolates frame by frame, so everything built from it moves as one.
private struct InterpolatedView<Content: View>: View, Animatable {
    var value: Double
    let content: (Double) -> Content

    init(value: Double, @ViewBuilder content: @escaping (Double) -> Content) {
        self.value = value
        self.content = content
    }

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { content(value) }
}

/// A circle that grows from its own centre when it appears.
private struct GrowingBall: View {
    let color: Color
    let size: CGFloat
    @State private var shown = false

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .scaleEffect(shown ? 1 : 0.3)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.16)) { shown = true } }
    }
}

/// A circle that fades out where it is (its owner keeps moving it with its day).
private struct FadingBall: View {
    let color: Color
    let size: CGFloat
    @State private var faded = false

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(faded ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 0.2)) { faded = true } }
    }
}
