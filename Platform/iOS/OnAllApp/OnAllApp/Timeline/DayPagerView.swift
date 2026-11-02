import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// The calendar's pager style: one day on the screen, and a sideways swipe turns to the next or the previous day, the way the week strip above it turns
/// weeks. A day is the same `DaySection` the list draws (date, all-day chips, the event and 일상 boxes with their transactions), alone in its own
/// vertical scroll for the days that do not fit. It is a try-out beside `DayListView`, which keeps the endless column.
///
/// Like the list it leads the selected day: turning a page moves `AppModel.selectedDay` (the header and the week strip follow, with a tick), and a day
/// picked elsewhere turns the pager to it. Days are read when they come near and kept only while they stay near.
struct DayPagerView: View {
    let model: AppModel
    /// The pages run under the translucent top bar; this is how far the content starts below the top of the screen.
    var topInset: CGFloat = 0
    let onSelect: (TimelineSelection) -> Void
    let onOpenTransaction: (LedgerEntryID) -> Void
    let onScrollToDay: (LocalDate) -> Void

    static let reach = 1825
    static let readAhead = 2
    static let keepDistance = 20

    @State private var center: Int
    @State private var position: Int?
    @State private var timelines: [Int: DayTimeline] = [:]
    @State private var reading: Set<Int> = []

    init(model: AppModel, topInset: CGFloat = 0, onSelect: @escaping (TimelineSelection) -> Void, onOpenTransaction: @escaping (LedgerEntryID) -> Void, onScrollToDay: @escaping (LocalDate) -> Void) {
        self.model = model
        self.topInset = topInset
        self.onSelect = onSelect
        self.onOpenTransaction = onOpenTransaction
        self.onScrollToDay = onScrollToDay
        let start = model.selectedDay.daysSinceUnixEpoch
        _center = State(initialValue: start)
        _position = State(initialValue: start)
    }

    var body: some View {
        let zone = model.dayZone
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach((center - Self.reach)...(center + Self.reach), id: \.self) { epoch in
                        let day = LocalDate(daysSinceUnixEpoch: epoch)
                        ScrollView {
                            DaySection(
                                day: day, timeline: timelines[epoch], isToday: day == model.today,
                                model: model, zone: zone, onSelect: onSelect, onOpenTransaction: onOpenTransaction
                            )
                            .padding(.bottom, Theme.Space.xl)
                        }
                        .contentMargins(.top, topInset, for: .scrollContent)
                        .contentMargins(.top, topInset, for: .scrollIndicators)
                        .ignoresSafeArea(edges: .top)
                        .frame(width: proxy.size.width)
                        .id(epoch)
                        .onAppear { if timelines[epoch] == nil { Task { await read(epoch) } } }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
        }
        .onChange(of: position) { old, new in
            guard let new, new != model.selectedDay.daysSinceUnixEpoch else { return }
            if old != nil { Haptics.snap() }
            onScrollToDay(LocalDate(daysSinceUnixEpoch: new))
        }
        .onChange(of: model.selectedDay) { _, day in
            let epoch = day.daysSinceUnixEpoch
            guard epoch != position, abs(epoch - center) <= Self.reach else { return }
            withAnimation(abs(epoch - (position ?? epoch)) <= 1 ? .easeOut(duration: 0.25) : nil) { position = epoch }
        }
        .task(id: position) { await readAround(position) }
        .onChange(of: model.dataGeneration) { _, _ in Task { await refreshAll() } }
    }

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
        if let timeline = await model.readDays([LocalDate(daysSinceUnixEpoch: epoch)]).first?.timeline { timelines[epoch] = timeline }
    }

    private func refreshAll() async {
        for epoch in timelines.keys.sorted() { await read(epoch, force: true) }
    }
}
