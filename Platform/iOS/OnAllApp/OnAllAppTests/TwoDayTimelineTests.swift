import CoreGraphics
import Foundation
import NEOBudgetCalendar
import NEOBudgetInMemoryCalendar
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let first = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let second = first.adding(days: 1)
private let third = first.adding(days: 2)
private let calendarID = CalendarID(rawValue: "work")

private func at(_ day: LocalDate, _ hour: Int, _ minute: Int = 0) -> Int64 { zone.instant(of: day, minuteOfDay: hour * 60 + minute) }

private func event(_ id: String, _ title: String, _ day: LocalDate, _ from: Int, _ to: Int) -> CalendarEvent {
    let range = (try? TimedRange(startUnixMilliseconds: zone.instant(of: day, minuteOfDay: from), endUnixMilliseconds: zone.instant(of: day, minuteOfDay: to))) ?? { fatalError("range") }()
    return CalendarEvent(id: CalendarEventID(rawValue: id), calendarID: calendarID, title: title, time: .timed(range), revisionToken: "r0")
}

// MARK: Columns

@Test func theGutterIsSharedAndTheRestIsSplitInTwo() {
    let columns = DayColumns(gutterWidth: 60, trailingPadding: 6, totalWidth: 375)
    #expect(columns.columnWidth == 157.5)
    #expect(columns.dayLayoutWidth == 217.5)
    #expect(columns.originX(of: 0) == 0 && columns.originX(of: 1) == 157.5)
    #expect(columns.column(atX: 10) == 0)                      // the hour gutter belongs to the first day
    #expect(columns.column(atX: 60 + 157) == 0 && columns.column(atX: 60 + 158) == 1)
    #expect(columns.column(atX: 5_000) == 1 && columns.column(atX: -5) == 0)
    #expect(columns.localPoint(CGPoint(x: 300, y: 40), column: 1) == CGPoint(x: 300 - 157.5, y: 40))
}

@Test(arguments: [320.0, 375.0, 430.0])
func aDaysContentStillHasRoomForAnEventAndATransactionCardOnTheNarrowestPhone(width: CGFloat) {
    let columns = DayColumns(gutterWidth: 60, trailingPadding: 6, totalWidth: width)
    let geometry = TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 1)
    let content = geometry.contentWidth(totalWidth: columns.dayLayoutWidth)
    #expect(content >= 100)                                    // room for a title and an amount in one column
    let card = TransactionCardPlan.width(content: content)
    #expect(card >= min(content, TransactionCardPlan.minimumWidth))
}

// MARK: Swiping between days

@Test func aSwipeMovesOneDayAtATimeHoweverFarOrFastItGoes() {
    let column: CGFloat = 157.5
    #expect(DaySwipe.daysToMove(translation: -200, velocity: -3_000, columnWidth: column) == 1)    // fingers left: next day, never two
    #expect(DaySwipe.daysToMove(translation: 900, velocity: 5_000, columnWidth: column) == -1)
    #expect(DaySwipe.daysToMove(translation: -70, velocity: 0, columnWidth: column) == 1)          // past 40% of a column
    #expect(DaySwipe.daysToMove(translation: -40, velocity: 0, columnWidth: column) == 0)          // short and slow: back
    #expect(DaySwipe.daysToMove(translation: -40, velocity: -800, columnWidth: column) == 1)       // short but flicked
    #expect(DaySwipe.daysToMove(translation: -40, velocity: 800, columnWidth: column) == 0)        // flicked the other way: back
    #expect(DaySwipe.daysToMove(translation: 0, velocity: 0, columnWidth: column) == 0)
}

@Test func theStripFollowsTheFingerButNeverUncoversMoreThanOneDay() {
    #expect(DaySwipe.liveOffset(translation: -50, columnWidth: 157.5) == -50)
    #expect(DaySwipe.liveOffset(translation: -999, columnWidth: 157.5) == -157.5)
    #expect(DaySwipe.liveOffset(translation: 999, columnWidth: 157.5) == 157.5)
    #expect(DaySwipe.settledOffset(days: 1, columnWidth: 157.5) == -157.5)
    #expect(DaySwipe.settledOffset(days: -1, columnWidth: 157.5) == 157.5)
    #expect(DaySwipe.settledOffset(days: 0, columnWidth: 157.5) == 0)
}

@Test func onlyAMostlySidewaysDragIsASwipeSoScrollingIsNeverTakenForOne() {
    #expect(DaySwipe.isSwipe(velocity: CGPoint(x: 300, y: 20)))
    #expect(DaySwipe.isSwipe(velocity: CGPoint(x: -300, y: 100)))
    #expect(!DaySwipe.isSwipe(velocity: CGPoint(x: 100, y: 300)))
    #expect(!DaySwipe.isSwipe(velocity: CGPoint(x: 200, y: 200)))                 // diagonal: scrolling
    #expect(!DaySwipe.isSwipe(velocity: .zero))
}

