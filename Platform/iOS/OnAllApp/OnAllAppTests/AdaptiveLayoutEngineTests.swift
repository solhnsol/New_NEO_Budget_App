import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

// All data here is synthetic: invented titles, ids and amounts.

private let mainDay = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let nextDay = mainDay.adding(days: 1)

private func ev(_ id: String, _ from: Int, _ to: Int, linked: Int = 0, kind: AmountKind = .spend) -> AllocationEvent {
    AllocationEvent(id: id, title: "일정 \(id)", startMinute: from, endMinute: to, linked: (0..<linked).map {
        AllocationTransaction(id: "\(id)-l\($0)", minute: from + $0, kind: kind, currency: "KRW", minorUnits: 1_000 + Int64($0))
    })
}

private func tx(_ id: String, _ minute: Int, _ kind: AmountKind = .spend, _ minor: Int64? = 1_000, currency: String = "KRW") -> AllocationTransaction {
    AllocationTransaction(id: id, minute: minute, kind: kind, currency: currency, minorUnits: minor)
}

private func day(_ date: LocalDate, events: [AllocationEvent] = [], transactions: [AllocationTransaction] = []) -> AllocationDay {
    AllocationDay(day: date, totalMinutes: 1440, events: events, transactions: transactions)
}

private func input(
    main: AllocationDay, secondary: AllocationDay? = nil, viewport: CGFloat = 800, scale: CGFloat = 1, previous: [ItemKey: Int]? = nil
) -> AllocationInput {
    AllocationInput(main: main, secondary: secondary ?? day(nextDay), viewportHeight: viewport, contentWidth: 180, textScale: scale, previous: previous)
}

private func placement(_ layout: AdaptiveLayout, _ id: String, _ role: DayRole = .main) throws -> EventPlacement {
    try #require(layout.events.first { $0.id == id && $0.key.role == role })
}

/// Everything the event has is shown: no linked transaction is summarised away.
private func showsAll(_ placed: EventPlacement) -> Bool {
    guard placed.hiddenLinkedCount == 0 else { return false }
    let hasRows: Bool = placed.expandedHeight > placed.minimumHeight
    return !hasRows || placed.level != EventLevel.title
}

private func busy(_ prefix: String, count: Int, start: Int = 9 * 60, linked: Int = 3) -> [AllocationEvent] {
    (0..<count).map { ev("\(prefix)\($0)", start + $0 * 90, start + $0 * 90 + 60, linked: linked) }
}

// MARK: Spare room goes to the main day first, then to the secondary

@Test func whenBothDaysAreQuietEverythingIsShownInFullAndNothingScrolls() {
    let layout = AdaptiveLayoutEngine.layout(input(
        main: day(mainDay, events: [ev("a", 600, 660, linked: 3), ev("b", 840, 900, linked: 1)]),
        secondary: day(nextDay, events: [ev("c", 720, 780, linked: 4)])
    ))
    #expect(layout.events.allSatisfy(showsAll))
    #expect(!layout.requiresScroll && layout.contentHeight <= layout.viewportHeight)
}

@Test func aBusyMainDayAndAQuietSecondaryDayKeepTheMainDaysDetail() throws {
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: busy("m", count: 4)), secondary: day(nextDay, events: [ev("s", 600, 660, linked: 3)]), viewport: 700))
    #expect(!layout.requiresScroll)
    #expect(layout.events.filter { $0.key.role == .main }.allSatisfy(showsAll))
    #expect(showsAll(try placement(layout, "s", .secondary)))                      // room was left, so the secondary day got it too
}

@Test func aBusySecondaryDayIsOnlyExpandedWhatTheMainDayLeavesOver() throws {
    let main = day(mainDay, events: busy("m", count: 3))
    let secondary = day(nextDay, events: busy("s", count: 6, start: 8 * 60))
    // A height that fits the main day in full but not both.
    let probe = AdaptiveLayoutEngine.layout(input(main: main, secondary: secondary, viewport: 5_000))
    let tight = AdaptiveLayoutEngine.layout(input(main: main, secondary: secondary, viewport: probe.contentHeight - 60))
    #expect(tight.events.filter { $0.key.role == .main }.allSatisfy(showsAll))
    #expect(tight.events.filter { $0.key.role == .secondary }.contains { !showsAll($0) })
    #expect(!tight.requiresScroll)
}

