import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private func build(
    _ events: [CalendarEvent],
    life: LifeState = .empty,
    transactions: [TransactionMarker] = [],
    on date: LocalDate = today,
    zone: DisplayTimeZone = seoul,
    policy: TimelineDisplayPolicy = .standard
) -> DayTimeline {
    DayTimelineBuilder.build(DayTimelineInput(
        day: date, timeZone: zone, calendars: defaultCalendars, events: events, life: life,
        transactions: transactions, policy: policy
    ))
}

/// `links` are (transaction, activity, transaction total): each assigns the whole transaction to the activity.
private func lifeWith(activities: [(String, CalendarEvent)], links: [(String, String, Int64)] = [], extra: [LifeChange] = []) -> LifeState {
    var changes: [LifeChange] = activities.map {
        .createActivity(Activity.materialized(from: $0.1, id: ActivityID(rawValue: $0.0), at: 1))
    }
    changes += links.map { wholeAllocation($0.0, to: $0.1, total: $0.2) }
    return try! LifeState.empty.applying(changes + extra)
}

private func clock(_ hour: Int, _ minute: Int = 0, on date: LocalDate = today) -> Int64 { at(date, hour, minute) }

@Test func theProductExampleDayRendersEventsLinkedSpendingAndAnUnlinkedTaxi() {
    let classEvent = event("class", calendar: "school", title: "수업", from: clock(10), to: clock(11, 30))
    let lunch = event("lunch", title: "점심", from: clock(12), to: clock(13))
    let lab = event("lab", calendar: "school", title: "연구실", from: clock(14), to: clock(17))
    let date = event("date", title: "데이트", from: clock(19), to: clock(22))
    let life = lifeWith(
        activities: [("a-lunch", lunch), ("a-lab", lab)],
        links: [("t-lunch", "a-lunch", 9_500), ("t-cafe", "a-lab", 5_800)]
    )
    let transactions = [
        marker("t-lunch", at: clock(12, 20), amount: 9_500, title: "식당"),
        marker("t-cafe", at: clock(14, 40), amount: 5_800, title: "카페"),
        marker("t-taxi", at: clock(22, 5), amount: 13_200, title: "택시")
    ]
    let timeline = build([date, lab, classEvent, lunch], life: life, transactions: transactions)

    #expect(timeline.blocks.map(\.title) == ["수업", "점심", "연구실", "데이트"])
    #expect(timeline.blocks.map(\.startMinute) == [600, 720, 840, 1_140])
    #expect(timeline.blocks.map(\.endMinute) == [690, 780, 1_020, 1_320])
    #expect(timeline.blocks.allSatisfy { $0.layout == OverlapLayout(column: 0, columnCount: 1) })

    let lunchBlock = timeline.blocks[1]
    #expect(lunchBlock.allocations.map(\.transactionID) == [txID("t-lunch")])
    #expect(lunchBlock.allocations.first?.title == "식당")
    #expect(lunchBlock.allocatedSpend.first?.exactMinorUnits == 9_500)
    #expect(lunchBlock.allocatedSpend.first?.isFullyKnown == true)
    #expect(lunchBlock.activity?.activityID == ActivityID(rawValue: "a-lunch"))
    #expect(timeline.blocks[2].allocatedSpend.first?.exactMinorUnits == 5_800)
    #expect(timeline.blocks[0].activity == nil && timeline.blocks[0].allocations.isEmpty)   // no Activity is normal

    #expect(timeline.markers.map(\.transactionID) == [txID("t-taxi")])
    #expect(timeline.markers.first?.allocations.isEmpty == true)             // unallocated is a normal state
    #expect(timeline.markers.first?.positionMinute == 22 * 60 + 5)

    #expect(timeline.summary.eventCount == 4)
    #expect(timeline.summary.unlinkedTransactionCount == 1)
    #expect(timeline.summary.totals.count == 1)
    #expect(timeline.summary.totals.first?.currency == "KRW")
    #expect(timeline.summary.totals.first?.linkedNetMinorUnits == 15_300)
    #expect(timeline.summary.totals.first?.unlinkedNetMinorUnits == 13_200)
}

