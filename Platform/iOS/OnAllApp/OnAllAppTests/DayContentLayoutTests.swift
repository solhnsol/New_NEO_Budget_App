import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let calendar = CalendarID(rawValue: "c")
private let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)

private func event(_ index: Int, _ startMinute: Int, _ endMinute: Int) throws -> CalendarEvent {
    let range = try TimedRange(
        startUnixMilliseconds: zone.instant(of: day, minuteOfDay: startMinute),
        endUnixMilliseconds: zone.instant(of: day, minuteOfDay: endMinute)
    )
    return CalendarEvent(id: CalendarEventID(rawValue: "e\(index)"), calendarID: calendar, title: "일정\(index)", time: .timed(range), revisionToken: "r")
}

/// Synthetic transaction: no real merchant, card or amount.
private func spend(_ id: String, minute: Int, won: Int64 = 4_500) throws -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: minute),
        amount: try Money(minorUnits: won, currency: "KRW"), flow: .spend, title: "테스트 \(id)"
    )
}

private func timeline(events: [CalendarEvent], transactions: [TransactionMarker] = [], link: [String: Int] = [:]) throws -> DayTimeline {
    var changes: [LifeChange] = []
    for (id, eventIndex) in link {
        let activityID = ActivityID(rawValue: "A\(eventIndex)")
        let source = try #require(events.first { $0.id.rawValue == "e\(eventIndex)" })
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
    let life = try LifeState.empty.applying(changes)
    return DayTimelineBuilder.build(DayTimelineInput(
        day: day, timeZone: zone, calendars: [CalendarDescriptor(id: calendar, title: "약속")],
        events: events, life: life, transactions: transactions
    ))
}

private let geometry = TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 1)
private let phoneWidth: CGFloat = 375

private func frames(_ layout: DayContentLayout, _ blocks: [EventBlock], width: CGFloat = phoneWidth) -> [BlockID: CGRect] {
    let available = geometry.contentWidth(totalWidth: width)
    return Dictionary(uniqueKeysWithValues: blocks.map { block in
        (block.id, geometry.blockFrame(block, totalWidth: width, insets: DayContentLayout.insets(for: layout.slot(of: block.id), available: available)))
    })
}

private func placements(_ layout: DayContentLayout, _ blocks: [EventBlock], focused: BlockID? = nil, width: CGFloat = phoneWidth) -> [BlockID: DayContentLayout.TitlePlacement] {
    let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
    let all = frames(layout, blocks, width: width)
    return layout.titlePlacements(
        top: { geometry.y(minute: byID[$0]?.displayStartMinute ?? 0) },
        bottom: { geometry.y(minute: byID[$0]?.displayEndMinute ?? 0) },
        left: { (all[$0]?.minX ?? 0) + EventTitleLayer.horizontalPadding },
        right: { (all[$0]?.maxX ?? 0) - EventTitleLayer.horizontalPadding },
        width: { DayContentLayout.estimatedTitleWidth(byID[$0]?.title ?? "", extra: 14) },
        columnRight: geometry.gutterWidth + geometry.contentWidth(totalWidth: width),
        minimumHeight: geometry.minimumBlockHeight, focused: focused
    )
}

/// Where each title is drawn on screen: its box.
private func titleBoxes(_ layout: DayContentLayout, _ blocks: [EventBlock], focused: BlockID? = nil, width: CGFloat = phoneWidth) -> [BlockID: CGRect] {
    let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
    let all = frames(layout, blocks, width: width)
    let places = placements(layout, blocks, focused: focused, width: width)
    return Dictionary(uniqueKeysWithValues: layout.order.compactMap { id in
        guard let frame = all[id], let place = places[id], let block = byID[id] else { return nil }
        let wanted = DayContentLayout.estimatedTitleWidth(block.title, extra: 14)
        let reach = place.overflows ? geometry.gutterWidth + geometry.contentWidth(totalWidth: width) : frame.maxX - EventTitleLayer.horizontalPadding
        let width = min(wanted, reach - (frame.minX + EventTitleLayer.horizontalPadding + place.dx))
        return (id, CGRect(x: frame.minX + EventTitleLayer.horizontalPadding + place.dx, y: frame.minY + place.dy, width: width, height: DayContentLayout.titleRowHeight))
    })
}

