import NEOBudgetCalendar
import SwiftUI

/// The design's calendar: the week strip and the month are one grid. Every week of the month is laid out at its own 96pt row; the clip over it is 60pt for
/// the week and grows to the whole month as `progress` (0 to 1) rises, and the selected week is held at the top by moving the rows up by
/// `selectedRow × 96 × (1 − progress)`. What a day shows is drawn once and fades by `progress` (its dots and amount for the week, its bars and amounts for
/// the month); nothing is swapped. Paging sideways attaches the neighbouring weeks (or months, once it is open) beside it, follows the finger, and lets
/// them take over, so a week and a month move the same way.
struct MonthUnfoldHeader<Top: View>: View {
    let state: MonthUnfoldState
    let today: LocalDate
    let cells: (LocalDate) -> WeekStripDay?
    let color: (CalendarID) -> Color
    /// A day was tapped.
    let onSelect: (LocalDate) -> Void
    /// A swipe settled on another week or month (its day, the selected day moved by 7 days or a month); called once, as it lands.
    let onPage: (LocalDate) -> Void
    /// A hold on a day of the open month was let go on it: a new event there.
    var onCreate: (LocalDate) -> Void = { _ in }
    let loadMonth: (LocalDate) async -> Void
    let selected: LocalDate
    var income: (LocalDate) -> Int64 = { _ in 0 }
    /// Changes whenever what the days show may have changed (the pages are redrawn only then, or when they move through `progress`).
    var dataVersion = 0
    @ViewBuilder let top: () -> Top

    var body: some View {
        VStack(spacing: 0) {
            top()
            CalendarCard(
                state: state, today: today, selected: selected, cells: cells, color: color, income: income, dataVersion: dataVersion,
                onSelect: onSelect, onPage: onPage, onCreate: onCreate, loadMonth: loadMonth
            )
            .padding(.horizontal, Theme.cardMargin)
            .padding(.top, Theme.Space.m)
        }
        .background(alignment: .top) { Theme.background.ignoresSafeArea(edges: .top) }
    }
}

private let rowHeight: CGFloat = 96
private let stripHeight: CGFloat = 60

struct CalendarCard: View {
    let state: MonthUnfoldState
    let today: LocalDate
    let selected: LocalDate
    let cells: (LocalDate) -> WeekStripDay?
    let color: (CalendarID) -> Color
    let income: (LocalDate) -> Int64
    let dataVersion: Int
    let onSelect: (LocalDate) -> Void
    let onPage: (LocalDate) -> Void
    let onCreate: (LocalDate) -> Void
    let loadMonth: (LocalDate) async -> Void

    /// The day names, the week and the handle: what the card takes in layout.
    static let closedHeight: CGFloat = 28 + stripHeight + 22

    private enum Axis { case horizontal, vertical }
    @State private var axis: Axis?
    @State private var startProgress: CGFloat = 0
    @State private var dragX: CGFloat = 0
    @State private var paging = false
    @State private var width: CGFloat = 0
    /// A hold on a day of the open month: where the finger is (in the card) and the day under it. A bar for the new event follows the finger.
    @State private var hold: (point: CGPoint, day: LocalDate)?

    private var first: LocalDate { MonthUnfold.firstOfMonth(selected) }
    private var rows: Int { MonthUnfold.rows(for: first) }

    var body: some View {
        let rows = rows
        ProgressDriven(value: state.progress) { p in
            VStack(spacing: 0) {
                dayNames
                ZStack(alignment: .topLeading) {
                    CalendarPage(sel: selected, p: p, today: today, version: dataVersion, cells: cells, color: color, income: income, onTap: tap).equatable().offset(x: dragX)
                    if paging {
                        CalendarPage(sel: step(-1), p: p, today: today, version: dataVersion, cells: cells, color: color, income: income, onTap: { _ in }).equatable().offset(x: dragX - width)
                        CalendarPage(sel: step(1), p: p, today: today, version: dataVersion, cells: cells, color: color, income: income, onTap: { _ in }).equatable().offset(x: dragX + width)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: stripHeight + MonthUnfold.growth(rows: rows, progress: p), alignment: .top)
                .clipped()
                // The rows above and below the visible band are laid out beyond the clip; without this they still took the touches over the header buttons.
                .contentShape(Rectangle())
                handle
            }
            .overlay(alignment: .topLeading) { holdPreview(p: p, rows: rows) }
            .background(UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.card, topTrailingRadius: Theme.Radius.card).fill(Theme.surface))
        }
        // Laid out at the closed height whatever `progress` is: the open month overflows over the day list (which is moved down by `growth`) instead of
        // pushing it, so a finger moving the calendar does not lay the list out again.
        .frame(height: Self.closedHeight, alignment: .top)
        .background(GeometryReader { proxy in Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { _, new in width = new } })
        .simultaneousGesture(drag)
        .modifier(HoldToCreate(enabled: state.progress > 0.5) { phase in holdChanged(phase) })
        .task(id: first) {
            await loadMonth(first)
        }
    }

