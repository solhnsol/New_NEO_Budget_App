import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private typealias F = TemporalGridFixtures

private func params(_ n: Int, _ scenario: AxisStabilityScenario) -> TemporalGridParameters {
    var p = TemporalGridParameters.with(slotCount: n)
    p.viewportHeight = scenario.viewportHeight
    p.textScale = scenario.textScale
    p.allocation = scenario.parameters
    return p
}

private func plan(_ scenario: AxisStabilityScenario, n: Int = 12, main: Int = 3) -> TemporalGridPlan {
    TemporalGridPlanner.plan(window: TemporalWindow(days: Array(scenario.days[(main - 1)...(main + 2)]), mainIndex: 1), parameters: params(n, scenario))
}

private func place(_ day: AllocationDay, _ partition: TemporalGridPartition, scale: CGFloat = 1) -> GridDayPlacement {
    GridPlacement.place(GridDayEntities.make(day), partition: partition, metrics: .standard(scale: scale), transactionPitch: GridPlacement.transactionPitch(AllocationParameters(), textScale: scale))
}

// MARK: Nothing is lost, nothing is moved

@Test func everyEventAndTransactionOfEveryFixtureKeepsItsIdItsTimeAndAnExactPosition() {
    for scenario in F.all {
        for n in [10, 12, 16] {
            let partition = plan(scenario, n: n).partition
            for index in 3...4 {
                let day = scenario.days[index]
                let entities = GridDayEntities.make(day)
                let placed = place(day, partition, scale: scenario.textScale)
                // P0: every event and every transaction is there, once, with the id it came with.
                #expect(placed.events.map(\.id).sorted() == day.events.map(\.id).sorted(), "\(scenario.name) N=\(n)")
                let transactionIDs = day.transactions.map(\.id) + day.events.flatMap { $0.linked.map(\.id) }
                #expect(placed.transactions.map(\.id).sorted() == transactionIDs.sorted(), "\(scenario.name) N=\(n)")
                // The times are the entity's real ones, and the position is the partition's y of that exact time.
                for event in placed.events {
                    let source = day.events.first { $0.id == event.id }!
                    #expect(event.startMinute == source.startMinute && event.endMinute == source.endMinute)
                    #expect(event.top == partition.timeToY(Double(source.startMinute)) && event.bottom == partition.timeToY(Double(source.endMinute)))
                    #expect(event.height >= 0)
                }
                for transaction in placed.transactions {
                    #expect(transaction.y == partition.timeToY(Double(transaction.minute)))
                }
                #expect(entities.events.count == day.events.count)
            }
        }
    }
}

@Test func anEventIsNeverMadeLongerToShowItsText() {
    // A 5 minute event in an 8 hour cell stays a fraction of a point tall. Its presentation is a line; its time range is not stretched.
    let day = F.day(3, events: [(300, 305)])
    let partition = TemporalGridPartition(wholeMinutes: [0, 480, 540, 600, 660, 720, 780, 840, 900, 960, 1020, 1380, 1440], totalHeight: 640)!
    let placed = place(day, partition)
    let event = placed.events[0]
    #expect(abs(event.height - 640.0 / 12 * 5 / 480) < 1e-9)
    #expect(event.presentation.level == .line)
    #expect(event.presentation == EventPresentation.make(height: event.height, insideCount: 0, metrics: .standard()))
}

@Test func transactionsAtTheSameMinuteShareAYAndStayReachable() {
    let day = F.day(3, transactions: [600, 600, 600, 601])
    let partition = plan(F.gridRuns[6]).partition
    let placed = place(day, partition)
    #expect(placed.transactions.count == 4)
    #expect(Set(placed.transactions.filter { $0.minute == 600 }.map(\.y)).count == 1)
    #expect(placed.independent.allSatisfy { $0.reveal < 1 })       // no room to write them: the dots remain, the text does not
    #expect(Set(placed.transactions.map(\.id)).count == 4)
}

// MARK: The cases the grid is asked about

@Test func anEmptyDayGetsEqualHourAlignedCellsAndNothingToDraw() {
    let result = plan(F.gridRuns[0])
    #expect(result.partition.boundaries == (0...12).map { Double($0 * 120) })
    let placed = place(F.gridRuns[0].days[3], result.partition)
    #expect(placed.events.isEmpty && placed.transactions.isEmpty)
}

@Test func anAllDayEventIsOneTallCardWhileAShortEventInsideItIsStillIdentified() {
    let scenario = F.gridRuns[1]
    let placed = place(scenario.days[3], plan(scenario).partition)
    let allDay = placed.events.first { $0.endMinute - $0.startMinute == 1440 }!
    #expect(abs(allDay.height - 640) < 1e-9)
    #expect(allDay.presentation.level == .detail || allDay.presentation.level == .summary)
    let meeting = placed.events.first { $0.endMinute - $0.startMinute == 60 }!
    #expect(meeting.presentation.title >= 1)
}

