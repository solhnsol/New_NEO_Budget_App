import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private let newYork = (try? DisplayTimeZone(identifier: "America/New_York")) ?? { fatalError("tz") }()
private let seoul = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let springDay = (try? LocalDate(year: 2026, month: 3, day: 8)) ?? { fatalError("date") }()
private let fallDay = (try? LocalDate(year: 2026, month: 11, day: 1)) ?? { fatalError("date") }()
private let ordinaryDay = (try? LocalDate(year: 2026, month: 10, day: 7)) ?? { fatalError("date") }()
private let calendarID = CalendarID(rawValue: "c")

/// Events given as elapsed minutes from the day's start (so a repeated hour's second occurrence can be named), transactions likewise.
private func timeline(on day: LocalDate, zone: DisplayTimeZone, events: [(Int, Int)], transactions: [Int] = []) throws -> DayTimeline {
    let start = zone.dayBounds(day).start
    let calendarEvents = try events.enumerated().map { index, span -> CalendarEvent in
        let range = try TimedRange(startUnixMilliseconds: start + Int64(span.0) * 60_000, endUnixMilliseconds: start + Int64(span.1) * 60_000)
        return CalendarEvent(id: CalendarEventID(rawValue: "e\(index)"), calendarID: calendarID, title: "일정 \(index)", time: .timed(range), revisionToken: "r")
    }
    let markers = try transactions.map { minute in
        TransactionMarker(
            id: LedgerEntryID(rawValue: "t\(minute)"), occurredAtUnixMilliseconds: start + Int64(minute) * 60_000,
            amount: try Money(minorUnits: 4_500, currency: "KRW"), flow: .spend, title: "상점 \(minute)"
        )
    }
    return DayTimelineBuilder.build(DayTimelineInput(
        day: day, timeZone: zone, calendars: [CalendarDescriptor(id: calendarID, title: "약속")], events: calendarEvents, life: .empty, transactions: markers
    ))
}

/// `event/1:c/2:e0` -> `e0`.
private func short(_ id: String) -> String { String(id.split(separator: ":").last ?? "") }

private func grid(height: CGFloat = 720) -> TemporalAxisMapping { TemporalAxisMapping(partition: TemporalGridPartition.uniform(slotCount: 12, totalHeight: height)) }   // 0.5 pt per minute

private func adapted(_ day: LocalDate, _ zone: DisplayTimeZone) -> (mapping: ElapsedMinuteAxisMapping, inner: TemporalAxisMapping) {
    let inner = grid()
    return (ElapsedMinuteAxisMapping(inner: inner, projection: WallClockProjection(day: day, zone: zone)), inner)
}

private func plan(_ timeline: DayTimeline, _ mapping: any TimeAxisMapping, layout: AdaptiveLayout? = nil, role: DayRole? = nil) -> DayRenderPlan {
    DayRenderPlan(timeline: timeline, role: role, layout: layout, geometry: mapping, layoutWidth: 217.5, titleWidth: { _ in 40 })
}

// MARK: An ordinary day: the adapter is the identity

