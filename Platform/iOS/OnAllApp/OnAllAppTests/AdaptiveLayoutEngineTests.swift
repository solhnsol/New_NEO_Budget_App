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
    guard placed.hiddenInsideCount == 0 else { return false }
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
    let reachable = layout.reachableTransactionIDs
    #expect(reachable == Set((0..<8).map { "t\($0)" } + (0..<5).map { "u\($0)" }))      // every transaction can still be reached
    // Linked transactions are inside their event; the count says how many there are even at title level.
    #expect(try placement(layout, "m0").hiddenInsideCount == 3)
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

// MARK: Transactions: lines, links and overflow

/// A transaction linked to an event that happened at `minute` of the day.
private func linkedTx(_ id: String, _ minute: Int, _ kind: AmountKind = .spend, _ minor: Int64? = 4_500) -> AllocationTransaction {
    AllocationTransaction(id: id, minute: minute, kind: kind, currency: "KRW", minorUnits: minor)
}

private func lineIDs(_ layout: AdaptiveLayout) -> [String] { layout.lines.map(\.transactionID) }

@Test func transactionsAreSeparateLinesByDefaultWhateverTheirNumber() {
    let ten = (0..<10).map { tx("t\($0)", 700 + $0 * 5) }
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [ev("a", 600, 660)], transactions: ten), viewport: 5_000))
    #expect(lineIDs(layout) == (0..<10).map { "t\($0)" })
    #expect(layout.overflows.isEmpty)
    // Ten lines, five minutes apart, still each have a readable distance from the next on the shared axis.
    let pitch = (AllocationParameters().transactionRow + AllocationParameters().lineGap)
    for index in 0..<9 { #expect(layout.axis.y(minute: 700 + (index + 1) * 5) - layout.axis.y(minute: 700 + index * 5) >= pitch - 0.5) }
}

@Test func twoLinesThatCannotKeepApartBecomeAnOverflowOnlyWhenThereIsNoRoom() throws {
    let pair = day(mainDay, transactions: [tx("a", 600), tx("b", 603)])
    let roomy = AdaptiveLayoutEngine.layout(input(main: pair, viewport: 3_000))
    #expect(lineIDs(roomy) == ["a", "b"] && roomy.overflows.isEmpty)
    let tight = AdaptiveLayoutEngine.layout(input(main: pair, viewport: 1))
    let overflow = try #require(tight.overflows.first)
    #expect(tight.lines.isEmpty && tight.overflows.count == 1 && overflow.transactionIDs == ["a", "b"])
    #expect(tight.reachableTransactionIDs == ["a", "b"])
}

@Test func transactionsFarApartAreNeverMergedJustBecauseTheAxisIsCompressed() {
    let far = day(mainDay, transactions: [tx("a", 9 * 60), tx("b", 12 * 60), tx("c", 15 * 60), tx("d", 20 * 60)])
    let layout = AdaptiveLayoutEngine.layout(input(main: far, viewport: 1))
    #expect(lineIDs(layout) == ["a", "b", "c", "d"] && layout.overflows.isEmpty)
    #expect(layout.requiresScroll)                                                   // it scrolls instead
}

@Test func onlyTheCollidingLinesMergeAndTheRestStayLines() {
    let mixed = day(mainDay, transactions: [tx("a", 600), tx("b", 602), tx("c", 604), tx("far", 900)])
    let layout = AdaptiveLayoutEngine.layout(input(main: mixed, viewport: 1))
    #expect(layout.overflows.count == 1 && layout.overflows[0].transactionIDs == ["a", "b", "c"])
    #expect(lineIDs(layout) == ["far"])
}

