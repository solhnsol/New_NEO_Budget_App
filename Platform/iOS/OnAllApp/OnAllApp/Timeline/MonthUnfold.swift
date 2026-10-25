import NEOBudgetCalendar
import SwiftUI

/// The sizes and calendar arithmetic of the month that unfolds out of the header.
enum MonthUnfold {
    /// A week of the month: the number row and the dots (the week strip's own) and, once the month is open, what was spent under them.
    static let numberRow: CGFloat = 36
    static let dotsRow: CGFloat = 9
    static let spendRow: CGFloat = 14
    static let rowHeight: CGFloat = numberRow + dotsRow + spendRow
    /// The weekday names over the weeks and the title bar (month and arrows) over those.
    static let labelRow: CGFloat = 15
    static let titleRow: CGFloat = 40
    /// What the strip has under its dots and the month does not.
    static let stripBottomPadding: CGFloat = 6

    static func firstOfMonth(_ day: LocalDate) -> LocalDate { day.adding(days: 1 - day.day) }

    static func shifted(_ month: LocalDate, by delta: Int) -> LocalDate {
        let index = month.year * 12 + (month.month - 1) + delta
        return (try? LocalDate(year: index / 12, month: index % 12 + 1, day: 1)) ?? month
    }

    static func rows(for month: LocalDate) -> Int {
        (month.weekday + LocalDate.daysInMonth(year: month.year, month: month.month) + 6) / 7
    }

    static func gridStart(of month: LocalDate) -> LocalDate { month.adding(days: -month.weekday) }

    /// The row of `month` the week of `day` is, or nil when that week is not in it.
    static func anchorRow(of day: LocalDate, in month: LocalDate) -> Int? {
        let offset = day.daysSinceUnixEpoch - gridStart(of: month).daysSinceUnixEpoch
        guard offset >= 0, offset / 7 < rows(for: month) else { return nil }
        return offset / 7
    }

    /// How far the header's bottom edge travels between closed and open: the finger moves the same distance, so the edge follows it.
    static func travel(rows: Int) -> CGFloat {
        let closed = labelRow + numberRow + dotsRow + stripBottomPadding
        return titleRow + labelRow + CGFloat(rows) * rowHeight - closed
    }

    /// The height of the strip at `unfold` (its weekday names folded away, a line for what was spent opened).
    static func stripHeight(unfold: CGFloat) -> CGFloat {
        labelRow * (1 - unfold) + numberRow + dotsRow + spendRow * unfold + stripBottomPadding * (1 - unfold)
    }

    /// 24,000 → 2.4만, 70,000 → 7만; under 10,000 it is written out (1,550). Nil when nothing was spent that day.
    static func spendText(of cell: WeekStripDay?) -> String? {
        guard let money = cell?.netSpend.first(where: { $0.currency == "KRW" }) ?? cell?.netSpend.first, money.minorUnits > 0 else { return nil }
        let won = money.minorUnits
        guard won >= 10_000 else { return Formatting.grouped(won) }
        let tenThousands = Double(won) / 10_000
        return (tenThousands >= 100 ? String(format: "%.0f", tenThousands) : String(format: "%.1f", tenThousands)).replacingOccurrences(of: ".0", with: "") + "만"
    }

    /// 0 until `from`, 1 from `to`, a straight line between.
    static func ramp(_ value: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat { max(0, min(1, (value - from) / (to - from))) }
}

/// How far the month is open and the pull that is opening or closing it. Held apart from the screen so that a finger moving it re-draws only the header.
@MainActor @Observable
final class MonthUnfoldState {
    /// 0 is the closed header, 1 the whole month.
    var progress: CGFloat = 0
    /// 1 while the strip's week is one of the weeks of the month shown, 0 when the month shown is another one (the strip then folds away).
    var presence: CGFloat = 1
    /// The first day of the month shown.
    var month = MonthUnfold.firstOfMonth(LocalDate(daysSinceUnixEpoch: 0))
    /// The day the strip showed when the month was opened. The weeks are laid out around its week, and stay so while the month closes on a day picked in it.
    var anchorDay = LocalDate(daysSinceUnixEpoch: 0)

    private enum Pull { case idle, pulling(start: CGFloat, origin: CGFloat), ignored }
    @ObservationIgnored private var pull = Pull.idle

    var isOpen: Bool { progress > 0.001 }

    /// A finger that has dragged the header (past the drag's small threshold) is not tapping: a day under it when it lets go is not a pick. The
    /// day buttons fire on release, before or after the drag's own end, so the lock holds while dragging and a moment past the end.
    @ObservationIgnored private var tapsLockedUntil = Date.distantPast
    var allowsTap: Bool { Date() >= tapsLockedUntil }

    private static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)

    func toggle(selected: LocalDate) { isOpen ? close() : open(selected: selected) }

    func open(selected: LocalDate) {
        if !isOpen { prepare(selected: selected) }
        withAnimation(Self.spring) { progress = 1 }
    }

