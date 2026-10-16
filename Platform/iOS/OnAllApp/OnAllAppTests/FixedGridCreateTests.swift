import CoreGraphics
import Foundation
import NEOBudgetCalendar
import NEOBudgetInMemoryCalendar
import Testing
@testable import OnAllApp

// Creating an event on the fixed grid: a long press on empty grid picks up a new event (an hour long) that follows the finger on the 15-minute lines
// (`FixedGridCreatePlacement`); when the finger lifts an edit session opens on it (`Target.new`), where it is named, its calendar chosen and its length
// changed; done creates it in the calendar, cancel writes nothing.

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let work = CalendarID(rawValue: "work")
private let home = CalendarID(rawValue: "home")
private let shared = CalendarID(rawValue: "shared")
private typealias I = FixedGridEditInteraction
private typealias P = FixedGridCreatePlacement

private func at(_ hour: Int, _ minute: Int = 0) -> Int64 { zone.instant(of: day, minuteOfDay: hour * 60 + minute) }

// MARK: Picking up and carrying

@Test func aPickedUpEventStartsAtTheLineAtOrBeforeTheFingerAndIsAnHourLong() {
    let p = P(day: day, fingerMinute: 14 * 60 + 40, dayMinutes: 1440) { _ in -12 }
    #expect(p.startMinute == 14 * 60 + 30 && p.endMinute == 15 * 60 + 30)               // the finger is on the card
    #expect(p.durationMinutes == P.defaultMinutes && p.grabOffset == -12)
    // Near the end of the day it stays inside it.
    let late = P(day: day, fingerMinute: 23 * 60 + 50, dayMinutes: 1440) { _ in 0 }
    #expect(late.startMinute == 23 * 60 && late.endMinute == 1440)
    // The offset is taken at the start it was put at.
    var asked: Int?
    _ = P(day: day, fingerMinute: 9 * 60 + 7, dayMinutes: 1440) { asked = $0; return 0 }
    #expect(asked == 9 * 60)
}

@Test func carryingMovesTheStartToTheNearestLineAndTheDayUnderTheFinger() {
    var p = P(day: day, fingerMinute: 10 * 60, dayMinutes: 1440) { _ in 0 }
    var moved = p.move(to: day, minute: 10 * 60 + 7, dayMinutes: 1440)
    #expect(!moved)                                                                       // nearer 10:00 than 10:15: no step
    moved = p.move(to: day, minute: 10 * 60 + 8, dayMinutes: 1440)
    #expect(moved && p.startMinute == 10 * 60 + 15)
    moved = p.move(to: day, minute: -30, dayMinutes: 1440)
    #expect(moved && p.startMinute == 0)                                                  // not before the day
    moved = p.move(to: day, minute: 2000, dayMinutes: 1440)
    #expect(moved && p.startMinute == 23 * 60)                                            // nor past its end
    let next = day.adding(days: 1)
    moved = p.move(to: next, minute: 23 * 60, dayMinutes: 1440)
    #expect(moved && p.day == next)                                                       // another column: another day
    #expect(p.endMinute - p.startMinute == 60)                                            // carrying never changes the length
    let target = p.target
    #expect(target.isNew && target.day == next && target.startMinute == 23 * 60 && target.endMinute == 1440)
}

// MARK: The session of a new event

@Test func aNewEventsSessionIsChangedFromTheStartSoLeavingItCreatesItAndCancelDoesNot() {
    let new = I.Target.new(day: day, startMinute: 600, endMinute: 660)
    var state = I()
    #expect(state.handle(.enter(new)) == [.freeze(session: 1, new), .began(session: 1, new)])
    #expect(state.session?.isDirty == true)
    _ = state.handle(.draftChanged(session: 1, isDirty: false))
    #expect(state.session?.isDirty == true)                                              // still something to save: the event itself
    #expect(state.handle(.tapOutside) == [.handle(session: 1, .none), .commit(session: 1)])

    var cancelled = I()
    _ = cancelled.handle(.enter(new))
    #expect(cancelled.handle(.cancel) == [.discard(session: 1), .unfreeze(session: 1, .middle), .ended(session: 1, .discarded)])

    // Another event tapped while a new one is open: the new one is created first (it is never silently dropped).
    var other = I()
    _ = other.handle(.enter(new))
    let lunch = I.Target(day: day, blockID: BlockID(rawValue: "lunch"), eventKey: CalendarEventKey(calendarID: work, eventID: CalendarEventID(rawValue: "lunch")), startMinute: 720, endMinute: 780)
    #expect(other.handle(.tapEvent(lunch)).contains(.commit(session: 1)))
}

/// An in-memory calendar with two writable calendars and a read-only one, the service over it, and an editor whose `create` runs the real command.
@MainActor
private final class Fixture {
    let provider: InMemoryCalendarProvider
    let service: CalendarCommandService
    let router = FixedGridEditRouter()
    var editor: FixedGridEditor!
    var calendars: [CalendarDescriptor]
    var createOverride: ((CalendarEventDraft) async -> CalendarCommandOutcome?)?

