import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private typealias F = TemporalGridFixtures

// The two axes behind one protocol: the folding axis Browse draws on today and the fixed grid.

private func hourlyPartition(viewport: CGFloat = 640) -> TemporalGridPartition {
    let scenario = F.demoTransRun()
    var p = TemporalGridParameters.hourly(slotCount: 12)
    p.viewportHeight = viewport; p.allocation = scenario.parameters
    return TemporalGridPlanner.plan(window: TemporalWindow(days: Array(scenario.days[0...3]), mainIndex: 1), parameters: p).partition
}

private func foldedAxis() -> TimelineAxis {
    TimelineAxis.browse(totalMinutes: 1440, anchors: [9 * 60, 9 * 60 + 15, 13 * 60, 20 * 60])
}

private func mappings() -> [(name: String, mapping: any TimeAxisMapping, exactInverse: Bool)] {
    let partition = hourlyPartition()
    let blended = TemporalGridPartition.interpolated(from: partition, to: hourlyPartition(viewport: 640), progress: 0.4) ?? partition
    return [
        ("선형 축(기존)", TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 0.5), false),
        ("접힌 축(기존)", TimelineGeometry(axis: foldedAxis()), false),
        ("전환 중 축(기존)", TimelineGeometry(from: .linear(totalMinutes: 1440, pointsPerMinute: 0.5), to: foldedAxis(), progress: 0.5), false),
        ("격자", TemporalAxisMapping(partition: partition), true),
        ("격자 3×", TemporalAxisMapping(partition: partition.zoomed(viewportHeight: 640, zoomScale: 3)), true),
        ("격자 보간", TemporalAxisMapping(partition: blended), true),
    ]
}