    func close() {
        restoreMonth()
        withAnimation(Self.spring) { progress = 0 }
    }

    /// An arrow or a sideways swipe: another month's weeks take the place of these. The strip folds away while its week is not among them.
    func shift(by delta: Int) {
        let next = MonthUnfold.shifted(month, by: delta)
        withAnimation(.snappy(duration: 0.3)) {
            month = next
            presence = MonthUnfold.anchorRow(of: anchorDay, in: next) == nil ? 0 : 1
        }
    }

    private func prepare(selected: LocalDate) {
        anchorDay = selected
        month = MonthUnfold.firstOfMonth(selected)
        presence = 1
    }

    /// Back to the month the strip's week is in, at once, so that closing (or pulling up) always ends on the strip.
    private func restoreMonth() {
        let home = MonthUnfold.firstOfMonth(anchorDay)
        guard month != home || presence != 1 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { month = home; presence = 1 }
    }

    /// A drag on the header: down opens the month, up closes it, and the edge follows the finger. It only starts on a vertical move, so the strip's own
    /// sideways swipe is untouched.
    func drag(_ translation: CGSize, selected: LocalDate) {
        tapsLockedUntil = .distantFuture
        switch pull {
        case .idle:
            guard abs(translation.height) > abs(translation.width), translation.height > 0 || isOpen else {
                if abs(translation.width) > 10 { pull = .ignored }
                return
            }
            if isOpen { restoreMonth() } else { prepare(selected: selected) }
            pull = .pulling(start: progress, origin: translation.height)
        case let .pulling(start, origin):
            let travel = MonthUnfold.travel(rows: MonthUnfold.rows(for: month))
            progress = max(0, min(1, start + (translation.height - origin) / travel))
        case .ignored:
            break
        }
    }

    /// Let go: it settles open or closed by where it was heading, as a spring that starts at the finger's own speed.
    func endDrag(_ translation: CGSize, velocity: CGSize) {
        tapsLockedUntil = Date().addingTimeInterval(0.25)
        defer { pull = .idle }
        switch pull {
        case .pulling:
            let travel = MonthUnfold.travel(rows: MonthUnfold.rows(for: month))
            let speed = velocity.height / travel
            let target: CGFloat = progress + speed * 0.25 > 0.5 ? 1 : 0
            let remaining = target - progress
            let initial = abs(remaining) > 0.02 ? max(-4, min(6, speed / remaining)) : 0
            if target == 0 { restoreMonth() }
            withAnimation(.interpolatingSpring(mass: 1, stiffness: 190, damping: 24, initialVelocity: initial)) { progress = target }
        case .ignored:
            if progress > 0.99, abs(translation.width) > 40, abs(translation.width) > abs(translation.height) * 1.5 { shift(by: translation.width < 0 ? 1 : -1) }
        case .idle:
            break
        }
    }
}

/// The dim over what the month unfolds across.
struct MonthScrim: View {
    let state: MonthUnfoldState

    var body: some View {
        Color.black.opacity(0.22 * min(1, state.progress))
            .ignoresSafeArea()
            .allowsHitTesting(state.isOpen)
            .onTapGesture { state.close() }
    }
}

/// The header with the month unfolding out of it. The current week stays where the strip is and the other weeks of the month open around it, above
/// and below, as far as the finger has pulled; the header's own material carries on behind all of it, so there is no change of colour.
///
/// The screen under the header keeps its place (the screen takes its inset from the header only while it is closed): the month is drawn over it.
struct MonthUnfoldHeader<Top: View, Strip: View>: View {
    let state: MonthUnfoldState
    let today: LocalDate
    let cells: (LocalDate) -> WeekStripDay?
    /// The list has a rule under the strip; the grid's column titles carry theirs.
    let showsRule: Bool
    let onSelect: (LocalDate) -> Void
    let loadMonth: (LocalDate) async -> Void
    let selected: LocalDate
    @ViewBuilder let top: () -> Top
    /// The week strip at the given unfold (0 closed, 1 open).
    @ViewBuilder let strip: (CGFloat) -> Strip

    var body: some View {
        UnfoldLayer(progress: state.progress, presence: state.presence) { progress, presence in
            content(progress: max(0, min(1.03, progress)), presence: max(0, min(1, presence)))
        }
        .task(id: MonthUnfold.firstOfMonth(selected)) { await loadMonth(MonthUnfold.firstOfMonth(selected)) }
        .task(id: state.month) { if state.isOpen { await loadMonth(state.month) } }
    }