    // MARK: Pieces

    private var dayNames: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { column in
                Text(Formatting.weekdayShort(MonthUnfold.gridStart(of: first).adding(days: column))).font(.onAll(size: 12)).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4).padding(.top, Theme.Space.s).frame(height: 28, alignment: .top)
    }

    private var handle: some View {
        Capsule().fill(Theme.rail).frame(width: 36, height: 4)
            .frame(maxWidth: .infinity).frame(height: 22).contentShape(Rectangle())
            .onTapGesture { state.toggle() }
    }

    private func tap(_ day: LocalDate) {
        guard state.allowsTap else { return }
        // Belt and braces: a day whose row is outside the visible band cannot have been what the finger meant.
        let start = MonthUnfold.gridStart(of: first)
        let row = (day.daysSinceUnixEpoch - start.daysSinceUnixEpoch) / 7
        let selectedRow = (selected.daysSinceUnixEpoch - start.daysSinceUnixEpoch) / 7
        let p = max(0, min(1.03, state.progress))
        let top = CGFloat(row) * rowHeight - CGFloat(selectedRow) * rowHeight * (1 - state.progress)
        guard top + rowHeight > 0, top < stripHeight + (CGFloat(rows) * rowHeight - stripHeight) * p else { return }
        onSelect(day)
    }

    /// The day a swipe would land on: a week away while it is a strip, a month away once it is open (the day of the month kept, or the last day of it).
    private func step(_ direction: Int) -> LocalDate {
        if state.progress < 0.5 { return selected.adding(days: 7 * direction) }
        let target = MonthUnfold.shifted(first, by: direction)
        return (try? LocalDate(year: target.year, month: target.month, day: min(selected.day, LocalDate.daysInMonth(year: target.year, month: target.month)))) ?? target
    }

    // MARK: Hold to create

    enum HoldPhase { case began(CGPoint), moved(CGPoint), ended(CGPoint, cancelled: Bool) }

    /// The day under a point of the open month.
    private func day(at point: CGPoint) -> LocalDate {
        let cell = max(1, (width - 8) / 7)
        let column = max(0, min(6, Int((point.x - 4) / cell)))
        let start = MonthUnfold.gridStart(of: first)
        let selectedRow = (selected.daysSinceUnixEpoch - start.daysSinceUnixEpoch) / 7
        let y = point.y - 28 + CGFloat(selectedRow) * rowHeight * (1 - state.progress)
        let row = max(0, min(rows - 1, Int(y / rowHeight)))
        return start.adding(days: row * 7 + column)
    }

    private func holdChanged(_ phase: HoldPhase) {
        switch phase {
        case let .began(point), let .moved(point): hold = (point, day(at: point))
        case let .ended(point, cancelled):
            let target = day(at: point)
            hold = nil
            axis = nil
            if !cancelled { onCreate(target) }
        }
    }

    @ViewBuilder
    private func holdPreview(p: CGFloat, rows: Int) -> some View {
        if let hold {
            let cell = max(1, (width - 8) / 7)
            let start = MonthUnfold.gridStart(of: first)
            let offset = (hold.day.daysSinceUnixEpoch - start.daysSinceUnixEpoch)
            let selectedRow = (selected.daysSinceUnixEpoch - start.daysSinceUnixEpoch) / 7
            ZStack(alignment: .topLeading) {
                // The day it would land on.
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentStrong.opacity(0.07))
                    .frame(width: cell, height: rowHeight)
                    .offset(x: 4 + CGFloat(offset % 7) * cell, y: 28 + CGFloat(offset / 7) * rowHeight - CGFloat(selectedRow) * rowHeight * (1 - p))
                // The new event, a bar like the month's own, following the finger.
                Text("새 일정").font(.onAll(size: 10)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 3)
                    .frame(width: cell - 4, height: 13, alignment: .leading)
                    .background(Theme.caution, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .shadow(color: Theme.textPrimary.opacity(0.22), radius: 8, y: 6)
                    .position(x: hold.point.x, y: hold.point.y - 34)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    // MARK: Gestures

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard hold == nil else { return }
                if axis == nil {
                    guard hypot(value.translation.width, value.translation.height) >= 6 else { return }
                    axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                    startProgress = state.progress
                    state.lockTaps()
                    if axis == .horizontal {
                        paging = true
                        let current = first
                        Task {
                            await loadMonth(MonthUnfold.shifted(current, by: -1))
                            await loadMonth(MonthUnfold.shifted(current, by: 1))
                        }
                    }
                }
                switch axis {
                case .horizontal: dragX = value.translation.width
                case .vertical:
                    let range = CGFloat(rows) * rowHeight - stripHeight
                    var next = startProgress + value.translation.height / range
                    // Past either end the pull is rubber (the design: a quarter of the finger).
                    if next > 1 { next = 1 + (next - 1) * 0.25 } else if next < 0 { next *= 0.25 }
                    state.progress = next
                case nil: break
                }
            }
            .onEnded { value in
                defer { axis = nil; state.unlockTapsSoon() }
                switch axis {
                case .horizontal: finishPaging(value)
                case .vertical: finishPull(value)
                case nil: break
                }
            }
    }

    private func finishPull(_ value: DragGesture.Value) {
        let range = CGFloat(rows) * rowHeight - stripHeight
        let v = value.velocity.height
        let p = state.progress
        let target: CGFloat = v > 500 ? 1 : v < -500 ? 0 : (p > 0.5 ? 1 : 0)
        let remaining = target - p
        let initial = abs(remaining) > 0.02 ? max(-6, min(8, v / (range * remaining))) : 0
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 223.8, damping: 26.3, initialVelocity: initial)) { state.progress = target }
    }

    private func finishPaging(_ value: DragGesture.Value) {
        let w = max(1, width)
        let dx = value.translation.width, vx = value.velocity.width
        let go = abs(dx) > w * 0.25 || abs(vx) > 400
        let direction = (dx < 0 || vx < -400) ? 1 : -1
        let target: CGFloat = go ? -CGFloat(direction) * w : 0
        let initial = abs(target - dx) > 1 ? max(-8, min(8, vx / (target - dx))) : 0
        let destination = step(direction)
        // The swap runs once, when the spring finishes or, if its completion never arrives (it can wait for the next redraw, so the first tap after a
        // swipe seemed to snap back to the old week), a moment after the spring should be at rest.
        var swapped = false
        let swapIn = {
            guard !swapped else { return }
            swapped = true
            // The neighbour is drawn just as the page that replaces it will be, so swapping them shows no change.
            var swap = Transaction()
            swap.disablesAnimations = true
            withTransaction(swap) {
                if go { onPage(destination) }
                dragX = 0
                paging = false
            }
        }
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 385.5, damping: 35.3, initialVelocity: initial), completionCriteria: .logicallyComplete) {
            dragX = target
        } completion: { swapIn() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { swapIn() }
    }
}