@Test func secondaryDetailIsNeverBoughtAtTheMainDaysExpense() {
    let main = day(mainDay, events: busy("m", count: 5))
    let secondary = day(nextDay, events: busy("s", count: 5, start: 10 * 60))
    for viewport in stride(from: CGFloat(300), through: 900, by: 40) {
        let layout = AdaptiveLayoutEngine.layout(input(main: main, secondary: secondary, viewport: viewport))
        let anySecondaryRaised = layout.events.contains { $0.key.role == .secondary && $0.level > .title }
        let mainAtLeastPreview = layout.events.filter { $0.key.role == .main }.allSatisfy { $0.level >= .preview }
        if anySecondaryRaised { #expect(mainAtLeastPreview, "viewport \(viewport)") }
    }
}

// MARK: Minimum information, summary, scroll

@Test func everyEventAndTransactionIsPresentEvenWhenNothingFits() throws {
    let main = day(mainDay, events: busy("m", count: 6), transactions: (0..<8).map { tx("t\($0)", 700 + $0 * 40) })
    let secondary = day(nextDay, events: busy("s", count: 6), transactions: (0..<5).map { tx("u\($0)", 800 + $0 * 50) })
    let layout = AdaptiveLayoutEngine.layout(input(main: main, secondary: secondary, viewport: 120))
    #expect(layout.requiresScroll && layout.scrollableHeight > 0)
    #expect(layout.events.count == 12)
    #expect(layout.events.allSatisfy { $0.level == .title })                         // squeezed to the title summary
    let reachable = Set(layout.groups.flatMap(\.transactionIDs))
    #expect(reachable == Set((0..<8).map { "t\($0)" } + (0..<5).map { "u\($0)" }))      // every transaction can still be reached
    // Linked transactions are inside their event; the count says how many there are even at title level.
    #expect(try placement(layout, "m0").hiddenLinkedCount == 3)
}

@Test func scrollingIsOnlyAllowedWhenTheSmallestFormStillDoesNotFit() {
    let main = day(mainDay, events: busy("m", count: 6))
    let roomy = AdaptiveLayoutEngine.layout(input(main: main, viewport: 4_000))
    #expect(!roomy.requiresScroll)
    let minimal = AdaptiveLayoutEngine.layout(input(main: main, viewport: 1))
    #expect(minimal.requiresScroll)
    // Just enough for the smallest form: no scrolling.
    let exact = AdaptiveLayoutEngine.layout(input(main: main, viewport: minimal.contentHeight))
    #expect(!exact.requiresScroll)
    // Below the smallest form it scrolls by exactly what is missing.
    let short = AdaptiveLayoutEngine.layout(input(main: main, viewport: minimal.contentHeight - 50))
    #expect(short.requiresScroll && abs(short.scrollableHeight - 50) < 0.5)
}

@Test func theLayoutOnlyGrowsAsFarAsTheScreenAllows() {
    let main = day(mainDay, events: busy("m", count: 4))
    for viewport in stride(from: CGFloat(200), through: 1_000, by: 50) {
        let layout = AdaptiveLayoutEngine.layout(input(main: main, viewport: viewport))
        if !layout.requiresScroll { #expect(layout.contentHeight <= viewport + 0.5) }
    }
}

// MARK: Dynamic Type

@Test func largerTextScalesTheHeightsAndMayTurnOnScrolling() throws {
    let main = day(mainDay, events: busy("m", count: 3))
    let normal = AdaptiveLayoutEngine.layout(input(main: main, viewport: 420))
    let large = AdaptiveLayoutEngine.layout(input(main: main, viewport: 420, scale: 2))
    let a = try placement(normal, "m0"), b = try placement(large, "m0")
    #expect(abs(b.minimumHeight - 2 * a.minimumHeight) < 0.01 && abs(b.expandedHeight - 2 * a.expandedHeight) < 0.01)
    #expect(large.contentHeight >= normal.contentHeight)
    let huge = AdaptiveLayoutEngine.layout(input(main: main, viewport: 200, scale: 3))
    #expect(huge.requiresScroll && huge.events.count == 3)
}

// MARK: Overlaps

@Test func partialOverlapIsIndentedOnceAndKeepsItsOwnBoundaries() throws {
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [ev("a", 540, 660), ev("b", 600, 720)])))
    let first = try placement(layout, "a"), second = try placement(layout, "b")
    #expect(first.overlap.role == .none && first.overlap.indent == 0)
    #expect(second.overlap.role == .partial(with: "a") && second.overlap.indent == 1 && !second.overlap.pullsInOnRight)
    #expect(second.startMinute == 600 && second.endMinute == 720)
    #expect(first.overlap.groupSize == 2 && !first.overlap.summarisesTitles)
}