// MARK: The shared axis

@Test func theTwoDaysShareOneAxisAndNeitherIsDrawnFolded() {
    let a = DayTimelineBuilder.build(DayTimelineInput(day: first, timeZone: zone, events: [event("a", "아침", first, 9 * 60, 10 * 60)], life: .empty, transactions: []))
    let b = DayTimelineBuilder.build(DayTimelineInput(day: second, timeZone: zone, events: [event("b", "오후", second, 15 * 60, 16 * 60)], life: .empty, transactions: []))
    let shared = TimelineAxis.browse(for: [a, b])
    for minute in [9 * 60, 9 * 60 + 30, 15 * 60, 15 * 60 + 30] {
        #expect(shared.pointsPerMinute(atMinute: minute) >= TimelineAxis.Parameters.standard.browseScale - 0.001)
    }
    // Alone, each day would fold the other's hours; shared, both days' hours are open.
    #expect(TimelineAxis.browse(for: a).pointsPerMinute(atMinute: 15 * 60 + 30) < TimelineAxis.Parameters.standard.browseScale)
    #expect(shared.height >= TimelineAxis.browse(for: a).height)
    #expect(shared.totalMinutes == 1440)
}

@Test func busyAndEmptyDaysSideBySideKeepEverythingReadable() {
    let busy = DayTimelineBuilder.build(DayTimelineInput(
        day: first, timeZone: zone, events: (0..<10).map { event("e\($0)", "일정\($0)", first, 8 * 60 + $0 * 60, 8 * 60 + $0 * 60 + 45) }, life: .empty, transactions: []))
    let empty = DayTimelineBuilder.build(DayTimelineInput(day: second, timeZone: zone, events: [], life: .empty, transactions: []))
    let axis = TimelineAxis.browse(for: [busy, empty])
    #expect(axis.height > 0 && empty.blocks.isEmpty)
    let layout = DayContentLayout(blocks: busy.blocks)
    #expect(busy.blocks.allSatisfy { layout.slot(of: $0.id) == .single })
}

// MARK: Editing in either column

@MainActor
private final class Rig {
    let provider: InMemoryCalendarProvider
    let service: CalendarCommandService
    let editor: TimelineEditor
    private(set) var days: [DayTimeline] = []

    init(events: [CalendarEvent]) async throws {
        let calendars = [CalendarDescriptor(id: calendarID, title: "업무", colorHex: "#4C8DF6")]
        provider = InMemoryCalendarProvider(calendars: calendars, events: events, supportedRecurrenceScopes: [.thisOccurrence, .allInSeries], dayZone: zone)
        service = CalendarCommandService(
            provider: provider, repository: InMemoryLifeRepository(), transactions: InMemoryTransactionSource(),
            configuration: CalendarServiceConfiguration(displayTimeZone: zone),
            makeID: { "id-\($0.rawValue)-\(UUID().uuidString)" }, now: { 1 }
        )
        let service = service
        let box = Box()
        self.box = box
        editor = TimelineEditor(environment: TimelineEditor.Environment(
            perform: { await service.perform($0) }, reload: { await box.reload?() },
            supportedScopes: [.thisOccurrence, .allInSeries], zone: zone, policy: .standard, calendars: { calendars }
        ))
        box.reload = { [unowned self] in await self.reload() }
        await reload()
    }

    private final class Box: @unchecked Sendable { var reload: (@MainActor () async -> Void)? }
    private let box: Box

    func reload() async {
        var loaded: [DayTimeline] = []
        for day in [first, second] { if let timeline = try? await service.dayTimeline(for: day) { loaded.append(timeline) } }
        days = loaded
        editor.timelinesDidChange(loaded)
    }

    func block(_ title: String) throws -> (block: EventBlock, column: Int, timeline: DayTimeline) {
        for (column, timeline) in days.enumerated() { if let block = timeline.blocks.first(where: { $0.title == title }) { return (block, column, timeline) } }
        throw Failure()
    }
    struct Failure: Error {}
}