@Test func calendarNameAndColorComeFromTheDescriptorNotTheEvent() {
    let blocks = build([
        event("a", calendar: "school", title: "수업", from: clock(9), to: clock(10)),
        event("b", calendar: "unknown", title: "정체불명", from: clock(11), to: clock(12))
    ]).blocks
    #expect(blocks[0].calendarTitle == "학교" && blocks[0].calendarColorHex == "#2E7D32")
    #expect(blocks[1].calendarTitle == nil && blocks[1].calendarColorHex == nil)
}

@Test func overlappingEventsShareAClusterAndGetDistinctColumns() {
    let events = [
        event("a", title: "A", from: clock(10), to: clock(12)),
        event("b", title: "B", from: clock(11), to: clock(13)),
        event("c", title: "C", from: clock(12), to: clock(14)),
        event("d", title: "D", from: clock(15), to: clock(16))
    ]
    let layouts = Dictionary(uniqueKeysWithValues: build(events).blocks.map { ($0.title, $0.layout) })
    #expect(layouts["A"] == OverlapLayout(column: 0, columnCount: 2))
    #expect(layouts["B"] == OverlapLayout(column: 1, columnCount: 2))
    #expect(layouts["C"] == OverlapLayout(column: 0, columnCount: 2))   // reuses A's column once A has ended
    #expect(layouts["D"] == OverlapLayout(column: 0, columnCount: 1))   // a new cluster
}

@Test func threeWayOverlapUsesThreeColumns() {
    let layouts = Dictionary(uniqueKeysWithValues: build([
        event("a", title: "A", from: clock(10), to: clock(12)),
        event("b", title: "B", from: clock(10, 30), to: clock(12)),
        event("c", title: "C", from: clock(11), to: clock(12))
    ]).blocks.map { ($0.title, $0.layout) })
    #expect(layouts["A"]?.columnCount == 3 && layouts["B"]?.columnCount == 3 && layouts["C"]?.columnCount == 3)
    #expect(Set([layouts["A"]?.column, layouts["B"]?.column, layouts["C"]?.column]).count == 3)
}

@Test func equalStartsPlaceTheLongerEventFirst() {
    let blocks = build([
        event("short", title: "짧은", from: clock(10), to: clock(11)),
        event("long", title: "긴", from: clock(10), to: clock(12))
    ]).blocks
    #expect(blocks.map(\.title) == ["긴", "짧은"])
    #expect(blocks[0].layout.column == 0 && blocks[1].layout.column == 1)
}

@Test func touchingEventsDoNotOverlap() {
    let blocks = build([
        event("a", title: "A", from: clock(10), to: clock(11)),
        event("b", title: "B", from: clock(11), to: clock(12))
    ]).blocks
    #expect(blocks.allSatisfy { $0.layout == OverlapLayout(column: 0, columnCount: 1) })
}

@Test func outputDoesNotDependOnInputOrder() {
    let events = (0..<8).map { index in
        event("e\(index)", title: "E\(index)", from: clock(9 + index / 2), to: clock(10 + index / 2 + index % 3))
    }
    let transactions = [marker("t1", at: clock(9, 30), amount: 1_000), marker("t2", at: clock(9, 30), amount: 2_000)]
    let forward = build(events, transactions: transactions)
    #expect(forward == build(events.reversed(), transactions: transactions.reversed()))
    #expect(forward == build(events.shuffledDeterministically(), transactions: transactions))
}

@Test func anEventSpanningMidnightIsClippedOnBothDays() {
    let overnight = event("night", title: "야간", from: clock(23), to: clock(1, on: today.adding(days: 1)))
    let first = build([overnight]).blocks[0]
    #expect(first.startMinute == 23 * 60 && first.endMinute == 1_440)
    #expect(first.continuesToNextDay && !first.continuesFromPreviousDay)
    #expect(first.endUnixMilliseconds == overnight.timedEnd)          // the real range is not clipped

    let second = build([overnight], on: today.adding(days: 1)).blocks[0]
    #expect(second.startMinute == 0 && second.endMinute == 60)
    #expect(second.continuesFromPreviousDay && !second.continuesToNextDay)
}