    init(calendars: [CalendarDescriptor] = [
        CalendarDescriptor(id: shared, title: "공유", isWritable: false),
        CalendarDescriptor(id: work, title: "업무"),
        CalendarDescriptor(id: home, title: "개인"),
    ]) async throws {
        self.calendars = calendars
        provider = InMemoryCalendarProvider(calendars: calendars, events: [], supportedRecurrenceScopes: [.thisOccurrence], dayZone: zone)
        service = CalendarCommandService(
            provider: provider, repository: InMemoryLifeRepository(), transactions: InMemoryTransactionSource(),
            configuration: CalendarServiceConfiguration(displayTimeZone: zone), makeID: { "id-\($0.rawValue)" }, now: { 1 }
        )
        editor = FixedGridEditor(router: router, environment: FixedGridEditor.Environment(
            zone: zone, generation: { 0 }, block: { _ in nil }, save: { _ in nil },
            calendars: { [unowned self] in self.calendars },
            create: { [unowned self] draft in
                if let createOverride = self.createOverride { return await createOverride(draft) }
                return await self.service.perform(.createEvent(CreateEventInput(draft: draft)))
            }
        ))
        router.editor = { [unowned self] in self.editor.perform($0) }
    }

    func settle(until done: () -> Bool) async {
        for _ in 0..<200 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func stored() async throws -> [CalendarEvent] {
        let bounds = zone.dayBounds(day)
        return try await provider.events(from: bounds.start, to: bounds.end, calendarIDs: nil)
    }
}

@MainActor
@Test func doneCreatesTheNewEventWithItsNameCalendarAndLengthAndTheGridUnfreezes() async throws {
    let f = try await Fixture()
    var grid: [I.Command] = []
    f.router.grid = { grid.append($0) }
    f.router.send(.enter(.new(day: day, startMinute: 14 * 60, endMinute: 15 * 60)))
    f.router.send(.tapTitle)
    #expect(f.editor.isNew && f.editor.isRenaming && f.editor.isChanged)
    #expect(f.editor.calendarID == work)                                                  // the first one that can be written
    #expect(f.editor.shownTitle == FixedGridEditor.newTitle)
    f.editor.title = "  치과  "
    f.editor.choose(shared)                                                               // read-only: not chosen
    f.editor.choose(home)
    #expect(f.editor.calendarID == home)
    // Its length is changed by its end handle, on the 15-minute lines.
    f.router.send(.handleDrag(.began, .end, point: .zero, minute: nil))
    f.router.send(.handleDrag(.moved, .end, point: .zero, minute: 15 * 60 + 30))
    f.router.send(.handleDrag(.ended, .end, point: .zero, minute: 15 * 60 + 30))
    f.router.send(.confirm)
    await f.settle { f.router.session == nil }
    let events = try await f.stored()
    #expect(events.count == 1)
    let event = try #require(events.first)
    let expected = try TimedRange(startUnixMilliseconds: at(14), endUnixMilliseconds: at(15, 30))
    #expect(event.title == "치과" && event.calendarID == home && event.time == .timed(expected))
    #expect(grid.last == .unfreeze(session: 1, .edge(.end, day: day, minute: 15 * 60 + 30)))
    #expect(f.editor.session == nil && !f.editor.isNew)
}

@MainActor
@Test func aNewEventWithNoNameIsCalledNewEventAndCancelWritesNothing() async throws {
    let f = try await Fixture()
    f.router.send(.enter(.new(day: day, startMinute: 9 * 60, endMinute: 10 * 60)))
    f.router.send(.cancel)
    #expect(try await f.stored().isEmpty)

    f.router.send(.enter(.new(day: day, startMinute: 9 * 60, endMinute: 10 * 60)))
    f.router.send(.tapOutside)                                                            // leaving it keeps it, as a calendar does
    await f.settle { f.router.session == nil }
    let events = try await f.stored()
    #expect(events.map(\.title) == [FixedGridEditor.newTitle] && events.first?.calendarID == work)
}

@MainActor
@Test func aFailedCreateGoesBackToEditingAndWithoutAWritableCalendarNothingOpens() async throws {
    let f = try await Fixture()
    f.createOverride = { _ in .providerFailure(.unsupported("test")) }
    f.router.send(.enter(.new(day: day, startMinute: 9 * 60, endMinute: 10 * 60)))
    f.router.send(.confirm)
    await f.settle { f.router.session?.committing == false }
    #expect(f.router.session?.committing == false && f.editor.isNew && f.editor.message?.isProblem == true)
    f.createOverride = nil
    f.router.send(.confirm)                                                               // tried again
    await f.settle { f.router.session == nil }
    #expect(try await f.stored().count == 1)

    let readOnly = try await Fixture(calendars: [CalendarDescriptor(id: shared, title: "공유", isWritable: false)])
    readOnly.router.send(.enter(.new(day: day, startMinute: 9 * 60, endMinute: 10 * 60)))
    await readOnly.settle { readOnly.router.session == nil }
    #expect(readOnly.router.session == nil && readOnly.editor.message?.text == "일정을 만들 수 있는 캘린더가 없어요")
}
