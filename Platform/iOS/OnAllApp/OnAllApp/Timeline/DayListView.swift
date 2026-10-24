import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The calendar's list style: one endless column of days, each a header and its boxes, with a line between days. An event is a box with only its name and
/// time and, set in under it, the transactions that went to it; the stretches between events are boxes named 일상 that hold the rest; all-day events are single lines. It reads the
/// same `DayTimeline` as the grid.
///
/// The day at the top of the screen is the selected day: scrolling moves `AppModel.selectedDay` (the header and the week strip follow, and a tick is felt
/// when a new day comes onto the screen, with a slight catch if the list is coasting), and picking a day elsewhere scrolls the list to it. The days sit in one lazy column over a fixed range, so scrolling up
/// never moves what is on screen; each day is read when it comes near (`readAhead` days either side of the top) and kept only while it stays near.
struct DayListView: View {
    let model: AppModel
    /// How far from the top of the screen the list starts: it runs under the translucent top bar, so what scrolls up shows through it.
    var topInset: CGFloat = 0
    let onSelect: (TimelineSelection) -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void
    /// The day at the top of the screen changed because the list was scrolled.
    let onScrollToDay: (LocalDate) -> Void

    /// The range of days the column holds, either side of the day the list opened on (about five years).
    static let reach = 1825
    /// Days read either side of the one at the top, and the distance after which a read day is dropped.
    static let readAhead = 4
    static let keepDistance = 40
    /// A jump further than this many days is instant; a nearer one scrolls.
    static let animatedJump = 10

    private static let space = "dayList"
    /// How hard the list holds back when a new day's line comes onto the screen while it coasts: the deceleration rate it drops to for `snagSeconds`
    /// (the normal rate is 0.998; each 0.001 lower is roughly a tenth more speed lost per second at that rate).
    static let snagRate: CGFloat = 0.9975
    static let snagSeconds = 0.05

    /// The day the column was built around. It is kept for the life of the view: the parent builds this struct again on every change of the selected
    /// day, and a centre that followed it would slide the whole range of days under the scroll position by a day at a time.
    @State private var center: Int
    @State private var timelines: [Int: DayTimeline] = [:]
    @State private var reading: Set<Int> = []
    /// For scrolling the list to a day. What it reports while the reader scrolls wobbles between neighbouring days, so it is never read as where the reader is.
    @State private var topEpoch: Int?
    /// The day at the top of the screen, from where the day sections actually are: the last one whose top has reached the top edge.
    @State private var readingEpoch: Int?
    /// The last day whose line was on the screen at the bottom, to see a new one come in.
    @State private var lastBottom: Int?
    @State private var scrollView = ScrollViewBox()
    /// The day a programmatic scroll is heading for: scroll positions reported on the way there are not the reader's.
    @State private var headingFor: Int?
    /// Days handed to the model from the scroll, and when, so the model's answer is not mistaken for a pick made elsewhere.
    @State private var pushed: [Int: Date] = [:]

    init(model: AppModel, topInset: CGFloat = 0, onSelect: @escaping (TimelineSelection) -> Void, onOpenTransaction: @escaping (LedgerEntryID) -> Void, onScrollToDay: @escaping (LocalDate) -> Void) {
        self.model = model
        self.topInset = topInset
        self.onSelect = onSelect
        self.onOpenTransaction = onOpenTransaction
        self.onScrollToDay = onScrollToDay
        let start = model.selectedDay.daysSinceUnixEpoch
        _center = State(initialValue: start)
        _topEpoch = State(initialValue: start)
        _readingEpoch = State(initialValue: start)
    }

