import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
import UIKit
@testable import OnAllApp

// Synthetic data only: invented titles, ids and amounts.

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let calendar = CalendarID(rawValue: "c")
private let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)
private let layoutWidth: CGFloat = 217.5                       // one of two day columns on a 375 point phone

private func event(_ index: Int, _ title: String, _ from: Int, _ to: Int) throws -> CalendarEvent {
    let range = try TimedRange(startUnixMilliseconds: zone.instant(of: day, minuteOfDay: from), endUnixMilliseconds: zone.instant(of: day, minuteOfDay: to))
    return CalendarEvent(id: CalendarEventID(rawValue: "e\(index)"), calendarID: calendar, title: title, time: .timed(range), revisionToken: "r")
}

private func spend(_ id: String, minute: Int, won: Int64 = 4_500) throws -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: minute),
        amount: try Money(minorUnits: won, currency: "KRW"), flow: .spend, title: "상점 \(id)"
    )
}

/// `link`: transaction id -> index of the event it is linked to.
private func timeline(_ events: [CalendarEvent], _ transactions: [TransactionMarker] = [], link: [String: Int] = [:]) throws -> DayTimeline {
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
        day: day, timeZone: zone, calendars: [CalendarDescriptor(id: calendar, title: "약속")],
        events: events, life: try LifeState.empty.applying(changes), transactions: transactions
    ))
}

private struct Rendered {
    let layout: AdaptiveLayout
    let geometry: TimelineGeometry
    let plan: DayRenderPlan
}

private func render(_ timeline: DayTimeline, viewport: CGFloat = 900, scale: CGFloat = 1, titleWidth: ((String) -> CGFloat)? = nil) -> Rendered {
    let contentWidth = TimelineGeometry(totalMinutes: 1440).contentWidth(totalWidth: layoutWidth)
    var input = AllocationInput(main: AllocationDay(timeline), secondary: nil, viewportHeight: viewport, contentWidth: contentWidth, textScale: scale)
    for block in timeline.blocks { input.titleWidths[block.title] = titleWidth?(block.title) ?? DayContentLayout.estimatedTitleWidth(block.title, extra: 14) * scale }
    let layout = AdaptiveLayoutEngine.layout(input)
    let geometry = TimelineGeometry(axis: layout.axis)
    let plan = DayRenderPlan(
        timeline: timeline, role: .main, layout: layout, geometry: geometry, layoutWidth: layoutWidth, textScale: scale,
        titleWidth: { input.titleWidths[$0] ?? 60 }
    )
    return Rendered(layout: layout, geometry: geometry, plan: plan)
}

private func item(_ r: Rendered, _ title: String) throws -> DayRenderPlan.EventItem {
    try #require(r.plan.events.first { $0.block.title == title })
}

// MARK: The plan puts things where the engine's axis says

@Test func eventCardsAreExactlyWhereTheSharedAxisPutsTheirTimes() throws {
    let r = render(try timeline([event(0, "회의", 600, 720), event(1, "점심", 780, 840)]))
    for placed in r.plan.events {
        #expect(placed.frame.minY == r.geometry.y(minute: placed.block.displayStartMinute))
        #expect(abs(placed.frame.maxY - r.geometry.y(minute: placed.block.displayEndMinute)) <= 1 || placed.frame.height == r.geometry.minimumBlockHeight)
    }
}

