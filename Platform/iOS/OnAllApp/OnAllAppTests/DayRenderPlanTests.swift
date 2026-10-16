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
    // Policy change: no 1pt seam is taken off the end, and no minimum height or "stop short of the next event" is applied. The card spans
    // the axis' y of its real start to the axis' y of its real end.
    let r = render(try timeline([event(0, "회의", 600, 720), event(1, "점심", 780, 840), event(2, "짧음", 900, 905)]))
    for placed in r.plan.events {
        #expect(placed.frame.minY == r.geometry.y(minute: placed.block.startMinute))
        #expect(abs(placed.frame.maxY - r.geometry.y(minute: placed.block.endMinute)) < 0.001)
    }
}

@Test func aTransactionLineSitsAtItsTimeAndItsTextIsNeverWrittenOnAnotherLine() throws {
    // Policy change: rows are no longer pushed down the day to make room. Each stays at its time; where the text of the next would land on
    // the previous one it is not written (its dot and touch area stay) and comes in as the room appears.
    let many = try (0..<8).map { try spend("t\($0)", minute: 700 + ($0 / 2)) }        // pairs at the same minute
    let r = render(try timeline([event(0, "회의", 600, 660)], many), viewport: 5_000)
    let lines = r.plan.lines.sorted { ($0.frame.minY, $0.id) < ($1.frame.minY, $1.id) }
    #expect(lines.count == 8)                                                          // none is dropped
    for line in lines {
        let minute = try #require(r.layout.lines.first { $0.transactionID == line.id }?.minute)
        #expect(abs(line.frame.midY - r.geometry.y(minute: minute)) < 0.01)            // at its real time
    }
    let written = lines.filter { $0.reveal >= 1 }
    for (above, below) in zip(written, written.dropFirst()) { #expect(above.frame.maxY - 8 <= below.frame.minY + 8 + 0.01) }
    #expect(lines.contains { $0.reveal < 1 })                                           // the same-minute twin waits
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
    #expect(a.frame.intersects(b.frame))                                               // truly overlapping events overlap in the same column
}

@Test func eventsThatStartTogetherAreNeverReplacedByACountAndEveryOneKeepsItsOwnCard() throws {
    // Policy change: no "일정 N개" card. Each keeps its Event ID, its own frame from the axis, and can be touched.
    let events = try [event(0, "가", 600, 700), event(1, "나", 600, 690), event(2, "다", 600, 680), event(3, "라", 605, 650)]
    let r = render(try timeline(events))
    #expect(r.plan.events.count == 4 && Set(r.plan.events.map(\.block.title)) == ["가", "나", "다", "라"])
    #expect(r.plan.events.allSatisfy { $0.placement?.overlap.indent ?? 0 <= 1 })
    for placed in r.plan.events {
        #expect(placed.frame.minY == r.geometry.y(minute: placed.block.startMinute))
        #expect(r.plan.hit(at: CGPoint(x: placed.frame.maxX - 2, y: placed.frame.maxY - 2)) != .nothing)
    }
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
    func offers(_ hit: DayRenderPlan.Hit, _ candidate: DayRenderPlan.Candidate) -> Bool {
        switch hit {
        case let .event(id): return candidate == .event(id)
        case let .line(id): return candidate == .line(id)
        case let .overflow(id): return candidate == .overflow(id)
        case let .choose(list): return list.contains(candidate)
        case .nothing: return false
        }
    }
    var crossed = false
    for minute in 600...615 {                                                                  // some minute puts the line right over the card
        let tl = try timeline([event(0, "가", 600, 615)], [spend("t", minute: minute)])
        let layout = AdaptiveLayoutEngine.layout(AllocationInput(main: AllocationDay(tl), secondary: nil, viewportHeight: 900, contentWidth: contentWidth))
        let plan = DayRenderPlan(timeline: tl, role: .main, layout: layout, geometry: TimelineGeometry(axis: layout.axis), layoutWidth: wide, titleWidth: { _ in 40 })
        let line = try #require(plan.lines.first), card = try #require(plan.events.first)
        guard line.frame.intersects(card.drawnFrame) else { continue }
        crossed = true
        let middle = CGPoint(x: line.frame.midX, y: line.frame.midY)
        let hit = plan.hit(at: middle)
        if line.reveal > 0 && line.frame.minY <= card.frame.minY + 0.5 && line.frame.maxY >= card.frame.maxY - 0.5 {
            // The card is wholly under the line's written text: the touch must offer both.
            guard case let .choose(candidates) = hit else { Issue.record("a fully covered event was not offered: \(hit)"); return }
            #expect(candidates.contains(.line("t")) && candidates.contains(.event(card.block.id)))
        } else if line.reveal == 0 && card.drawnFrame.contains(middle) {
            // The line's text is not written over the card: there the card is touched as itself.
            #expect(hit == .event(card.block.id), "\(minute): \(hit)")
        }
        // Whatever covers what, both can be chosen: the event somewhere on its card, the line at its dot.
        let box = card.drawnFrame.insetBy(dx: 1, dy: 1)
        var samples: [CGPoint] = []
        for i in 0...8 {
            for j in 0...4 { samples.append(CGPoint(x: box.minX + box.width * CGFloat(i) / 8, y: box.minY + box.height * CGFloat(j) / 4)) }
        }
        #expect(samples.contains { offers(plan.hit(at: $0), .event(card.block.id)) }, "\(minute): the event cannot be chosen")
        let dot = plan.hit(at: CGPoint(x: line.markFrame.minX + 2, y: line.anchorY ?? line.frame.midY))
        #expect(offers(dot, .line("t")), "\(minute): the line's dot hits \(dot)")
    }
    #expect(crossed)
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
        #expect(placed.frame.minY == current.geometry.y(minute: placed.block.startMinute))                      // the start is never moved
        #expect(abs(placed.frame.height - (current.geometry.y(minute: placed.block.endMinute) - placed.frame.minY)) < 0.001)  // nor is the end stretched
    }
}