    var body: some View {
        let zone = model.dayZone
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach((center - Self.reach)...(center + Self.reach), id: \.self) { epoch in
                    DaySection(
                        day: LocalDate(daysSinceUnixEpoch: epoch), timeline: timelines[epoch], isToday: LocalDate(daysSinceUnixEpoch: epoch) == model.today,
                        model: model, zone: zone, onSelect: onSelect, onOpenTransaction: onOpenTransaction
                    )
                    .id(epoch)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: DayTopKey.self, value: [epoch: proxy.frame(in: .named(Self.space)).minY])
                    })
                    .onAppear { if timelines[epoch] == nil { Task { await read(epoch) } } }
                }
            }
            .scrollTargetLayout()
            .background(ScrollViewFinder(box: scrollView))
        }
        .contentMargins(.top, topInset, for: .scrollContent)
        .contentMargins(.top, topInset, for: .scrollIndicators)
        .ignoresSafeArea(edges: .top)
        .coordinateSpace(name: Self.space)
        .scrollPosition(id: $topEpoch, anchor: .top)
        .onPreferenceChange(DayTopKey.self) { moved(to: $0) }
        .task(id: readingEpoch) { await readAround(readingEpoch) }
        .onChange(of: model.selectedDay) { _, day in selectionChanged(to: day.daysSinceUnixEpoch) }
        .onChange(of: model.dataGeneration) { _, _ in Task { await refreshAll() } }
    }

    // MARK: Following the model, and leading it

    /// The sections reported where they are. The day at the top follows them; a new day coming onto the screen is felt once.
    private func moved(to now: [Int: CGFloat]) {
        guard !now.isEmpty else { return }
        let height = scrollView.view?.bounds.height ?? 0
        let top = now.filter { $0.value <= 0.5 }.keys.max() ?? now.keys.min()!
        let bottom = now.filter { $0.value <= height }.keys.max() ?? top
        defer { lastBottom = bottom }
        guard headingFor == nil else { return }
        // A new day comes onto the screen when the line between days enters from the bottom edge (the list moves up) or from the top edge (it
        // moves down: the day at the top changes to the one before). A day leaving the screen is not felt.
        let enteredBelow = lastBottom.map { bottom > $0 } ?? false
        let enteredAbove = readingEpoch.map { top < $0 } ?? false
        if enteredBelow || enteredAbove {
            Haptics.snap()
            scrollView.snag(rate: Self.snagRate, seconds: Self.snagSeconds)
        }
        scrolled(to: top)
    }

    private func scrolled(to epoch: Int) {
        guard epoch != readingEpoch else { return }
        readingEpoch = epoch
        guard epoch != model.selectedDay.daysSinceUnixEpoch else { return }
        pushed[epoch] = Date()
        onScrollToDay(LocalDate(daysSinceUnixEpoch: epoch))
    }

    private func selectionChanged(to epoch: Int) {
        guard epoch != readingEpoch else { return }
        if let at = pushed[epoch], Date().timeIntervalSince(at) < 1 { return }
        guard abs(epoch - center) <= Self.reach else { return }
        let jump = abs(epoch - (readingEpoch ?? epoch))
        headingFor = epoch
        readingEpoch = epoch
        if jump > Self.animatedJump {
            topEpoch = epoch
        } else {
            withAnimation(.easeOut(duration: 0.3)) { topEpoch = epoch }
        }
        // The list is deaf to the reader's position until it has arrived (or for as long as a scroll takes).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(jump > Self.animatedJump ? 0.3 : 0.6))
            if headingFor == epoch { headingFor = nil }
        }
    }

    // MARK: Reading days

    private func readAround(_ top: Int?) async {
        guard let top else { return }
        for epoch in ([top] + (1...Self.readAhead).flatMap { [top + $0, top - $0] }) {
            if Task.isCancelled { return }
            await read(epoch)
        }
        for epoch in timelines.keys where abs(epoch - top) > Self.keepDistance { timelines[epoch] = nil }
    }

    private func read(_ epoch: Int, force: Bool = false) async {
        guard force || (timelines[epoch] == nil && !reading.contains(epoch)) else { return }
        reading.insert(epoch)
        defer { reading.remove(epoch) }
        let day = LocalDate(daysSinceUnixEpoch: epoch)
        if let timeline = await model.readDays([day]).first?.timeline { timelines[epoch] = timeline }
    }

    /// The calendar or the ledger changed: the days held are read again, and each is replaced as it lands so nothing blinks.
    private func refreshAll() async {
        for epoch in timelines.keys.sorted() { await read(epoch, force: true) }
    }
}