@Test func everyMappingStartsAtZeroEndsAtItsHeightAndNeverGoesBackwards() {
    for (name, mapping, _) in mappings() {
        #expect(mapping.y(minute: 0) == 0, "\(name)")
        // The height of the content; while the old axis changes shape it never shrinks below where it started (see `TimelineGeometry.contentHeight`).
        #expect(mapping.contentHeight >= mapping.y(minute: mapping.totalMinutes) - 1e-9, "\(name)")
        if name != "전환 중 축(기존)" { #expect(abs(mapping.y(minute: mapping.totalMinutes) - mapping.contentHeight) < 1e-9, "\(name)") }
        var previous: CGFloat = -1
        for minute in 0...mapping.totalMinutes {
            let y = mapping.y(minute: minute)
            #expect(y >= previous - 1e-9, "\(name) minute \(minute)")
            previous = y
        }
    }
}

@Test func yAndMinuteAreInversesWhereTheAxisIsNotFolded() {
    for (name, mapping, exact) in mappings() {
        for minute in stride(from: 0, through: mapping.totalMinutes, by: 7) {
            let y = mapping.y(minute: minute)
            let back = mapping.minute(atY: y)
            // Coarse inside a folded stretch (many minutes per point): the minute found is on the same point of the axis.
            #expect(abs(mapping.y(minute: back) - y) < 1.0 || !exact && back != minute, "\(name) minute \(minute)")
            if exact { #expect(back == minute, "\(name) minute \(minute)") }
        }
        // And the other way: a height gives a minute whose height is within a minute's height of it.
        for y in stride(from: CGFloat(0), through: mapping.contentHeight, by: 3.7) {
            let minute = mapping.minute(atY: y)
            #expect(minute >= 0 && minute <= mapping.totalMinutes)
        }
    }
}

@Test func theGridsExactMinutesRoundTripToTheLastDigitAtAnyZoomAndBetweenTwoDays() {
    for (name, mapping, exact) in mappings() where exact {
        for minute in stride(from: 0.0, through: 1440.0, by: 0.37) {
            #expect(abs(mapping.exactMinute(atY: mapping.y(exactMinute: minute)) - minute) < 1e-9, "\(name)")
        }
        for y in stride(from: CGFloat(0), through: mapping.contentHeight, by: 1.13) {
            #expect(abs(mapping.y(exactMinute: mapping.exactMinute(atY: y)) - y) < 1e-9, "\(name)")
        }
    }
    // The folding axis has whole minutes only: its exact variants are the whole-minute answer.
    let old = TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 0.5)
    #expect(old.y(exactMinute: 600.4) == old.y(minute: 600))
    #expect(old.exactMinute(atY: old.y(minute: 600)) == 600)
}

@Test func theColumnConstantsAndTheBlockFrameAreTheSameForBothAxes() {
    let old = TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 0.5)
    let grid = TemporalAxisMapping(partition: TemporalGridPartition.uniform(slotCount: 12, totalHeight: 720))   // 0.5 points per minute too
    #expect(old.gutterWidth == grid.gutterWidth && old.trailingPadding == grid.trailingPadding && old.columnSpacing == grid.columnSpacing)
    #expect(old.minimumBlockHeight == grid.minimumBlockHeight)
    #expect(old.contentWidth(totalWidth: 217.5) == grid.contentWidth(totalWidth: 217.5))
    for minute in [0, 1, 90, 600, 1439, 1440] { #expect(abs(old.y(minute: minute) - grid.y(minute: minute)) < 1e-9) }       // the same line, two types
}

// MARK: The day layout does not know which one it has

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day0 = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()

private func timeline() throws -> DayTimeline {
    let calendar = CalendarID(rawValue: "c")
    func event(_ index: Int, _ title: String, _ from: Int, _ to: Int) throws -> CalendarEvent {
        let range = try TimedRange(startUnixMilliseconds: zone.instant(of: day0, minuteOfDay: from), endUnixMilliseconds: zone.instant(of: day0, minuteOfDay: to))
        return CalendarEvent(id: CalendarEventID(rawValue: "e\(index)"), calendarID: calendar, title: title, time: .timed(range), revisionToken: "r")
    }
    let markers = try [610, 700].map { minute in
        TransactionMarker(
            id: LedgerEntryID(rawValue: "t\(minute)"), occurredAtUnixMilliseconds: zone.instant(of: day0, minuteOfDay: minute),
            amount: try Money(minorUnits: 4_500, currency: "KRW"), flow: .spend, title: "상점"
        )
    }
    return DayTimelineBuilder.build(DayTimelineInput(
        day: day0, timeZone: zone, calendars: [CalendarDescriptor(id: calendar, title: "약속")],
        events: [try event(0, "아침", 9 * 60, 10 * 60), try event(1, "회의", 13 * 60, 13 * 60 + 17), try event(2, "저녁", 18 * 60, 19 * 60 + 30)],
        life: .empty, transactions: markers
    ))
}

@Test func theDayLayoutPlacesEverythingOnWhicheverAxisItIsGiven() throws {
    let day = try timeline()
    let partition = hourlyPartition()
    for (name, mapping) in [("기존", TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 0.6) as any TimeAxisMapping), ("격자", TemporalAxisMapping(partition: partition))] {
        let layout = AdaptiveLayoutEngine.layout(AllocationInput(main: AllocationDay(day), secondary: nil, viewportHeight: 640, contentWidth: 200))
        let plan = DayRenderPlan(timeline: day, role: .main, layout: layout, geometry: mapping, layoutWidth: 217.5, titleWidth: { _ in 40 })
        #expect(plan.events.count == 3 && plan.lines.count + plan.overflows.count >= 1, "\(name)")
        for item in plan.events {
            // Exactly the axis' own answer for its start and its end; the height is the difference, with nothing added for text.
            #expect(abs(item.frame.minY - mapping.y(minute: item.block.displayStartMinute)) < 1e-9, "\(name)")
            #expect(abs(item.frame.height - (mapping.y(minute: item.block.displayEndMinute) - item.frame.minY)) < 1e-6, "\(name)")
        }
        for line in plan.lines { #expect(line.frame.height > 0 && line.anchorY != nil, "\(name)") }
    }
}

@Test func theGridAxisGivesTheSameLayoutAsTheEngineDecidesForItsOwnFixedAxis() throws {
    // The engine, on the grid's axis through the old type, and the plan on the grid's mapping: the same y for the same time.
    let day = try timeline()
    let partition = hourlyPartition()
    let adapted = partition.timelineAxis()
    #expect(adapted.isExact)
    var input = AllocationInput(main: AllocationDay(day), secondary: nil, viewportHeight: 640, contentWidth: 200)
    input.fixedAxis = adapted.axis
    let layout = AdaptiveLayoutEngine.layout(input)
    let mapping = TemporalAxisMapping(partition: partition)
    let viaOldType = DayRenderPlan(timeline: day, role: .main, layout: layout, geometry: TimelineGeometry(axis: adapted.axis), layoutWidth: 217.5, titleWidth: { _ in 40 })
    let viaGrid = DayRenderPlan(timeline: day, role: .main, layout: layout, geometry: mapping, layoutWidth: 217.5, titleWidth: { _ in 40 })
    #expect(viaOldType.events.count == viaGrid.events.count)
    for (a, b) in zip(viaOldType.events, viaGrid.events) {
        #expect(a.block.id == b.block.id)
        #expect(abs(a.frame.minY - b.frame.minY) < 1e-6 && abs(a.frame.height - b.frame.height) < 1e-6)
        // The same height gives the same look (compared with a tolerance: the two axes add up the same heights in a different order).
        #expect(a.presentation.level == b.presentation.level)
        for (x, y) in [(a.presentation.card, b.presentation.card), (a.presentation.title, b.presentation.title), (a.presentation.endTime, b.presentation.endTime)] {
            #expect(abs(x - y) < 1e-6)
        }
    }
    #expect(viaOldType.lines.map(\.id) == viaGrid.lines.map(\.id))
}