@Test func onAnOrdinaryDayTheAdapterIsExactlyTheInnerAxis() throws {
    let (mapping, inner) = adapted(ordinaryDay, seoul)
    #expect(mapping.projection.isIdentity && mapping.totalMinutes == 1440 && mapping.preservesInstantIdentity)
    for minute in 0...1440 {
        #expect(mapping.y(minute: minute) == inner.y(minute: minute))
        #expect(mapping.y(endMinute: minute) == inner.y(minute: minute))
        #expect(mapping.minute(atY: mapping.y(minute: minute)) == minute)
    }
    let day = try timeline(on: ordinaryDay, zone: seoul, events: [(9 * 60, 10 * 60), (13 * 60, 13 * 60 + 17), (22 * 60, 1440)], transactions: [610, 800])
    let a = plan(day, mapping), b = plan(day, inner)
    #expect(a.events.map(\.block.id) == b.events.map(\.block.id))
    for (x, y) in zip(a.events, b.events) { #expect(x.frame == y.frame && x.drawnFrame == y.drawnFrame && x.touchFrame == y.touchFrame && x.presentation == y.presentation) }
    #expect(a.lines.map(\.id) == b.lines.map(\.id) && zip(a.lines, b.lines).allSatisfy { $0.frame == $1.frame && $0.reveal == $1.reveal })
    let allocation = AllocationDay(day)
    #expect(mapping.projection.projected(allocation) == allocation)
}

@Test func aPreparedPlanPlacedAtSeveralZoomsEqualsMakingTheWholePlanEachTime() throws {
    let day = try timeline(on: ordinaryDay, zone: seoul, events: [(9 * 60, 10 * 60), (9 * 60 + 30, 11 * 60), (13 * 60, 13 * 60 + 17)], transactions: [550, 610, 640, 800])
    let layout = AdaptiveLayoutEngine.layout(AllocationInput(main: AllocationDay(day), secondary: nil, viewportHeight: 640, contentWidth: 200))
    let prepared = DayRenderPlan.Prepared(timeline: day, role: .main, layout: layout)
    for zoom in [1.0, 2.0, 5.5] as [CGFloat] {
        let mapping = TemporalAxisMapping(partition: TemporalGridPartition.uniform(slotCount: 12, totalHeight: 640 * zoom))
        let placed = DayRenderPlan(prepared: prepared, geometry: mapping, layoutWidth: 217.5, titleWidth: { _ in 40 })
        let whole = plan(day, mapping, layout: layout, role: .main)
        #expect(placed.events.map { "\($0.block.id) \($0.frame) \($0.presentation)" } == whole.events.map { "\($0.block.id) \($0.frame) \($0.presentation)" })
        #expect(placed.lines.map { "\($0.id) \($0.frame) \($0.reveal)" } == whole.lines.map { "\($0.id) \($0.frame) \($0.reveal)" })
        #expect(placed.overflows.map { "\($0.id) \($0.frame) \($0.reveal)" } == whole.overflows.map { "\($0.id) \($0.frame) \($0.reveal)" })
    }
}

// MARK: Spring forward (23 hours)

@Test func onASpringForwardDayEventsAndTransactionsLandOnTheirWallClockMinutes() throws {
    let (mapping, inner) = adapted(springDay, newYork)
    #expect(mapping.totalMinutes == 23 * 60 && !mapping.projection.isIdentity && mapping.preservesInstantIdentity)
    let day = try timeline(on: springDay, zone: newYork, events: [(120, 180), (90, 150), (60, 120)], transactions: [125, 100])
    let result = plan(day, mapping)
    let frames = Dictionary(uniqueKeysWithValues: result.events.map { (short($0.block.id.rawValue), $0.frame) })
    #expect(abs(frames["e0"]!.minY - inner.y(minute: 180)) < 1e-9 && abs(frames["e0"]!.maxY - inner.y(minute: 240)) < 1e-9)
    #expect(abs(frames["e1"]!.minY - inner.y(minute: 90)) < 1e-9 && abs(frames["e1"]!.maxY - inner.y(minute: 210)) < 1e-9)
    #expect(abs(frames["e2"]!.minY - inner.y(minute: 60)) < 1e-9 && abs(frames["e2"]!.maxY - inner.y(minute: 120)) < 1e-9, "e2 \(frames["e2"]!) y90 \(inner.y(minute: 90)) y120 \(inner.y(minute: 120))")
    let lines = Dictionary(uniqueKeysWithValues: result.lines.map { ($0.id, $0.anchorY ?? 0) })
    #expect(abs(lines["t125"]! - inner.y(minute: 185)) < 1e-9 && abs(lines["t100"]! - inner.y(minute: 100)) < 1e-9)
    #expect(result.events.map(\.block.id.rawValue).map(short).sorted() == ["e0", "e1", "e2"] && result.lines.map(\.id).sorted() == ["t100", "t125"])
    let projection = mapping.projection
    #expect(projection.displayElapsed(forWall: 150) == .init(minute: 120, isUnambiguous: false))
    #expect(projection.displayElapsed(forWall: 200) == .init(minute: 140, isUnambiguous: true))
}

// MARK: Fall back (25 hours)

@Test func onAFallBackDayTheSecondOccurrenceOverlapsTheFirstAndTheAxisRefusesToSaveFromAPosition() throws {
    let (mapping, inner) = adapted(fallDay, newYork)
    #expect(mapping.totalMinutes == 25 * 60 && !mapping.preservesInstantIdentity)
    let day = try timeline(on: fallDay, zone: newYork, events: [(90, 110), (150, 170), (90, 130)], transactions: [95, 155])
    let result = plan(day, mapping)
    let frames = Dictionary(uniqueKeysWithValues: result.events.map { (short($0.block.id.rawValue), $0.frame) })
    #expect(frames["e0"]!.minY == frames["e1"]!.minY && frames["e0"]!.maxY == frames["e1"]!.maxY)
    #expect(abs(frames["e0"]!.minY - inner.y(minute: 90)) < 1e-9 && abs(frames["e0"]!.maxY - inner.y(minute: 110)) < 1e-9)
    #expect(abs(frames["e2"]!.minY - inner.y(minute: 90)) < 1e-9 && abs(frames["e2"]!.maxY - inner.y(minute: 120)) < 1e-9)
    let lines = Dictionary(uniqueKeysWithValues: result.lines.map { ($0.id, $0.anchorY ?? 0) })
    #expect(abs(lines["t95"]! - inner.y(minute: 95)) < 1e-9 && abs(lines["t155"]! - inner.y(minute: 95)) < 1e-9)
    #expect(result.events.count == 3 && result.lines.count == 2)
    let planner = TimelineEditPlanner(policy: .standard, zone: newYork, geometry: mapping, timeline: day)
    let block = try #require(day.blocks.first)
    #expect(planner.preview(.move, block: block, translationY: 10) == nil && planner.preview(.resizeEnd, block: block, translationY: 10) == nil)
    #expect(mapping.projection.displayElapsed(forWall: 90) == .init(minute: 90, isUnambiguous: false))
    #expect(mapping.projection.displayElapsed(forWall: 130) == .init(minute: 190, isUnambiguous: true))
}

@Test func theOtherAxesKeepTheirInstantsSoEditingIsAllowedOnThem() throws {
    let day = try timeline(on: ordinaryDay, zone: seoul, events: [(9 * 60, 10 * 60)])
    let block = try #require(day.blocks.first)
    let ordinary = adapted(ordinaryDay, seoul).mapping
    let spring = adapted(springDay, newYork).mapping
    for mapping in [ordinary as any TimeAxisMapping, spring, TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 1), grid()] {
        #expect(mapping.preservesInstantIdentity)
    }
    let planner = TimelineEditPlanner(policy: .standard, zone: seoul, geometry: ordinary, timeline: day)
    let moved = try #require(planner.preview(.move, block: block, translationY: 30 * 0.5))
    #expect(moved.range.startUnixMilliseconds - block.startUnixMilliseconds == 30 * 60_000)
}

