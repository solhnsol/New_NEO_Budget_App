import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import QuartzCore
import Testing
@testable import OnAllApp

// Browse on the fixed Temporal Grid (read-only) against Browse as it is: the same days, drawn on two axes. What may differ is where things are and how much of each is
// written; what may not is which events and transactions there are, when they happened, what they link to, and that each can be touched.

private let seoul = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let newYork = (try? DisplayTimeZone(identifier: "America/New_York")) ?? { fatalError("tz") }()
private let calendarID = CalendarID(rawValue: "c")
private let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)

// MARK: Building days

/// A `DayTimeline` with the content of an `AllocationDay` (the fixtures are written as those): the same ids, titles, minutes and links.
func fixtureTimeline(_ source: AllocationDay, zone: DisplayTimeZone = seoul) throws -> DayTimeline {
    let start = zone.dayBounds(source.day).start
    var events: [CalendarEvent] = []
    var markers: [TransactionMarker] = []
    var changes: [LifeChange] = []
    func marker(_ id: String, _ minute: Int, _ units: Int64?) throws -> TransactionMarker {
        TransactionMarker(
            id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: start + Int64(minute) * 60_000,
            amount: try Money(minorUnits: units ?? 1_000, currency: "KRW"), flow: .spend, title: "상점 \(id)"
        )
    }
    for event in source.events {
        let range = try TimedRange(startUnixMilliseconds: start + Int64(event.startMinute) * 60_000, endUnixMilliseconds: start + Int64(max(event.endMinute, event.startMinute + 1)) * 60_000)
        let calendarEvent = CalendarEvent(id: CalendarEventID(rawValue: event.id), calendarID: calendarID, title: event.title, time: .timed(range), revisionToken: "r")
        events.append(calendarEvent)
        guard !event.linked.isEmpty else { continue }
        let activityID = ActivityID(rawValue: "A-" + event.id)
        changes.append(.createActivity(Activity.materialized(from: calendarEvent, id: activityID, at: 1)))
        for transaction in event.linked {
            let made = try marker(transaction.id, transaction.minute, transaction.minorUnits)
            markers.append(made)
            changes.append(.upsertAllocation(
                TransactionAllocation(
                    id: AllocationID(rawValue: "alloc-" + transaction.id), transactionID: made.id, activityID: activityID,
                    amount: try AmountEntry(currency: "KRW", knowledge: .exact(made.amount.minorUnits), provenance: provenance),
                    provenance: provenance, createdAtUnixMilliseconds: 1),
                transactionTotal: made.amount, flow: .spend))
        }
    }
    for transaction in source.transactions { markers.append(try marker(transaction.id, transaction.minute, transaction.minorUnits)) }
    return DayTimelineBuilder.build(DayTimelineInput(
        day: source.day, timeZone: zone, calendars: [CalendarDescriptor(id: calendarID, title: "약속")],
        events: events, life: try LifeState.empty.applying(changes), transactions: markers
    ))
}

private let columnWidth: CGFloat = (402 - 60) / 2
private let layoutWidth: CGFloat = 60 + columnWidth
private let contentWidth: CGFloat = columnWidth - 6

private func strip(_ timelines: [DayTimeline]) -> [StripDay] { timelines.map { StripDay(day: $0.day, timeline: $0) } }

private struct Drawn {
    let plans: [DayRenderPlan]
    let timelines: [DayTimeline]
}

/// Browse as it is: the engine decides the axis from a budget; `TimelineGeometry` is that axis.
private func classic(_ shown: [DayTimeline], height: CGFloat, scale: CGFloat) -> Drawn {
    let layout = AdaptiveLayoutEngine.layout(AllocationInput(main: AllocationDay(shown[0]), secondary: AllocationDay(shown[1]), viewportHeight: height, contentWidth: contentWidth, textScale: scale))
    let geometry = TimelineGeometry(axis: layout.axis)
    let plans = [DayRole.main, .secondary].enumerated().map { index, role in
        DayRenderPlan(timeline: shown[index], role: role, layout: layout, geometry: geometry, layoutWidth: layoutWidth, textScale: scale, metrics: .standard(scale: scale), titleWidth: { _ in 40 })
    }
    return Drawn(plans: plans, timelines: shown)
}

