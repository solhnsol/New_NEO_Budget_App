import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The rows of a day, shared by the pager: a day is its date and all-day chips, then its events and 일상 stretches as boxes on one vertical line,
/// each with the transactions that went to it. It reads the same `DayTimeline` as the grid.

/// One day: its date, then its boxes, with a line above it that divides it from the day before.
struct DaySection: View {
    let day: LocalDate
    let timeline: DayTimeline?
    let isToday: Bool
    let model: AppModel
    let zone: DisplayTimeZone
    let onSelect: (TimelineSelection) -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            let plan = timeline.map(DayListPlan.make)
            HStack(spacing: Theme.Space.s) {
                Text(Formatting.dayTitle(day)).font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(isToday ? Theme.accent : Theme.textSecondary).fixedSize()
                // All-day events sit beside the date, as small chips.
                let allDays = timeline?.allDay.sorted { $0.id < $1.id } ?? []
                if allDays.count == 1, let only = allDays.first {
                    AllDayChip(item: only) { onSelect(.allDay(only)) }
                } else if allDays.count > 1 {
                    AllDayCount(items: allDays, onSelect: { onSelect(.allDay($0)) })
                }
                Spacer(minLength: 0)
            }
            if let timeline, let plan {
                if plan.items.isEmpty && timeline.allDay.isEmpty {
                    Text("일정과 거래가 없어요").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).padding(.vertical, Theme.Space.xs)
                }
                // The boxes hang on one vertical line like points on a timeline; it is only how they are drawn, they are still a list.
                let boxes = plan.items.filter { if case .allDay = $0 { false } else { true } }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(boxes.enumerated()), id: \.element.id) { index, item in
                        let rail = ListRail(
                            isFirst: index == 0, isLast: index == boxes.count - 1,
                            joinsPrevious: index > 0 && boxes[index - 1].minutes?.end == item.minutes?.start && item.minutes != nil,
                            joinsNext: index < boxes.count - 1 && boxes[index + 1].minutes?.start == item.minutes?.end && item.minutes != nil
                        )
                        switch item {
                        case .allDay: EmptyView()
                        case let .event(block):
                            EventCard(block: block, rail: rail, model: model, zone: zone, onSelect: { onSelect(.event(block)) }, onOpenTransaction: onOpenTransaction)
                        case let .daily(group):
                            DailyCard(group: group, rail: rail, model: model, zone: zone, onOpenTransaction: onOpenTransaction)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
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

/// Where a box sits on the day's vertical line: the line starts at the first box's dot and ends at the last one's.
private struct ListRail {
    let isFirst: Bool
    let isLast: Bool
    /// The box starts where the one above ends (or ends where the one below starts): their bars meet with no gap.
    var joinsPrevious = false
    var joinsNext = false
    static let gutter: CGFloat = 24
    static let barWidth: CGFloat = 6
    /// How far a transaction is set in from the line it hangs on (its dot sits on the line).
    static let indent: CGFloat = 12
    /// The column left of the line that carries each box's and transaction's time, as on a timeline.
    static let timeWidth: CGFloat = 46
}

private extension EnvironmentValues {
    /// The colour of the box a transaction sits in, for its dot on the box's bar.
    @Entry var railColor: Color = Theme.textTertiary
    /// A transaction inside an event is a larger ringed dot on the event's bar; one in the gap between events is a small plain dot on the grey line.
    @Entry var railRing = false
}

/// A box of the day: a bar in its colour, a small header that is only a name and a time, and under it the transactions. A box with no transactions
/// is one thin line.
private struct ListBox<Lines: View>: View {
    let rail: ListRail
    let title: String
    let timeText: String
    let totalText: String?
    let color: Color
    let symbol: String
    /// The empty stretch between events: no name, no time, no bar; only its transactions, always shown (never folded), on the grey line.
    var gap = false
    /// For a gap: how many transactions it holds. One is simply shown; several fold into a circle with their count on the line, and open on a tap.
    var gapCount = 0
    /// When the box starts, shown in the column left of the line.
    var startText: String?
    let hasLines: Bool
    var onSelect: (() -> Void)?
    @ViewBuilder let lines: () -> Lines
    /// A box shows its name, time and total; its transactions open under it on a tap of the chevron.
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Group {
                if let startText { TimeLabel(text: startText).padding(.top, Theme.Space.m) } else { Color.clear }
            }
            .frame(width: ListRail.timeWidth, alignment: .trailing)
            rail_
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The event is an area, so its stretch of the line is a bar in its colour as tall as the box; a thin grey line joins the bars across the gaps.
    private var rail_: some View {
        let inset = Theme.Space.m
        return GeometryReader { proxy in
            let top = rail.isFirst && !gap ? inset : 0
            let bottom = rail.isLast && !gap ? proxy.size.height - inset : proxy.size.height
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.textTertiary.opacity(0.35)).frame(width: 2, height: max(0, bottom - top))
                    .offset(x: (ListRail.gutter - 2) / 2, y: top)
                if !gap {
                let barTop = rail.joinsPrevious ? 0 : inset
                let barBottom = rail.joinsNext ? proxy.size.height : proxy.size.height - inset
                let round = ListRail.barWidth / 2
                UnevenRoundedRectangle(
                    topLeadingRadius: rail.joinsPrevious ? 0 : round, bottomLeadingRadius: rail.joinsNext ? 0 : round,
                    bottomTrailingRadius: rail.joinsNext ? 0 : round, topTrailingRadius: rail.joinsPrevious ? 0 : round
                )
                .fill(color).frame(width: ListRail.barWidth, height: max(0, barBottom - barTop))
                .offset(x: (ListRail.gutter - ListRail.barWidth) / 2, y: barTop)
                }
            }
        }
        .frame(width: ListRail.gutter)
        .contentShape(Rectangle())
        .onTapGesture { if gap { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } }
        .accessibilityHidden(true)
    }

    private var content: some View {
        if gap {
            return AnyView(gapContent)
        }
        return AnyView(boxContent)
    }

    private var gapContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            // The summary stays on top whether the stretch is folded or open, with a small arrow that says which way a tap goes.
            HStack(spacing: Theme.Space.xs) {
                Text(["거래 \(gapCount)건", totalText].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .overlay(alignment: .leading) {
                Circle().fill(Theme.textTertiary.opacity(0.8)).frame(width: 7, height: 7)
                    .offset(x: -(ListRail.gutter / 2 + Theme.Space.s + ListRail.indent) - 3.5)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .listTap { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } }
            if expanded { lines() }
        }
        .padding(.leading, ListRail.indent).padding(.vertical, expanded ? Theme.Space.m : Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.railColor, color)
    }

    private var boxContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                // The bar carries the colour, so there is no icon here: the name, and the time under it.
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(timeText).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).minimumScaleFactor(0.75)
                }
                Spacer(minLength: Theme.Space.s)
                if let totalText { Text(totalText).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary) }
                if hasLines {
                    Image(systemName: "chevron.down").font(.system(.footnote, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0)).frame(width: 28, height: 28).contentShape(Rectangle())
                        .listTap { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } }
                }
            }
            .contentShape(Rectangle())
            .listTap { if let onSelect { onSelect() } else if hasLines { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } }
            if hasLines && expanded {
                VStack(alignment: .leading, spacing: Theme.Space.m) { lines() }.padding(.leading, ListRail.indent).environment(\.railColor, color).environment(\.railRing, true)
            }
        }
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An event: its name and time, and the transactions that went to it inside.
private struct EventCard: View {
    let block: EventBlock
    let rail: ListRail
    let model: AppModel
    let zone: DisplayTimeZone
    let onSelect: () -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void

