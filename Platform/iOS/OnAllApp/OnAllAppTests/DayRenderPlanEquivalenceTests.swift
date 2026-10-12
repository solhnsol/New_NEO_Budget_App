import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

// The day layout's output, over a spread of days, axes, text sizes, roles and focus states, written out in full and reduced to one digest per day. The
// digests were taken from the layout as it was before its static data was prepared apart from the axis-dependent part; the layout must keep producing the
// same plans, to the last digit of every frame, whichever way the work is divided.

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day0 = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let calendar = CalendarID(rawValue: "c")
private let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)

private func event(_ index: Int, _ from: Int, _ to: Int) throws -> CalendarEvent {
    let range = try TimedRange(startUnixMilliseconds: zone.instant(of: day0, minuteOfDay: from), endUnixMilliseconds: zone.instant(of: day0, minuteOfDay: min(to, 1439)))
    return CalendarEvent(id: CalendarEventID(rawValue: "e\(index)"), calendarID: calendar, title: "일정 \(index) 제목입니다", time: .timed(range), revisionToken: "r")
}

private func marker(_ id: String, _ minute: Int) throws -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day0, minuteOfDay: minute),
        amount: try Money(minorUnits: Int64(4_500 + minute), currency: "KRW"), flow: .spend, title: "상점 \(id)"
    )
}

/// `link`: transaction id -> index of the event it is linked to.
private func timeline(_ events: [CalendarEvent], _ transactions: [TransactionMarker], link: [String: Int] = [:]) throws -> DayTimeline {
    var changes: [LifeChange] = []
    for (id, index) in link.sorted(by: { $0.key < $1.key }) {
        let activityID = ActivityID(rawValue: "A\(index)")
        let source = try #require(events.first { $0.id.rawValue == "e\(index)" })
        if !changes.contains(where: { if case let .createActivity(activity) = $0 { return activity.id == activityID } else { return false } }) {
            changes.append(.createActivity(Activity.materialized(from: source, id: activityID, at: 1)))
        }
        let total = try #require(transactions.first { $0.id.rawValue == id }).amount
        changes.append(.upsertAllocation(
            TransactionAllocation(
                id: AllocationID(rawValue: "alloc-\(id)"), transactionID: LedgerEntryID(rawValue: id), activityID: activityID,
                amount: try AmountEntry(currency: "KRW", knowledge: .exact(total.minorUnits), provenance: provenance),
                provenance: provenance, createdAtUnixMilliseconds: 1),
            transactionTotal: total, flow: .spend))
    }
    return DayTimelineBuilder.build(DayTimelineInput(
        day: day0, timeZone: zone, calendars: [CalendarDescriptor(id: calendar, title: "약속")],
        events: events, life: try LifeState.empty.applying(changes), transactions: transactions
    ))
}

private struct Day {
    let name: String
    let timeline: DayTimeline
}

private func days() throws -> [Day] {
    var busyEvents = try (8..<20).map { try event($0, $0 * 60, $0 * 60 + 50) }
    busyEvents += [try event(40, 9 * 60 + 10, 9 * 60 + 30), try event(41, 13 * 60, 13 * 60 + 12)]
    var busyTransactions = try [("t9", 9 * 60), ("t12", 12 * 60), ("t15", 15 * 60), ("t18", 18 * 60 + 5), ("x1", 8 * 60 + 20), ("x2", 8 * 60 + 25), ("x3", 10 * 60 + 40)].map { try marker($0.0, $0.1) }
    busyTransactions.append(try marker("in1", 9 * 60 + 12))
    let busy = try timeline(busyEvents, busyTransactions, link: ["t9": 9, "t12": 12, "in1": 40, "x3": 9])
    let dense = try timeline([try event(1, 9 * 60, 10 * 60)], try (0..<30).map { try marker("d\($0)", 14 * 60 + $0 * 2) } + [try marker("same1", 14 * 60 + 10), try marker("same2", 14 * 60 + 10)])
    let overlapping = try timeline(
        [try event(1, 9 * 60, 17 * 60), try event(2, 10 * 60, 15 * 60), try event(3, 11 * 60, 14 * 60), try event(4, 12 * 60, 12 * 60 + 30), try event(5, 9 * 60 + 30, 11 * 60)],
        [try marker("o1", 12 * 60 + 10), try marker("o2", 16 * 60)], link: ["o1": 4]
    )
    let longAndShort = try timeline(
        [try event(1, 9 * 60, 18 * 60), try event(2, 10 * 60, 10 * 60 + 17), try event(3, 12 * 60, 12 * 60 + 5), try event(4, 0, 90), try event(5, 22 * 60, 1439)],
        [try marker("l1", 10 * 60 + 8), try marker("l2", 13 * 60), try marker("l3", 23 * 60 + 30)], link: ["l1": 2, "l3": 5]
    )
    let empty = try timeline([], [])
    return [Day(name: "busy", timeline: busy), Day(name: "dense", timeline: dense), Day(name: "overlapping", timeline: overlappingSelf(overlapping)), Day(name: "longAndShort", timeline: longAndShort), Day(name: "empty", timeline: empty)]
}