@Test func anOverflowKeepsEveryOriginalTransactionAndNeverMixesKindsOrCurrenciesIntoOneAmount() throws {
    let mixed = [
        tx("a", 600, .spend, 3_000), tx("b", 601, .income, 50_000), tx("c", 602, .refund, 1_000), tx("d", 603, .transfer, 200_000),
        tx("e", 604, .spend, 2_000), tx("f", 605, .spend, 7, currency: "USD"), tx("g", 606, .spend, nil),
    ]
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, transactions: mixed), viewport: 1))
    let overflow = try #require(layout.overflows.first)
    #expect(layout.overflows.count == 1 && overflow.members.count == 7)
    #expect(overflow.members.map(\.transactionID) == ["a", "b", "c", "d", "e", "f", "g"])      // time order, none dropped
    #expect(overflow.members.map(\.minute) == [600, 601, 602, 603, 604, 605, 606])               // each keeps its own time
    #expect(overflow.members.map(\.kind) == mixed.map(\.kind) && overflow.members.map(\.minorUnits) == mixed.map(\.minorUnits))
    // The default summary is a count, per kind. Amounts exist per kind and currency but are not offered as one figure.
    #expect(overflow.countsByKind == [KindCount(kind: .spend, count: 4), KindCount(kind: .income, count: 1), KindCount(kind: .refund, count: 1), KindCount(kind: .transfer, count: 1)])
    #expect(!overflow.showsAmountTotal)
    func total(_ kind: AmountKind, _ currency: String = "KRW") -> AmountSum? { overflow.amountTotals.first { $0.kind == kind && $0.currency == currency } }
    #expect(total(.spend) == AmountSum(kind: .spend, currency: "KRW", minorUnits: 5_000, count: 3, unknownCount: 1))
    #expect(total(.income)?.minorUnits == 50_000 && total(.refund)?.minorUnits == 1_000 && total(.transfer)?.minorUnits == 200_000)
    #expect(total(.spend, "USD")?.minorUnits == 7 && overflow.amountTotals.count == 5)
}

@Test func anOverflowOfOneKindInOneCurrencyMayShowItsTotal() throws {
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, transactions: [tx("a", 600, .spend, 3_000), tx("b", 601, .spend, 2_000)]), viewport: 1))
    let overflow = try #require(layout.overflows.first)
    #expect(overflow.showsAmountTotal && overflow.amountTotals == [AmountSum(kind: .spend, currency: "KRW", minorUnits: 5_000, count: 2, unknownCount: 0)])
}

@Test func overflowsNeverCrossDays() {
    let layout = AdaptiveLayoutEngine.layout(input(
        main: day(mainDay, transactions: (0..<3).map { tx("m\($0)", 600 + $0) }),
        secondary: day(nextDay, transactions: (0..<3).map { tx("s\($0)", 603 + $0) }), viewport: 1
    ))
    #expect(layout.overflows.count == 2 && Set(layout.overflows.map(\.role)) == [.main, .secondary])
    for overflow in layout.overflows {
        let prefix = overflow.role == .main ? "m" : "s"
        #expect(overflow.transactionIDs.allSatisfy { $0.hasPrefix(prefix) })
    }
}

@Test func anUnlinkedTransactionInsideAnEventsTimeStaysIndependentOfIt() throws {
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [ev("lunch", 720, 780)], transactions: [tx("coffee", 740)])))
    #expect(try placement(layout, "lunch").linkedTotals.isEmpty && layout.lines.map(\.transactionID) == ["coffee"])
    #expect(layout.lines[0].link == nil)
}

@Test func aLinkedTransactionWithinTheEventsTimeIsDrawnInsideItAndHasNoLine() throws {
    let event = AllocationEvent(id: "lunch", title: "점심", startMinute: 720, endMinute: 780, linked: [linkedTx("in", 745)])
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [event])))
    #expect(layout.lines.isEmpty)
    let placed = try placement(layout, "lunch")
    #expect(placed.outsideLinkedCount == 0 && placed.shownInsideRows == 1)
}

@Test func aLinkedTransactionOutsideTheEventsTimeIsALineAtItsRealTimeCarryingItsLink() throws {
    let late = linkedTx("late", 20 * 60)
    let event = AllocationEvent(id: "lunch", title: "점심", startMinute: 720, endMinute: 780, linked: [late])
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [event]), viewport: 900))
    let line = try #require(layout.lines.first)
    #expect(layout.lines.count == 1 && line.transactionID == "late" && line.minute == 20 * 60)          // its own time, not the event's
    #expect(line.link == LinkMetadata(eventID: "lunch", happenedOutsideEventRange: true))
    #expect(!layout.axis.isFolded(minute: 20 * 60 + 5))                                                // so that time is on the axis
    #expect(layout.axis.isFolded(minute: 15 * 60))
    let placed = try placement(layout, "lunch")
    #expect(placed.outsideLinkedCount == 1 && placed.linkedTotals.map(\.minorUnits) == [4_500])        // the event still knows it
    #expect(placed.startMinute == 720 && placed.endMinute == 780)                                      // and its time is untouched
}