/// One page of the grid: the month of `sel`, every week at its own row, held so that `sel`'s week is at the top while `p` is 0.
private struct CalendarPage: View, Equatable {
    let sel: LocalDate
    let p: CGFloat
    let today: LocalDate
    let version: Int
    let cells: (LocalDate) -> WeekStripDay?
    let color: (CalendarID) -> Color
    let income: (LocalDate) -> Int64
    let onTap: (LocalDate) -> Void

    /// Redrawn only when the page, how far it is open, or what the days hold changes: a page that is only being carried sideways is left as it is.
    nonisolated static func == (lhs: CalendarPage, rhs: CalendarPage) -> Bool {
        lhs.sel == rhs.sel && lhs.p == rhs.p && lhs.today == rhs.today && lhs.version == rhs.version
    }

    var body: some View {
        let first = MonthUnfold.firstOfMonth(sel)
        let start = MonthUnfold.gridStart(of: first)
        let rowCount = MonthUnfold.rows(for: first)
        let selectedRow = (sel.daysSinceUnixEpoch - start.daysSinceUnixEpoch) / 7
        VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { row in
                CalendarWeekRow(
                    days: (0..<7).map { start.adding(days: row * 7 + $0) }, month: first, sel: sel, p: p, today: today,
                    cells: cells, color: color, income: income, onTap: onTap
                )
                .frame(height: rowHeight)
            }
        }
        .offset(y: -CGFloat(selectedRow) * rowHeight * (1 - p))
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct CalendarWeekRow: View {
    let days: [LocalDate]
    let month: LocalDate
    let sel: LocalDate
    let p: CGFloat
    let today: LocalDate
    let cells: (LocalDate) -> WeekStripDay?
    let color: (CalendarID) -> Color
    let income: (LocalDate) -> Int64
    let onTap: (LocalDate) -> Void

    var body: some View {
        let infos = days.map(cells)
        let read = infos.compactMap { $0 }
        let layout = read.count == 7 ? MonthWeekLayout(week: read, lanes: MonthWeekBars.lanes) : nil
        // The month's layer (bars, amounts) is there from a third of the way and fully at the end; the week's (dots, amount) is gone by 40%.
        let monthLayer = max(0, p * 2 - 0.7)
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { column in
                    CalendarDay(
                        day: days[column], info: infos[column], inMonth: days[column].month == month.month, isSelected: days[column] == sel, today: today,
                        p: p, color: color, income: income(days[column]), overflow: layout?.overflow[column], onTap: onTap
                    )
                }
            }
            if let layout {
                MonthWeekBars(layout: layout, color: color).padding(.top, MonthUnfold.numberRow)
                    .opacity(monthLayer).offset(y: -(1 - p) * 6)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct CalendarDay: View {
    let day: LocalDate
    let info: WeekStripDay?
    let inMonth: Bool
    let isSelected: Bool
    let today: LocalDate
    let p: CGFloat
    let color: (CalendarID) -> Color
    let income: Int64
    let overflow: [WeekStripEvent]?
    let onTap: (LocalDate) -> Void

    var body: some View {
        let past = day < today
        let spent = past ? MonthUnfold.spendText(of: info) : nil
        let came = past && income > 0 ? MonthUnfold.amountText(income) : nil
        let weekLayer = max(0, 1 - p * 2.5), monthLayer = max(0, p * 2 - 0.7)
        ZStack(alignment: .top) {
            Text("\(day.day)")
                .font(.onAll(size: 16, weight: isSelected || day == today ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isSelected || day == today ? Theme.accentStrong : (inMonth ? Theme.textPrimary : Theme.disabled))
                .frame(width: 32, height: 32)
                .background(isSelected ? Theme.accentSoft : Color.clear, in: Circle())
                .padding(.top, 4)
            IncomeDot(show: came != nil, y: 6)
            // The week's layer: what the day holds, in one line under the number.
            Group {
                if past {
                    Text(spent ?? " ").font(.onAll(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.accent).lineLimit(1).minimumScaleFactor(0.6)
                } else {
                    EventDots(events: info?.events ?? [], color: color)
                }
            }
            .frame(height: 16).padding(.top, 40)
            .opacity(weekLayer).offset(y: -p * 4)
            // The month's layer: the amounts at the foot of the cell, and the events the bars had no room for.
            if inMonth {
                EventDots(events: came != nil && spent != nil ? [] : (overflow ?? []), color: color)
                    .padding(.top, 70).frame(maxHeight: .infinity, alignment: .top)
                    .opacity(monthLayer).offset(y: -(1 - p) * 6)
                AmountLines(spent: spent, income: came, open: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 2)
                    .opacity(monthLayer).offset(y: -(1 - p) * 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { onTap(day) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.month)월 \(day.day)일, 일정 \(info?.eventCount ?? 0)건" + (spent.map { ", 지출 \($0)" } ?? ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Moves `content` down by as much as the calendar card has grown. It reads the progress here, so a finger moving the calendar re-runs only this
/// (an offset) and not the screen that built `content`.
struct UnfoldPush<Content: View>: View {
    let state: MonthUnfoldState
    let rows: Int
    let content: Content

    init(state: MonthUnfoldState, rows: Int, @ViewBuilder content: () -> Content) {
        self.state = state
        self.rows = rows
        self.content = content()
    }

    var body: some View {
        ProgressDriven(value: state.progress) { p in content.offset(y: MonthUnfold.growth(rows: rows, progress: p)) }
    }
}

/// Draws `content` from a number that SwiftUI interpolates frame by frame, so everything built from it moves as one.
private struct ProgressDriven<Content: View>: View, Animatable {
    var value: CGFloat
    let content: (CGFloat) -> Content

    init(value: CGFloat, @ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.value = value
        self.content = content
    }

    nonisolated var animatableData: CGFloat {
        get { value }
        set { value = newValue }
    }

    var body: some View { content(value) }
}

/// Attaches the hold-and-follow to the open month (iOS 18 and later).
private struct HoldToCreate: ViewModifier {
    let enabled: Bool
    let phase: (CalendarCard.HoldPhase) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(HapticHoldDrag(isEnabled: enabled, began: { phase(.began($0)) }, moved: { phase(.moved($0)) }, ended: { phase(.ended($0, cancelled: $1)) }))
        } else {
            content
        }
    }
}