    /// How long it lasts, as a person says it: 1시간 30분.
    private static func duration(from start: Int64, to end: Int64) -> String {
        let minutes = max(0, Int((end - start) / 60_000))
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)분" }
        return rest == 0 ? "\(hours)시간" : "\(hours)시간 \(rest)분"
    }

    var body: some View {
        ListBox(
            rail: rail, title: block.title, timeText: Self.duration(from: block.startUnixMilliseconds, to: block.endUnixMilliseconds),
            totalText: block.allocatedSpend.first.map { Formatting.aggregate($0) },
            color: Color(hex: block.calendarColorHex) ?? Theme.accent, symbol: model.calendarSymbol(id: block.eventKey.calendarID, title: block.calendarTitle),
            startText: Formatting.time(block.startUnixMilliseconds, zoneIdentifier: zone.identifier), hasLines: !block.allocations.isEmpty, onSelect: onSelect
        ) {
            ForEach(block.allocations, id: \.allocationID) { item in
                DayListTransactionLine(
                    title: model.transactionOverrides[item.transactionID]?.title ?? item.title ?? "거래",
                    detail: item.occursOnSelectedDay ? Formatting.time(item.occurredAtUnixMilliseconds, zoneIdentifier: zone.identifier)
                        : Formatting.shortDate(item.occurredAtUnixMilliseconds, zoneIdentifier: zone.identifier),
                    amountText: Formatting.knowledge(item.allocatedAmount, currency: item.transactionAmount.currency),
                    isRefund: item.flow == .refund,
                    category: model.transactionOverrides[item.transactionID]?.category ?? item.categoryID
                ) { onOpenTransaction(item.transactionID) }
            }
        }
    }
}

/// The stretch between events, drawn as the empty space between them, with the transactions no event holds.
private struct DailyCard: View {
    let group: DayListPlan.DailyGroup
    let rail: ListRail
    let model: AppModel
    let zone: DisplayTimeZone
    let onOpenTransaction: (LedgerEntryID) -> Void