@Test func theLedgerCountsATransactionOnceHoweverManyPlacesReferToIt() {
    let shared = linkedTx("x", 20 * 60, .spend, 4_500)
    let first = AllocationEvent(id: "a", title: "가", startMinute: 720, endMinute: 780, linked: [shared])
    let second = AllocationEvent(id: "b", title: "나", startMinute: 900, endMinute: 960, linked: [shared])
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [first, second], transactions: [shared]), viewport: 900))
    #expect(layout.ledgerTotals == [AmountSum(kind: .spend, currency: "KRW", minorUnits: 4_500, count: 1, unknownCount: 0)])
    #expect(layout.lines.count == 1)                                                                     // and it is one line, not three
}

@Test func eventTotalsKeepRefundsApartFromSpending() throws {
    let event = AllocationEvent(id: "x", title: "행사", startMinute: 600, endMinute: 660, linked: [
        tx("a", 600, .spend, 8_000), tx("b", 610, .refund, 3_000), tx("c", 620, .spend, 2_000),
    ])
    let placed = try placement(AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [event]))), "x")
    #expect(placed.linkedTotals.map(\.kind) == [.spend, .refund] && placed.linkedTotals.map(\.minorUnits) == [10_000, 3_000])
}

@Test func amountKindsAndCurrenciesNeverShareASumInTheLedgerEither() {
    let all = [tx("a", 600, .spend, 3_000), tx("b", 700, .income, 50_000), tx("c", 800, .refund, 1_000), tx("d", 900, .transfer, 9_000), tx("e", 1_000, .spend, 7, currency: "USD")]
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, transactions: all), viewport: 900))
    #expect(layout.ledgerTotals.count == 5 && layout.ledgerTotals.allSatisfy { $0.count == 1 })
}

// MARK: Event titles, headers

private func titledEvent(_ title: String, _ from: Int, _ to: Int) -> AllocationEvent { AllocationEvent(id: "e", title: title, startMinute: from, endMinute: to, linked: []) }

@Test func aTitleThatCollidesWithALineMovesToAnExternalHeaderWhenThereIsClearRoomAbove() throws {
    let event = titledEvent("아주 긴 일정 제목입니다", 12 * 60, 13 * 60)
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [event], transactions: [tx("t", 12 * 60 + 20)]), viewport: 900))
    let placed = try placement(layout, "e")
    #expect(placed.titleResolution == .externalHeader)
    let header = try #require(placed.header)
    #expect(header.eventID == placed.id && header.attachedToMinute == 12 * 60)                      // the event's id, attached to its start
    #expect(placed.startMinute == 12 * 60 && placed.endMinute == 13 * 60)                           // no time changed
    // Clear room: above the start by the header's height, with nothing in it.
    let top = layout.axis.y(minute: 12 * 60)
    #expect(top - header.height >= -0.01)
    for target in layout.touchTargets where target.id != "e" { #expect(target.visualMaxY <= top - header.height + 0.01 || target.visualMinY >= top - 0.01) }
}

@Test func aTitleWithNoLineUnderItNeedsNoHeader() throws {
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [titledEvent("아주 긴 일정 제목입니다", 12 * 60, 13 * 60)], transactions: [tx("t", 12 * 60 + 50)])))
    #expect(try placement(layout, "e").titleResolution == .none && (try placement(layout, "e")).header == nil)
}

@Test func withoutRoomAboveTheTitleIsShortenedInsteadOfCoveringAnything() throws {
    // A line just before the start fills the space where a header would go.
    let event = titledEvent("아주 긴 일정 제목입니다", 12 * 60, 13 * 60)
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [event], transactions: [tx("before", 11 * 60 + 58), tx("inside", 12 * 60 + 3)]), viewport: 900))
    let placed = try placement(layout, "e")
    #expect(placed.header == nil)
    guard case let .abbreviated(width) = placed.titleResolution else { Issue.record("expected an abbreviated title, got \(placed.titleResolution)"); return }
    #expect(width >= AllocationParameters().minimumTitleWidth && width < 180)
}

@Test func whenEvenAShortTitleHasNoRoomTheStretchIsEnlargedIfTheScreenAllows() throws {
    let event = titledEvent("아주 긴 일정 제목입니다", 12 * 60, 13 * 60)
    let content = day(mainDay, events: [event], transactions: [tx("before", 11 * 60 + 58), tx("inside", 12 * 60 + 3)])
    var narrow = input(main: content, viewport: 900)
    narrow.contentWidth = 120
    let roomy = AdaptiveLayoutEngine.layout(narrow)
    let placed = try placement(roomy, "e")
    #expect(placed.titleResolution == .expandedRange && placed.header == nil)
    let params = AllocationParameters()
    #expect(roomy.axis.y(minute: 12 * 60 + 3) - roomy.axis.y(minute: 12 * 60) >= params.titleRow + params.lineGap + params.transactionRow / 2 - 0.5)
    #expect(placed.startMinute == 12 * 60 && placed.endMinute == 13 * 60)

    // With no spare height it is not enlarged: the title is cut, not printed over the line.
    var tight = narrow
    tight.viewportHeight = 1
    let cramped = try placement(AdaptiveLayoutEngine.layout(tight), "e")
    guard case .cramped = cramped.titleResolution else { Issue.record("expected cramped, got \(cramped.titleResolution)"); return }
    #expect(cramped.header == nil)
}