@Test func anEventInsideAnotherIsAnInnerCardIndentedOnce() throws {
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [ev("outer", 540, 780), ev("inner", 600, 660)])))
    let inner = try placement(layout, "inner")
    #expect(inner.overlap.role == .contained(in: "outer") && inner.overlap.indent == 1 && inner.overlap.pullsInOnRight)
}

@Test func threeOrMoreOverlapsNeverIndentPastOneStepAndSummariseTheirTitles() throws {
    let events = (0..<5).map { ev("e\($0)", 600 + $0 * 10, 900) }
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: events)))
    #expect(layout.events.allSatisfy { $0.overlap.indent <= 1 })
    #expect(layout.events.allSatisfy { $0.overlap.groupSize == 5 && $0.overlap.summarisesTitles })
    #expect(Set(layout.events.map(\.id)).count == 5)                                  // none is dropped
    // A containing chain is still one step: nested inside nested is not a second indent.
    let nested = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [ev("a", 540, 900), ev("b", 600, 800), ev("c", 650, 700)])))
    #expect(nested.events.allSatisfy { $0.overlap.indent <= 1 })
}

// MARK: Transactions: clusters, links, independence

@Test func denseUnlinkedTransactionsAreClusteredWhenTightAndLooseWhenThereIsRoom() throws {
    let crowd = (0..<5).map { tx("t\($0)", 700 + $0 * 4) }
    let main = day(mainDay, events: [ev("a", 600, 660)], transactions: crowd)
    let tight = AdaptiveLayoutEngine.layout(input(main: main, viewport: 1))
    let group = try #require(tight.groups.first)
    #expect(tight.groups.count == 1 && group.presentation == .cluster && group.transactionIDs.count == 5)
    let roomy = AdaptiveLayoutEngine.layout(input(main: main, viewport: 3_000))
    #expect(roomy.groups.first?.presentation == .rows)                               // released into one line each
    #expect(roomy.groups.first?.transactionIDs == tight.groups.first?.transactionIDs)
}

@Test func transactionsFarApartOrFewInNumberAreNeverClustered() {
    let main = day(mainDay, transactions: [tx("a", 600), tx("b", 700), tx("c", 800), tx("d", 900)])
    let layout = AdaptiveLayoutEngine.layout(input(main: main, viewport: 1))
    #expect(layout.groups.count == 4 && layout.groups.allSatisfy { $0.presentation == .rows })
    let pair = AdaptiveLayoutEngine.layout(input(main: day(mainDay, transactions: [tx("x", 600), tx("y", 605)]), viewport: 1))
    #expect(pair.groups.count == 1 && pair.groups[0].presentation == .rows)           // two close ones are two lines, not a card
}

@Test func clustersNeverCrossDays() {
    let layout = AdaptiveLayoutEngine.layout(input(
        main: day(mainDay, transactions: (0..<3).map { tx("m\($0)", 600 + $0) }),
        secondary: day(nextDay, transactions: (0..<3).map { tx("s\($0)", 603 + $0) }), viewport: 1
    ))
    #expect(layout.groups.count == 2)
    #expect(Set(layout.groups.map(\.role)) == [.main, .secondary])
    for group in layout.groups {
        let prefix = group.role == .main ? "m" : "s"
        #expect(group.transactionIDs.allSatisfy { $0.hasPrefix(prefix) })
    }
}

@Test func anUnlinkedTransactionInsideAnEventsTimeStaysIndependentOfIt() throws {
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [ev("lunch", 720, 780)], transactions: [tx("coffee", 740)])))
    #expect(try placement(layout, "lunch").linkedTotals.isEmpty)
    #expect(layout.groups.map(\.transactionIDs) == [["coffee"]])
}

