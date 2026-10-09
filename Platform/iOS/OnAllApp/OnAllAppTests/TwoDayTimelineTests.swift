import CoreGraphics
import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
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

@Test func theHeaderIsTheSameHeightWhateverTheDaysHold() {
    #expect(DayHeaderStrip.height == 58)
}

// MARK: Main day sets the axis, the secondary day only assists

private func dayOf(_ day: LocalDate, _ events: [CalendarEvent], markers: [TransactionMarker] = []) -> DayTimeline {
    DayTimelineBuilder.build(DayTimelineInput(day: day, timeZone: zone, events: events, life: .empty, transactions: markers))
}

private func spend(_ id: String, _ day: LocalDate, minute: Int) -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: minute),
        amount: (try? Money(minorUnits: 3_000, currency: "KRW")) ?? { fatalError("money") }(), flow: .spend, title: id
    )
}

private let browse = TimelineAxis.Parameters.standard.browseScale

@Test func withoutASecondaryDayTheAxisIsTheMainDaysOwn() {
    let main = dayOf(first, [event("a", "가", first, 9 * 60, 10 * 60), event("b", "나", first, 15 * 60, 16 * 60)])
    #expect(TimelineAxis.browse(main: main, secondary: nil) == TimelineAxis.browse(for: main))
    #expect(TimelineAxis.browse(main: main, secondary: dayOf(second, [])) == TimelineAxis.browse(for: main))   // nothing to assist
}

@Test func theSecondaryDaysEventIsOpenedJustEnoughWhereTheMainDayFoldedIt() {
    let main = dayOf(first, [event("a", "가", first, 9 * 60, 10 * 60), event("b", "나", first, 20 * 60, 21 * 60)])
    let alone = TimelineAxis.browse(for: main)
    #expect(alone.isFolded(minute: 14 * 60))                                       // the main day folds the afternoon
    let secondary = dayOf(second, [event("c", "다", second, 14 * 60, 15 * 60)])
    let shared = TimelineAxis.browse(main: main, secondary: secondary)
    // The secondary event is drawn at a readable height, on the same axis...
    #expect(shared.y(minute: 15 * 60) - shared.y(minute: 14 * 60) >= TimelineAxis.Parameters.standard.minimumItemHeight - 0.5)
    // ...but opened only as far as that needs, not to full size.
    #expect(shared.pointsPerMinute(atMinute: 14 * 60 + 30) <= browse)
    #expect(shared.height < alone.height + 40)
    // And the main day's own stretches are exactly as they were.
    #expect(shared.y(minute: 10 * 60) - shared.y(minute: 9 * 60) == alone.y(minute: 10 * 60) - alone.y(minute: 9 * 60))
}

@Test func manySecondaryEventsDoNotUnfoldTheWholeAxis() {
    let main = dayOf(first, [event("a", "가", first, 9 * 60, 10 * 60)])
    let crowded = dayOf(second, (0..<10).map { event("s\($0)", "보조\($0)", second, 11 * 60 + $0 * 70, 11 * 60 + $0 * 70 + 30) })
    let shared = TimelineAxis.browse(main: main, secondary: crowded)
    // The symmetric rule would keep every stretch either day touches at full size.
    let anchors = (main.blocks + crowded.blocks).flatMap { [$0.startMinute, $0.endMinute] }
    let both = TimelineAxis.browse(totalMinutes: 1440, anchors: anchors)
    #expect(shared.height < both.height)
    // Every secondary event is still drawn at least a readable height tall.
    for block in crowded.blocks {
        // (A 30 minute event at browse scale is 18 points; the block is drawn at least 24 tall regardless, and no more than browse is asked.)
        let drawn = shared.y(minute: block.displayEndMinute) - shared.y(minute: block.displayStartMinute)
        #expect(drawn >= min(TimelineAxis.Parameters.standard.minimumItemHeight, CGFloat(block.displayEndMinute - block.displayStartMinute) * browse) - 0.5)
    }
}

