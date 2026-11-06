import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import QuartzCore
import Testing
@testable import OnAllApp

// The static part of a day's plan is made when the day or its data changes, and only placed on every frame of a zoom or a date move.

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let calendarID = CalendarID(rawValue: "c")

private func dayTimeline(_ day: LocalDate, events: Int = 12, transactions: Int = 18, revision: String = "r") throws -> DayTimeline {
    let start = zone.dayBounds(day).start
    let calendarEvents = try (0..<events).map { index -> CalendarEvent in
        let from = Int64(index * 110 + 20), to = from + Int64(35 + index % 4 * 20)
        let range = try TimedRange(startUnixMilliseconds: start + from * 60_000, endUnixMilliseconds: start + to * 60_000)
        return CalendarEvent(id: CalendarEventID(rawValue: "e\(index)"), calendarID: calendarID, title: "일정 \(index)", time: .timed(range), revisionToken: revision)
    }
    let markers = try (0..<transactions).map { index in
        TransactionMarker(
            id: LedgerEntryID(rawValue: "t\(index)"), occurredAtUnixMilliseconds: start + Int64(index * 75 + 10) * 60_000,
            amount: try Money(minorUnits: Int64(1_000 + index), currency: "KRW"), flow: .spend, title: "상점 \(index)"
        )
    }
    return DayTimelineBuilder.build(DayTimelineInput(
        day: day, timeZone: zone, calendars: [CalendarDescriptor(id: calendarID, title: "약속")], events: calendarEvents, life: .empty, transactions: markers
    ))
}

private func layout(_ timeline: DayTimeline) -> AdaptiveLayout {
    AdaptiveLayoutEngine.layout(AllocationInput(main: AllocationDay(timeline), secondary: nil, viewportHeight: 640, contentWidth: 200))
}

private func axis(_ height: CGFloat) -> TemporalAxisMapping { TemporalAxisMapping(partition: TemporalGridPartition.uniform(slotCount: 12, totalHeight: height)) }

@Test func theSameDayDataAndLayoutIsPreparedOnceWhateverTheAxisDoes() throws {
    let day = try LocalDate(year: 2026, month: 10, day: 7)
    let timeline = try dayTimeline(day)
    let engine = layout(timeline)
    let cache = DayPlanPreparations()
    let first = cache.prepared(timeline: timeline, role: .main, layout: engine)
    for step in 0..<120 {
        let again = cache.prepared(timeline: timeline, role: .main, layout: engine)
        #expect(again === first)
        _ = DayRenderPlan(prepared: again, geometry: axis(640 + CGFloat(step) * 12), layoutWidth: 217.5, titleWidth: { _ in 40 })
    }
    #expect(cache.preparations == 1 && cache.hits == 120)
}

@Test func aChangeOfDayDataRoleOrLayoutPreparesAgainAndTheOldEntryIsStillThere() throws {
    let day = try LocalDate(year: 2026, month: 10, day: 7)
    let a = try dayTimeline(day), b = try dayTimeline(day, revision: "changed"), c = try dayTimeline(day.adding(days: 1))
    let cache = DayPlanPreparations()
    let pa = cache.prepared(timeline: a, role: .main, layout: layout(a))
    let pb = cache.prepared(timeline: b, role: .main, layout: layout(b))
    let pc = cache.prepared(timeline: c, role: .main, layout: layout(c))
    let pr = cache.prepared(timeline: a, role: .secondary, layout: layout(a))
    #expect(cache.preparations == 4 && pa !== pb && pb !== pc && pa !== pr)
    #expect(cache.prepared(timeline: a, role: .main, layout: layout(a)) === pa)            // an equal layout, made again, is found
    #expect(cache.preparations == 4 && cache.hits == 1)
}

@Test func theCacheIsBoundedAndDropsTheLeastRecentlyUsedFirst() throws {
    let cache = DayPlanPreparations(limit: 3)
    let base = try LocalDate(year: 2026, month: 10, day: 7)
    let days = try (0..<4).map { try dayTimeline(base.adding(days: $0), events: 3, transactions: 3) }
    for timeline in days.prefix(3) { _ = cache.prepared(timeline: timeline, role: nil, layout: nil) }
    _ = cache.prepared(timeline: days[0], role: nil, layout: nil)                          // day 0 is now the most recent
    _ = cache.prepared(timeline: days[3], role: nil, layout: nil)                          // pushes day 1 out
    #expect(cache.count == 3)
    let before = cache.preparations
    _ = cache.prepared(timeline: days[0], role: nil, layout: nil)
    #expect(cache.preparations == before)
    _ = cache.prepared(timeline: days[1], role: nil, layout: nil)
    #expect(cache.preparations == before + 1)
}

@Test func placingAPreparedDayIsMuchCheaperThanMakingTheWholePlanAndStaticWorkIsNeverRepeatedAcrossAZoom() throws {
    let day = try LocalDate(year: 2026, month: 10, day: 7)
    let timeline = try dayTimeline(day, events: 14, transactions: 24)
    let engine = layout(timeline)
    let frames = 240
    let cache = DayPlanPreparations()

    // Zoom 1 -> 6 in `frames` steps, then a date-style blend of two partitions; the old way builds everything on every frame.
    func zoomAxis(_ step: Int) -> TemporalAxisMapping { axis(640 * (1 + 5 * CGFloat(step) / CGFloat(frames))) }
    let wholeStart = CACurrentMediaTime()
    for step in 0..<frames {
        _ = DayRenderPlan(timeline: timeline, role: .main, layout: engine, geometry: zoomAxis(step), layoutWidth: 217.5, titleWidth: { _ in 40 })
    }
    let whole = CACurrentMediaTime() - wholeStart

    let placeStart = CACurrentMediaTime()
    for step in 0..<frames {
        let prepared = cache.prepared(timeline: timeline, role: .main, layout: engine)
        _ = DayRenderPlan(prepared: prepared, geometry: zoomAxis(step), layoutWidth: 217.5, titleWidth: { _ in 40 })
    }
    let placed = CACurrentMediaTime() - placeStart

    let a = TemporalGridPartition(wholeMinutes: [0, 480, 540, 570, 600, 660, 720, 840, 960, 1080, 1200, 1320, 1440], totalHeight: 640)!
    let b = TemporalGridPartition.uniform(slotCount: 12, totalHeight: 640)
    let blendStart = CACurrentMediaTime()
    for step in 0...frames {
        let blend = TemporalGridPartition.interpolated(from: a, to: b, progress: Double(step) / Double(frames))!
        let prepared = cache.prepared(timeline: timeline, role: .main, layout: engine)
        _ = DayRenderPlan(prepared: prepared, geometry: TemporalAxisMapping(partition: blend), layoutWidth: 217.5, titleWidth: { _ in 40 })
    }
    let blended = CACurrentMediaTime() - blendStart

    print(String(format: "MEASURE phase1a plan per frame: whole %.3f ms, placed %.3f ms (x%.1f), blend %.3f ms; preparations %d over %d frames",
                 whole / Double(frames) * 1000, placed / Double(frames) * 1000, whole / max(placed, 1e-9), blended / Double(frames + 1) * 1000, cache.preparations, 2 * frames + 1))
    #expect(cache.preparations == 1)                                                       // the static part: once, for 481 frames
    #expect(cache.hits == 2 * frames)
    #expect(placed < whole)
}