@Test func aLinkedTransactionBelongsToItsEventWhereverItHappenedAndAddsNoLineOfItsOwn() throws {
    let late = AllocationTransaction(id: "late", minute: 1_200, kind: .spend, currency: "KRW", minorUnits: 4_500)
    let event = AllocationEvent(id: "lunch", title: "점심", startMinute: 720, endMinute: 780, linked: [late])
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [event])))
    #expect(layout.groups.isEmpty)
    let placed = try placement(layout, "lunch")
    #expect(placed.linkedTotals == [AmountSum(kind: .spend, currency: "KRW", minorUnits: 4_500, count: 1, unknownCount: 0)])
    // Its own time (20:00) asks nothing of the axis: that stretch stays folded.
    #expect(layout.axis.isFolded(minute: 1_200))
}

// MARK: Amount safety

@Test func kindsAndCurrenciesAreNeverAddedTogether() throws {
    let mixed = [
        tx("a", 600, .spend, 3_000), tx("b", 601, .income, 50_000), tx("c", 602, .refund, 1_000), tx("d", 603, .transfer, 200_000),
        tx("e", 604, .spend, 2_000), tx("f", 605, .spend, 7, currency: "USD"), tx("g", 606, .spend, nil),
    ]
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, transactions: mixed), viewport: 1))
    let totals = try #require(layout.groups.first).totals
    func total(_ kind: AmountKind, _ currency: String = "KRW") -> AmountSum? { totals.first { $0.kind == kind && $0.currency == currency } }
    #expect(total(.spend) == AmountSum(kind: .spend, currency: "KRW", minorUnits: 5_000, count: 3, unknownCount: 1))   // the unsettled one is counted, not guessed
    #expect(total(.income)?.minorUnits == 50_000 && total(.refund)?.minorUnits == 1_000 && total(.transfer)?.minorUnits == 200_000)
    #expect(total(.spend, "USD")?.minorUnits == 7)
    #expect(totals.count == 5)
    #expect(totals.reduce(0) { $0 + $1.count } == 7)                                 // nothing lost, nothing double counted
}

@Test func eventTotalsKeepRefundsApartFromSpending() throws {
    let event = AllocationEvent(id: "x", title: "행사", startMinute: 600, endMinute: 660, linked: [
        tx("a", 600, .spend, 8_000), tx("b", 610, .refund, 3_000), tx("c", 620, .spend, 2_000),
    ])
    let placed = try placement(AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [event]))), "x")
    #expect(placed.linkedTotals.map(\.kind) == [.spend, .refund] && placed.linkedTotals.map(\.minorUnits) == [10_000, 3_000])
}

// MARK: Axis

@Test func aLongEventKeepsItsMiddleCompressedAndItsEdgesReadable() {
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [ev("long", 9 * 60, 21 * 60)]), viewport: 900))
    let axis = layout.axis
    #expect(axis.isFolded(minute: 15 * 60))
    #expect(axis.pointsPerMinute(atMinute: 9 * 60 + 10) >= AllocationParameters().browseScale - 0.001)
    #expect(axis.pointsPerMinute(atMinute: 20 * 60 + 40) >= AllocationParameters().browseScale - 0.001)
    #expect(axis.y(minute: 21 * 60) - axis.y(minute: 9 * 60) < 12 * 60 * 0.6 / 3)       // far shorter than its natural length
}

@Test func theTwoDaysShareOneAxisAndTimeStaysInOrder() {
    let layout = AdaptiveLayoutEngine.layout(input(
        main: day(mainDay, events: busy("m", count: 3)), secondary: day(nextDay, events: busy("s", count: 3, start: 13 * 60)), viewport: 900
    ))
    var last: CGFloat = -1
    for minute in stride(from: 0, through: 1_440, by: 15) {
        let y = layout.axis.y(minute: minute)
        #expect(y >= last)
        last = y
    }
    #expect(layout.contentHeight == layout.axis.height)
    // Both days' items sit on that axis with at least their required height.
    for placed in layout.events {
        #expect(layout.axis.y(minute: placed.endMinute) - layout.axis.y(minute: placed.startMinute) >= min(placed.requiredHeight, 1_000) - 0.5 || placed.endMinute - placed.startMinute > AllocationParameters().longEventMinutes)
    }
}

@Test func aSecondaryDaysItemsAreNeverLostInAFoldedStretch() {
    let layout = AdaptiveLayoutEngine.layout(input(
        main: day(mainDay, events: [ev("m", 540, 600)]), secondary: day(nextDay, events: [ev("s", 17 * 60, 17 * 60 + 30, linked: 2)]), viewport: 600
    ))
    #expect(!layout.axis.isFolded(minute: 17 * 60 + 10))
    let s = layout.events.first { $0.key.role == .secondary }
    #expect(s != nil && layout.axis.y(minute: 17 * 60 + 30) - layout.axis.y(minute: 17 * 60) >= (s?.requiredHeight ?? 0) - 0.5)
}