@MainActor
private func fixed(_ days: [DayTimeline], zone: DisplayTimeZone = seoul, height: CGFloat, scale: CGFloat, model: FixedGridBrowseModel = FixedGridBrowseModel()) throws -> (Drawn, FixedGridWindow) {
    let environment = FixedGridEnvironment(viewportHeight: height, contentWidth: contentWidth, textScale: scale)
    let window = try #require(model.window(strip: strip(days), zone: zone, environment: environment))
    let plans = [DayRole.main, .secondary].enumerated().map { index, role in
        DayRenderPlan(
            prepared: DayRenderPlan.Prepared(timeline: days[index + 1], role: role, layout: window.layout), geometry: model.axis(for: days[index + 1].day, partition: window.partition, zone: zone),
            layoutWidth: layoutWidth, textScale: scale, metrics: .standard(scale: scale), titleWidth: { window.titleWidths[$0] ?? 40 }
        )
    }
    return (Drawn(plans: plans, timelines: [days[1], days[2]]), window)
}

private func transactionIDs(_ plan: DayRenderPlan) -> [String] {
    plan.lines.map(\.id) + plan.overflows.flatMap { $0.members.map(\.transactionID) } + plan.events.flatMap { $0.insideRows.map { $0.transactionID.rawValue } }
}

private func visibleTitles(_ plan: DayRenderPlan) -> Int { plan.events.filter { $0.presentation.title > 0.99 }.count }

// MARK: The flag

@Test func theFixedGridIsTheDefaultAndOnlyTheLaunchArgumentBringsBackTheClassicBrowse() {
    #expect(BrowseAxisMode.resolve(arguments: []) == .fixedGrid)
    #expect(BrowseAxisMode.resolve(arguments: ["-demo", "-demo-trans"]) == .fixedGrid)
    #expect(BrowseAxisMode.resolve(arguments: ["-demo", "-browse-temporal"]) == .fixedGrid)      // the old switch still works and changes nothing
    #expect(BrowseAxisMode.resolve(arguments: ["-demo", "-browse-classic"]) == .classic)         // DEBUG builds (these tests) read it
    #expect(BrowseAxisMode.current == .fixedGrid)                                                // the test process was not launched with it
}

// MARK: Equivalence of what is drawn

