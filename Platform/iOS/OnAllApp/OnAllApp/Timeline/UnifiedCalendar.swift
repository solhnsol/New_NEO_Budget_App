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
        let p = state.progress
        VStack(spacing: 0) {
                dayNames
                ZStack(alignment: .topLeading) {
                    CalendarPage(sel: selected, state: state, today: today, version: dataVersion, cells: cells, color: color, income: income, onTap: tap).equatable().offset(x: dragX)
                    if paging {
                        CalendarPage(sel: step(-1), state: state, today: today, version: dataVersion, cells: cells, color: color, income: income, onTap: { _ in }).equatable().offset(x: dragX - width)
                        CalendarPage(sel: step(1), state: state, today: today, version: dataVersion, cells: cells, color: color, income: income, onTap: { _ in }).equatable().offset(x: dragX + width)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: stripHeight + (CGFloat(rows) * rowHeight - stripHeight) * max(0, min(1.03, p)), alignment: .top)
                .clipped()
                handle
        }
        .overlay(alignment: .topLeading) { holdPreview(p: p, rows: rows) }
        .background(UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.card, topTrailingRadius: Theme.Radius.card).fill(Theme.surface))
        .background(GeometryReader { proxy in Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { _, new in width = new } })
        .modifier(CardPan(changed: panChanged, ended: panEnded))
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

    /// The finger on the card (first call of a touch: it takes hold of a month that is still settling; `translation` is from where the touch began).
    private func panChanged(_ translation: CGSize) {
        guard hold == nil else { return }
        if axis == nil {
            guard hypot(translation.width, translation.height) >= 6 else { return }
            axis = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
            state.stop()
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
        case .horizontal: dragX = translation.width
        case .vertical:
            let range = CGFloat(rows) * rowHeight - stripHeight
            var next = startProgress + translation.height / range
            // Past either end the pull is rubber (the design: a quarter of the finger).
            if next > 1 { next = 1 + (next - 1) * 0.25 } else if next < 0 { next *= 0.25 }
            state.progress = next
        case nil: break
        }
    }

    private func panEnded(_ translation: CGSize, _ velocity: CGSize) {
        defer { axis = nil; state.unlockTapsSoon() }
        switch axis {
        case .horizontal: finishPaging(dx: translation.width, vx: velocity.width)
        case .vertical: finishPull(v: velocity.height)
        case nil: break
        }
    }

    private func finishPull(v: CGFloat) {
        let range = CGFloat(rows) * rowHeight - stripHeight
        let p = state.progress
        // The finger's speed goes on into the spring: the month keeps moving the way the hand was.
        state.settle(to: v > 500 ? 1 : v < -500 ? 0 : (p > 0.5 ? 1 : 0), velocity: v / range)
    }

    private func finishPaging(dx: CGFloat, vx: CGFloat) {
        let w = max(1, width)
        let go = abs(dx) > w * 0.25 || abs(vx) > 400
        let direction = (dx < 0 || vx < -400) ? 1 : -1
        let target: CGFloat = go ? -CGFloat(direction) * w : 0
        let initial = abs(target - dx) > 1 ? max(-8, min(8, vx / (target - dx))) : 0
        let destination = step(direction)
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 385.5, damping: 35.3, initialVelocity: initial), completionCriteria: .logicallyComplete) {
            dragX = target
        } completion: {
            // The neighbour is drawn just as the page that replaces it will be, so swapping them shows no change.
            var swap = Transaction()
            swap.disablesAnimations = true
            withTransaction(swap) {
                if go { onPage(destination) }
                dragX = 0
                paging = false
            }
        }
    }
}

/// One page of the grid: the month of `sel`, every week at its own row, held so that `sel`'s week is at the top while `p` is 0.
private struct CalendarPage: View, Equatable {
    let sel: LocalDate
    let state: MonthUnfoldState
    let today: LocalDate
    let version: Int
    let cells: (LocalDate) -> WeekStripDay?
    let color: (CalendarID) -> Color
    let income: (LocalDate) -> Int64
    let onTap: (LocalDate) -> Void

    /// Redrawn only when the page, how far it is open, or what the days hold changes: a page that is only being carried sideways is left as it is.
    nonisolated static func == (lhs: CalendarPage, rhs: CalendarPage) -> Bool {
        lhs.sel == rhs.sel && lhs.state === rhs.state && lhs.today == rhs.today && lhs.version == rhs.version
    }