@Test func eventsOutsideTheDayAreIgnoredAndBoundaryEdgesAreExclusive() {
    let bounds = seoul.dayBounds(today)
    let events = [
        event("ends-at-start", from: bounds.start - 3_600_000, to: bounds.start),
        event("starts-at-end", from: bounds.end, to: bounds.end + 3_600_000),
        event("yesterday", from: bounds.start - 7_200_000, to: bounds.start - 3_600_000),
        event("inside", title: "안", from: clock(8), to: clock(9))
    ]
    #expect(build(events).blocks.map(\.title) == ["안"])
}

@Test func veryShortEventsGetAMinimumVisualHeightWithoutChangingTheEvent() {
    let blip = event("blip", title: "잠깐", from: clock(12), to: clock(12, 5))
    let block = build([blip]).blocks[0]
    #expect(block.startMinute == 720 && block.endMinute == 725)
    #expect(block.displayStartMinute == 720 && block.displayEndMinute == 735)
    #expect(block.endUnixMilliseconds == blip.timedEnd)
}

@Test func theVisualFloorNeverOverrunsTheEndOfTheDay() {
    let late = event("late", title: "막차", from: clock(23, 55), to: seoul.dayBounds(today).end)
    let block = build([late]).blocks[0]
    #expect(block.displayEndMinute == 1_440)
    #expect(block.displayStartMinute == 1_425)
    #expect(block.startMinute == 1_435)
}

@Test func shortAdjacentEventsThatWouldVisuallyCollideGetSeparateColumns() {
    let blocks = build([
        event("a", title: "A", from: clock(12), to: clock(12, 5)),
        event("b", title: "B", from: clock(12, 10), to: clock(12, 15))
    ]).blocks
    #expect(blocks[0].layout.columnCount == 2 && blocks[1].layout.columnCount == 2)
    #expect(blocks[0].layout.column != blocks[1].layout.column)
}

@Test func allDayEventsAreListedSeparatelyWithPerDayPosition() {
    let trip = allDayEvent("trip", title: "여행", from: today.adding(days: -1), to: today.adding(days: 1))
    let holiday = allDayEvent("holiday", calendar: "readonly", title: "공휴일", from: today, to: today)
    let elsewhere = allDayEvent("later", title: "다음주", from: today.adding(days: 7), to: today.adding(days: 7))
    let timeline = build([elsewhere, holiday, trip])
    #expect(timeline.blocks.isEmpty)
    #expect(timeline.allDay.map(\.title) == ["여행", "공휴일"])    // the longer event first among those starting earlier
    #expect(timeline.allDay[0].isFirstDayOfEvent == false && timeline.allDay[0].isLastDayOfEvent == false)
    #expect(timeline.allDay[1].isFirstDayOfEvent && timeline.allDay[1].isLastDayOfEvent)
    #expect(timeline.summary.allDayCount == 2)
    let firstDay = build([trip], on: today.adding(days: -1)).allDay[0]
    #expect(firstDay.isFirstDayOfEvent && !firstDay.isLastDayOfEvent)
}

@Test func allDayOrderingIsLongerFirstThenStable() {
    let events = [
        allDayEvent("b", title: "B", from: today, to: today),
        allDayEvent("a", title: "A", from: today, to: today.adding(days: 3)),
        allDayEvent("c", title: "C", from: today, to: today)
    ]
    #expect(build(events).allDay.map(\.title) == ["A", "B", "C"])
}

@Test func aTransactionLinkIsMeaningNotTimeContainment() {
    // The date is today at 19:00; the movie ticket was bought yesterday evening.
    let date = event("date", title: "데이트", from: clock(19), to: clock(22))
    let ticketTime = clock(18, on: today.adding(days: -1))
    let life = lifeWith(activities: [("a-date", date)], links: [("t-ticket", "a-date", 14_000)])
    let timeline = build([date], life: life, transactions: [marker("t-ticket", at: ticketTime, amount: 14_000, title: "영화표")])

    let block = timeline.blocks[0]
    #expect(block.allocations.count == 1)
    #expect(block.allocations[0].occursOnSelectedDay == false)
    #expect(block.allocatedSpend.first?.exactMinorUnits == 14_000)
    #expect(timeline.markers.isEmpty)                         // it is inside the activity, not a stray marker
    #expect(timeline.summary.totals.isEmpty)                  // and it is not today's spending
    #expect(timeline.summary.unlinkedTransactionCount == 0)
}