@MainActor
@Test func everyFixtureKeepsEveryEventAndTransactionItsTimeItsLinksAndAWayToTouchItOnTheFixedGrid() throws {
    var rows: [String] = []
    for scenario in TemporalGridFixtures.all {
        let days = try scenario.days.prefix(6).map { try fixtureTimeline($0) }
        let window = Array(days[1...4])                                    // D-1, D, D+1, D+2 with D = days[2]
        let height = scenario.viewportHeight
        let scale = scenario.textScale
        let old = classic([window[1], window[2]], height: height, scale: scale)
        let (new, grid) = try fixed(window, height: height, scale: scale)

        for index in 0..<2 {
            let day = new.timelines[index]
            let a = old.plans[index], b = new.plans[index]
            // The same events, once each, with the very same block (time, links, state).
            #expect(a.events.map(\.block) == b.events.map(\.block) && b.events.map(\.block.id).sorted { $0.rawValue < $1.rawValue } == day.blocks.map(\.id).sorted { $0.rawValue < $1.rawValue }, "\(scenario.name)")
            // The same transactions, each exactly once, whether it is a line, in an overflow or inside an event.
            #expect(transactionIDs(a).sorted() == transactionIDs(b).sorted(), "\(scenario.name)")
            #expect(Set(transactionIDs(b)).count == transactionIDs(b).count, "\(scenario.name) duplicates")
            // Links: what an event holds is what it holds.
            for item in b.events { #expect(Set(item.insideRows.map(\.transactionID)).isSubset(of: Set(item.block.allocations.map(\.transactionID)))) }
            // Real times: an event's top and bottom are where its own start and end are on the axis, never moved for text.
            let axis = FixedGridBrowseModel().axis(for: day.day, partition: grid.partition, zone: seoul)
            for item in b.events {
                #expect(abs(item.frame.minY - axis.y(minute: item.block.startMinute)) < 1e-6, "\(scenario.name) \(item.block.title) top")
                #expect(abs(item.frame.maxY - axis.y(bottomOfSpanFrom: item.block.startMinute, to: item.block.endMinute)) < 1e-6 || item.frame.height == axis.minimumBlockHeight, "\(scenario.name) bottom")
            }
            for line in b.lines { if let y = line.anchorY { #expect(y >= 0 && y <= grid.partition.totalHeight + 1) } }
            // Touch: 44 pt, a way to every event, and a name for VoiceOver.
            for item in b.events {
                #expect(item.touchFrame.height >= 44 - 1e-6, "\(scenario.name) touch")
                #expect(!item.block.title.isEmpty)
            }
            for line in b.lines { #expect(line.touchFrame.height >= 44 - 1e-6 && !TransactionLineView.accessibilityText(line).isEmpty) }
            for overflow in b.overflows { #expect(overflow.touchFrame.height >= 44 - 1e-6 && !OverflowCardView.accessibilityText(overflow).isEmpty) }
            #expect(try reachableEvents(b) == Set(b.events.map(\.block.id)), "\(scenario.name) reachable")
        }
        rows.append("| \(scenario.name) | \(old.plans.map(visibleTitles).reduce(0, +)) | \(new.plans.map(visibleTitles).reduce(0, +)) | \(old.plans.map { $0.events.count }.reduce(0, +)) | \(new.plans.map { $0.lines.count + $0.overflows.count }.reduce(0, +)) / \(old.plans.map { $0.lines.count + $0.overflows.count }.reduce(0, +)) |")
    }
    print("MEASURE browse-fixed-grid titles (old/new), events, transaction lines+overflows (new/old)\n" + rows.joined(separator: "\n"))
}

/// Every event can be reached by some touch on its touch area: by itself, or offered in a choice.
private func reachableEvents(_ plan: DayRenderPlan) throws -> Set<BlockID> {
    var reached = Set<BlockID>()
    for item in plan.events {
        let frame = item.touchFrame
        for fx in stride(from: 0.05, through: 0.96, by: 0.1) {
            for fy in stride(from: 0.05, through: 0.96, by: 0.1) {
                switch plan.hit(at: CGPoint(x: frame.minX + frame.width * fx, y: frame.minY + frame.height * fy)) {
                case let .event(id): reached.insert(id)
                case let .choose(candidates): for case let .event(id) in candidates { reached.insert(id) }
                default: break
                }
            }
        }
    }
    return reached
}

@MainActor
@Test func overlappingEventsAreEachSelectableAndTouchingOneOpensItsDetails() throws {
    let scenario = try #require(TemporalGridFixtures.all.first { $0.name.hasPrefix("7 ") })
    let days = try scenario.days.prefix(6).map { try fixtureTimeline($0) }
    let (drawn, _) = try fixed(Array(days[1...4]), height: 640, scale: 1)
    let plan = drawn.plans[0]
    let day = drawn.timelines[0]
    #expect(plan.events.count == 5)
    var opened = Set<BlockID>()
    for item in plan.events {
        let probe = CGPoint(x: item.drawnFrame.midX, y: item.drawnFrame.midY)
        var candidates: [DayRenderPlan.Candidate] = []
        switch plan.hit(at: probe) {
        case let .event(id): candidates = [.event(id)]
        case let .choose(found): candidates = found
        default: break
        }
        for candidate in candidates {
            if case let .event(id) = candidate, case let .event(block)? = FixedGridTouch.selection(for: candidate, in: day, plan: plan) {
                #expect(block.id == id && TimelineSelection.event(block).id == "event-" + id.rawValue)
                opened.insert(id)
            }
        }
    }
    #expect(opened.count >= 3)                                                    // the overlapped ones reached from their own centres; the rest through `reachableEvents`
    #expect(try reachableEvents(plan) == Set(plan.events.map(\.block.id)))
}

@MainActor
@Test func everyKindOfTouchOpensTheSameSheetItOpensInBrowse() throws {
    let scenario = try #require(TemporalGridFixtures.all.first { $0.name.hasPrefix("17 ") })
    let days = try scenario.days.prefix(6).map { try fixtureTimeline($0) }
    let (drawn, _) = try fixed(Array(days[1...4]), height: 640, scale: 1)
    let plan = drawn.plans[0], day = drawn.timelines[0]
    var kinds = Set<String>()
    for overflow in plan.overflows {
        if case let .overflow(selection)? = FixedGridTouch.selection(for: .overflow(overflow.id), in: day, plan: plan) {
            #expect(selection.rows.count == overflow.members.count)
            kinds.insert("overflow")
        }
    }
    for line in plan.lines {
        let selection = FixedGridTouch.selection(for: .line(line.id), in: day, plan: plan)
        if case let .marker(marker)? = selection { #expect(marker.transactionID.rawValue == line.id); kinds.insert("marker") }
    }
    #expect(kinds.contains("marker") || kinds.contains("overflow"))
    // A linked transaction on its own line opens the allocation sheet with the event it belongs to.
    let linked = try #require(TemporalGridFixtures.all.first { $0.name.hasPrefix("15 ") })
    let linkedDays = try linked.days.prefix(6).map { try fixtureTimeline($0) }
    let (linkedDrawn, _) = try fixed(Array(linkedDays[1...4]), height: 640, scale: 1)
    let lines = linkedDrawn.plans[0].lines.filter { $0.link != nil || $0.linkedEventTitle != nil }
    for line in lines {
        let selection = FixedGridTouch.selection(for: .line(line.id), in: linkedDrawn.timelines[0], plan: linkedDrawn.plans[0])
        if case .allocation(_, let title)? = selection { #expect(title == line.linkedEventTitle) } else if case .marker? = selection {} else { Issue.record("no selection for \(line.id)") }
    }
}

// MARK: Nothing per frame

@MainActor
@Test func theGridIsPlannedOnceAndNoFrameRunsThePlannerTheEngineOrTheDayAnalysis() throws {
    let scenario = try #require(TemporalGridFixtures.all.first { $0.name.hasPrefix("18 ") })     // 32 events
    let days = try scenario.days.prefix(6).map { try fixtureTimeline($0) }
    let window = Array(days[1...4])
    let model = FixedGridBrowseModel()
    let preparations = DayPlanPreparations()
    let environment = FixedGridEnvironment(viewportHeight: 640, contentWidth: contentWidth, textScale: 1)
    func frame(_ timelines: [DayTimeline], _ environment: FixedGridEnvironment) throws {
        let grid = try #require(model.window(strip: strip(timelines), zone: seoul, environment: environment))
        for index in 1...2 {
            let prepared = preparations.prepared(timeline: timelines[index], role: index == 1 ? .main : .secondary, layout: grid.layout)
            _ = DayRenderPlan(prepared: prepared, geometry: model.axis(for: timelines[index].day, partition: grid.partition, zone: seoul), layoutWidth: layoutWidth, titleWidth: { grid.titleWidths[$0] ?? 40 })
        }
    }
    for _ in 0..<300 { try frame(window, environment) }                  // redraws, scroll offsets, swipe offsets: nothing the plan depends on changes
    #expect(model.windowRuns == 1 && model.layoutRuns == 1 && model.store.planRuns == 1 && model.windowHits == 299)
    #expect(preparations.preparations == 2 && preparations.hits == 598)

    // Moving on one day plans the next window once (and prepares its two shown days again); nothing else.
    let moved = Array(days[2...5])
    for _ in 0..<50 { try frame(moved, environment) }
    #expect(model.windowRuns == 2 && model.layoutRuns == 2 && model.store.planRuns == 2)
    #expect(preparations.preparations == 4)          // new roles and a new layout: both shown days are prepared again, once

    // A different text size or room is a different window.
    try frame(moved, FixedGridEnvironment(viewportHeight: 560, contentWidth: contentWidth, textScale: 1))
    #expect(model.windowRuns == 3)
}

@MainActor
@Test func theCostOfAFrameOnTheFixedGridIsAPlacementNotAPlan() throws {
    var lines: [String] = []
    for name in ["18 ", "17 ", "14 ", "19 "] {
        let scenario = try #require(TemporalGridFixtures.all.first { $0.name.hasPrefix(name) })
        let days = try scenario.days.prefix(6).map { try fixtureTimeline($0) }
        let window = Array(days[1...4])
        let scale = scenario.textScale
        let model = FixedGridBrowseModel(), preparations = DayPlanPreparations()
        let environment = FixedGridEnvironment(viewportHeight: 640, contentWidth: contentWidth, textScale: scale)
        let start = CACurrentMediaTime()
        let grid = try #require(model.window(strip: strip(window), zone: seoul, environment: environment))
        let first = (CACurrentMediaTime() - start) * 1000
        let frames = 200
        let begin = CACurrentMediaTime()
        for _ in 0..<frames {
            let again = try #require(model.window(strip: strip(window), zone: seoul, environment: environment))
            for index in 1...2 {
                let prepared = preparations.prepared(timeline: window[index], role: index == 1 ? .main : .secondary, layout: again.layout)
                _ = DayRenderPlan(prepared: prepared, geometry: model.axis(for: window[index].day, partition: again.partition, zone: seoul), layoutWidth: layoutWidth, textScale: scale, titleWidth: { grid.titleWidths[$0] ?? 40 })
            }
        }
        let perFrame = (CACurrentMediaTime() - begin) * 1000 / Double(frames)
        lines.append(String(format: "%@: first window %.1f ms (planner + engine, once), frame %.3f ms (window lookup + 2 placements)", scenario.name, first, perFrame))
        #expect(perFrame < 8.3)
    }
    print("MEASURE browse-fixed-grid frame cost\n" + lines.joined(separator: "\n"))
}

// MARK: Daylight saving, midnight, several days

@MainActor
@Test func aDaylightSavingDayIsDrawnOnTheWallClockAxisWithEveryEventAndTransactionAndNeverConvertedToAnotherInstant() throws {
    for (day, hours) in [(try LocalDate(year: 2026, month: 3, day: 8), 23), (try LocalDate(year: 2026, month: 11, day: 1), 25)] {
        let start = newYork.dayBounds(day).start
        func make(_ date: LocalDate, spans: [(Int, Int)], transactions: [Int]) throws -> DayTimeline {
            let begin = newYork.dayBounds(date).start
            let events = try spans.enumerated().map { index, span in
                CalendarEvent(id: CalendarEventID(rawValue: "e\(index)"), calendarID: calendarID, title: "일정 \(index)",
                              time: .timed(try TimedRange(startUnixMilliseconds: begin + Int64(span.0) * 60_000, endUnixMilliseconds: begin + Int64(span.1) * 60_000)), revisionToken: "r")
            }
            let markers = try transactions.map { minute in
                TransactionMarker(id: LedgerEntryID(rawValue: "t\(minute)"), occurredAtUnixMilliseconds: begin + Int64(minute) * 60_000, amount: try Money(minorUnits: 3_000, currency: "KRW"), flow: .spend, title: "상점")
            }
            return DayTimelineBuilder.build(DayTimelineInput(day: date, timeZone: newYork, calendars: [CalendarDescriptor(id: calendarID, title: "약속")], events: events, life: .empty, transactions: markers))
        }
        _ = start
        let total = hours * 60
        let days = [
            try make(day.adding(days: -1), spans: [(60, 120)], transactions: [30]),
            try make(day, spans: [(0, 90), (120, 180), (150, 170), (total - 120, total)], transactions: [60, 125, 155, 200]),
            try make(day.adding(days: 1), spans: [(600, 660)], transactions: [700]),
            try make(day.adding(days: 2), spans: [], transactions: []),
        ]
        let model = FixedGridBrowseModel()
        let (drawn, grid) = try fixed(days, zone: newYork, height: 640, scale: 1, model: model)
        #expect(grid.layout == nil)                                                       // such a day is drawn without the engine's decisions (WallClockProjection's contract)
        #expect(grid.partition.boundaries.first == 0 && grid.partition.boundaries.last == 1440)
        let plan = drawn.plans[0]
        #expect(plan.events.count == 4 && Set(transactionIDs(plan)) == ["t60", "t125", "t155", "t200"])
        let axis = model.axis(for: day, partition: grid.partition, zone: newYork)
        #expect(axis.totalMinutes == total)
        // The first and last events touch the edges of the wall-clock axis.
        let byTitle = Dictionary(uniqueKeysWithValues: plan.events.map { ($0.block.title, $0.frame) })
        #expect(abs(byTitle["일정 0"]!.minY) < 1e-6 && abs(byTitle["일정 3"]!.maxY - grid.partition.totalHeight) < 1.5)
        // An axis on which two instants share a position never saves a time from one.
        #expect(axis.preservesInstantIdentity == (hours != 25))
        // No event's own instants were rewritten: the blocks are the ones the timeline built.
        #expect(plan.events.map(\.block).sorted { $0.title < $1.title } == days[1].blocks.sorted { $0.title < $1.title })
    }
}

@MainActor
@Test func aMultiDayEventAndOneAtMidnightKeepTheirEdgesOnTheFixedAxis() throws {
    let day = try LocalDate(year: 2027, month: 3, day: 10)
    func make(_ date: LocalDate) throws -> DayTimeline {
        let start = seoul.dayBounds(day).start
        let range = try TimedRange(startUnixMilliseconds: start - 3 * 3_600_000, endUnixMilliseconds: start + 2 * 86_400_000 + 3_600_000)      // from the evening before to the morning after next
        let events = [
            CalendarEvent(id: CalendarEventID(rawValue: "long"), calendarID: calendarID, title: "여러 날", time: .timed(range), revisionToken: "r"),
            CalendarEvent(id: CalendarEventID(rawValue: "late"), calendarID: calendarID, title: "자정까지", time: .timed(try TimedRange(startUnixMilliseconds: start + 22 * 3_600_000, endUnixMilliseconds: start + 24 * 3_600_000)), revisionToken: "r"),
        ]
        return DayTimelineBuilder.build(DayTimelineInput(day: date, timeZone: seoul, calendars: [CalendarDescriptor(id: calendarID, title: "약속")], events: events, life: .empty, transactions: []))
    }
    let days = try (-1...2).map { try make(day.adding(days: $0)) }
    let (drawn, grid) = try fixed(days, height: 640, scale: 1)
    for index in 0..<2 {
        let plan = drawn.plans[index]
        let long = try #require(plan.events.first { $0.block.title == "여러 날" })
        #expect(long.block.continuesFromPreviousDay && long.block.continuesToNextDay == (index == 0 ? true : false) || index == 1)
        #expect(abs(long.frame.minY) < 1e-6 && abs(long.frame.maxY - grid.partition.totalHeight) < 1.5)       // clamped to the day: the whole axis
    }
    let late = try #require(drawn.plans[0].events.first { $0.block.title == "자정까지" })
    #expect(abs(late.frame.maxY - grid.partition.totalHeight) < 1.5)
}