private func block(_ timeline: DayTimeline, _ title: String) throws -> EventBlock {
    try #require(timeline.blocks.first { $0.title == title })
}

// MARK: Empty and busy days

@Test func anEmptyDayHasNothingToLayOut() throws {
    let empty = try timeline(events: [])
    let layout = DayContentLayout(blocks: empty.blocks)
    #expect(layout.order.isEmpty && empty.markers.isEmpty)
}

@Test func eventsThatDoNotOverlapAllUseTheFullColumn() throws {
    let busy = try timeline(events: (0..<8).map { try event($0, 8 * 60 + $0 * 90, 8 * 60 + $0 * 90 + 60) })
    let layout = DayContentLayout(blocks: busy.blocks)
    let all = frames(layout, busy.blocks)
    let full = geometry.contentWidth(totalWidth: phoneWidth) - geometry.columnSpacing
    for block in busy.blocks {
        #expect(layout.slot(of: block.id) == .single)
        #expect(all[block.id]?.width == full && all[block.id]?.minX == geometry.gutterWidth)
    }
}

// MARK: Containment and partial overlap

@Test func anEventInsideAnotherIsAnInnerCardWithinItsBounds() throws {
    let nested = try timeline(events: [event(0, 9 * 60, 13 * 60), event(1, 10 * 60, 11 * 60)])
    let outer = try block(nested, "일정0"), inner = try block(nested, "일정1")
    let layout = DayContentLayout(blocks: nested.blocks)
    let all = frames(layout, nested.blocks)
    #expect(layout.slot(of: inner.id).nestDepth == 1 && layout.slot(of: outer.id).nestDepth == 0)
    let (o, i) = (try #require(all[outer.id]), try #require(all[inner.id]))
    #expect(o.contains(i))
    #expect(i.minX > o.minX && i.maxX < o.maxX)             // pulled in on both sides: it reads as inside
    #expect(i.width > 0.7 * o.width)                        // and keeps most of the width, not a narrow lane
    #expect(layout.order.last == inner.id)                  // drawn over the outer card
}

@Test func partiallyOverlappingEventsKeepTheirOwnStartAndEndAndFullWidth() throws {
    let partial = try timeline(events: [event(0, 9 * 60, 11 * 60), event(1, 10 * 60 + 30, 12 * 60 + 30)])
    let first = try block(partial, "일정0"), second = try block(partial, "일정1")
    let layout = DayContentLayout(blocks: partial.blocks)
    let all = frames(layout, partial.blocks)
    let (a, b) = (try #require(all[first.id]), try #require(all[second.id]))
    #expect(a.minY == geometry.y(minute: 9 * 60) && b.minY == geometry.y(minute: 10 * 60 + 30))
    #expect(abs(a.maxY - geometry.y(minute: 11 * 60)) <= 1 && abs(b.maxY - geometry.y(minute: 12 * 60 + 30)) <= 1)
    #expect(b.minX > a.minX && b.maxX == a.maxX)            // shifted in from the left only; not a nested card
    #expect(a.width > 0.8 * (geometry.contentWidth(totalWidth: phoneWidth)))
    #expect(layout.slot(of: second.id).nestDepth == 0)
}

@Test func eventsStartingTogetherKeepTheirEdgesAndEachShowItsTitle() throws {
    let tied = try timeline(events: [event(0, 9 * 60, 10 * 60), event(1, 9 * 60, 11 * 60), event(2, 9 * 60, 10 * 60 + 30)])
    let layout = DayContentLayout(blocks: tied.blocks)
    let all = frames(layout, tied.blocks)
    // The cards stay exactly where their times put them...
    for block in tied.blocks {
        let frame = try #require(all[block.id])
        #expect(frame.minY == geometry.y(minute: block.displayStartMinute))
        #expect(abs(frame.maxY - geometry.y(minute: block.displayEndMinute)) <= 1)
    }
    // ...and only the title text moves, so no two titles overlap.
    let boxes = Array(titleBoxes(layout, tied.blocks).values)
    for (index, box) in boxes.enumerated() { for other in boxes[(index + 1)...] { #expect(!box.intersects(other)) } }
}

@Test func aTitleOnlyMovesWhenItWouldLandOnAnotherTitle() throws {
    let apart = try timeline(events: [event(0, 9 * 60, 12 * 60), event(1, 10 * 60, 11 * 60)])
    let layout = DayContentLayout(blocks: apart.blocks)
    #expect(placements(layout, apart.blocks).values.allSatisfy { $0 == .init() })
    let close = try timeline(events: [event(0, 9 * 60, 12 * 60), event(1, 9 * 60 + 5, 11 * 60)])
    let near = DayContentLayout(blocks: close.blocks)
    let moved = placements(near, close.blocks)
    #expect(moved[try block(close, "일정1").id]?.dy == DayContentLayout.titleRowHeight - 5)
}

// MARK: Three or more overlaps

@Test(arguments: [3, 4, 6, 9])
func everyCardOfADeepOverlapCanStillBeReachedAndKeepsMostOfItsWidth(count: Int) throws {
    // A staircase: each event starts 20 minutes after the previous and they all run into the afternoon.
    let deep = try timeline(events: (0..<count).map { try event($0, 9 * 60 + $0 * 20, 15 * 60) })
    let layout = DayContentLayout(blocks: deep.blocks)
    let all = frames(layout, deep.blocks)
    #expect(Set(deep.blocks.map { layout.slot(of: $0.id).level }).count == count)       // every card has its own level
    for block in deep.blocks {
        let frame = try #require(all[block.id])
        #expect(frame.width >= 0.5 * geometry.contentWidth(totalWidth: phoneWidth))      // never squeezed into a lane
        // Somewhere on the card a touch lands on this card and no other (its exposed strip or its own top).
        let probe = CGPoint(x: frame.minX + 2, y: frame.maxY - 4)
        #expect(layout.topmost(at: probe, frames: all, focused: nil) == block.id)
    }
    // Every title is still shown and none is drawn over another.
    let boxes = Array(titleBoxes(layout, deep.blocks).values)
    for (index, box) in boxes.enumerated() { for other in boxes[(index + 1)...] { #expect(!box.intersects(other)) } }
}

@Test func selectingACardInTheMiddleBringsItToTheFrontAndKeepsItsTrueEdges() throws {
    let deep = try timeline(events: [event(0, 9 * 60, 15 * 60), event(1, 9 * 60 + 10, 15 * 60), event(2, 9 * 60 + 20, 15 * 60)])
    let middle = try block(deep, "일정1")
    let layout = DayContentLayout(blocks: deep.blocks)
    let plain = frames(layout, deep.blocks)
    let focused = frames(layout, deep.blocks)
    let point = CGPoint(x: (focused[middle.id]?.midX ?? 0), y: geometry.y(minute: 12 * 60))
    #expect(layout.topmost(at: point, frames: focused, focused: middle.id) == middle.id)
    #expect(layout.topmost(at: point, frames: plain, focused: nil) != middle.id)         // under the others until picked
    #expect(focused[middle.id]?.minY == geometry.y(minute: 9 * 60 + 10))                   // true edge, so its handles are on its real times
    #expect(placements(layout, deep.blocks, focused: middle.id)[middle.id] == .init())          // and its title stays at its own top
    #expect(layout.hitOrder(focused: middle.id).first == middle.id)
}

@Test func theLevelStepNarrowsRatherThanLettingCardsRunOffTheColumn() throws {
    let wide = DayContentLayout.insets(for: CardSlot(level: 8, maxLevel: 8), available: 300)
    #expect(wide.left <= 300 * DayContentLayout.maximumShiftShare + 0.001)
    let few = DayContentLayout.insets(for: CardSlot(level: 1, maxLevel: 2), available: 300)
    #expect(few.left == DayContentLayout.maximumLevelStep)
}

// MARK: Transactions

@Test func aTransactionWithNoEventIsAnOrdinaryUnlinkedCardWithNoWarning() throws {
    let day = try timeline(events: [event(0, 9 * 60, 10 * 60)], transactions: [spend("t1", minute: 14 * 60)])
    let marker = try #require(day.markers.first)
    #expect(TransactionCardPlan.style(for: marker) == .unlinked)
    #expect(TransactionCardPlan.note(for: .unlinked) == nil)
}

@Test func anUnlinkedTransactionDuringAnEventStaysUnlinkedAndOutOfTheEventTotal() throws {
    let during = try timeline(events: [event(0, 12 * 60, 13 * 60)], transactions: [spend("t1", minute: 12 * 60 + 30)])
    let lunch = try block(during, "일정0")
    #expect(lunch.allocations.isEmpty && lunch.allocatedSpend.isEmpty)        // never attributed on time alone
    #expect(during.markers.map(\.transactionID.rawValue) == ["t1"])
    #expect(during.summary.unlinkedTransactionCount == 1)
    // It is drawn inside the event's time range, but as a card of its own.
    let position = try #require(during.markers.first?.positionMinute)
    #expect(position >= lunch.startMinute && position < lunch.endMinute)
}

@Test func aLinkedTransactionLivesInsideItsEventAndIsNotCountedTwice() throws {
    let linked = try timeline(events: [event(0, 12 * 60, 13 * 60)], transactions: [spend("t1", minute: 12 * 60 + 30)], link: ["t1": 0])
    #expect(linked.markers.isEmpty)
    let lunch = try block(linked, "일정0")
    #expect(lunch.allocations.count == 1)
    let total = try #require(linked.summary.totals.first)
    #expect(total.linkedNetMinorUnits == 4_500 && total.unlinkedNetMinorUnits == 0)
}

@Test func aTransactionLinkedToAnEventButMadeOutsideItsHoursStillBelongsToTheEvent() throws {
    let late = try timeline(events: [event(0, 12 * 60, 13 * 60)], transactions: [spend("t1", minute: 15 * 60)], link: ["t1": 0])
    #expect(late.markers.isEmpty)                                              // no stray second card
    let lunch = try block(late, "일정0")
    let item = try #require(lunch.allocations.first)
    // Its own time is kept, outside the event's range, so the event can show it as the time it was really made.
    #expect(item.occurredAtUnixMilliseconds == zone.instant(of: day, minuteOfDay: 15 * 60))
    #expect(item.occurredAtUnixMilliseconds > lunch.endUnixMilliseconds)
    let total = try #require(late.summary.totals.first)
    #expect(total.linkedNetMinorUnits + total.unlinkedNetMinorUnits == 4_500)  // counted once
}

// MARK: Narrow screens

@Test(arguments: [320.0, 375.0, 430.0])
func aTransactionCardKeepsItsAmountReadableOnEveryPhoneWidth(screenWidth: CGFloat) throws {
    let content = geometry.contentWidth(totalWidth: screenWidth)
    let width = TransactionCardPlan.width(content: content)
    #expect(width >= TransactionCardPlan.minimumWidth && width <= content)
    // The amount of a large purchase still fits next to the icon and padding.
    let widestAmount: CGFloat = 12 * 8                                           // "-12,345,678원" at 12pt, about 8pt a glyph
    #expect(width - 16 - 14 >= widestAmount - 20)
    #expect(TransactionCardPlan.showsTitle(width: width) == (width >= TransactionCardPlan.titleThreshold))
}

@Test func theCardLeavesTheStartOfTheEventUnderItReadable() {
    let content = geometry.contentWidth(totalWidth: 320)
    #expect(content - TransactionCardPlan.width(content: content) >= 80)       // room left of the card for an event title
}

@Test(arguments: [217.5, 250.0, 300.0])
func fiveEventsStartingTogetherKeepEveryTitleApartEvenInTheNarrowestDayColumn(layoutWidth: CGFloat) throws {
    // 217.5 is one of two columns on a 375 point phone; the others are wider and narrower still.
    let cluster = try timeline(events: [event(0, 16 * 60, 17 * 60 + 30), event(1, 16 * 60, 17 * 60), event(2, 16 * 60 + 5, 16 * 60 + 40), event(3, 16 * 60, 17 * 60 + 10), event(4, 16 * 60 + 10, 16 * 60 + 55)])
    let layout = DayContentLayout(blocks: cluster.blocks)
    let boxes = Array(titleBoxes(layout, cluster.blocks, width: layoutWidth).values)
    #expect(boxes.count == 5)
    for (index, box) in boxes.enumerated() { for other in boxes[(index + 1)...] { #expect(!box.intersects(other)) } }
}