@Test func aLinkedTransactionWhoseActivityIsNotShownAppearsAsLinkedElsewhere() {
    let trip = event("trip", title: "여행", from: clock(9, on: today.adding(days: 1)), to: clock(18, on: today.adding(days: 1)))
    let life = lifeWith(activities: [("a-trip", trip)], links: [("t-ktx", "a-trip", 59_800)])
    let timeline = build([], life: life, transactions: [marker("t-ktx", at: clock(9), amount: 59_800, title: "KTX")])
    #expect(timeline.markers.count == 1)
    let elsewhere = timeline.markers[0].allocations
    #expect(elsewhere.count == 1)
    #expect(elsewhere[0].activityID == ActivityID(rawValue: "a-trip") && elsewhere[0].activityTitle == "여행")
    #expect(elsewhere[0].eventMissing == false && elsewhere[0].isShownToday == false)
    #expect(timeline.summary.totals.first?.linkedNetMinorUnits == 59_800)
    #expect(timeline.summary.totals.first?.unlinkedNetMinorUnits == 0)
    #expect(timeline.summary.unlinkedTransactionCount == 0)
}

@Test func anEventDeletedElsewhereStaysVisibleAsAGhostWithItsSpending() throws {
    let gone = event("gone", title: "취소된 모임", from: clock(15), to: clock(16))
    var life = lifeWith(activities: [("a-gone", gone)], links: [("t-food", "a-gone", 20_000)])
    let missing = CalendarEventAssociation(event: gone).markedMissing(at: 5)
    life = try life.applying([.updateAssociation(ActivityID(rawValue: "a-gone"), missing)])
    let transactions = [marker("t-food", at: clock(15, 30), amount: 20_000)]

    let shown = build([], life: life, transactions: transactions)
    #expect(shown.blocks.count == 1)
    #expect(shown.blocks[0].state == .eventMissing)
    #expect(shown.blocks[0].isEditable == false)
    #expect(shown.blocks[0].title == "취소된 모임")
    #expect(shown.blocks[0].allocatedSpend.first?.exactMinorUnits == 20_000)
    #expect(shown.markers.isEmpty)

    let hidden = build([], life: life, transactions: transactions, policy: TimelineDisplayPolicy(includeMissingEventGhosts: false))
    #expect(hidden.blocks.isEmpty)
    let hiddenAllocation = hidden.markers.first?.allocations.first
    #expect(hiddenAllocation?.activityID == ActivityID(rawValue: "a-gone") && hiddenAllocation?.activityTitle == "취소된 모임")
    #expect(hiddenAllocation?.eventMissing == true)
}

@Test func refundsSubtractFromNetSpendingAndAreMarkedAsRefunds() {
    let timeline = build([], transactions: [
        marker("spend", at: clock(10), amount: 10_000),
        marker("refund", at: clock(11), amount: 3_000, flow: .refund)
    ])
    #expect(timeline.summary.totals.first?.unlinkedNetMinorUnits == 7_000)
    #expect(timeline.markers.map(\.flow) == [.spend, .refund])
    #expect(timeline.summary.unlinkedTransactionCount == 2)
}

@Test func totalsAreKeptPerCurrency() {
    let usd = TransactionMarker(
        id: txID("usd"), occurredAtUnixMilliseconds: clock(10), amount: try! Money(minorUnits: 1_250, currency: "USD"), flow: .spend
    )
    let timeline = build([], transactions: [usd, marker("krw", at: clock(11), amount: 5_000)])
    #expect(timeline.summary.totals.map(\.currency) == ["KRW", "USD"])
}

@Test func theActivityBadgeCarriesTypeAreaAndTags() throws {
    let lunch = event("lunch", title: "점심", from: clock(12), to: clock(13))
    let life = try lifeWith(activities: [("a", lunch)], extra: [
        .upsertTag(OnAllTag(id: TagID(rawValue: "t1"), name: "뒤풀이")),
        .upsertArea(Area(id: AreaID(rawValue: "yeonnam"), displayName: "연남")),
        .setActivityType(ActivityID(rawValue: "a"), Assigned(.social, provenance: userProvenance())),
        .setActivityArea(ActivityID(rawValue: "a"), Assigned(AreaID(rawValue: "yeonnam"), provenance: userProvenance())),
        .setActivityTag(ActivityID(rawValue: "a"), TagAssignment(tagID: TagID(rawValue: "t1"), provenance: userProvenance()))
    ])
    let badge = build([lunch], life: life).blocks[0].activity
    #expect(badge?.activityType == .social)
    #expect(badge?.areaID == AreaID(rawValue: "yeonnam"))
    #expect(badge?.tagIDs == [TagID(rawValue: "t1")])
}

