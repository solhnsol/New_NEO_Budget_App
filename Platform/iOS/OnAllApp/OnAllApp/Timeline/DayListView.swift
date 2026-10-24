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
    /// While the finger drags, the list holds at a day's line: it follows the finger only this fraction of the way, and lets go (to the finger's
    /// position) once the finger has pulled `releasePull` points past the line.
    static let holdGive: CGFloat = 0.2
    static let releasePull: CGFloat = 36

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
    /// True from arriving on a day until the reader first touches the list: days read after that change the heights above, and the day is kept on the line.
    @State private var untouched = false
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
        _headingFor = State(initialValue: start)
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
                        // The space's own origin rides along under `Int.min`: it sits below the status bar, not at the top of the screen.
                        let top = proxy.frame(in: .named(Self.space)).minY
                        Color.clear.preference(key: DayTopKey.self, value: [epoch: top, Int.min: proxy.frame(in: .global).minY - top])
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
        .task {
            // Opening on a day: the day the model is on is what the list opened on.
            let epoch = model.selectedDay.daysSinceUnixEpoch
            if headingFor != nil { headingFor = epoch; readingEpoch = epoch; await arrive(at: epoch, after: 0.3) }
        }
        .onChange(of: model.selectedDay) { _, day in selectionChanged(to: day.daysSinceUnixEpoch) }
        .onChange(of: model.dataGeneration) { _, _ in Task { await refreshAll() } }
    }

    // MARK: Following the model, and leading it

    /// The sections reported where they are. The day at the top follows them; a new day coming onto the screen is felt once.
    private func moved(to reported: [Int: CGFloat]) {
        var now = reported
        let origin = now.removeValue(forKey: Int.min) ?? 0
        guard !now.isEmpty else { return }
        // Where the bottom of the bar (the top of what can really be seen) and the bottom edge of the list are, in the space the days are reported in.
        let scrollTop = scrollView.view?.convert(CGPoint.zero, to: nil).y ?? 0
        let line = scrollTop + topInset - origin
        let height = scrollTop + (scrollView.view?.bounds.height ?? 0) - origin
        scrollView.tops = now
        scrollView.line = line
        // The header is drawn over the top of the list: the day at the top is the one at the top of what can really be seen below it.
        let top = now.filter { $0.value <= line + 0.5 }.keys.max() ?? now.keys.min()!
        let bottom = now.filter { $0.value <= height }.keys.max() ?? top
        defer { lastBottom = bottom }
        if scrollView.view?.isTracking == true { untouched = false }
        guard headingFor == nil else { return }
        // A new day comes onto the screen when the line between days enters from the bottom edge (the list moves up) or from the top edge (it
        // moves down: the day at the top changes to the one before). A day leaving the screen is not felt.
        let enteredBelow = lastBottom.map { bottom > $0 } ?? false
        let enteredAbove = readingEpoch.map { top < $0 } ?? false
        if enteredBelow || enteredAbove {
            Haptics.snap()
            scrollView.snag(rate: Self.snagRate, seconds: Self.snagSeconds)
        }
        if let old = readingEpoch, old != top, let boundary = now[top > old ? top : old] {
            scrollView.hold(dir: top > old ? 1 : -1, lineGap: boundary - line, give: Self.holdGive, release: Self.releasePull)
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
        Task { await arrive(at: epoch, after: jump > Self.animatedJump ? 0.3 : 0.6) }
    }

    /// The list is deaf to the reader's position until it has arrived (or for as long as a scroll takes). It then brings the day's top to the line a few
    /// times: the lazy column lands the day where its estimate of the days above puts it, and the estimate settles as they are drawn.
    private func arrive(at epoch: Int, after delay: Double) async {
        try? await Task.sleep(for: .seconds(delay))
        for _ in 0..<5 {
            guard headingFor == epoch else { return }
            scrollView.align(epoch)
            try? await Task.sleep(for: .milliseconds(120))
        }
        if headingFor == epoch { headingFor = nil; untouched = true }
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
        if let timeline = await model.readDays([day]).first?.timeline {
            timelines[epoch] = timeline
            if untouched, let at = readingEpoch {
                try? await Task.sleep(for: .milliseconds(60))
                if untouched { scrollView.align(at) }
            }
        }
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
                ForEach(plan.items) { item in
                    switch item {
                    case .allDay: EmptyView()
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
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
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
            color: Color(hex: block.calendarColorHex) ?? Theme.accent, symbol: model.calendarSymbol(id: block.eventKey.calendarID, title: block.calendarTitle), hasLines: !block.allocations.isEmpty, onSelect: onSelect
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
    weak var view: UIScrollView? { didSet { if view !== oldValue { observe() } } }
    private var releasing: Task<Void, Never>?
    private var normalRate: UIScrollView.DecelerationRate?
    private var observation: NSKeyValueObservation?
    private var writing = false
    /// Where each day's top last was reported, in the list's own space, and where the visible part of the list starts (under the bar).
    var tops: [Int: CGFloat] = [:]
    var line: CGFloat = 0

    /// Moves the list by whatever it takes for `epoch`'s top to sit exactly at `line`: a scroll to a day lands where the lazy column's estimate of the
    /// days above puts it, which can be well short of the line, and the day would change at the first touch.
    func align(_ epoch: Int) {
        guard let view, !view.isTracking, !view.isDecelerating, let y = tops[epoch], abs(y - line) > 0.5 else { return }
        view.contentOffset.y += y - line
    }

    /// A day's line held under the finger: where the offset is held, which way the list was moving, and where the finger and the offset were when it was caught.
    private struct Hold {
        let heldY: CGFloat, dir: CGFloat, fingerY: CGFloat, offsetY: CGFloat, give: CGFloat, release: CGFloat
    }
    private var holding: Hold?

    private func observe() {
        observation = view?.observe(\.contentOffset) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.offsetChanged() }
        }
    }

    /// While the finger drags past a day's line, the list stays on the line and gives only a little, until the finger has pulled hard enough: then it lets go
    /// and lands where the finger is.
    func hold(dir: CGFloat, lineGap: CGFloat, give: CGFloat, release: CGFloat) {
        guard let view, view.isTracking, holding == nil else { return }
        let y = view.contentOffset.y
        holding = Hold(heldY: y + lineGap, dir: dir, fingerY: view.panGestureRecognizer.location(in: nil).y, offsetY: y, give: give, release: release)
    }

    private func offsetChanged() {
        guard !writing, let view, let hold = holding else { return }
        guard view.isTracking else { holding = nil; return }
        let natural = hold.offsetY - (view.panGestureRecognizer.location(in: nil).y - hold.fingerY)
        let pull = hold.dir * (natural - hold.heldY)
        writing = true
        defer { writing = false }
        if pull > 0 && pull < hold.release {
            view.contentOffset.y = hold.heldY + hold.dir * pull * hold.give
        } else {
            holding = nil
            view.contentOffset.y = natural
        }
    }

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
