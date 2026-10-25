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
/// When the week changes (a swipe on the strip), nothing morphs across pages: the old circle and capsule stay on their days and leave with
/// the week, and the new ones simply appear on the new week.
///
/// One state drives all of it: the day number `position`. Each day's circle and number colour are drawn from whether that day is the
/// position (one animation per day, keyed on that), and the capsule's two ends and the page are numbers animated towards it. A new day while
/// any of those is mid-flight only retargets them; no task finishes, removes or places anything later.
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
    /// How far the month is open under the strip (0 closed, 1 open): its weekday names fold away (the month has its own over all the weeks), a line for
    /// what was spent opens under each day, and it no longer pages sideways.
    var unfold: CGFloat = 0

    private static let numberRow: CGFloat = 36
    private static let ball: CGFloat = 32
    private static let weeksShown = 3

    /// The capsule's two ends as day numbers (days since the epoch), driven separately so the right end can lag the left.
    @State private var leading: Double = 0
    @State private var trailing: Double = 0
    /// The day (as a number) at the strip's left edge. Everything is placed by its own day number against this one value, so the strip can
    /// page between weeks, and be re-based when a swipe lands on a new week, without anything having to move.
    @State private var viewOffset: Double = 0
    @State private var seeded = false
    /// The day whose circle is being carried off by its week (a week swipe): it keeps its circle, at full strength, until it is off screen.
    @State private var leaving: Int?
    /// While a finger is dragging the strip, the strip follows it directly (no animation); on release it eases to the page it settles on.
    @State private var dragging = false
    @State private var stripWidth: CGFloat = 0
    /// A swipe on the strip itself is changing the week: the capsule does not follow the days, it fades out and comes back on the new day.
    @State private var swipedWeek = false
    /// A day tapped while (or just after) the strip is dragged is the drag's touch, not a pick.
    @State private var tapsBlockedUntil = Date.distantPast
    @State private var capsuleOpacity = 1.0
    /// The new week's capsule appearing, and the end of a week swipe that moved no day: both are cancelled by the next move.
    @State private var capsuleFade: Task<Void, Never>?
    @State private var swipeReset: Task<Void, Never>?
    /// The capsule that has just left a week: it stays on the days it was on and slides away with them.
    @State private var capsuleGhosts: [CapsuleGhost] = []

    private struct CapsuleGhost: Identifiable { let id = UUID(); let lead: Double; let trail: Double }

    private static let capsuleSpring = Animation.interpolatingSpring(stiffness: 190, damping: 19)

    private var weekStart: LocalDate { selected.adding(days: -selected.weekday) }
    private var position: Int { selected.daysSinceUnixEpoch + pendingShift }
    /// The first day of the week the circle is in: where the strip's left edge should be.
    private var pageStart: Int { position - LocalDate(daysSinceUnixEpoch: position).weekday }

    var body: some View {
        let probe = BrowseProbe.begin(.weekStripBody)
        defer { BrowseProbe.end(probe) }
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { column in
                    Text(Formatting.weekdayShort(weekStart.adding(days: column))).font(.system(.caption2)).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity)
                }
            }
            .frame(height: MonthUnfold.labelRow - 2, alignment: .top)
            .padding(.bottom, 2)
            .frame(height: MonthUnfold.labelRow * (1 - unfold), alignment: .top)
            .clipped()
            .opacity(1 - unfold)
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
                            ForEach(capsuleGhosts) { ghost in
                                capsuleShape(lead: ghost.lead, trail: ghost.trail, offset: offset, cell: cell).transition(.identity)
                            }
                            ForEach(low..<high, id: \.self) { number in
                                dayCell(LocalDate(daysSinceUnixEpoch: number), cell: cell)
                                    .offset(x: (CGFloat(number) - CGFloat(offset)) * cell)
                            }
                        }
                    }
                    .animation(dragging ? nil : .snappy(duration: 0.34), value: viewOffset)
                }
                .frame(width: geometry.size.width, height: Self.numberRow + 9 + MonthUnfold.spendRow * unfold, alignment: .topLeading)
            }
            .frame(height: Self.numberRow + 9 + MonthUnfold.spendRow * unfold)
            .clipped()
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard unfold == 0, abs(value.translation.width) > abs(value.translation.height) else { return }
                        dragging = true
                        tapsBlockedUntil = Date().addingTimeInterval(0.4)
                        // The strip is held and dragged: the neighbouring weeks come into view with the finger.
                        let cell = max(1, stripWidth / 7)
                        viewOffset = Double(pageStart) - Double(max(-stripWidth, min(stripWidth, value.translation.width)) / cell)
                    }
                    .onEnded { value in
                        guard dragging else { return }
                        dragging = false
                        tapsBlockedUntil = Date().addingTimeInterval(0.3)
                        let width = max(1, stripWidth)
                        let flick = abs(value.velocity.width) > 500 && (value.velocity.width < 0) == (value.translation.width < 0)
                        let far = abs(value.translation.width) > width * 0.3
                        if far || flick, abs(value.translation.width) > 8 {
                            // The page changes with the day the strip's selection moves to (see `move`).
                            swipedWeek = true
                            leaving = position
                            swipeReset?.cancel()
                            swipeReset = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(600))
                                guard !Task.isCancelled else { return }
                                swipedWeek = false
                                leaving = nil
                            }
                            // The strip does not wait for the day to move: it pages to the next week as the finger lets go (the screen may be busy
                            // moving the days below), and `move` then finds it already there. Until then it would sit half-way with no circle.
                            let direction = value.translation.width < 0 ? 1 : -1
                            viewOffset = Double(pageStart + 7 * direction)
                            onPage(direction)
                        } else {
                            viewOffset = Double(pageStart)
                        }
                    }
            )
        }
        .padding(.horizontal, 8)
        .padding(.bottom, MonthUnfold.stripBottomPadding * (1 - unfold))
        .onAppear { seed() }
        // The day can change inside a transaction that turns animations off (the screen moves the selected day that way, so the grid below does not
        // animate): the strip's own motion is started in a fresh one, so the page, the circle leaving with its week and the capsule always move.
        .onChange(of: position) { old, _ in withTransaction(Transaction()) { move(from: old) } }
    }

    private enum Role { case none, first, second }

    private func role(of day: LocalDate) -> Role {
        let number = day.daysSinceUnixEpoch
        // The circle and capsule that are leaving with their week still sit on their own days, so those numbers keep how they were written on them.
        for anchor in [position] + (leaving.map { [$0] } ?? []) {
            if number == anchor { return .first }
            if showsNextDay, number == anchor + 1 { return .second }
        }
        return .none
    }

    private func isShown(_ day: LocalDate) -> Bool { day == selected || (showsNextDay && day == selected.adding(days: 1)) }

    private func seed() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { leading = Double(position); trailing = Double(position); viewOffset = Double(pageStart) }
        seeded = true
    }

    /// The capsule's left end follows the new day at once and its right end a moment later (the delay belongs to the animation), which is what
    /// makes it stretch like a liquid. A newer day replaces both animations where they are, so nothing waits to land late.
    private func move(from previous: Int) {
        guard seeded else { return seed() }
        let target = position
        let wasSwipe = swipedWeek
        swipedWeek = false
        swipeReset?.cancel()
        capsuleFade?.cancel()
        if !wasSwipe { leaving = nil; capsuleOpacity = 1 }
        viewOffset = Double(pageStart)
        if wasSwipe { return replaceCapsule(to: target) }
        // Going forward the circle's end moves first and the far end catches up (the capsule squeezes, then stretches). Going back it is the
        // far end that moves first and the circle's end that catches up, so the capsule does the same thing in both directions.
        let quick = Self.capsuleSpring, slow = Self.capsuleSpring.delay(0.045)
        if target < previous {
            withAnimation(quick) { trailing = Double(target) }
            withAnimation(slow) { leading = Double(target) }
        } else {
            withAnimation(quick) { leading = Double(target) }
            withAnimation(slow) { trailing = Double(target) }
        }
    }

    /// A week swipe: the capsule does not morph across the pages. The old one stays on its days and leaves with the week; the new one simply
    /// appears on the new week.
    private func replaceCapsule(to target: Int) {
        let ghost = CapsuleGhost(lead: leading, trail: trailing)
        capsuleGhosts.append(ghost)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            capsuleGhosts.removeAll { $0.id == ghost.id }
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { leading = Double(target); trailing = Double(target); capsuleOpacity = 0 }
        capsuleFade = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) { capsuleOpacity = 1 }
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
                        capsuleShape(lead: lead, trail: trail, offset: offset, cell: cell).opacity(capsuleOpacity)
                    }
                    .animation(dragging ? nil : Self.capsuleSpring, value: viewOffset)
                }
            }
        }
    }

    private func capsuleShape(lead: Double, trail: Double, offset: Double, cell: CGFloat) -> some View {
        let start = (CGFloat(lead) - CGFloat(offset) + 0.5) * cell
        let end = (CGFloat(trail) - CGFloat(offset) + 2) * cell - 4
        return Capsule().fill(Theme.fill)
            .frame(width: max(Self.ball, end - start), height: Self.ball)
            .offset(x: start, y: (Self.numberRow - Self.ball) / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func updateWidth(_ width: CGFloat) {
        if abs(stripWidth - width) > 0.5 { DispatchQueue.main.async { stripWidth = width } }
    }

    private func dayCell(_ day: LocalDate, cell: CGFloat) -> some View {
        let info = cells[day]
        let role = role(of: day)
        return VStack(spacing: 0) {
            ZStack {
                // The day's own circle: in when it is the first day, out when it is not, and the number's colour with it, all from `role`. A day
                // changed again half-way simply turns back from wherever it is.
                Circle().fill(day == today ? Theme.accent : Theme.textPrimary).frame(width: Self.ball, height: Self.ball)
                    .scaleEffect(role == .first || swipedWeek ? 1 : 0.3)
                    .opacity(role == .first ? 1 : 0)
                    .allowsHitTesting(false)
                Button { if Date() >= tapsBlockedUntil { onSelect(day) } } label: {
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
            .animation(roleAnimation(role), value: role)
            HStack(spacing: 3) {
                Circle().fill((info?.eventCount ?? 0) > 0 ? Theme.accent : .clear).frame(width: 5, height: 5)
                Circle().fill((info?.unlinkedTransactionCount ?? 0) > 0 ? Theme.caution : .clear).frame(width: 5, height: 5)
            }
            .frame(height: 9)
            if unfold > 0 {
                Text(MonthUnfold.spendText(of: info) ?? " ")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(height: MonthUnfold.spendRow)
                    .opacity(unfold)
            }
        }
        .frame(width: cell)
    }

    /// The circle grows in over a moment and fades out over a little longer; a circle carried off by its week is not animated at all.
    private func roleAnimation(_ role: Role) -> Animation? {
        if role == .first { return .easeOut(duration: 0.16) }
        return swipedWeek ? nil : .easeOut(duration: 0.2)
    }

    private func numberColor(_ role: Role, _ day: LocalDate) -> Color {
        switch role {
        case .first: return day == today ? .white : Theme.surface
        case .second: return Theme.textSecondary
        case .none: return day == today ? Theme.accent : Theme.textPrimary
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
                    let color = Color(hex: item.calendarColorHex) ?? Theme.accent
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