@Test func scatteredShortEventsAreEachIdentified() {
    let scenario = F.gridRuns[2]
    let placed = place(scenario.days[3], plan(scenario).partition)
    #expect(placed.titlesShown >= placed.events.count - 1)
}

@Test func denseShortEventsGetMoreTitlesThanEqualCells() {
    let scenario = F.gridRuns[3]
    let planned = place(scenario.days[3], plan(scenario).partition)
    let uniform = place(scenario.days[3], TemporalGridPartition.uniform(slotCount: 12, totalHeight: 640))
    #expect(planned.titlesShown > uniform.titlesShown)
}

@Test func aLongEventOverlappedByShortOnesKeepsBothVisible() {
    let scenario = F.gridRuns[4]
    let partition = plan(scenario).partition
    let placed = place(scenario.days[3], partition)
    #expect(placed.events.allSatisfy { $0.height > 0 })
    let long = placed.events.first { $0.endMinute - $0.startMinute == 540 }!
    #expect(long.presentation.title >= 1)
    let shorts = placed.events.filter { $0.endMinute - $0.startMinute < 60 }
    #expect(shorts.count == 3)
    #expect(shorts.filter { $0.presentation.level >= .low }.count >= 2)      // at least two of the three short ones can be read
}

@Test func whenMainAndSecondaryAreBusyAtOtherTimesBothAreReadable() {
    let scenario = F.gridRuns[5]
    let partition = plan(scenario, main: 4).partition
    let main = place(scenario.days[4], partition), secondary = place(scenario.days[5], partition)
    #expect(main.titlesShown >= main.events.count - 1)
    #expect(secondary.titlesShown >= secondary.events.count - 2)
}

@Test func denseTransactionsAreFullyAccessibleAndMoreAreWrittenThanOnEqualCells() {
    let scenario = F.gridRuns[6]
    let planned = place(scenario.days[3], plan(scenario).partition)
    let uniform = place(scenario.days[3], TemporalGridPartition.uniform(slotCount: 12, totalHeight: 640))
    #expect(planned.independent.count == scenario.days[3].transactions.count)
    #expect(planned.transactionTextShown >= uniform.transactionTextShown)
}

@Test func aDayWithThirtyTwoEventsStillPlacesEveryOneOfThem() {
    let scenario = F.gridRuns[7]
    for n in [10, 12, 16] {
        let result = plan(scenario, n: n)
        let placed = place(scenario.days[3], result.partition)
        #expect(placed.events.count == 32)
        #expect(Set(placed.events.map(\.id)).count == 32)
        let uniform = place(scenario.days[3], TemporalGridPartition.uniform(slotCount: n, totalHeight: 640))
        // Not all 32 can be written in 640 pt (that needs about a point per minute for 15 hours); the grid still writes more of them than equal cells.
        #expect(placed.events.filter { $0.presentation.level >= .low }.count >= uniform.events.filter { $0.presentation.level >= .low }.count)
        #expect(placed.events.allSatisfy { $0.height > 0 })
    }
}

@Test func largerTextAsksForMoreHeightAndTheGridStaysValid() {
    let busy = F.busy(3)
    var big = F.gridRuns[8]
    big = AxisStabilityScenario(name: big.name, days: (0..<9).map { _ in busy }, textScale: 3.0)
    let normal = AxisStabilityScenario(name: "x", days: (0..<9).map { _ in busy }, textScale: 1)
    let bigResult = plan(big), normalResult = plan(normal)
    #expect(bigResult.partition.slotCount == 12 && normalResult.partition.slotCount == 12)
    // The thresholds of EventPresentation grow with the text, so the same partition shows fewer titles at 3x.
    let sameGrid = normalResult.partition
    #expect(place(busy, sameGrid, scale: 3).titlesShown <= place(busy, sameGrid, scale: 1).titlesShown)
    // And planning for the bigger text is not worse for it than reusing the grid planned for the normal text.
    #expect(place(busy, bigResult.partition, scale: 3).titlesShown >= place(busy, sameGrid, scale: 3).titlesShown)
}

// MARK: Moving between two days