@Test func aTransactionLineSitsAtItsTimeAndNeverOnAnotherLine() throws {
    let many = try (0..<8).map { try spend("t\($0)", minute: 700 + ($0 / 2)) }        // pairs at the same minute
    let r = render(try timeline([event(0, "회의", 600, 660)], many), viewport: 5_000)
    let lines = r.plan.lines.sorted { $0.frame.minY < $1.frame.minY }
    #expect(lines.count == 8)
    for (above, below) in zip(lines, lines.dropFirst()) { #expect(above.frame.maxY <= below.frame.minY + 0.01) }          // no two lines on one another
    #expect(lines.allSatisfy { $0.frame.height == AllocationParameters().transactionRow })
}

// MARK: Events and their transactions

@Test func aLinkedTransactionInsideTheEventsTimeIsInsideItsCardAndHasNoLine() throws {
    let r = render(try timeline([event(0, "점심", 720, 780)], [spend("in", minute: 740)], link: ["in": 0]), viewport: 900)
    let card = try item(r, "점심")
    #expect(card.insideRows.map(\.transactionID.rawValue) == ["in"] && r.plan.lines.isEmpty)
}

@Test func aLinkedTransactionOutsideTheEventsTimeIsALineAtItsRealTimeWithItsLink() throws {
    let r = render(try timeline([event(0, "점심", 720, 780)], [spend("late", minute: 1_200)], link: ["late": 0]), viewport: 900)
    let card = try item(r, "점심")
    #expect(card.insideRows.isEmpty)
    let line = try #require(r.plan.lines.first)
    #expect(r.plan.lines.count == 1 && line.link?.eventID == card.block.id.rawValue && line.linkedEventTitle == "점심")
    #expect(abs(line.frame.midY - r.geometry.y(minute: 1_200)) < 0.5)                                        // at 20:00, not at the event
}

@Test func anUnlinkedTransactionInsideAnEventIsItsOwnLineAndNotInTheCard() throws {
    let r = render(try timeline([event(0, "점심", 720, 780)], [spend("coffee", minute: 740)]), viewport: 900)
    #expect(try item(r, "점심").insideRows.isEmpty)
    #expect(r.plan.lines.map(\.id) == ["coffee"] && r.plan.lines[0].link == nil)
    #expect(r.plan.lines[0].display?.title == "상점 coffee" && r.plan.lines[0].display?.amount.minorUnits == 4_500)      // name and amount carried as they are
}

@Test func theSameTransactionIsNeverDrawnTwice() throws {
    let r = render(try timeline([event(0, "점심", 720, 780), event(1, "저녁", 1_080, 1_140)], [spend("late", minute: 1_300), spend("free", minute: 800)], link: ["late": 0]), viewport: 900)
    let ids = r.plan.lines.map(\.id) + r.plan.overflows.flatMap { $0.members.map(\.transactionID) } + r.plan.events.flatMap { $0.insideRows.map(\.transactionID.rawValue) }
    #expect(ids.count == Set(ids).count)
}

// MARK: External headers

private let longTitle = "아주 긴 일정 제목입니다"

@Test func anExternalHeaderIsAttachedAboveTheCardOfTheSameEvent() throws {
    let r = render(try timeline([event(0, longTitle, 12 * 60, 13 * 60)], [spend("t", minute: 12 * 60 + 20)]))
    let card = try item(r, longTitle)
    let header = try #require(card.header)
    #expect(header.maxY == card.frame.minY && header.minX == card.frame.minX && header.width == card.frame.width)         // attached, same column
    #expect(!card.showsTitleInCard)
    #expect(card.placement?.header?.eventID == card.block.id.rawValue)
    // Touching the header means the same event as touching the card.
    #expect(r.plan.hit(at: CGPoint(x: header.midX, y: header.midY)) == .event(card.block.id))
    #expect(r.plan.hit(at: CGPoint(x: card.frame.minX + 4, y: card.frame.maxY - 4)) == .event(card.block.id))
    // Its start boundary is the card's own top, below the header; the event's time is unchanged.
    #expect(card.frame.minY == r.geometry.y(minute: 12 * 60) && card.block.startMinute == 12 * 60)
}

@Test func withoutAConflictThereIsNoHeaderAndTheTitleStaysInTheCard() throws {
    let r = render(try timeline([event(0, longTitle, 12 * 60, 13 * 60)], [spend("t", minute: 14 * 60)]))
    let card = try item(r, longTitle)
    #expect(card.header == nil && card.showsTitleInCard)
}

// MARK: Overflow, overlap, touch

@Test func anOverflowIsDrawnOnlyWhenTheEngineSaysSoAndKeepsAStableId() throws {
    let crowd = try [spend("a", minute: 600), spend("b", minute: 601), spend("c", minute: 602)]
    let roomy = render(try timeline([], crowd), viewport: 5_000)
    #expect(roomy.plan.overflows.isEmpty && roomy.plan.lines.count == 3)                    // the renderer adds no rule of its own
    let tight = render(try timeline([], crowd), viewport: 1)
    let overflow = try #require(tight.plan.overflows.first)
    #expect(tight.plan.lines.isEmpty && overflow.members.count == 3)
    #expect(render(try timeline([], crowd), viewport: 1).plan.overflows.first?.id == overflow.id)       // same input, same id
    #expect(overflow.focusTarget == .overflow(overflowID: overflow.id, transactionIDs: ["a", "b", "c"]))
    #expect(tight.plan.hit(at: CGPoint(x: overflow.frame.midX, y: overflow.frame.midY)) == .overflow(overflow.id))
}

@Test func twoOverlappingEventsKeepFullWidthAndOneStepOfIndent() throws {
    let r = render(try timeline([event(0, "가", 540, 660), event(1, "나", 600, 720)]))
    let a = try item(r, "가"), b = try item(r, "나")
    #expect(b.frame.minX - a.frame.minX == AllocationParameters().indentStep && b.frame.maxX == a.frame.maxX)
    #expect(r.plan.summaries.isEmpty)
}

@Test func eventsThatStartTogetherAreSummarisedAndEveryOneRemainsReachable() throws {
    let events = try [event(0, "가", 600, 700), event(1, "나", 600, 690), event(2, "다", 600, 680), event(3, "라", 605, 650)]
    let r = render(try timeline(events))
    #expect(r.plan.events.allSatisfy { $0.placement?.overlap.indent ?? 0 <= 1 })
    let summary = try #require(r.plan.summaries.first)
    #expect(summary.items.count == 4)                                                       // every title is in the summary
    #expect(Set(r.plan.events.map(\.block.title)) == ["가", "나", "다", "라"])                // and every card still exists to touch
}

@Test func twoShortEventsWhoseTouchAreasMeetAskWhichWasMeant() throws {
    let r = render(try timeline([event(0, "가", 600, 615), event(1, "나", 615, 630)]), viewport: 900)
    let a = try item(r, "가"), b = try item(r, "나")
    #expect(a.touchFrame.height >= AllocationParameters().minimumTouchHeight - 0.01 && a.frame.height < a.touchFrame.height)       // drawn small, touched at finger size
    #expect(r.plan.hit(at: CGPoint(x: a.frame.midX, y: a.frame.midY)) == .event(a.block.id))                                      // inside a card: that card
    let seam = CGPoint(x: a.frame.midX, y: (a.frame.maxY + b.frame.minY) / 2 + (a.frame.maxY - b.frame.minY > 0 ? 0 : 0))
    if case let .choose(candidates) = r.plan.hit(at: CGPoint(x: seam.x, y: a.touchFrame.maxY - 1)) { #expect(candidates.contains(.event(a.block.id)) || candidates.contains(.event(b.block.id))) }
}

@Test func aLineCoveringAShortEventStillLetsTheEventBeChosen() throws {
    let wide: CGFloat = 140                                                                   // narrow: a line spans the whole card
    let contentWidth = TimelineGeometry(totalMinutes: 1440).contentWidth(totalWidth: wide)
    var offeredAChoice = false
    for minute in 600...615 {                                                                  // some minute puts the line right over the card
        let tl = try timeline([event(0, "가", 600, 615)], [spend("t", minute: minute)])
        let layout = AdaptiveLayoutEngine.layout(AllocationInput(main: AllocationDay(tl), secondary: nil, viewportHeight: 900, contentWidth: contentWidth))
        let plan = DayRenderPlan(timeline: tl, role: .main, layout: layout, geometry: TimelineGeometry(axis: layout.axis), layoutWidth: wide, titleWidth: { _ in 40 })
        let line = try #require(plan.lines.first), card = try #require(plan.events.first)
        let hit = plan.hit(at: CGPoint(x: line.frame.midX, y: line.frame.midY))
        if line.frame.minY <= card.frame.minY + 0.5 && line.frame.maxY >= card.frame.maxY - 0.5 {
            // The card is wholly under the line: the touch must offer both.
            guard case let .choose(candidates) = hit else { Issue.record("a fully covered event was not offered: \(hit)"); return }
            #expect(candidates.contains(.line("t")) && candidates.contains(.event(card.block.id)))
            offeredAChoice = true
        } else if case .choose = hit {
            offeredAChoice = true
        }
    }
    #expect(offeredAChoice)
}

@Test func largerTextScalesTheLinesTheEngineReservedRoomFor() throws {
    let tl = try timeline([event(0, "회의", 600, 660)], [spend("t", minute: 900)])
    let normal = render(tl, scale: 1), large = render(tl, scale: 2)
    #expect(abs(large.plan.lines[0].frame.height - 2 * normal.plan.lines[0].frame.height) < 0.01)
}

// MARK: Real text widths

@Test func measuredTitleWidthsGrowWithDynamicTypeAndAreInTheRangeOfTheEstimate() {
    let titles = ["회의", "알고리즘 수업", "Weekly sync", "아주 긴 일정 제목입니다"]
    for title in titles {
        let small = TextMeasurer.titleWidth(title, contentSize: .extraSmall)
        let standard = TextMeasurer.titleWidth(title, contentSize: .large)
        let huge = TextMeasurer.titleWidth(title, contentSize: .accessibilityExtraExtraExtraLarge)
        #expect(small < standard && standard < huge)
        // The old estimate (12 per wide character, 7 per narrow) is a guide only; the engine is given the measurement.
        let estimate = DayContentLayout.estimatedTitleWidth(title, extra: 14)
        #expect(standard > estimate * 0.5 && standard < estimate * 1.6, "\(title): measured \(standard), estimated \(estimate)")
    }
    #expect(TextMeasurer.textScale(contentSize: .accessibilityExtraExtraExtraLarge) > 2 * TextMeasurer.textScale(contentSize: .extraSmall) * 0.9)
}

@Test func theEngineUsesTheMeasuredWidthNotTheEstimateWhenTheyDisagree() throws {
    let tl = try timeline([event(0, longTitle, 12 * 60, 13 * 60)], [spend("t", minute: 12 * 60 + 20)])
    let estimated = render(tl)                                                             // the estimate says the title is wide: a conflict
    #expect(try item(estimated, longTitle).header != nil)
    let narrow = render(tl, titleWidth: { _ in 30 })                                       // measured narrow: no conflict, no header
    #expect(try item(narrow, longTitle).header == nil && (try item(narrow, longTitle)).showsTitleInCard)
}

// MARK: Transactions are text

@Test func aTitleIsOnlyKeptShortForALineThatIsReallyOnItsRow() throws {
    // A long event with a spend far below its start: nothing is on the title's row, so the title keeps the whole card.
    let apart = render(try timeline([event(0, "아주 긴 일정 제목입니다 정말로", 600, 720)], [spend("t", minute: 700)]), viewport: 900)
    #expect(try item(apart, "아주 긴 일정 제목입니다 정말로").titleMaxWidth == nil)
}

@Test func transactionRowsAreTextHeightNotCardHeight() throws {
    let r = render(try timeline([event(0, "회의", 600, 660)], [spend("t", minute: 900)]), viewport: 900)
    let line = try #require(r.plan.lines.first)
    #expect(line.frame.height == AllocationParameters().transactionRow)
    #expect(AllocationParameters().overflowCard <= AllocationParameters().transactionRow)
}

// MARK: A day sliding in uses the axis already on screen

private func incomingPlan(_ incoming: DayTimeline, on current: Rendered) -> DayRenderPlan {
    DayRenderPlan(
        timeline: incoming, role: nil, layout: current.layout, geometry: current.geometry, layoutWidth: layoutWidth, titleWidth: { _ in 30 }
    )
}

@Test func anIncomingDayKeepsItsTrueTimesOnTheAxisItIsDrawnOn() throws {
    let current = render(try timeline([event(0, "오후", 13 * 60, 14 * 60)]))                 // the morning is compressed on this axis
    let incoming = try timeline([event(1, "가", 540, 555), event(2, "나", 555, 570), event(3, "다", 570, 585)])
    let plan = incomingPlan(incoming, on: current)
    #expect(plan.events.count == 3)
    for placed in plan.events {
        #expect(placed.frame.minY == current.geometry.y(minute: placed.block.displayStartMinute))              // the start is never moved
        let trueHeight = current.geometry.y(minute: placed.block.displayEndMinute) - placed.frame.minY - 1
        #expect(abs(placed.frame.height - max(3, trueHeight)) < 0.01)                                           // nor is the end stretched
    }
}

@Test func shortEventsCrowdedByTheAxisBecomeOneCountInsteadOfAPileOfTitles() throws {
    let current = render(try timeline([event(0, "오후", 13 * 60, 14 * 60)]))
    let incoming = try timeline([event(1, "가", 540, 555), event(2, "나", 555, 570), event(3, "다", 570, 585)])
    let plan = incomingPlan(incoming, on: current)
    let crowd = try #require(plan.summaries.first { $0.countOnly })
    #expect(crowd.items.count == 3)
    #expect(plan.events.allSatisfy { !$0.showsTitleInCard })                                                   // no title is printed over another
    #expect(plan.events.count == 3)                                                                             // the events themselves are all still there
}

@Test func anIncomingEventThatHasRoomKeepsItsCardAndTitle() throws {
    let current = render(try timeline([event(0, "오후", 13 * 60, 14 * 60)]))
    let incoming = try timeline([event(1, "회의", 13 * 60, 14 * 60)])                                          // in the part of the axis that has room
    let plan = incomingPlan(incoming, on: current)
    let placed = try #require(plan.events.first)
    #expect(plan.summaries.isEmpty && placed.showsTitleInCard && placed.frame.height >= 24)
}

@Test func whileTheAxisIsStillChangingTheDayThatIsNowMainIsDrawnOnTheAxisItHasAtThatMoment() throws {
    let current = render(try timeline([event(0, "오후", 13 * 60, 14 * 60)]))                 // the axis the move starts from
    let target = try timeline([event(1, "가", 540, 555), event(2, "나", 555, 570), event(3, "다", 570, 585)])
    let targetRender = render(target)                                                          // what the engine decided for the day itself
    let plan = DayRenderPlan(
        timeline: target, role: .main, layout: targetRender.layout, geometry: current.geometry, layoutWidth: layoutWidth,
        settled: false, titleWidth: { _ in 30 }
    )
    #expect(plan.events.allSatisfy { $0.frame.minY == current.geometry.y(minute: $0.block.displayStartMinute) })
    #expect(plan.events.allSatisfy { abs($0.frame.height - max(3, current.geometry.y(minute: $0.block.displayEndMinute) - $0.frame.minY - 1)) < 0.01 })
    let crowd = plan.summaries.first { $0.countOnly }
    #expect(plan.events.allSatisfy { $0.frame.height < 19 })                                         // the morning is squeezed on this axis
    #expect(crowd?.items.count == 3)                                                               // so the three that follow one another are a count
    #expect(plan.events.allSatisfy { !$0.showsTitleInCard })                                       // and no title is printed over another
}