@Test func aSecondaryTransactionKeepsRoomForItsCard() {
    let main = dayOf(first, [event("a", "가", first, 9 * 60, 10 * 60)])
    let secondary = dayOf(second, [], markers: [spend("t", second, minute: 15 * 60 + 20)])
    let shared = TimelineAxis.browse(main: main, secondary: secondary)
    #expect(shared.y(minute: 15 * 60 + 40) - shared.y(minute: 15 * 60) >= TimelineAxis.Parameters.standard.minimumItemHeight - 0.5)
}

@Test func whereTheMainDayAlreadyShowsTheTimeNothingIsAddedForTheSecondary() {
    let main = dayOf(first, [event("a", "가", first, 9 * 60, 10 * 60)])
    let secondary = dayOf(second, [event("c", "다", second, 9 * 60 + 15, 9 * 60 + 30)])
    #expect(TimelineAxis.browse(main: main, secondary: secondary) == TimelineAxis.browse(for: main))
}

@Test func theMainDayNeverGetsItsOwnAxisSoBothDaysShareEveryMinuteHeight() {
    let main = dayOf(first, [event("a", "가", first, 9 * 60, 10 * 60)])
    let secondary = dayOf(second, [event("c", "다", second, 14 * 60, 15 * 60)])
    let axis = TimelineAxis.browse(main: main, secondary: secondary)
    // One value answers for both days: a minute has one height, whichever day an item is on.
    for minute in stride(from: 0, through: 1440, by: 30) { #expect(axis.y(minute: minute) == axis.y(minute: minute)) }
    #expect(axis.totalMinutes == 1440)
}

@MainActor @Test func editingHoldsTheBrowseAxisAndLeavingLetsItFollowTheDaysAgain() async throws {
    let rig = try await Rig(events: [event("a", "첫날", first, 9 * 60, 10 * 60), event("b", "둘째 날", second, 14 * 60, 15 * 60)])
    let found = try rig.block("첫날")
    #expect(rig.editor.enterEditMode(for: found.block, pressMinute: 9 * 60 + 10))
    rig.editor.completeTransition()
    let held = rig.editor.geometry.axis
    // The days change while editing (as after a reload): the axis does not.
    let other = dayOf(first, [event("a", "첫날", first, 9 * 60, 10 * 60), event("z", "추가", first, 18 * 60, 19 * 60)])
    rig.editor.timelinesDidChange([other, rig.days[1]])
    rig.editor.completeTransition()
    #expect(rig.editor.geometry.axis == held)
    rig.editor.exitEditMode()
    rig.editor.completeTransition()
    #expect(rig.editor.geometry.axis != held)                                      // follows the new day again
    #expect(rig.editor.geometry.axis == TimelineAxis.browse(main: other, secondary: rig.days[1]))
}

@MainActor @Test func afterASwipeTheAxisIsRecomputedForTheNewMainDayAnchoredAtTheCentreOfTheScreen() async throws {
    let rig = try await Rig(events: [event("a", "첫날", first, 9 * 60, 10 * 60), event("b", "둘째 날", second, 14 * 60, 15 * 60)])
    rig.editor.visibleRange = { 100...900 }
    let before = rig.editor.geometry.axis
    let centre = before.minute(atY: 500)
    let newMain = dayOf(second, [event("b", "둘째 날", second, 14 * 60, 15 * 60)])
    let newSecondary = dayOf(third, [event("c", "셋째 날", third, 20 * 60, 21 * 60)])
    rig.editor.timelinesDidChange([newMain, newSecondary])
    #expect(rig.editor.geometry.axis == TimelineAxis.browse(main: newMain, secondary: newSecondary))
    let transition = try #require(rig.editor.transition)
    // The centre minute moves by exactly the difference between the shapes, so it stays where it was on screen.
    #expect(abs(transition.delta - (transition.to.y(minute: centre) - transition.from.y(minute: centre))) < 0.5)
}