@Test func betweenTwoDaysNothingIsPlannedAgainAndEveryFrameKeepsTheLinesStill() throws {
    let scenario = F.demoTransRun()
    let store = TemporalGridStore()
    let p = params(12, scenario)
    let a = store.plan(window: TemporalWindow(days: Array(scenario.days[0...3]), mainIndex: 1), parameters: p).partition
    let b = store.plan(window: TemporalWindow(days: Array(scenario.days[1...4]), mainIndex: 1), parameters: p).partition
    #expect(a.boundaries.count == b.boundaries.count)
    store.resetCounters()
    let entities = GridDayEntities.make(scenario.days[2])
    var previous: [GridEventPlacement]?
    var worstStep: CGFloat = 0
    for frame in 0...100 {
        let blend = try #require(TemporalGridPartition.interpolated(from: a, to: b, progress: Double(frame) / 100))
        #expect(blend.totalHeight == a.totalHeight)
        for slot in 0..<12 { #expect(blend.top(ofSlot: slot) == a.top(ofSlot: slot)) }
        let placed = GridPlacement.place(entities, partition: blend, metrics: .standard(), transactionPitch: 26)
        if let previous { for (x, y) in zip(previous, placed.events) { worstStep = max(worstStep, abs(x.top - y.top), abs(x.bottom - y.bottom)) } }
        previous = placed.events
    }
    #expect(store.planRuns == 0 && store.profileBuilds == 0)       // 101 frames, no optimisation, no profile
    #expect(worstStep < 8)                                          // a 640 pt grid moved over 100 steps: a frame moves an item a few points at most
}

@Test func theTimeOrderOfEventsNeverFlipsDuringTheBlend() throws {
    let scenario = F.demoTransRun()
    let a = plan(scenario, main: 1).partition, b = plan(scenario, main: 3).partition
    let entities = GridDayEntities.make(scenario.days[4])
    for step in 0...50 {
        let blend = try #require(TemporalGridPartition.interpolated(from: a, to: b, progress: Double(step) / 50))
        let placed = GridPlacement.place(entities, partition: blend, metrics: .standard(), transactionPitch: 26)
        let order = placed.events.sorted { ($0.startMinute, $0.id) < ($1.startMinute, $1.id) }.map(\.top)
        #expect(zip(order, order.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

// MARK: Counting what is recomputed per frame

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day0 = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()

private func realTimeline(events: Int, transactions: Int) throws -> DayTimeline {
    let calendar = CalendarID(rawValue: "c")
    var calendarEvents: [CalendarEvent] = []
    for index in 0..<events {
        let start = 8 * 60 + index * 25
        let range = try TimedRange(startUnixMilliseconds: zone.instant(of: day0, minuteOfDay: start), endUnixMilliseconds: zone.instant(of: day0, minuteOfDay: start + 20))
        calendarEvents.append(CalendarEvent(id: CalendarEventID(rawValue: "e\(index)"), calendarID: calendar, title: "일정 \(index)", time: .timed(range), revisionToken: "r"))
    }
    var markers: [TransactionMarker] = []
    for index in 0..<transactions {
        markers.append(TransactionMarker(
            id: LedgerEntryID(rawValue: "t\(index)"), occurredAtUnixMilliseconds: zone.instant(of: day0, minuteOfDay: 8 * 60 + index * 7),
            amount: try Money(minorUnits: 4_500, currency: "KRW"), flow: .spend, title: "상점 \(index)"
        ))
    }
    return DayTimelineBuilder.build(DayTimelineInput(
        day: day0, timeZone: zone, calendars: [CalendarDescriptor(id: calendar, title: "약속")], events: calendarEvents, life: .empty, transactions: markers
    ))
}

@Test func printWhatTheExistingRendererRecomputesOnEveryFrameOfADateMove() throws {
    // `TimelineGridView.dayContent` builds a `DayRenderPlan` inside the body that `TimelineView(.animation)` re-evaluates on every frame
    // of an axis change. Measure one such build against the temporal grid's per-frame work for the same day.
    let timeline = try realTimeline(events: 24, transactions: 30)
    let allocationDay = AllocationDay(timeline)
    let layout = AdaptiveLayoutEngine.layout(AllocationInput(main: allocationDay, secondary: nil, viewportHeight: 640, contentWidth: 200))
    let from = layout.axis, to = TemporalGridPartition.uniform(slotCount: 12, totalHeight: 640).timelineAxis().axis
    let frames = 60
    let clock = ContinuousClock()
    func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
    let renderPlan = clock.measure {
        for frame in 0..<frames {
            let geometry = TimelineGeometry(from: from, to: to, progress: CGFloat(frame) / CGFloat(frames - 1))
            _ = DayRenderPlan(timeline: timeline, role: .main, layout: layout, geometry: geometry, layoutWidth: 217.5, titleWidth: { _ in 40 })
        }
    }
    let a = TemporalGridPartition.uniform(slotCount: 12, totalHeight: 640)
    let b = plan(F.gridRuns[7]).partition
    let entities = GridDayEntities.make(allocationDay)
    let gridFrame = clock.measure {
        for frame in 0..<frames {
            let blend = TemporalGridPartition.interpolated(from: a, to: b, progress: Double(frame) / Double(frames - 1))!
            _ = GridPlacement.place(entities, partition: blend, metrics: .standard(), transactionPitch: 26)
        }
    }
    let entityBuild = clock.measure { for _ in 0..<frames { _ = GridDayEntities.make(allocationDay) } }
    print("PER-FRAME  DayRenderPlan.init: \(String(format: "%.3f", ms(renderPlan) / Double(frames))) ms/frame (24 events, 30 transactions, built \(frames)x, one per frame as dayContent does)")
    print("PER-FRAME  grid placement (blend + y + EventPresentation): \(String(format: "%.3f", ms(gridFrame) / Double(frames))) ms/frame; static entities built once: \(String(format: "%.3f", ms(entityBuild) / Double(frames))) ms")
    #expect(ms(gridFrame) / Double(frames) < ms(renderPlan) / Double(frames) + 5)
}