/// One day of the column: its date, then its cards, with a line above it that divides it from the day before.
private struct DaySection: View {
    let day: LocalDate
    let timeline: DayTimeline?
    let isToday: Bool
    let model: AppModel
    let zone: DisplayTimeZone
    let onSelect: (TimelineSelection) -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(Formatting.dayTitle(day)).font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(isToday ? Theme.accent : Theme.textSecondary)
            if let timeline {
                let plan = DayListPlan.make(timeline)
                if plan.items.isEmpty {
                    Text("일정과 거래가 없어요").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).padding(.vertical, Theme.Space.xs)
                }
                ForEach(plan.items) { item in
                    switch item {
                    case let .allDay(allDay): AllDayLine(item: allDay) { onSelect(.allDay(allDay)) }
                    case let .event(block):
                        EventCard(block: block, model: model, zone: zone, onSelect: { onSelect(.event(block)) }, onOpenTransaction: onOpenTransaction)
                    case let .daily(group):
                        DailyCard(group: group, timeline: timeline, model: model, zone: zone, onOpenTransaction: onOpenTransaction)
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

private struct AllDayLine: View {
    let item: AllDayItem
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Circle().fill(Color(hex: item.calendarColorHex) ?? Theme.accent).frame(width: 8, height: 8)
            Text(item.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Text("하루 종일").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        .listTap(onTap)
    }
}

/// A box of the list: a bar in its colour, a small header that is only a name and a time, and under it the transactions, set in from the header so
/// the two read as levels. A box with no transactions is one thin line.
private struct ListBox<Lines: View>: View {
    let title: String
    let timeText: String
    let totalText: String?
    let color: Color
    let symbol: String
    let hasLines: Bool
    var onSelect: (() -> Void)?
    @ViewBuilder let lines: () -> Lines
    /// A box shows its name, time and total; its transactions open under it on a tap of the chevron.
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 32, height: 32).background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(timeText).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).minimumScaleFactor(0.75)
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
                VStack(alignment: .leading, spacing: Theme.Space.m) { lines() }.padding(.leading, 32 + Theme.Space.s)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

/// An event: its name and time, and the transactions that went to it inside.
private struct EventCard: View {
    let block: EventBlock
    let model: AppModel
    let zone: DisplayTimeZone
    let onSelect: () -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void

    var body: some View {
        ListBox(
            title: block.title, timeText: Formatting.timeRange(block.startUnixMilliseconds, block.endUnixMilliseconds, zoneIdentifier: zone.identifier),
            totalText: block.allocatedSpend.first.map { Formatting.aggregate($0) },
            color: Color(hex: block.calendarColorHex) ?? Theme.accent, symbol: "calendar", hasLines: !block.allocations.isEmpty, onSelect: onSelect
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

/// The stretch of ordinary life between events, as an event named 일상 that holds the transactions no event does.
private struct DailyCard: View {
    let group: DayListPlan.DailyGroup
    let timeline: DayTimeline
    let model: AppModel
    let zone: DisplayTimeZone
    let onOpenTransaction: (LedgerEntryID) -> Void

    var body: some View {
        let start = timeline.dayStartUnixMilliseconds
        let currency = group.markers[0].amount.currency
        let net = group.markers.filter { $0.amount.currency == currency }.reduce(Int64(0)) { $0 + ($1.flow == .refund ? -$1.amount.minorUnits : $1.amount.minorUnits) }
        let total: String? = Formatting.money(net, currency: currency)
        return ListBox(
            title: "일상",
            timeText: Formatting.timeRange(start + Int64(group.fromMinute) * 60_000, start + Int64(group.toMinute) * 60_000, zoneIdentifier: zone.identifier),
            totalText: total, color: Theme.textSecondary, symbol: "sun.max", hasLines: true
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
            IconTile(
                systemName: CategoryIcon.symbol(for: category) ?? (isRefund ? "arrow.uturn.backward" : "creditcard"),
                tint: isRefund ? Theme.accent : Theme.textSecondary, size: 36
            )
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(detail).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            Text((isRefund ? "+" : "") + amountText).font(Theme.Typo.amount).foregroundStyle(Theme.amountColor(isIncoming: isRefund))
        }
        .listTap(onTap)
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

/// Each day section's top, in the list's own space.
private struct DayTopKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// The `UIScrollView` under the SwiftUI list, found so it can be held back for a moment as it coasts past a day's line.
@MainActor private final class ScrollViewBox {
    weak var view: UIScrollView?
    private var releasing: Task<Void, Never>?
    private var normalRate: UIScrollView.DecelerationRate?

    func snag(rate: CGFloat, seconds: Double) {
        guard let view, view.isDecelerating, !view.isTracking else { return }
        if normalRate == nil { normalRate = view.decelerationRate }
        view.decelerationRate = UIScrollView.DecelerationRate(rawValue: rate)
        releasing?.cancel()
        releasing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.view?.decelerationRate = self.normalRate ?? .normal
            self.normalRate = nil
        }
    }
}

private struct ScrollViewFinder: UIViewRepresentable {
    let box: ScrollViewBox
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            var up: UIView? = view
            while let current = up, !(current is UIScrollView) { up = current.superview }
            box.view = up as? UIScrollView
        }
    }
}
