import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// One day of the calendar as a rail timeline (design cal-v5 / cal-v7): the hours run down the left, one thin rail runs through the day, and everything
/// hangs on it. A transaction is a hollow dot on the rail at the minute it happened with its row to the right; an event that has begun is a stretch of
/// the rail in its colour with its name left-aligned beside it; an event still to come is a card whose left edge is that same stretch. The vertical
/// spacing is `RailAxis`'s: room where something sits, empty hours squeezed.

/// One day: its date (and all-day chips, and a word about the day on the right), then the rail.
struct DaySection: View {
    let day: LocalDate
    let timeline: DayTimeline?
    let isToday: Bool
    let model: AppModel
    let zone: DisplayTimeZone
    let onSelect: (TimelineSelection) -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void

    var body: some View {
        if isToday {
            TimelineView(.everyMinute) { context in content(nowMilliseconds: Int64(context.date.timeIntervalSince1970 * 1000)) }
        } else if let timeline {
            // Any other day is wholly past or wholly to come, whatever the clock says.
            content(nowMilliseconds: timeline.dayEndUnixMilliseconds <= model.nowMilliseconds ? Int64.max / 2 : Int64.min / 2)
        } else {
            content(nowMilliseconds: 0)
        }
    }

    private func content(nowMilliseconds: Int64) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text("\(day.day)일 \(Formatting.weekdayShort(day))요일").font(Theme.Typo.section).foregroundStyle(Theme.textPrimary).fixedSize()
                // All-day events sit beside the date, as small chips.
                let allDays = timeline?.allDay.sorted { $0.id < $1.id } ?? []
                if allDays.count == 1, let only = allDays.first {
                    AllDayChip(item: only) { onSelect(.allDay(only)) }
                } else if allDays.count > 1 {
                    AllDayCount(items: allDays, onSelect: { onSelect(.allDay($0)) })
                }
                Spacer(minLength: 0)
                if let timeline, let text = RailPlan.headline(timeline, nowMilliseconds: nowMilliseconds, income: model.income(on: day)) {
                    text.font(.onAll(size: 15, weight: .medium)).lineLimit(1)
                }
            }
            .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
            .padding(.bottom, 6)
            if let timeline {
                RailTimeline(
                    timeline: timeline, nowMilliseconds: nowMilliseconds, zone: zone, incomes: model.incomeByDay[day] ?? [], onSelect: onSelect, onOpenTransaction: onOpenTransaction,
                    onCreate: { minute in model.newEventSeed = (day, minute); model.creatingEvent = true }, model: model
                )
                    .padding(.trailing, Theme.Space.l)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    /// A row of the list that opens on a tap. A tap, not a `Button`: a button inside the list's scroll view still fires when the finger is lifted over it
    /// after a sideways swipe (the rows are as wide as the screen, so the finger never leaves them), which opened the card the swipe began on. A tap gesture
    /// fails as soon as the finger has moved, so a swipe (the day swipe, a scroll) never opens anything.
    func listTap(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

private struct AllDayChip: View {
    let item: AllDayItem
    let onTap: () -> Void

    var body: some View {
        let color = Color(hex: item.calendarColorHex) ?? Theme.accent
        HStack(spacing: Theme.Space.xs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(item.title).font(Theme.Typo.caption.weight(.medium)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
        .background(color.opacity(0.14), in: Capsule())
        .listTap(onTap)
    }
}

/// Several all-day events as one chip with their count; a tap opens a bubble listing them.
private struct AllDayCount: View {
    let items: [AllDayItem]
    let onSelect: (AllDayItem) -> Void
    @State private var open = false

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "sun.horizon").font(.system(.caption2, weight: .semibold))
            Text("종일 \(items.count)개").font(Theme.Typo.caption.weight(.medium))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
        .background(Theme.accent.opacity(0.14), in: Capsule())
        .listTap { open = true }
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(items, id: \.id) { item in
                    HStack(spacing: Theme.Space.s) {
                        Circle().fill(Color(hex: item.calendarColorHex) ?? Theme.accent).frame(width: 8, height: 8)
                        Text(item.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { open = false; onSelect(item) }
                }
            }
            .padding(Theme.Space.l)
            .frame(minWidth: 220, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// What the rail draws for one day, decided apart from SwiftUI: which events are bars (begun) and which are cards (to come), the transactions at
/// their minutes, and the axis between them.
struct RailPlan {
    struct Row: Identifiable {
        let id: String
        let transactionID: LedgerEntryID
        let minute: Int
        let title: String
        let category: CanonicalCategoryID?
        let amountText: String
        let isIncoming: Bool
        /// The colour of the event it happened inside, or of the event it was linked to; none for an ordinary one.
        let colorHex: String?
        /// A deposit (not spending): drawn with a red down-arrow tile, opens nothing.
        var isIncome = false
    }

    let past: [EventBlock]
    let cards: [EventBlock]
    let rows: [Row]
    /// Each row's y: its minute's place on the axis, or a row below the one above when two share a minute, so none sits on another.
    let rowYs: [CGFloat]
    /// The rail's height, grown if stacked rows ran past the axis.
    let height: CGFloat
    let axis: RailAxis
    static let rowHeight: CGFloat = 36
    /// The now line's minute, only while it falls inside this day.
    let nowMinute: Int?

    /// Where something drawn has touches of its own, in the rail's space (a transaction row, an event card, a begun event's bar and name): a hold on the
    /// empty time between them makes a new event, on these it does what they do.
    var touchBands: [CGRect] {
        let wide: CGFloat = 4000
        var bands = rowYs.map { CGRect(x: 0, y: $0 - Self.rowHeight / 2, width: wide, height: Self.rowHeight) }
        for block in cards {
            let top = CGFloat(axis.y(block.displayStartMinute))
            bands.append(CGRect(x: 0, y: top, width: wide, height: max(6, CGFloat(axis.y(block.displayEndMinute)) - top)))
        }
        for block in past {
            let top = CGFloat(axis.y(block.displayStartMinute)), bottom = CGFloat(axis.y(block.displayEndMinute))
            bands.append(CGRect(x: 0, y: top, width: 70, height: max(6, bottom - top)))
            bands.append(CGRect(x: 0, y: top, width: wide, height: 22))
        }
        return bands
    }

    init(_ timeline: DayTimeline, nowMilliseconds: Int64, incomes: [IncomeItem] = []) {
        let raw = (nowMilliseconds - timeline.dayStartUnixMilliseconds) / 60_000
        let cutoff = Int(max(-1, min(Int64(timeline.totalMinutes + 1), raw)))
        let blocks = timeline.blocks.sorted { ($0.displayStartMinute, $0.id.rawValue) < ($1.displayStartMinute, $1.id.rawValue) }
        let past = blocks.filter { $0.displayStartMinute < cutoff }
        let now = cutoff >= 0 && cutoff < timeline.totalMinutes ? cutoff : nil

        var rows: [Row] = timeline.markers.map { marker in
            let inside = past.first { $0.displayStartMinute <= marker.positionMinute && marker.positionMinute < $0.displayEndMinute }
            let linked = marker.allocations.first { $0.activityID != nil }.flatMap { link in blocks.first { $0.activity?.activityID == link.activityID } }
            return Row(
                id: "m/" + marker.transactionID.rawValue, transactionID: marker.transactionID, minute: marker.positionMinute, title: marker.title ?? "거래",
                category: marker.categoryID, amountText: RailPlan.railAmount(Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency), incoming: marker.flow == .refund),
                isIncoming: marker.flow == .refund, colorHex: (inside ?? linked)?.calendarColorHex
            )
        }
        // A transaction wholly inside an event has no marker of its own; it is drawn from the event's allocations, where it happened.
        let marked = Set(timeline.markers.map(\.transactionID))
        for block in blocks {
            for item in block.allocations where item.occursOnSelectedDay && !marked.contains(item.transactionID) {
                let minute = Int(max(0, min(Int64(timeline.totalMinutes - 1), (item.occurredAtUnixMilliseconds - timeline.dayStartUnixMilliseconds) / 60_000)))
                rows.append(Row(
                    id: "a/" + item.allocationID.rawValue, transactionID: item.transactionID, minute: minute, title: item.title ?? "거래", category: item.categoryID,
                    amountText: RailPlan.railAmount(Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency), incoming: item.flow == .refund),
                    isIncoming: item.flow == .refund, colorHex: block.calendarColorHex
                ))
            }
        }
        for item in incomes {
            let minute = Int(max(0, min(Int64(timeline.totalMinutes - 1), (item.occurredAtUnixMilliseconds - timeline.dayStartUnixMilliseconds) / 60_000)))
            rows.append(Row(
                id: "i/" + item.id.rawValue, transactionID: item.id, minute: minute, title: item.title ?? "입금", category: nil,
                amountText: "+" + Formatting.grouped(item.minorUnits), isIncoming: true, colorHex: nil, isIncome: true
            ))
        }
        rows.sort { ($0.minute, $0.id) < ($1.minute, $1.id) }

        let events = blocks.map { RailAxis.Event(start: $0.displayStartMinute, end: $0.displayEndMinute, isCard: $0.displayStartMinute >= cutoff) }
        var covered = events.flatMap { [$0.start, $0.end] } + rows.map(\.minute)
        if let now { covered.append(now) }
        let range = RailAxis.hourRange(covering: covered, totalMinutes: timeline.totalMinutes)
        let axis = RailAxis(events: events, transactions: rows.map(\.minute), now: now, firstMinute: range.first, lastMinute: range.last)
        var ys: [CGFloat] = []
        // Rows sharing a minute stack downward; the axis already made room for that (`RailAxis.Needs.stackStep`).
        for row in rows { ys.append(max(CGFloat(axis.y(row.minute)), (ys.last ?? -.infinity) + Self.rowHeight + 2)) }
        self.past = past
        self.cards = blocks.filter { $0.displayStartMinute >= cutoff }
        self.rows = rows
        self.rowYs = ys
        self.axis = axis
        self.nowMinute = now
        self.height = max(CGFloat(axis.height), (ys.last ?? 0) + Self.rowHeight)
    }

    /// The row's amount as the design writes it: the number alone, with a minus for money spent and a plus for money coming in.
    static func railAmount(_ text: String, incoming: Bool) -> String { (incoming ? "+" : "−") + (text.hasSuffix("원") ? String(text.dropLast()) : text) }

    /// The design's right side of the day title: what was spent ("−9,500원", blue) when anything was; otherwise, for a day not yet over, how many events it holds.
    static func headline(_ timeline: DayTimeline, nowMilliseconds: Int64, income: Int64 = 0) -> Text? {
        let spent = timeline.summary.totals.first.map { $0.linkedNetMinorUnits + $0.unlinkedNetMinorUnits } ?? 0
        // Money in (red, no sign) then money out (blue, minus), as the design writes them.
        let came = income > 0 ? Text(Formatting.grouped(income) + "원").foregroundStyle(Theme.income) : nil
        let went = spent > 0 ? Text("−" + Formatting.grouped(spent) + "원").foregroundStyle(Theme.accent) : nil
        if let came, let went { return came + Text(" ") + went }
        if let line = came ?? went { return line }
        guard nowMilliseconds < timeline.dayEndUnixMilliseconds, !timeline.blocks.isEmpty else { return nil }
        return Text("일정 \(timeline.blocks.count)건").foregroundStyle(Theme.textTertiary)
    }
}

private enum RailMetrics {
    /// Where the rail runs, from the left edge of the day: the hour labels sit left of it, everything else right of it.
    static let railX: CGFloat = 51
    static let railWidth: CGFloat = 2
    static let barWidth: CGFloat = 6
    static let dotSize: CGFloat = 12
    static let contentX: CGFloat = 68
    static let hourLabelX: CGFloat = 14
    static let hourLabelWidth: CGFloat = 30
    static let rowHeight = RailPlan.rowHeight
    static let vertical: CGFloat = 12
}

/// The rail itself: hour lines and labels, the rail, past events as bars, to-come events as cards, transactions as dots with rows, the now line.
private struct RailTimeline: View {
    let timeline: DayTimeline
    let nowMilliseconds: Int64
    let zone: DisplayTimeZone
    var incomes: [IncomeItem] = []
    let onSelect: (TimelineSelection) -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void
    /// A long press on empty time: a new event there (snapped to 15 minutes).
    var onCreate: (Int) -> Void = { _ in }
    /// Selection mode lives on the model: a row picks itself there.
    var model: AppModel?

    var body: some View {
        let plan = RailPlan(timeline, nowMilliseconds: nowMilliseconds, incomes: incomes)
        let axis = plan.axis
        let height = plan.height
        ZStack(alignment: .topLeading) {
            ForEach(axis.hourMarks(avoiding: plan.nowMinute), id: \.hour) { mark in
                Text("\(mark.hour)").font(Theme.Typo.caption.monospacedDigit()).foregroundStyle(Theme.disabled)
                    .frame(width: RailMetrics.hourLabelWidth, height: 14, alignment: .trailing).offset(x: RailMetrics.hourLabelX, y: CGFloat(mark.y) - 7)
            }
            Capsule().fill(Theme.rail).frame(width: RailMetrics.railWidth, height: height).offset(x: RailMetrics.railX)
            ForEach(plan.past, id: \.id) { block in PastEventBar(block: block, axis: axis) { onSelect(.event(block)) } }
            ForEach(plan.cards, id: \.id) { block in EventCardView(block: block, axis: axis) { onSelect(.event(block)) } }
            ForEach(Array(plan.rows.enumerated()), id: \.element.id) { index, row in
                TransactionRailRow(
                    row: row, selected: model?.selection.contains(row.transactionID) ?? false, selecting: model?.selection.isActive ?? false,
                    onTap: {
                        guard !row.isIncome, !HapticHold.justHeld(row.id) else { return }
                        if let model, model.selection.isActive { withAnimation(Theme.Motion.select) { model.selection.toggle(row.transactionID) } } else { onOpenTransaction(row.transactionID) }
                    },
                    onLongPress: { if !row.isIncome, let model { withAnimation(Theme.Motion.select) { model.selection.begin(with: row.transactionID) } } }
                ).offset(y: plan.rowYs[index] - RailMetrics.rowHeight / 2)
            }
            if let now = plan.nowMinute { NowLine(minute: now, y: CGFloat(axis.y(now))) }
        }
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .hapticLongPress(at: { location in
                // A hold that starts on a row or an event belongs to that row or event (selecting, opening), not to the empty time under it.
                guard !plan.touchBands.contains(where: { $0.contains(location) }) else { return }
                let minute = plan.axis.minute(atY: Double(location.y))
                let snapped = min(timeline.totalMinutes - Theme.Motion.dragSnapMinutes, (minute + Theme.Motion.dragSnapMinutes / 2) / Theme.Motion.dragSnapMinutes * Theme.Motion.dragSnapMinutes)
                onCreate(max(0, snapped))
            })
        .padding(.vertical, RailMetrics.vertical)
    }
}

private func clockText(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

/// An event that has begun: the rail turns its colour and thickens over its stretch; the name stands beside it at its start, left-aligned.
private struct PastEventBar: View {
    let block: EventBlock
    let axis: RailAxis
    let onTap: () -> Void

    var body: some View {
        let color = Color(hex: block.calendarColorHex) ?? Theme.accent
        let top = CGFloat(axis.y(block.displayStartMinute)), bottom = CGFloat(axis.y(block.displayEndMinute))
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: RailMetrics.barWidth / 2).fill(color).frame(width: RailMetrics.barWidth, height: max(RailMetrics.barWidth, bottom - top))
                .contentShape(Rectangle().inset(by: -8)).onTapGesture(perform: onTap)
                .offset(x: RailMetrics.railX + RailMetrics.railWidth / 2 - RailMetrics.barWidth / 2, y: top)
            Text(block.title).font(.onAll(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                .padding(.leading, RailMetrics.contentX).contentShape(Rectangle()).onTapGesture(perform: onTap).offset(y: top + 2)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(block.title), \(clockText(block.displayStartMinute))부터 \(clockText(block.displayEndMinute))까지")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onTap)
    }
}

/// An event still to come: a card whose left edge is its stretch of the rail; its title and time range, or one line of both when it is short.
private struct EventCardView: View {
    let block: EventBlock
    let axis: RailAxis
    let onTap: () -> Void

    var body: some View {
        let color = Color(hex: block.calendarColorHex) ?? Theme.accent
        let top = CGFloat(axis.y(block.displayStartMinute))
        let height = max(RailMetrics.barWidth, CGFloat(axis.y(block.displayEndMinute)) - top)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 12, topTrailingRadius: 12)
        let range = clockText(block.displayStartMinute) + " – " + clockText(block.displayEndMinute)
        Group {
            if height < 40 {
                HStack(spacing: Theme.Space.s) {
                    Text(block.title).font(.onAll(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(range).font(Theme.Typo.label).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Theme.Space.xs)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(block.title).font(.onAll(size: 16, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(range).font(Theme.Typo.label).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
        }
        .padding(.leading, RailMetrics.barWidth + 13).padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(color.opacity(0.14), in: shape)
        .background(Theme.surface, in: shape)
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: RailMetrics.barWidth) }
        .clipShape(shape)
        .padding(.leading, RailMetrics.railX + RailMetrics.railWidth / 2 - RailMetrics.barWidth / 2)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(block.title), \(range)")
        .accessibilityAddTraits(.isButton)
        .offset(y: top)
    }
}

/// One transaction: a hollow dot on the rail at its minute (its colour is the event's it happened in, else the text colour), then its category tile,
/// name, time and amount on one line, no card. Spent is blue, money coming in is red.
private struct TransactionRailRow: View {
    let row: RailPlan.Row
    var selected = false
    /// Selection mode is on (every row shows its box).
    var selecting = false
    let onTap: () -> Void
    var onLongPress: () -> Void = {}

    var body: some View {
        let dot = Color(hex: row.colorHex) ?? Theme.textPrimary
        ZStack(alignment: .topLeading) {
            Circle().fill(Theme.surface).overlay(Circle().strokeBorder(row.colorHex == nil ? Theme.textTertiary : dot, lineWidth: 2)).frame(width: RailMetrics.dotSize, height: RailMetrics.dotSize)
                .offset(x: RailMetrics.railX + RailMetrics.railWidth / 2 - RailMetrics.dotSize / 2, y: (RailMetrics.rowHeight - RailMetrics.dotSize) / 2)
            HStack(spacing: 0) {
                SelectCheckSlot(selecting: selecting && !row.isIncome, picked: selected)
                let tile = row.isIncome ? (icon: "down", tint: Theme.incomeSoft) : CategoryIcon.tile(for: row.category)
                LineIcon(name: tile.icon, size: 16).foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30).background(tile.tint, in: Circle())
                (Text(row.title).font(.onAll(size: 16, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    + Text(" ").font(.onAll(size: 16))
                    + Text(clockText(row.minute)).font(.onAll(size: 12).monospacedDigit()).foregroundStyle(Theme.textTertiary))
                    .lineLimit(1).padding(.leading, 8)
                Spacer(minLength: Theme.Space.s)
                Text(row.amountText).font(.onAll(size: 16, weight: row.isIncoming ? .semibold : .medium).monospacedDigit())
                    .foregroundStyle(Theme.amountColor(isIncoming: row.isIncoming)).lineLimit(1).fixedSize()
            }
            .padding(.leading, RailMetrics.contentX).frame(height: RailMetrics.rowHeight)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(alignment: .topLeading) {
            // A picked row's band: the design's light blue, from the rail's side to the card's edge.
            if selected {
                Theme.accentSoft.frame(height: RailMetrics.rowHeight).padding(.leading, 58).padding(.trailing, -Theme.Space.l)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .hapticLongPress(id: row.id, enabled: !selecting && !row.isIncome, perform: onLongPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(row.amountText), \(clockText(row.minute))")
        .accessibilityAddTraits(.isButton)
    }
}

/// The now line: a 1.5pt accent line across the day with a dot on the rail and the time at the left in the hour labels' column.
private struct NowLine: View {
    let minute: Int
    let y: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.accent).frame(height: 1).offset(y: y - 0.5)
            Circle().fill(Theme.accent).frame(width: 10, height: 10).offset(x: RailMetrics.railX + RailMetrics.railWidth / 2 - 5, y: y - 5.5)
            Text(clockText(minute)).font(.onAll(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.accent)
                .padding(.horizontal, 2).background(Theme.surface).offset(x: 6, y: y - 8)
            Color.clear.frame(width: 1, height: 1).id("railNow").offset(y: y)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Opens one transaction's details (with editing) from the calendar: the ledger entry is read when the sheet appears.
struct LedgerEntryLoader: View {
    let id: LedgerEntryID
    let model: AppModel
    @State private var entry: LedgerListEntry?
    @State private var missing = false

    var body: some View {
        Group {
            if let entry {
                TransactionQuickSheet(entry: entry, model: model)
            } else if missing {
                Text("이 거래를 찾지 못했어요").foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity).onAllSheet()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).onAllSheet()
            }
        }
        .task(id: model.overrideRevision) {
            let sections = await model.ledgerSections() ?? []
            entry = sections.lazy.flatMap(\.entries).first { $0.id == id }
            missing = entry == nil
        }
    }
}