    var body: some View {
        let currency = group.markers[0].amount.currency
        let net = group.markers.filter { $0.amount.currency == currency }.reduce(Int64(0)) { $0 + ($1.flow == .refund ? -$1.amount.minorUnits : $1.amount.minorUnits) }
        return ListBox(
            rail: rail, title: "", timeText: "", totalText: Formatting.money(net, currency: currency), color: Theme.textTertiary, symbol: "", gap: true, gapCount: group.markers.count, hasLines: true
        ) {
            ForEach(group.markers, id: \.transactionID) { marker in
                DayListTransactionLine(
                    title: model.transactionOverrides[marker.transactionID]?.title ?? marker.title ?? "거래",
                    detail: Formatting.time(marker.occurredAtUnixMilliseconds, zoneIdentifier: zone.identifier),
                    amount: marker.amount, isRefund: marker.flow == .refund,
                    category: model.transactionOverrides[marker.transactionID]?.category ?? marker.categoryID
                ) { onOpenTransaction(marker.transactionID) }
            }
        }
    }
}

/// One transaction: its category on a tile, what and when, the amount; money coming back is blue with a plus.
private struct DayListTransactionLine: View {
    @Environment(\.railColor) private var railColor
    @Environment(\.railRing) private var railRing
    let title: String
    let detail: String
    let amountText: String
    let isRefund: Bool
    let category: CanonicalCategoryID?
    let onTap: () -> Void

    init(title: String, detail: String, amount: Money, isRefund: Bool, category: CanonicalCategoryID?, onTap: @escaping () -> Void) {
        self.init(title: title, detail: detail, amountText: Formatting.money(amount.minorUnits, currency: amount.currency), isRefund: isRefund, category: category, onTap: onTap)
    }

    init(title: String, detail: String, amountText: String, isRefund: Bool, category: CanonicalCategoryID?, onTap: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.amountText = amountText
        self.isRefund = isRefund
        self.category = category
        self.onTap = onTap
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: CategoryIcon.symbol(for: category) ?? (isRefund ? "arrow.uturn.backward" : "creditcard"))
                .font(.system(size: 14, weight: .medium)).foregroundStyle(isRefund ? Theme.accent : Theme.textTertiary).frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title).font(Theme.Typo.label).foregroundStyle(Theme.textPrimary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
            Text((isRefund ? "+" : "") + amountText).font(.system(.subheadline, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.amountColor(isIncoming: isRefund))
        }
        .listTap(onTap)
        // Its time sits in the column left of the line and a small dot on the line, level with the row: each transaction reads as a moment on a timeline.
        .overlay(alignment: .leading) {
            TimeLabel(text: detail).frame(width: ListRail.timeWidth, alignment: .trailing)
                .offset(x: -(ListRail.timeWidth + Theme.Space.s + ListRail.gutter + Theme.Space.s + ListRail.indent))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            Group {
                if railRing {
                    Circle().fill(Color(.systemBackground)).frame(width: 12, height: 12).overlay(Circle().stroke(railColor, lineWidth: 2.5))
                } else {
                    Circle().fill(railColor).frame(width: 7, height: 7)
                }
            }
            .offset(x: -(ListRail.gutter / 2 + Theme.Space.s + ListRail.indent) - (railRing ? 6 : 3.5))
                .allowsHitTesting(false)
        }
    }
}

/// A time in the column beside the line: the 오전/오후 small above the clock time; a date (a transaction of another day) is shown as it is.
private struct TimeLabel: View {
    let text: String

    var body: some View {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        VStack(alignment: .trailing, spacing: 0) {
            if parts.count == 2 {
                Text(parts[0]).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                Text(parts[1]).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            } else {
                Text(text).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
    }
}

/// Opens one transaction's details (with editing) from the calendar: the ledger entry is read when the sheet appears.
struct LedgerEntryLoader: View {
    let id: LedgerEntryID
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var entry: LedgerListEntry?
    @State private var missing = false

    var body: some View {
        NavigationStack {
            Group {
                if let entry {
                    TransactionDetailView(entry: entry, model: model)
                } else if missing {
                    Text("이 거래를 찾지 못했어요").foregroundStyle(Theme.textTertiary)
                } else {
                    ProgressView()
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
        .task(id: model.overrideRevision) {
            let sections = await model.ledgerSections() ?? []
            entry = sections.lazy.flatMap(\.entries).first { $0.id == id }
            missing = entry == nil
        }
    }
}

private extension DayListPlan.Item {
    /// The stretch of the day an event covers, in minutes from its start; none for an all-day item or the gap between events (a gap never joins a bar).
    var minutes: (start: Int, end: Int)? {
        switch self {
        case .allDay: nil
        case let .event(block): (block.startMinute, block.endMinute)
        case .daily: nil
        }
    }
}