@Test func daylightSavingDaysUseTheirRealLength() {
    let date = day(2026, 3, 8)
    let threeToFour = event("dst", title: "DST", from: at(date, 3, 0, in: newYork), to: at(date, 4, 0, in: newYork))
    let timeline = build([threeToFour], on: date, zone: newYork)
    #expect(timeline.totalMinutes == 23 * 60)
    #expect(timeline.blocks[0].startMinute == 120)     // two real hours after midnight; 02:xx does not exist
    #expect(timeline.blocks[0].endMinute == 180)
    #expect(build([], on: day(2026, 11, 1), zone: newYork).totalMinutes == 25 * 60)
    #expect(build([], on: today).totalMinutes == 24 * 60)
}

@Test func recurringAndReadOnlyFlagsPassThrough() {
    let blocks = build([
        event("r", title: "반복", from: clock(9), to: clock(10), recurring: true),
        event("ro", calendar: "readonly", title: "읽기", from: clock(11), to: clock(12), editable: false)
    ]).blocks
    #expect(blocks[0].isRecurringInstance && blocks[0].isEditable)
    #expect(!blocks[1].isRecurringInstance && !blocks[1].isEditable)
}

@Test func theWeekStripSummarizesSevenDaysFromTheChosenFirstWeekday() {
    let wednesday = day(2026, 10, 7)
    let events = [
        event("e1", from: at(wednesday, 9), to: at(wednesday, 10)),
        event("e2", from: at(wednesday, 11), to: at(wednesday, 12)),
        allDayEvent("trip", from: day(2026, 10, 8), to: day(2026, 10, 9))
    ]
    let life = lifeWith(activities: [], links: [])
    let strip = WeekStripBuilder.build(
        containing: wednesday, firstWeekday: 0, timeZone: seoul, events: events, life: life,
        transactions: [marker("a", at: at(wednesday, 12), amount: 1_000), marker("b", at: at(day(2026, 10, 10), 8), amount: 2_000)]
    )
    #expect(strip.map(\.day) == (4...10).map { day(2026, 10, $0) })
    #expect(strip[3].eventCount == 2 && strip[4].eventCount == 1 && strip[5].eventCount == 1)
    #expect(strip[3].unlinkedTransactionCount == 1)
    #expect(strip[3].netSpend == [won(1_000)] && strip[6].netSpend == [won(2_000)])
    #expect(strip[0].netSpend.isEmpty)

    let mondayFirst = WeekStripBuilder.build(containing: wednesday, firstWeekday: 1, timeZone: seoul, events: [], life: life, transactions: [])
    #expect(mondayFirst.first?.day == day(2026, 10, 5) && mondayFirst.last?.day == day(2026, 10, 11))
}

// MARK: Helpers

private extension CalendarEvent {
    var timedEnd: Int64 {
        if case let .timed(range) = time { return range.endUnixMilliseconds }
        return 0
    }
}

private extension Array {
    /// A fixed permutation, so the test is reproducible without a random source.
    func shuffledDeterministically() -> [Element] {
        enumerated().sorted { ($0.offset * 7 + 3) % 11 < ($1.offset * 7 + 3) % 11 }.map(\.element)
    }
}

@Test func blocksCarryTheRevisionTheUserWasLookingAtAndGhostsCarryNone() throws {
    let live = CalendarEvent(
        id: eventID("live"), calendarID: calendarID("life"), title: "회의", time: .timed(timed(at(today, 10), at(today, 11))), revisionToken: "r7")
    let allDay = CalendarEvent(
        id: eventID("trip"), calendarID: calendarID("life"), title: "여행", time: .allDay(allDayRange(today, today)), revisionToken: "r9")
    let result = DayTimelineBuilder.build(DayTimelineInput(day: today, timeZone: seoul, events: [live, allDay], life: .empty, transactions: []))
    #expect(result.blocks.first?.revisionToken == "r7")
    #expect(result.allDay.first?.revisionToken == "r9")
}