// MARK: Midnight and several days

@Test func spansThatTouchOrCrossMidnightAreDrawnToTheEdgesOfTheAxis() throws {
    for (day, zone) in [(ordinaryDay, seoul), (springDay, newYork), (fallDay, newYork)] {
        let (mapping, inner) = adapted(day, zone)
        let total = mapping.totalMinutes
        let built = try timeline(on: day, zone: zone, events: [(0, 120), (total - 90, total), (0, total)])
        let frames = Dictionary(uniqueKeysWithValues: plan(built, mapping).events.map { (short($0.block.id.rawValue), $0.frame) })
        #expect(frames["e0"]!.minY == inner.y(minute: 0))
        #expect(abs(frames["e1"]!.maxY - inner.contentHeight) < 1e-9)
        #expect(frames["e2"]!.minY == 0 && abs(frames["e2"]!.maxY - inner.contentHeight) < 1e-9)
    }
}

// MARK: The engine's input

@Test func theEnginesInputInWallClockMinutesKeepsEveryIdAndEveryAmount() throws {
    let day = try timeline(on: fallDay, zone: newYork, events: [(60, 120), (150, 170), (200, 260)], transactions: [95, 155, 210])
    let projection = WallClockProjection(day: fallDay, zone: newYork)
    let original = AllocationDay(day)
    let projected = projection.projected(original)
    #expect(projected.totalMinutes == 1440)
    #expect(projected.events.map(\.id) == original.events.map(\.id) && projected.events.map(\.title) == original.events.map(\.title))
    #expect(projected.transactions.map(\.id) == original.transactions.map(\.id) && projected.transactions.map(\.minorUnits) == original.transactions.map(\.minorUnits))
    let spans = Dictionary(uniqueKeysWithValues: projected.events.map { (short($0.id), ($0.startMinute, $0.endMinute)) })
    #expect(spans["e1"]! == (90, 110))
    #expect(spans["e2"]! == (140, 200))
}

@Test func aDaylightSavingDayDrawnWithoutAnEngineLayoutKeepsEveryTransactionAsALineAtItsTime() throws {
    let (mapping, inner) = adapted(springDay, newYork)
    let day = try timeline(on: springDay, zone: newYork, events: [(120, 240)], transactions: [30, 130, 131, 132, 500])
    let result = plan(day, mapping)
    #expect(result.lines.count == 5 && result.overflows.isEmpty)
    let wall: [String: Int] = ["t30": 30, "t130": 190, "t131": 191, "t132": 192, "t500": 560]
    for line in result.lines { #expect(abs((line.anchorY ?? -1) - inner.y(minute: wall[line.id]!)) < 1e-9, "\(line.id)") }
    #expect(result.events.count == 1)
}