@Test func anOverlappedEventDoesNotGetAHeaderOverItsParent() throws {
    let outer = AllocationEvent(id: "outer", title: "바깥 일정", startMinute: 540, endMinute: 900, linked: [])
    let inner = AllocationEvent(id: "inner", title: "아주 긴 안쪽 일정 제목", startMinute: 600, endMinute: 660, linked: [])
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [outer, inner], transactions: [tx("t", 604)]), viewport: 900))
    #expect(try placement(layout, "inner").header == nil)                                           // the room above it is the outer card
    #expect(layout.events.compactMap(\.header).allSatisfy { $0.eventID == "outer" || $0.eventID == "inner" })
}

// MARK: Touch targets

@Test func aShortEventIsDrawnSmallButTouchedAtFingerSize() throws {
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [ev("short", 600, 615)]), viewport: 900))
    let target = try #require(layout.touchTargets.first { $0.id == "short" })
    #expect(target.visualMaxY - target.visualMinY < AllocationParameters().minimumTouchHeight)
    #expect(target.touchMaxY - target.touchMinY >= AllocationParameters().minimumTouchHeight - 0.01)
    #expect(target.touchMinY <= target.visualMinY && target.touchMaxY >= target.visualMaxY)
}

@Test func neighbouringShortItemsWhoseTouchAreasMeetAreReturnedAsCandidatesToChooseFrom() {
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [ev("a", 600, 615), ev("b", 615, 630)]), viewport: 900))
    let conflict = layout.touchConflicts.first { $0.candidates.contains("a") }
    #expect(conflict?.candidates == ["a", "b"])
    let apart = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: [ev("a", 600, 615), ev("b", 900, 915)]), viewport: 900))
    #expect(apart.touchConflicts.isEmpty)
}

@Test func linesThatMeetOneAnotherAreAlsoCandidatesToChooseFrom() {
    let layout = AdaptiveLayoutEngine.layout(input(main: day(mainDay, transactions: [tx("a", 600), tx("b", 606)]), viewport: 3_000))
    // Separate lines a readable distance apart (24 + 2) still have 44 point touch areas that overlap: the choice is returned.
    #expect(layout.lines.count == 2)
    #expect(layout.touchConflicts.contains { $0.candidates == ["a", "b"] })
}

// MARK: Focus

private func focusRestore(_ layout: AdaptiveLayout? = nil) -> FocusRestore {
    FocusRestore(mainDay: mainDay, secondaryDay: nextDay, anchorMinute: 12 * 60, layoutState: layout?.state ?? [:])
}

@Test func focusingAnEventOnTheSecondaryDayPromotesItsDayAndShrinksTheOtherToAHeader() throws {
    let late = linkedTx("late", 20 * 60, .spend, 6_000)
    let event = AllocationEvent(id: "party", title: "모임", startMinute: 15 * 60, endMinute: 17 * 60, linked: [linkedTx("in", 16 * 60), late])
    let main = day(mainDay, events: [ev("m", 600, 660)])
    let secondary = day(nextDay, events: [event])
    let base = AdaptiveLayoutEngine.layout(input(main: main, secondary: secondary, viewport: 800))
    var request = input(main: main, secondary: secondary, viewport: 800)
    request.focus = FocusRequest(target: .event(eventID: "party"), restore: focusRestore(base))
    let layout = AdaptiveLayoutEngine.layout(request)
    let focus = try #require(layout.focus)
    #expect(focus.target == .event(eventID: "party") && focus.mainDay == nextDay && focus.secondaryDay == mainDay)
    #expect(focus.secondary == .headerOnly(height: AllocationParameters().secondaryHeader))
    // The detail lists everything linked, the one outside the event's time with its own time and the link kept.
    #expect(focus.rows.map(\.transactionID) == ["in", "late"])
    #expect(focus.rows.map(\.relation) == [.insideEventRange, .outsideEventRange] && focus.rows.map(\.minute) == [16 * 60, 20 * 60])
    #expect(!focus.detailNeedsInternalScroll)
    // The timeline behind it is the focused day alone and is not stretched.
    #expect(layout.events.map(\.id) == ["party"] && layout.contentHeight <= AllocationParameters().focusContext + 0.5 || layout.requiresScroll)
    #expect(focus.restore == focusRestore(base))                                                         // enough to come back exactly
}