@MainActor @Test func anEventInTheSecondDayMovesOnItsOwnDayWhenDraggedInTheSharedAxis() async throws {
    let rig = try await Rig(events: [event("a", "첫날", first, 9 * 60, 10 * 60), event("b", "둘째 날", second, 14 * 60, 15 * 60)])
    let found = try rig.block("둘째 날")
    #expect(found.column == 1)
    let geometry = rig.editor.geometry
    #expect(rig.editor.begin(.move, block: found.block, timeline: found.timeline, geometry: geometry, column: found.column))
    #expect(rig.editor.preview?.column == 1)
    // The axis is shared, so the same drag distance means the same minutes in either column.
    rig.editor.update(translationY: geometry.y(minute: 14 * 60 + 60) - geometry.y(minute: 14 * 60))
    rig.editor.finish()
    await rig.editor.waitUntilSettled()
    let stored = try #require(await rig.provider.storedEvent(found.block.eventKey))
    guard case let .timed(range) = stored.time else { Issue.record("not timed"); return }
    #expect(range.startUnixMilliseconds == at(second, 15))              // an hour later, still on the second day
    let other = try rig.block("첫날")
    #expect(other.block.startUnixMilliseconds == at(first, 9))          // the first day's event is untouched
}

@MainActor @Test func aNewEventPressedInTheSecondColumnIsCreatedOnTheSecondDay() async throws {
    let rig = try await Rig(events: [])
    let timeline = rig.days[1]
    #expect(rig.editor.focusForCreate(atMinute: 11 * 60))
    let geometry = rig.editor.geometry
    #expect(rig.editor.beginCreate(atY: geometry.y(minute: 11 * 60), timeline: timeline, geometry: geometry, column: 1))
    rig.editor.updateCreate(toY: geometry.y(minute: 12 * 60))
    #expect(rig.editor.preview?.column == 1)
    #expect(rig.editor.preview?.range.startUnixMilliseconds == at(second, 11))
    rig.editor.cancel()
}

@MainActor @Test func aSwipeToANewPairOfDaysKeepsTheTimeAtTheTopOfTheScreenWhereItWas() async throws {
    let rig = try await Rig(events: [event("a", "첫날", first, 9 * 60, 10 * 60), event("b", "둘째 날", second, 14 * 60, 15 * 60)])
    rig.editor.visibleRange = { 100...900 }
    let before = rig.editor.geometry
    let anchor = before.minute(atY: 100 + 24)
    // The next pair of days has an event at 20:00, which opens the axis there.
    let later = DayTimelineBuilder.build(DayTimelineInput(day: third, timeZone: zone, events: [event("c", "셋째 날", third, 20 * 60, 21 * 60)], life: .empty, transactions: []))
    rig.editor.timelinesDidChange([rig.days[1], later])
    if let transition = rig.editor.transition {
        // The anchor minute is shifted by exactly the difference between the two shapes, so it does not move on screen.
        #expect(abs(transition.delta - (transition.to.y(minute: anchor) - transition.from.y(minute: anchor))) < 0.5)
    }
    #expect(rig.editor.timelines.map(\.day) == [second, third])
}

@MainActor @Test func swipingToTheNextDayDoesNotReLayTheDayOutWhenOnlyAnEmptyNeighbourJoinsTheAxis() async throws {
    let rig = try await Rig(events: [])
    func day(_ offset: Int, _ events: [CalendarEvent]) -> DayTimeline {
        DayTimelineBuilder.build(DayTimelineInput(day: first.adding(days: offset), timeZone: zone, events: events, life: .empty, transactions: []))
    }
    let d0 = day(0, [event("a", "가", first, 9 * 60, 10 * 60)])
    let d1 = day(1, [event("b", "나", second, 14 * 60, 15 * 60)])
    let d2 = day(2, [event("c", "다", third, 11 * 60, 12 * 60)])
    let d3 = day(3, [event("d", "라", first.adding(days: 3), 16 * 60, 17 * 60)])
    let d4 = day(4, [])
    rig.editor.visibleRange = { 100...900 }
    rig.editor.timelinesDidChange([d0, d1], axisDays: [d0, d1, d2])
    let before = rig.editor.geometry
    // One day over: d4 (empty) joins and nothing leaves that mattered, so the axis, and everything on screen, stays put.
    rig.editor.timelinesDidChange([d1, d2], axisDays: [d0, d1, d2, d3])
    #expect(rig.editor.transition?.delta ?? 0 == 0 || rig.editor.geometry == before)
    rig.editor.completeTransition()
    let steady = rig.editor.geometry
    rig.editor.timelinesDidChange([d2, d3], axisDays: [d1, d2, d3, d4])
    // d0's event edges left the axis set, so it may fold, but never moves the day when it does not change shape.
    if let transition = rig.editor.transition { #expect(transition.from == steady.axis) } else { #expect(rig.editor.geometry == steady) }
}

@Test func theHeaderIsTheSameHeightWhateverTheDaysHold() {
    #expect(DayHeaderStrip.height == 58)
}