// MARK: Determinism and stability

@Test func theSameInputAlwaysGivesTheSameLayoutRegardlessOfInputOrder() {
    let events = busy("m", count: 5)
    let txs = (0..<6).map { tx("t\($0)", 650 + $0 * 7) }
    let a = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: events, transactions: txs), secondary: day(nextDay, events: busy("s", count: 3)), viewport: 500))
    let b = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: events, transactions: txs), secondary: day(nextDay, events: busy("s", count: 3)), viewport: 500))
    let shuffled = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: events.reversed(), transactions: txs.reversed()), secondary: day(nextDay, events: busy("s", count: 3).reversed()), viewport: 500))
    #expect(a == b)
    #expect(a.state == shuffled.state && a.axis == shuffled.axis && a.groups == shuffled.groups)
}

@Test func aSmallChangeOfDataDoesNotFlipUnrelatedItemsWhenThePreviousLayoutIsKept() {
    let main = day(mainDay, events: busy("m", count: 5), transactions: [tx("t0", 1_000)])
    let before = AdaptiveLayoutEngine.layout(input(main: main, secondary: day(nextDay, events: busy("s", count: 4)), viewport: 620))
    let changedMain = day(mainDay, events: busy("m", count: 5), transactions: [tx("t0", 1_000), tx("t1", 1_030)])
    let after = AdaptiveLayoutEngine.layout(input(main: changedMain, secondary: day(nextDay, events: busy("s", count: 4)), viewport: 620, previous: before.state))
    let moved = before.state.filter { after.state[$0.key] != $0.value }
    #expect(moved.count <= 2)
    #expect(after.events.count == before.events.count)
}

@Test func theLayoutIsHeldWhileAnEventIsBeingEdited() {
    let main = day(mainDay, events: busy("m", count: 3))
    let frozen = AdaptiveLayoutEngine.layout(input(main: main, viewport: 500))
    var editing = input(main: day(mainDay, events: busy("m", count: 9)), viewport: 200, scale: 2)
    editing.mode = .editing(frozen: frozen)
    #expect(AdaptiveLayoutEngine.layout(editing) == frozen)
}

@Test func theScrollPositionIsNotPartOfTheInputSoScrollingCannotChangeTheLayout() {
    let names = Mirror(reflecting: input(main: day(mainDay))).children.compactMap(\.label)
    #expect(!names.contains { $0.lowercased().contains("offset") || $0.lowercased().contains("scroll") })
}

// MARK: From the calendar's read model

@Test func theAdapterCarriesTheTimelinesEventsAndUnlinkedTransactionsAsTheyAre() throws {
    let zone = try DisplayTimeZone(identifier: "Asia/Seoul")
    let range = try TimedRange(startUnixMilliseconds: zone.instant(of: mainDay, minuteOfDay: 720), endUnixMilliseconds: zone.instant(of: mainDay, minuteOfDay: 780))
    let event = CalendarEvent(id: CalendarEventID(rawValue: "e"), calendarID: CalendarID(rawValue: "c"), title: "점심", time: .timed(range), revisionToken: "r")
    let marker = TransactionMarker(
        id: LedgerEntryID(rawValue: "t"), occurredAtUnixMilliseconds: zone.instant(of: mainDay, minuteOfDay: 740),
        amount: try Money(minorUnits: 4_500, currency: "KRW"), flow: .refund, title: "환불 테스트"
    )
    let timeline = DayTimelineBuilder.build(DayTimelineInput(day: mainDay, timeZone: zone, events: [event], life: .empty, transactions: [marker]))
    let converted = AllocationDay(timeline)
    #expect(converted.events.map(\.title) == ["점심"] && converted.events[0].startMinute == 720 && converted.events[0].linked.isEmpty)
    #expect(converted.transactions == [AllocationTransaction(id: "t", minute: 740, kind: .refund, currency: "KRW", minorUnits: 4_500)])
    let layout = AdaptiveLayoutEngine.layout(AllocationInput(main: converted, secondary: nil, viewportHeight: 600, contentWidth: 180))
    #expect(layout.events.count == 1 && layout.groups.count == 1)
}