    private func content(progress p: CGFloat, presence: CGFloat) -> some View {
        let month = state.month
        let rowCount = MonthUnfold.rows(for: month)
        let anchor = p > 0 ? MonthUnfold.anchorRow(of: state.anchorDay, in: month) : nil
        let before = anchor ?? (p > 0 ? rowCount : 0)
        let after = anchor.map { rowCount - 1 - $0 } ?? 0
        let unfold = min(1, p)
        return VStack(spacing: 0) {
            top()
            titleBar(month: month, p: p)
            weekdayLabels(month: month, p: p)
            weeks(0..<before, month: month, p: p, nearestLast: true)
            strip(unfold)
                .frame(height: presence < 1 ? MonthUnfold.stripHeight(unfold: unfold) * presence : nil, alignment: .top)
                .clipped()
                .opacity(presence)
                .allowsHitTesting(presence > 0.5)
            weeks((rowCount - after)..<rowCount, month: month, p: p, nearestLast: false)
            if showsRule { Divider() } else if p > 0 { Divider().opacity(min(1, p * 3)).frame(height: min(1, p * 3)) }
        }
        .background { TopBarBackground().ignoresSafeArea(edges: .top) }
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { state.drag($0.translation, selected: selected) }
                .onEnded { state.endDrag($0.translation, velocity: $0.velocity) }
        )
    }

    private func titleBar(month: LocalDate, p: CGFloat) -> some View {
        HStack {
            Button { state.shift(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: MonthUnfold.titleRow) }
            Spacer()
            Text("\(String(month.year))년 \(month.month)월").font(.system(.subheadline, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { state.shift(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: MonthUnfold.titleRow) }
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: MonthUnfold.titleRow, alignment: .top)
        .frame(height: MonthUnfold.titleRow * p, alignment: .top)
        .clipped()
        .opacity(MonthUnfold.ramp(p, from: 0.25, to: 0.75))
        .allowsHitTesting(p > 0.9)
    }

    private func weekdayLabels(month: LocalDate, p: CGFloat) -> some View {
        let start = MonthUnfold.gridStart(of: month)
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { column in
                Text(Formatting.weekdayShort(start.adding(days: column))).font(.system(.caption2)).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: MonthUnfold.labelRow, alignment: .top)
        .frame(height: MonthUnfold.labelRow * p, alignment: .top)
        .clipped()
        .opacity(p)
    }

    /// Weeks of the month that lie on one side of the strip. They are drawn at their own size and uncovered from the strip outwards: the week next to it
    /// first, the farthest last, each fading in as the opening edge passes it.
    private func weeks(_ rows: Range<Int>, month: LocalDate, p: CGFloat, nearestLast: Bool) -> some View {
        let start = MonthUnfold.gridStart(of: month)
        let open = CGFloat(rows.count) * MonthUnfold.rowHeight * p
        return VStack(spacing: 0) {
            ForEach(Array(rows), id: \.self) { row in
                let distance = nearestLast ? rows.upperBound - row : row - rows.lowerBound + 1
                let shown = max(0, min(1, (open - CGFloat(distance - 1) * MonthUnfold.rowHeight) / MonthUnfold.rowHeight))
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in dayCell(start.adding(days: row * 7 + column), month: month) }
                }
                .padding(.horizontal, 8)
                .frame(height: MonthUnfold.rowHeight)
                .opacity(shown)
            }
        }
        .frame(height: open, alignment: nearestLast ? .bottom : .top)
        .clipped()
    }

    /// Made like the strip's day, so the week that is the strip and the weeks around it read as one.
    private func dayCell(_ day: LocalDate, month: LocalDate) -> some View {
        let info = cells(day)
        let spent = MonthUnfold.spendText(of: info)
        return Button { if state.allowsTap { onSelect(day) } } label: {
            VStack(spacing: 0) {
                Text("\(day.day)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(day == today ? Theme.accent : Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: MonthUnfold.numberRow, maxHeight: MonthUnfold.numberRow)
                HStack(spacing: 3) {
                    Circle().fill((info?.eventCount ?? 0) > 0 ? Theme.accent : .clear).frame(width: 5, height: 5)
                    Circle().fill((info?.unlinkedTransactionCount ?? 0) > 0 ? Theme.caution : .clear).frame(width: 5, height: 5)
                }
                .frame(height: MonthUnfold.dotsRow)
                Text(spent ?? " ")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(height: MonthUnfold.spendRow)
            }
            .frame(maxWidth: .infinity)
            .opacity(day.month == month.month ? 1 : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.month)월 \(day.day)일, 일정 \(info?.eventCount ?? 0)건" + (spent.map { ", 지출 \($0)" } ?? ""))
    }
}

/// Draws `content` from the open amount and the strip's presence as SwiftUI interpolates them frame by frame, so that everything laid out from them
/// (heights, fades) is worked out afresh at every point of a spring and not only at its two ends.
private struct UnfoldLayer<Content: View>: View, Animatable {
    var progress: CGFloat
    var presence: CGFloat
    let content: (CGFloat, CGFloat) -> Content

    init(progress: CGFloat, presence: CGFloat, @ViewBuilder content: @escaping (CGFloat, CGFloat) -> Content) {
        self.progress = progress
        self.presence = presence
        self.content = content
    }

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, presence) }
        set { progress = newValue.first; presence = newValue.second }
    }

    var body: some View { content(progress, presence) }
}