@Test func theDetailMeasuresItsOwnHeightAndScrollsInsideItselfWhenItDoesNotFit() throws {
    let event = AllocationEvent(id: "big", title: "큰 행사", startMinute: 600, endMinute: 900, linked: (0..<30).map { linkedTx("t\($0)", 600 + $0) })
    var request = AllocationInput(main: day(mainDay, events: [event]), secondary: nil, viewportHeight: 400, contentWidth: 180)
    request.focus = FocusRequest(target: .event(eventID: "big"), restore: focusRestore())
    let focus = try #require(AdaptiveLayoutEngine.layout(request).focus)
    let params = AllocationParameters()
    #expect(focus.detailHeightNeeded == params.titleRow + 30 * params.detailRow)
    #expect(focus.detailNeedsInternalScroll && abs(focus.detailScrollableHeight - (focus.detailHeightNeeded - focus.detailHeightAvailable)) < 0.01)
    #expect(focus.secondary == .none)                                                                    // no other day to shrink
    request.viewportHeight = 2_000
    let roomy = try #require(AdaptiveLayoutEngine.layout(request).focus)
    #expect(!roomy.detailNeedsInternalScroll)
}

@Test func focusingAnOverflowCarriesItsTransactionsAndLeavesTheOtherDayAsAHeader() throws {
    let crowd = [tx("a", 600, .spend, 3_000), tx("b", 602, .income, 9_000), tx("c", 604, .refund, 500)]
    let main = day(mainDay, transactions: crowd)
    var request = input(main: main, secondary: day(nextDay, events: [ev("s", 600, 660)]), viewport: 1)
    let before = AdaptiveLayoutEngine.layout(request)
    let overflow = try #require(before.overflows.first)
    request.focus = FocusRequest(target: .overflow(overflowID: overflow.id, transactionIDs: overflow.transactionIDs), restore: focusRestore(before))
    request.viewportHeight = 800
    let focus = try #require(AdaptiveLayoutEngine.layout(request).focus)
    #expect(focus.mainDay == mainDay && focus.secondaryDay == nextDay)
    #expect(focus.rows.map(\.transactionID) == ["a", "b", "c"] && focus.rows.allSatisfy { $0.relation == .overflowMember })
    #expect(focus.rows.map(\.kind) == [.spend, .income, .refund] && focus.rows.map(\.minorUnits) == [3_000, 9_000, 500])
}

@Test func focusOnSomethingThatIsNotThereFallsBackToTheOrdinaryLayout() {
    var request = input(main: day(mainDay, events: [ev("a", 600, 660)]), viewport: 600)
    request.focus = FocusRequest(target: .event(eventID: "ghost"), restore: focusRestore())
    let layout = AdaptiveLayoutEngine.layout(request)
    #expect(layout.focus == nil && layout.events.count == 1)
}

@Test func theFocusRestoreIsEverythingNeededToReturnToTheSameTwoDays() {
    let base = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: busy("m", count: 3)), secondary: day(nextDay, events: busy("s", count: 2)), viewport: 500))
    let restore = FocusRestore(mainDay: mainDay, secondaryDay: nextDay, anchorMinute: 700, layoutState: base.state)
    let again = AdaptiveLayoutEngine.layout(input(main: day(mainDay, events: busy("m", count: 3)), secondary: day(nextDay, events: busy("s", count: 2)), viewport: 500, previous: restore.layoutState))
    #expect(again.state == base.state && again.axis == base.axis)
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
    #expect(a.state == shuffled.state && a.axis == shuffled.axis && a.lines == shuffled.lines && a.overflows == shuffled.overflows)
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
    #expect(layout.events.count == 1 && layout.lines.count == 1)
}

@Test func spareHeightAfterEverythingIsShownIsLeftEmpty() {
    let main = day(mainDay, events: busy("m", count: 2), transactions: [tx("t", 1_000)])
    let a = AdaptiveLayoutEngine.layout(input(main: main, viewport: 1_500))
    let b = AdaptiveLayoutEngine.layout(input(main: main, viewport: 4_000))
    #expect(a.contentHeight == b.contentHeight && a.state == b.state && !b.requiresScroll)
    #expect(b.contentHeight < b.viewportHeight)
}