    var body: some View {
        let first = MonthUnfold.firstOfMonth(sel)
        let start = MonthUnfold.gridStart(of: first)
        let rowCount = MonthUnfold.rows(for: first)
        let selectedRow = (sel.daysSinceUnixEpoch - start.daysSinceUnixEpoch) / 7
        // Past days are tinted by what was spent, from the most (deepest) to the least, so the month reads at a glance.
        let spends = (0..<rowCount * 7).compactMap { i -> (LocalDate, Int64)? in
            let d = start.adding(days: i)
            guard d < today, let m = (cells(d)?.netSpend.first(where: { $0.currency == "KRW" }) ?? cells(d)?.netSpend.first)?.minorUnits, m > 0 else { return nil }
            return (d, m)
        }.sorted { $0.1 < $1.1 }
        let shades = Dictionary(uniqueKeysWithValues: spends.enumerated().map { ($1.0, Double($0 + 1) / Double(spends.count)) })
        VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { row in
                CalendarWeekRow(
                    days: (0..<7).map { start.adding(days: row * 7 + $0) }, month: first, sel: sel, state: state, today: today, shades: shades,
                    cells: cells, color: color, income: income, onTap: onTap
                )
                .frame(height: rowHeight)
            }
        }
        .modifier(ByProgress(state: state, y: { -CGFloat(selectedRow) * rowHeight * (1 - $0) }))
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct CalendarWeekRow: View {
    let days: [LocalDate]
    let month: LocalDate
    let sel: LocalDate
    let state: MonthUnfoldState
    let today: LocalDate
    let shades: [LocalDate: Double]
    let cells: (LocalDate) -> WeekStripDay?
    let color: (CalendarID) -> Color
    let income: (LocalDate) -> Int64
    let onTap: (LocalDate) -> Void

    var body: some View {
        let infos = days.map(cells)
        let read = infos.compactMap { $0 }
        let layout = read.count == 7 ? MonthWeekLayout(week: read, lanes: MonthWeekBars.lanes) : nil
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { column in
                    CalendarDay(
                        day: days[column], info: infos[column], inMonth: days[column].month == month.month, isSelected: days[column] == sel, today: today,
                        state: state, shade: shades[days[column]] ?? 0, color: color, income: income(days[column]), overflow: layout?.overflow[column], onTap: onTap
                    )
                }
            }
            if let layout {
                MonthWeekBars(layout: layout, color: color).padding(.top, MonthUnfold.numberRow)
                    .modifier(ByProgress(state: state, opacity: monthLayer, y: { -(1 - $0) * 6 }))
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
    let state: MonthUnfoldState
    /// 0 for a day with no spending to show; up to 1 for the month's biggest.
    let shade: Double
    let color: (CalendarID) -> Color
    let income: Int64
    let overflow: [WeekStripEvent]?
    let onTap: (LocalDate) -> Void

    var body: some View {
        let past = day < today
        let spent = past ? MonthUnfold.spendText(of: info) : nil
        let came = past && income > 0 ? MonthUnfold.amountText(income) : nil
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
            .modifier(ByProgress(state: state, opacity: { Double(max(0, 1 - $0 * 2.5)) }, y: { -$0 * 4 }))
            // The month's layer: the amounts at the foot of the cell, and the events the bars had no room for.
            if inMonth {
                EventDots(events: came != nil && spent != nil ? [] : (overflow ?? []), color: color)
                    .padding(.top, 70).frame(maxHeight: .infinity, alignment: .top)
                    .modifier(ByProgress(state: state, opacity: monthLayer, y: { -(1 - $0) * 6 }))
                AmountLines(spent: spent, income: came, open: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 2)
                    .modifier(ByProgress(state: state, opacity: monthLayer, y: { -(1 - $0) * 6 }))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.accent.opacity(0.03 + 0.09 * shade).opacity(shade > 0 ? 1 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onTap(day) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.month)월 \(day.day)일, 일정 \(info?.eventCount ?? 0)건" + (spent.map { ", 지출 \($0)" } ?? ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The month's layer (bars, amounts) is there from a third of the way and fully at the end; the week's (dots, amount) is gone by 40%.
private func monthLayer(_ p: CGFloat) -> Double { Double(max(0, p * 2 - 0.7)) }

/// An opacity and a shift taken from how far the month is open. The progress is read here and nowhere above, so a finger moving it re-evaluates these
/// small modifiers and nothing else: the days themselves (their text, their bars) are not laid out again.
private struct ByProgress: ViewModifier {
    let state: MonthUnfoldState
    var opacity: (CGFloat) -> Double = { _ in 1 }
    var y: (CGFloat) -> CGFloat = { _ in 0 }

    func body(content: Content) -> some View {
        let p = state.progress
        content.opacity(opacity(p)).offset(y: y(p))
    }
}

/// The drag of the card. From iOS 18 a UIKit pan, so a finger moving does not pass through SwiftUI's gesture state on every frame; before, a DragGesture.
private struct CardPan: ViewModifier {
    let changed: (CGSize) -> Void
    let ended: (CGSize, CGSize) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(PanRepresentable(changed: changed, ended: ended))
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { changed($0.translation) }
                    .onEnded { ended($0.translation, $0.velocity) }
            )
        }
    }
}

@available(iOS 18.0, *)
private struct PanRepresentable: UIGestureRecognizerRepresentable {
    let changed: (CGSize) -> Void
    let ended: (CGSize, CGSize) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Beside the hold-to-create and the day taps.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let t = pan.translation(in: pan.view)
        let translation = CGSize(width: t.x, height: t.y)
        switch pan.state {
        case .began, .changed: changed(translation)
        case .ended:
            let v = pan.velocity(in: pan.view)
            ended(translation, CGSize(width: v.x, height: v.y))
        case .cancelled, .failed: ended(translation, .zero)
        default: break
        }
    }
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