@Test func shortEventsCrowdedByTheAxisStayThreeEventsAndWriteNothingOverEachOther() throws {
    // Policy change: they are no longer one "일정 3개" card. Each is its own thin card at its time, with no text where there is no room.
    let current = render(try timeline([event(0, "오후", 13 * 60, 14 * 60)]))
    let incoming = try timeline([event(1, "가", 540, 555), event(2, "나", 555, 570), event(3, "다", 570, 585)])
    let plan = incomingPlan(incoming, on: current)
    #expect(plan.events.count == 3 && Set(plan.events.map(\.block.id)).count == 3)
    #expect(plan.events.allSatisfy { !$0.showsTitleInCard || $0.header != nil || $0.presentation.showsTitle })
    #expect(plan.events.allSatisfy { !$0.presentation.showsTitle })                                           // no title is printed over another
    let frames = plan.events.map(\.frame).sorted { $0.minY < $1.minY }
    for (above, below) in zip(frames, frames.dropFirst()) { #expect(above.maxY <= below.minY + 0.001) }       // and they do not overlap: their times do not
}

@Test func anIncomingEventThatHasRoomKeepsItsCardAndTitle() throws {
    let current = render(try timeline([event(0, "오후", 13 * 60, 14 * 60)]))
    let incoming = try timeline([event(1, "회의", 13 * 60, 14 * 60)])                                          // in the part of the axis that has room
    let plan = incomingPlan(incoming, on: current)
    let placed = try #require(plan.events.first)
    #expect(placed.showsTitleInCard && placed.frame.height >= 24 && placed.presentation.level >= .low)
}

@Test func theSameHeightLooksTheSameWhetherOrNotAnythingIsMoving() throws {
    // Policy change: there is no separate "moving" drawing. A day drawn on an axis other than the one the engine laid it out for is
    // drawn by the same rules: every event's look is a function of its height only.
    let current = render(try timeline([event(0, "오후", 13 * 60, 14 * 60)]))
    let target = try timeline([event(1, "가", 540, 555), event(2, "나", 555, 570), event(3, "다", 570, 585)])
    let targetRender = render(target)
    let plan = DayRenderPlan(
        timeline: target, role: .main, layout: targetRender.layout, geometry: current.geometry, layoutWidth: layoutWidth, titleWidth: { _ in 30 }
    )
    #expect(plan.events.allSatisfy { $0.frame.minY == current.geometry.y(minute: $0.block.startMinute) })
    #expect(plan.events.allSatisfy { abs($0.frame.height - (current.geometry.y(minute: $0.block.endMinute) - $0.frame.minY)) < 0.001 })
    #expect(plan.events.allSatisfy { $0.presentation == EventPresentation.make(height: $0.frame.height, insideCount: 0) })
    #expect(plan.events.allSatisfy { $0.frame.height < 19 })                                       // the morning is squeezed on this axis
    #expect(plan.events.allSatisfy { !$0.presentation.showsTitle && $0.presentation.level < .low })
}

@Test func aShortEventRightBeforeAnotherDoesNotPushItAsideOrRunOverIt() throws {
    // 20:00-20:10 and 20:10-23:00 touch in time and do not overlap; each is exactly its own span.
    let r = render(try timeline([event(0, "짧은 준비", 20 * 60, 20 * 60 + 10), event(1, "밤 작업", 20 * 60 + 10, 23 * 60)]))
    let short = try item(r, "짧은 준비"), long = try item(r, "밤 작업")
    #expect(long.frame.minX == short.frame.minX)                                  // one column: no indent for an overlap that is not there
    #expect(abs(short.frame.maxY - long.frame.minY) < 0.001)                      // they meet exactly where the times meet
    #expect(short.frame.minY == r.geometry.y(minute: short.block.startMinute))
}

@Test func eventsThatReallyOverlapStillIndent() throws {
    let r = render(try timeline([event(0, "가", 600, 660), event(1, "나", 630, 720)]))
    let first = try item(r, "가"), second = try item(r, "나")
    #expect(second.frame.minX > first.frame.minX)
}

@Test func twoEventsThatStartTogetherOverlapInOneColumnAndKeepTheirIDs() throws {
    // Policy change: no lanes. The two overlap on screen, the later one indented a step; titles are kept apart by the title placement.
    let r = render(try timeline([event(0, "Push", 8 * 60, 10 * 60), event(1, "인바디 측정", 8 * 60, 8 * 60 + 30)]))
    let a = try item(r, "Push"), b = try item(r, "인바디 측정")
    #expect(a.frame.intersects(b.frame))
    #expect(a.block.id != b.block.id && a.frame.minY == b.frame.minY)
    #expect(a.frame.width > r.geometry.contentWidth(totalWidth: layoutWidth) / 2 && b.frame.width > r.geometry.contentWidth(totalWidth: layoutWidth) / 2)   // no narrow lanes
    let titleRows = [a, b].filter(\.showsTitleInCard).map { CGRect(x: $0.frame.minX + $0.title.dx, y: $0.frame.minY + $0.title.dy, width: 40, height: 16) }
    if titleRows.count == 2 { #expect(!titleRows[0].intersects(titleRows[1])) }
}

@Test func eventsWithAGapInTimeKeepTheGapOnTheAxis() throws {
    // Policy change: the card is not shortened to "look" separate. Whatever gap the axis gives the gap in time is the gap on screen.
    let r = render(try timeline([event(0, "이동", 16 * 60 + 35, 17 * 60 + 30), event(1, "스크림", 21 * 60, 22 * 60)]))
    let first = try item(r, "이동"), second = try item(r, "스크림")
    #expect(abs((second.frame.minY - first.frame.maxY) - (r.geometry.y(minute: 21 * 60) - r.geometry.y(minute: 17 * 60 + 30))) < 0.001)
}

@Test func sliversThatFollowOneAnotherEachKeepTheirColourOverTheirOwnTime() throws {
    let current = render(try timeline([event(0, "오후", 13 * 60, 14 * 60)]))
    let incoming = try timeline([event(1, "가", 540, 555), event(2, "나", 555, 570), event(3, "다", 570, 585)])
    let plan = incomingPlan(incoming, on: current)
    #expect(plan.events.count == 3)
    #expect(plan.events.allSatisfy { $0.presentation.level <= .sliver && $0.drawnFrame.height >= DayRenderPlan.thinnestDrawn })
    #expect(plan.events.allSatisfy { $0.drawnFrame.midY == $0.frame.midY || $0.drawnFrame == $0.frame })       // the drawn line is centred on the true span
}

@Test func aSliverNeverPushesItsNeighboursTitleAside() throws {
    let current = render(try timeline([event(0, "오후", 13 * 60, 14 * 60)]))                 // the morning is squeezed on this axis
    let incoming = try timeline([event(1, "앞", 540, 550), event(2, "뒤", 550, 630)])
    let plan = incomingPlan(incoming, on: current)
    let first = try #require(plan.events.first { $0.block.title == "앞" }), second = try #require(plan.events.first { $0.block.title == "뒤" })
    #expect(!first.presentation.showsTitle)                                                   // no room for its title
    #expect(second.title == DayContentLayout.TitlePlacement())                                // the neighbour's title is not pushed aside by it
    #expect(abs(first.frame.maxY - second.frame.minY) < 0.001)                                 // the two meet where their times meet
}

@Test func aCardTooThinForATitleGetsAHeaderTabOnlyWhereTheSpaceAboveIsFreeAndALineNever() throws {
    let geometry = TimelineGeometry(totalMinutes: 1440)                                    // the plain axis: a 5 minute event is a thin card
    func plan(_ events: [CalendarEvent]) throws -> DayRenderPlan {
        DayRenderPlan(timeline: try timeline(events), role: nil, layout: nil, geometry: geometry, layoutWidth: layoutWidth, titleWidth: { _ in 30 })
    }
    let alone = try plan([event(1, "앞", 17 * 60, 17 * 60 + 12), event(2, "뒤", 17 * 60 + 12, 18 * 60 + 30)])
    let thin = try #require(alone.events.first { $0.block.title == "앞" })
    #expect(thin.presentation.level == .sliver && !thin.showsTitleInCard)
    let tab = try #require(thin.header)
    #expect(tab.maxY <= thin.drawnFrame.minY + 0.01 && tab.minX == thin.frame.minX)                 // sits on the card, in its column
    #expect(alone.events.filter { $0.block.title != "앞" }.allSatisfy { !$0.frame.intersects(tab) })  // and covers no other event
    let busy = try plan([event(3, "위", 16 * 60 + 40, 16 * 60 + 58), event(1, "앞", 17 * 60, 17 * 60 + 12), event(2, "뒤", 17 * 60 + 12, 18 * 60 + 30)])
    let covered = try #require(busy.events.first { $0.block.title == "앞" })
    #expect(covered.header.map { rect in !busy.events.contains { $0.block.title != "앞" && $0.frame.intersects(rect) } } ?? true)
    // A line (a few minutes on this axis) has no header at all: it is not forced to name itself.
    let line = try plan([event(1, "선", 12 * 60, 12 * 60 + 2)])
    let only = try #require(line.events.first)
    #expect(only.presentation.level == .line && only.header == nil)
}

// MARK: On an axis planned for stability, what is drawn is what the axis has room for

@Test func onAStabilizedAxisEveryLineSitsAtItsTimeAndEveryRowHasItsHeight() throws {
    let events = try [event(0, "회의", 9 * 60, 11 * 60), event(1, "점심", 12 * 60, 13 * 60), event(2, "짧은", 15 * 60, 15 * 60 + 10)]
    let spends = try [spend("a", minute: 9 * 60 + 30), spend("b", minute: 9 * 60 + 36), spend("c", minute: 9 * 60 + 44), spend("d", minute: 14 * 60), spend("e", minute: 14 * 60 + 3)]
    let tl = try timeline(events, spends, link: ["a": 0, "c": 0])
    let main = AllocationDay(tl)
    let empty = { (offset: Int) in AllocationDay(day: main.day.adding(days: offset), totalMinutes: main.totalMinutes, events: [], transactions: []) }
    for viewport in [320, 640, 900] as [CGFloat] {
        let made = StabilizedLayout.make(
            days: [empty(-1), main, empty(1), empty(2)], mainIndex: 1, viewport: viewport,
            contentWidth: TimelineGeometry(totalMinutes: 1440).contentWidth(totalWidth: layoutWidth)
        )
        let geometry = TimelineGeometry(axis: made.layout.axis)
        let plan = DayRenderPlan(timeline: tl, role: .main, layout: made.layout, geometry: geometry, layoutWidth: layoutWidth, titleWidth: { _ in 40 })
        // Events: a card that shows more than its title has the height that level needs, on this very axis.
        for item in plan.events {
            guard let placed = item.placement else { continue }
            if placed.level != .title { #expect(item.frame.height + 1 >= placed.requiredHeight, "\(viewport): \(item.block.title) shows rows without their height") }
            if placed.titleResolution == .externalHeader { #expect(item.header != nil) }
        }
        // Lines: each one drawn at the minute it happened (never pushed down to make room), and none over another.
        let lines = plan.lines.sorted { $0.frame.minY < $1.frame.minY }
        for line in lines {
            let exact = geometry.y(minute: made.layout.lines.first { $0.transactionID == line.id }?.minute ?? 0)
            #expect(abs(line.frame.midY - exact) < 0.6, "\(viewport): \(line.id) was moved off its time")
        }
        for (a, b) in zip(lines, lines.dropFirst()) { #expect(a.frame.maxY <= b.frame.minY + 0.5, "\(viewport): two lines overlap") }
        // Overflows: made only where two lines could not be a row apart on the axis.
        for overflow in plan.overflows {
            let minutes = overflow.members.map(\.minute)
            guard let first = minutes.min(), let last = minutes.max(), minutes.count > 1 else { continue }
            #expect(geometry.y(minute: last) - geometry.y(minute: first) < (AllocationParameters().transactionRow + AllocationParameters().lineGap) * CGFloat(minutes.count - 1) + 0.5)
        }
    }
}

@Test func aCardsRowsStopWhereAnEventInsideItBeginsSoItsTitleIsNotWrittenOverThem() throws {
    // Regression (a new event put around "스터디" on the fixed grid): the enclosing card's "거래 2건" row ran down under the inner card, where the inner
    // card's title is written in the layer above all cards.
    let tl = try timeline(
        [event(0, "새 일정", 750, 945), event(1, "스터디", 840, 900)],
        [spend("a", minute: 760), spend("b", minute: 770), spend("c", minute: 780)], link: ["a": 0, "b": 0, "c": 0]
    )
    var sawRows = false
    for viewport in stride(from: CGFloat(200), through: 1_400, by: 40) {
        let r = render(tl, viewport: viewport)
        let outer = try item(r, "새 일정"), inner = try item(r, "스터디")
        guard let rows = outer.rowsFrame else { continue }
        sawRows = true
        #expect(rows.maxY <= inner.frame.minY + 0.5, "@\(viewport): rows reach \(rows.maxY), 스터디 begins at \(inner.frame.minY)")
    }
    #expect(sawRows)
}

@Test func aTitleMovedDownIsNotWrittenOnACardInsideItsOwnAndItsRowsStayAboveItsEndTime() throws {
    // Regression (a new event 12:15–15:15 put around "스터디" on the fixed grid, under "점심 약속" 12:00): the new event's title, moved down clear of
    // "점심 약속", landed on "스터디"'s card and read as its title; "스터디"'s own title went down a row and its rows ("편의점") down with it, over its "14:30".
    let tl = try timeline(
        [event(0, "점심 약속", 720, 780), event(1, "새 일정", 735, 915), event(2, "스터디", 750, 870)],
        [spend("cafe", minute: 750, won: 4_800), spend("store", minute: 845, won: 3_500)], link: ["cafe": 2, "store": 2]
    )
    let metrics = EventPresentation.Metrics.standard()
    var sawRows = false
    for viewport in stride(from: CGFloat(300), through: 1_600, by: 50) {
        let r = render(tl, viewport: viewport)
        let outer = try item(r, "새 일정"), inner = try item(r, "스터디")
        if outer.showsTitleInCard {
            let titleTop = outer.frame.minY + outer.title.dy
            #expect(titleTop < inner.frame.minY - 0.5 || outer.title.dx > 0 && outer.frame.minX + outer.title.dx >= inner.frame.minX,
                    "@\(viewport): 새 일정's title at \(titleTop) is on 스터디's card from \(inner.frame.minY)")
        }
        guard let rows = inner.rowsFrame else { continue }
        sawRows = true
        if inner.presentation.showsEndTime {
            #expect(rows.maxY <= inner.drawnFrame.maxY - metrics.timeLine - metrics.padding + 0.5, "@\(viewport): 스터디's rows reach \(rows.maxY), its card ends at \(inner.drawnFrame.maxY)")
        }
    }
    #expect(sawRows)
}

// MARK: Inside rows and transaction lines on the fixed grid

/// The demo's two days (`-demo -browse-temporal`) in the shape the fixed grid sees them: a card holding two inside rows ("스터디") over the stretch where a
/// line of another event's transaction ("분식", linked to "점심 약속" but after its end) is drawn, with the next day's "팀 회의" at `meetingStart`.
@MainActor
private func demoLikeFixedGrid(meetingStart: Int, viewport: CGFloat) throws -> [DayRenderPlan] {
    func tx(_ id: String, _ hour: Int, _ minute: Int, _ won: Int64) -> AllocationTransaction {
        AllocationTransaction(id: id, minute: hour * 60 + minute, kind: .spend, currency: "KRW", minorUnits: won)
    }
    let d = (try? LocalDate(year: 2026, month: 10, day: 13)) ?? { fatalError("date") }()
    let days = try [
        AllocationDay(day: d.adding(days: -1), totalMinutes: 1440, events: [AllocationEvent(id: "movie", title: "영화", startMinute: 20 * 60, endMinute: 22 * 60 + 10, linked: [])], transactions: []),
        AllocationDay(day: d, totalMinutes: 1440, events: [
            AllocationEvent(id: "class", title: "알고리즘 수업", startMinute: 9 * 60, endMinute: 10 * 60 + 30, linked: []),
            AllocationEvent(id: "lunch", title: "점심 약속", startMinute: 12 * 60, endMinute: 13 * 60, linked: [
                tx("restaurant", 12, 20, 12_000), tx("dessert", 12, 50, 3_000), tx("parking", 12, 55, 2_000), tx("snack", 13, 20, 3_200),
            ]),
            AllocationEvent(id: "study", title: "스터디", startMinute: 12 * 60 + 30, endMinute: 14 * 60 + 30, linked: [tx("cafe", 12, 30, 4_800), tx("convenience", 14, 5, 3_500)]),
            AllocationEvent(id: "workout", title: "저녁 운동", startMinute: 19 * 60, endMinute: 20 * 60 + 30, linked: []),
        ], transactions: [tx("delivery", 21, 30, 6_200)]),
        AllocationDay(day: d.adding(days: 1), totalMinutes: 1440, events: [AllocationEvent(id: "team", title: "팀 회의", startMinute: meetingStart, endMinute: 16 * 60, linked: [])], transactions: []),
        AllocationDay(day: d.adding(days: 2), totalMinutes: 1440, events: [], transactions: []),
    ].map { try fixtureTimeline($0, zone: zone) }
    let column: CGFloat = (402 - 60) / 2
    let model = FixedGridBrowseModel()
    let window = try #require(model.window(
        strip: days.map { StripDay(day: $0.day, timeline: $0) }, zone: zone,
        environment: FixedGridEnvironment(viewportHeight: viewport, contentWidth: column - 6, textScale: 1)
    ))
    return [DayRole.main, .secondary].enumerated().map { index, role in
        DayRenderPlan(
            prepared: DayRenderPlan.Prepared(timeline: days[index + 1], role: role, layout: window.layout),
            geometry: model.axis(for: days[index + 1].day, partition: window.partition, zone: zone),
            layoutWidth: 60 + column, metrics: .standard(), titleWidth: { window.titleWidths[$0] ?? 40 }
        )
    }
}

@MainActor
@Test func aCardsInsideRowsAreNeverWrittenOverByATransactionLineOnTheFixedGrid() throws {
    // Regression: moving the next day's "팀 회의" to 13:30 gives 13:00–14:00 more height on the shared partition, so "스터디" has room for its rows
    // ("카페" at 12:30) while the line of "분식" (13:20) got room for its text too, and the two were written on top of each other.
    let textInset: CGFloat = 4                                 // a line's text is its frame less this above and below
    var sawRows = false
    for meetingStart in [15 * 60, 13 * 60 + 30] {
        for viewport in [360, 420, 460, 520, 600, 700, 820] as [CGFloat] {
            let plan = try demoLikeFixedGrid(meetingStart: meetingStart, viewport: viewport)[0]
            let written = plan.lines.filter { $0.reveal > 0 }
            for item in plan.events {
                guard let rows = item.rowsFrame else { continue }
                sawRows = sawRows || item.block.title == "스터디"
                // The rows sit inside the card, one below another, each at its own y.
                #expect(rows.minY >= item.drawnFrame.minY && rows.maxY <= item.drawnFrame.maxY + 0.01)
                #expect(rows.height + 0.01 >= min(item.drawnFrame.maxY - rows.minY, (InlineAllocationPlan.rowHeight - 2) * CGFloat(item.presentation.shownRows)))
                for line in written where line.frame.insetBy(dx: 0, dy: textInset).intersects(rows) {
                    // Only while the rows are still coming in may the line's text be partly there, and never more than they are not.
                    #expect(line.reveal <= 1 - item.presentation.transactions + 0.001,
                            "\(meetingStart / 60):\(meetingStart % 60) @\(viewport): line \(line.id) written over \(item.block.title)'s rows")
                }
            }
            // Nothing is lost: the line keeps its time and its touch area, and every inside transaction is still in its card.
            let label = "\(meetingStart / 60):\(meetingStart % 60) @\(viewport)"
            let snack = try #require(plan.lines.first { $0.id == "snack" })
            let study = try #require(plan.events.first { $0.block.title == "스터디" })
            #expect(snack.touchFrame.height > 0)
            #expect(study.insideRows.map(\.transactionID.rawValue).sorted() == ["cafe", "convenience"])
            // Touch follows what is drawn. The dot at the line's time reaches the transaction, and the card it lies across is never what it is
            // confused with (only something whose touch area the engine says meets the line may be asked about too).
            let dot = CGPoint(x: snack.markFrame.minX + 2, y: snack.anchorY ?? snack.frame.midY)
            switch plan.hit(at: dot) {
            case .line("snack"): break
            case let .choose(candidates):
                #expect(candidates.first == .line("snack") && !candidates.contains(.event(study.block.id)), "\(label): the dot of 분식 offers \(candidates)")
            case let other: Issue.record("\(label): the dot of 분식 hits \(other)")
            }
            // Where the line's text is not written, the card under it, its rows included, is touched as the card.
            let points = [CGPoint(x: study.drawnFrame.midX, y: snack.anchorY ?? snack.frame.midY)] + (study.rowsFrame.map { [CGPoint(x: $0.midX, y: $0.minY + 6)] } ?? [])
            for point in points where !written.contains(where: { $0.frame.contains(point) }) {
                #expect(plan.hit(at: point) == .event(study.block.id), "\(label): \(point) on 스터디 hits \(plan.hit(at: point))")
            }
        }
    }
    #expect(sawRows, "no viewport gave 스터디 room for its rows, so the case was never checked")
}