private func overlappingSelf(_ value: DayTimeline) -> DayTimeline { value }

private func fnv(_ text: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return String(hash, radix: 16)
}

private func describe(_ plan: DayRenderPlan, height: CGFloat) -> String {
    var out: [String] = []
    for item in plan.events {
        out.append("E \(item.block.id.rawValue) \(item.frame) \(item.drawnFrame) \(item.touchFrame) \(item.title) \(item.presentation) \(String(describing: item.header)) \(item.showsTitleInCard) rows=\(item.insideRows.map(\.allocationID.rawValue)) \(item.shownRows) \(item.hiddenRows) \(String(describing: item.titleMaxWidth)) \(item.insideAnchors) \(item.startTimeFits) \(String(describing: item.placement?.level))")
    }
    for line in plan.lines {
        out.append("L \(line.id) \(String(describing: line.display)) \(String(describing: line.link)) \(String(describing: line.linkedEventTitle)) \(line.frame) \(line.touchFrame) \(String(describing: line.anchorY)) \(line.reveal)")
    }
    for overflow in plan.overflows {
        out.append("O \(overflow.id) \(overflow.frame) \(overflow.touchFrame) \(String(describing: overflow.anchorY)) \(overflow.members.map(\.transactionID)) \(overflow.reveal) \(overflow.showsAmountTotal)")
    }
    var y: CGFloat = 0
    while y <= height {
        var x: CGFloat = 0
        while x <= 220 { out.append("H \(x) \(y) \(plan.hit(at: CGPoint(x: x, y: y)))"); x += 22 }
        y += max(9, height / 60)
    }
    return out.joined(separator: "\n")
}

private func geometries() -> [(name: String, geometry: any TimeAxisMapping)] {
    var partitionParameters = TemporalGridParameters.hourly(slotCount: 12)
    partitionParameters.viewportHeight = 640
    let scenario = TemporalGridFixtures.demoTransRun()
    let partition = TemporalGridPlanner.plan(window: TemporalWindow(days: Array(scenario.days[0...3]), mainIndex: 1), parameters: partitionParameters).partition
    return [
        ("linear", TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 0.6)),
        ("folded", TimelineGeometry(axis: TimelineAxis.browse(totalMinutes: 1440, anchors: [9 * 60, 10 * 60, 13 * 60, 14 * 60, 18 * 60, 22 * 60]))),
        ("grid", TemporalAxisMapping(partition: partition)),
        ("grid3x", TemporalAxisMapping(partition: partition.zoomed(viewportHeight: 640, zoomScale: 3))),
    ]
}

/// One digest line per combination, in a fixed order.
private func combinations(of day: Day) -> [(label: String, digest: String)] {
    var result: [(String, String)] = []
    let main = AllocationDay(day.timeline)
    for (geometryName, geometry) in geometries() {
        for scale in [1.0, 2.2] as [CGFloat] {
            let layouts: [(String, DayRole?, AdaptiveLayout?)] = {
                var input = AllocationInput(main: main, secondary: nil, viewportHeight: 640, contentWidth: 200, textScale: scale)
                for block in day.timeline.blocks { input.titleWidths[block.title] = DayContentLayout.estimatedTitleWidth(block.title, extra: 14) * scale }
                let alone = AdaptiveLayoutEngine.layout(input)
                var pair = input
                pair.secondary = AllocationDay(day.timeline)
                let both = AdaptiveLayoutEngine.layout(pair)
                return [("main", .main, alone), ("secondary", .secondary, both), ("none", nil, nil)]
            }()
            for (layoutName, role, layout) in layouts {
                let blocks = day.timeline.blocks
                let focusStates: [(String, BlockID?, BlockID?)] = [("plain", nil, nil), ("focused", blocks.first?.id, nil), ("expanded", nil, blocks.dropFirst().first?.id)]
                for (focusName, focused, expanded) in focusStates {
                    let plan = DayRenderPlan(
                        timeline: day.timeline, role: role, layout: layout, geometry: geometry, layoutWidth: 217.5, textScale: scale, expanded: expanded, focused: focused,
                        titleWidth: { DayContentLayout.estimatedTitleWidth($0, extra: 14) * scale }
                    )
                    result.append(("\(geometryName)/\(scale)/\(layoutName)/\(focusName)", fnv(describe(plan, height: min(geometry.contentHeight, 1200)))))
                }
            }
        }
    }
    return result
}

@Test func theDayLayoutProducesThePlansItAlwaysDid() throws {
    let expected: [String: String] = [
        "busy": "321e5f1e582104bc", "dense": "7ba4158276287d79", "overlapping": "2bd9c109a5de40e5", "longAndShort": "8038ae45e866a8b3", "empty": "6913f3cb5b16accc",
    ]
    for day in try days() {
        let list = combinations(of: day)
        for item in list { print("EQ|\(day.name)|\(item.label)|\(item.digest)") }
        let combined = fnv(list.map { "\($0.label)=\($0.digest)" }.joined(separator: ";"))
        print("EQ|\(day.name)|COMBINED|\(combined)")
        #expect(combined == expected[day.name], "\(day.name)")
    }
}
