import CoreGraphics
import Foundation
import NEOBudgetCalendar
import NEOBudgetInMemoryCalendar
import Testing
@testable import OnAllApp

// Phase 3A, the four parts joined: the edit session (`FixedGridEditInteraction` through its router) drives `FixedGridEditor`, which holds the event as an
// `EditDraft`, moves it by handle drags and the precision bubble's ±15, and saves it through `EventSavePipeline` on a real command service and in-memory
// calendar. What the session hears back (commitFinished / commitFailed, the unfreeze anchor) is checked, and so is what the calendar holds afterwards.

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let work = CalendarID(rawValue: "work")
private typealias I = FixedGridEditInteraction

private func at(_ hour: Int, _ minute: Int = 0, on date: LocalDate = day) -> Int64 { zone.instant(of: date, minuteOfDay: hour * 60 + minute) }
private func range(_ from: Int64, _ to: Int64) -> TimedRange { (try? TimedRange(startUnixMilliseconds: from, endUnixMilliseconds: to)) ?? { fatalError("range") }() }

/// A calendar with a single event (10:00–11:00), one past midnight (23:00–01:00) and a daily series (14:00–15:00), the service over it, and the timeline as
/// read now (read again after every save, as `AppModel.save` does).
@MainActor
private final class Fixture {
    let provider: InMemoryCalendarProvider
    let service: CalendarCommandService
    let router = FixedGridEditRouter()
    var timeline: DayTimeline
    var editor: FixedGridEditor!
    /// Replaces the real save when set (a failure, a missing service).
    var saveOverride: ((EventSaveRequest) async -> EventSaveResult?)?

    init() async throws {
        let single = CalendarEvent(id: CalendarEventID(rawValue: "one"), calendarID: work, title: "회의", time: .timed(range(at(10), at(11))), revisionToken: "r0")
        let late = CalendarEvent(id: CalendarEventID(rawValue: "late"), calendarID: work, title: "야간", time: .timed(range(at(23), at(1, on: day.adding(days: 1)))), revisionToken: "r0")
        provider = InMemoryCalendarProvider(
            calendars: [CalendarDescriptor(id: work, title: "업무")], events: [single, late], supportedRecurrenceScopes: [.thisOccurrence, .allInSeries], dayZone: zone
        )
        await provider.seedSeries(calendarID: work, title: "스터디", firstStartUnixMilliseconds: at(14), durationMilliseconds: 3_600_000, count: 3)
        service = CalendarCommandService(
            provider: provider, repository: InMemoryLifeRepository(), transactions: InMemoryTransactionSource(),
            configuration: CalendarServiceConfiguration(displayTimeZone: zone), makeID: { "id-\($0.rawValue)" }, now: { 1 }
        )
        timeline = try await service.dayTimeline(for: day)
        let pipeline = EventSavePipeline(service: service, supportedScopes: [.thisOccurrence, .allInSeries], zone: zone)
        editor = FixedGridEditor(router: router, environment: FixedGridEditor.Environment(
            zone: zone, generation: { 0 },
            block: { [unowned self] target in self.timeline.blocks.first { $0.id == target.blockID } ?? self.timeline.blocks.first { $0.eventKey == target.eventKey } },
            save: { [unowned self] request in
                if let saveOverride = self.saveOverride { return await saveOverride(request) }
                let result = await pipeline.save(request)
                if let reread = try? await self.service.dayTimeline(for: day) { self.timeline = reread }
                return result
            }
        ))
        router.editor = { [unowned self] in self.editor.perform($0) }
    }

    func block(_ title: String) -> EventBlock { timeline.blocks.first { $0.title == title }! }
    func target(_ title: String) -> I.Target { I.Target(day: day, block: block(title)) }

    /// The elapsed minute of the day an instant is at (what the screen sends for a finger at that time).
    func minute(_ instant: Int64) -> Int { Int((instant - zone.dayBounds(day).start) / 60_000) }

    func drag(_ handle: I.Handle, toMinute minute: Int) {
        router.send(.handleDrag(.began, handle, point: .zero, minute: nil))
        router.send(.handleDrag(.moved, handle, point: .zero, minute: minute))
        router.send(.handleDrag(.ended, handle, point: .zero, minute: minute))
    }

    /// Waits for a save (or anything else sent from a task) to come back.
    func settle(until done: () -> Bool = { false }) async {
        for _ in 0..<200 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func stored(_ title: String) async -> CalendarEvent? { await provider.storedEvent(block(title).eventKey) }
}

// MARK: Draft, handles, bubble

@MainActor
@Test func aSessionHoldsTheEventAsADraftThatHandleDragsAndTheBubbleMove() async throws {
    let f = try await Fixture()
    f.router.send(.enter(f.target("회의")))
    let draft = try #require(f.editor.draft)
    #expect(draft.range == range(at(10), at(11)) && !draft.isChanged)
    #expect(f.editor.bubbleInput == nil)                                                    // no handle chosen yet

    // The end dragged to 11:37: on the 15-minute grid, 11:30; the session hears the draft changed.
    f.drag(.end, toMinute: f.minute(at(11, 37)))
    #expect(f.editor.draft?.range == range(at(10), at(11, 30)))
    #expect(f.router.session?.isDirty == true)
    // A drag lets the handle go when it ends: no bubble during or after it (the card shows the time).
    #expect(f.router.session?.handle == I.HandleState.none && f.editor.bubbleInput == nil)

    // A tap on the handle brings the end's bubble, at its time, both steps allowed; +15 and −15 go through the draft.
    f.router.send(.handleTap(.end))
    let input = try #require(f.editor.bubbleInput)
    #expect(input.edge == .end && input.instant == Date(timeIntervalSince1970: Double(at(11, 30)) / 1_000))
    #expect(input.canDecrement && input.canIncrement)
    f.editor.bubble(.increment15)
    #expect(f.editor.draft?.range == range(at(10), at(11, 45)))
    f.editor.bubble(.decrement15); f.editor.bubble(.decrement15); f.editor.bubble(.decrement15)
    #expect(f.editor.draft?.range == range(at(10), at(11)))
    #expect(f.router.session?.isDirty == false)                                             // back to the original: not dirty

    // While a handle is dragged there is no bubble; the start's bubble at the minimum length: no later step.
    f.router.send(.handleDrag(.began, .start, point: .zero, minute: nil))
    #expect(f.editor.bubbleInput == nil)
    f.router.send(.handleDrag(.moved, .start, point: .zero, minute: f.minute(at(10, 52))))
    f.router.send(.handleDrag(.ended, .start, point: .zero, minute: f.minute(at(10, 52))))
    #expect(f.editor.draft?.range == range(at(10, 45), at(11)))
    f.router.send(.handleTap(.start))
    #expect(f.editor.bubbleInput?.canIncrement == false && f.editor.bubbleInput?.canDecrement == true)

    // Close: the chosen handle lets go, the bubble goes.
    f.editor.bubble(.dismiss)
    #expect(f.router.session?.handle == I.HandleState.none && f.editor.bubbleInput == nil)
}

@MainActor
@Test func aCancelledDragPutsTheEdgeBackAndCancelDropsTheDraft() async throws {
    let f = try await Fixture()
    f.router.send(.enter(f.target("회의")))
    f.router.send(.handleDrag(.began, .start, point: .zero, minute: nil))
    f.router.send(.handleDrag(.moved, .start, point: .zero, minute: f.minute(at(9))))
    #expect(f.editor.draft?.range == range(at(9), at(11)))
    f.router.send(.handleDrag(.cancelled, .start, point: .zero, minute: nil))
    #expect(f.editor.draft?.range == range(at(10), at(11)) && f.router.session?.isDirty == false)

    f.drag(.start, toMinute: f.minute(at(9)))
    f.router.send(.cancel)
    #expect(f.router.session == nil && f.editor.draft == nil)
    #expect(f.router.log.contains(.discard(session: 1)))
    #expect(await f.stored("회의")?.time == .timed(range(at(10), at(11))))                  // nothing written
}

// MARK: Saving

@MainActor
@Test func doneSavesTheDraftAndTheGridUnfreezesAtTheEditedEdge() async throws {
    let f = try await Fixture()
    f.router.send(.enter(f.target("회의")))
    f.drag(.end, toMinute: f.minute(at(12, 10)))
    f.router.send(.confirm)
    #expect(f.router.session?.committing == true && f.editor.isSaving && f.editor.bubbleInput == nil)
    await f.settle { f.router.session == nil }

    #expect(await f.stored("회의")?.time == .timed(range(at(10), at(12, 15))))
    #expect(f.router.log.contains(.unfreeze(session: 1, .edge(.end, day: day, minute: f.minute(at(12, 15))))))
    #expect(f.router.log.last == .ended(session: 1, .committed))
    #expect(f.editor.draft == nil && f.editor.message == nil)
}

@MainActor
@Test func aRecurringEventAsksForTheScopeAndNoAnswerKeepsEditing() async throws {
    let f = try await Fixture()
    f.router.send(.enter(f.target("스터디")))
    f.drag(.start, toMinute: f.minute(at(13, 30)))
    f.router.send(.confirm)
    await f.settle { f.editor.scopeQuestion != nil }
    let question = try #require(f.editor.scopeQuestion)
    #expect(question.options == [.thisOccurrence, .allInSeries])

    // No answer: back to editing, the change kept, nothing written.
    f.editor.answer(nil)
    #expect(f.router.session?.committing == false && f.router.session?.isDirty == true && !f.editor.isSaving)
    #expect(await f.stored("스터디")?.time == .timed(range(at(14), at(15))))

    // Done again, this occurrence: written.
    f.router.send(.confirm)
    await f.settle { f.editor.scopeQuestion != nil }
    f.editor.answer(.thisOccurrence)
    await f.settle { f.router.session == nil }
    #expect(f.router.log.last == .ended(session: 1, .committed))
    #expect(await f.stored("스터디")?.time == .timed(range(at(13, 30), at(15))))
}

@MainActor
@Test func anEventChangedElsewhereIsNotOverwrittenAndTheSessionEnds() async throws {
    let f = try await Fixture()
    f.router.send(.enter(f.target("회의")))
    f.drag(.end, toMinute: f.minute(at(12)))
    let key = f.block("회의").eventKey
    await f.provider.editExternally(key, update: CalendarEventUpdate(title: "회의 (변경)"))
    f.router.send(.confirm)
    await f.settle { f.router.session == nil }

    #expect(f.router.log.contains(.ended(session: 1, .discarded)))
    #expect(f.editor.message?.text == FixedGridEditor.text(for: .targetChanged(current: try #require(await f.provider.storedEvent(key)))))
    #expect(await f.provider.storedEvent(key)?.time == .timed(range(at(10), at(11))))      // the other change stays; ours was not written
}

@MainActor
@Test func aFailedSaveGoesBackToEditingWithTheChangeAndCanBeTriedAgain() async throws {
    let f = try await Fixture()
    f.router.send(.enter(f.target("회의")))
    f.drag(.end, toMinute: f.minute(at(11, 30)))
    await f.provider.failNextWrite(with: .saveFailed(retryable: true, reason: "test"))
    f.router.send(.confirm)
    await f.settle { f.router.session?.committing == false }
    #expect(f.router.session?.isDirty == true && f.editor.draft?.range == range(at(10), at(11, 30)))
    #expect(f.editor.message?.isProblem == true)

    f.router.send(.confirm)
    await f.settle { f.router.session == nil }
    #expect(f.router.log.last == .ended(session: 1, .committed))
    #expect(await f.stored("회의")?.time == .timed(range(at(10), at(11, 30))))
}

@MainActor
@Test func withoutACalendarTheSaveFailsAndEditingGoesOn() async throws {
    let f = try await Fixture()
    f.saveOverride = { _ in nil }
    f.router.send(.enter(f.target("회의")))
    f.drag(.end, toMinute: f.minute(at(11, 30)))
    f.router.send(.confirm)
    await f.settle { f.router.session?.committing == false }
    #expect(f.router.session != nil && f.editor.message?.isProblem == true)
}

// MARK: What cannot be edited

@MainActor
@Test func anEventOverMidnightEndsItsSessionAtOnceAndSaysWhy() async throws {
    let f = try await Fixture()
    let late = f.block("야간")
    #expect(FixedGridEditor.refusal(for: late, zone: zone) == .spansDays)
    #expect(FixedGridEditor.refusal(for: f.block("회의"), zone: zone) == nil)

    // Even entered (the screen checks first), the session does not stay open.
    f.router.send(.enter(I.Target(day: day, block: late)))
    #expect(f.editor.draft == nil)
    await f.settle { f.router.session == nil }
    #expect(f.router.session == nil && f.router.log.last == .ended(session: 1, .cancelled))
    #expect(f.editor.message?.text == FixedGridEditor.text(for: .spansDays))
}

@MainActor
@Test func anotherEventTappedWithoutChangesMovesTheDraftToIt() async throws {
    let f = try await Fixture()
    f.router.send(.enter(f.target("회의")))
    f.router.send(.tapEvent(f.target("스터디")))
    #expect(f.router.session?.id == 1 && f.editor.draft?.original.title == "스터디")
    #expect(f.editor.draft?.range == range(at(14), at(15)))
}

@MainActor
@Test func aReloadThatChangedTheEventIsNotedWhileEditing() async throws {
    let f = try await Fixture()
    f.router.send(.enter(f.target("회의")))
    #expect(f.editor.conflictNote == nil)
    await f.provider.editExternally(f.block("회의").eventKey, update: CalendarEventUpdate(time: .timed(range(at(10, 30), at(11)))))
    f.timeline = try await f.service.dayTimeline(for: day)
    f.editor.dataChanged(generation: 1, timelines: [f.timeline])
    #expect(f.editor.conflictNote != nil)
}

// MARK: The bar's words

@Test func theBarSaysHowFarAnEdgeMoved() {
    #expect(EditSessionBarText.minutes(15 * 60_000) == "+15분")
    #expect(EditSessionBarText.minutes(-90 * 60_000) == "−1시간 30분")
    #expect(EditSessionBarText.minutes(120 * 60_000) == "+2시간")
}

// MARK: The wheel, the title

@MainActor
@Test func theWheelOffersTheEdgesTimesInsideTheDayAndSetsTheOneTurnedTo() async throws {
    let f = try await Fixture()
    f.router.send(.enter(f.target("회의")))
    f.router.send(.handleTap(.end))
    let end = try #require(f.editor.bubbleInput)
    // The end: from 15 minutes after the start (10:15) to midnight, every quarter hour.
    #expect(end.choices.first == EventSaveTime.date(at(10, 15)) && end.choices.last == EventSaveTime.date(zone.dayBounds(day).end))
    let quarterHours: Int = (1440 - 615) / 15 + 1                                            // 10:15 … 24:00
    #expect(end.choices.count == quarterHours)
    f.editor.bubble(.set(EventSaveTime.date(at(12, 45))))
    #expect(f.editor.draft?.range == range(at(10), at(12, 45)) && f.router.session?.isDirty == true)
    // The start's wheel now ends 15 minutes before the new end.
    f.router.send(.handleTap(.start))
    let start = try #require(f.editor.bubbleInput)
    #expect(start.choices.first == EventSaveTime.date(zone.dayBounds(day).start) && start.choices.last == EventSaveTime.date(at(12, 30)))
    f.editor.bubble(.set(EventSaveTime.date(at(9, 30))))
    #expect(f.editor.draft?.range == range(at(9, 30), at(12, 45)))
}

@MainActor
@Test func aRenameIsSavedWithTheTimeAndABlankTitleKeepsTheOriginal() async throws {
    let f = try await Fixture()
    f.router.send(.enter(f.target("회의")))
    f.router.send(.tapTitle)
    #expect(f.editor.isRenaming && f.editor.title == "회의")
    // Typing makes the session dirty; the card shows what is typed.
    f.editor.title = "  주간 회의 "
    #expect(f.router.session?.isDirty == true)
    #expect(f.editor.newTitle == "주간 회의")
    #expect(f.editor.shownTitle == "  주간 회의 ")
    // A blank title is no change, and when the keyboard goes the original comes back.
    f.editor.title = "   "
    #expect(f.router.session?.isDirty == false && f.editor.shownTitle == "회의")
    f.router.send(.endRename)
    #expect(!f.editor.isRenaming && f.editor.title == "회의")
    // Renamed and moved, done saves both in one write.
    f.router.send(.tapTitle)
    f.editor.title = "주간 회의"
    f.drag(.end, toMinute: f.minute(at(11, 30)))
    #expect(!f.editor.isRenaming)                                                          // the handle ended the renaming, the title kept
    f.router.send(.confirm)
    await f.settle { f.router.session == nil }
    let stored = try #require(await f.provider.storedEvent(CalendarEventKey(calendarID: work, eventID: CalendarEventID(rawValue: "one"))))
    #expect(stored.title == "주간 회의" && stored.time == .timed(range(at(10), at(11, 30))))
}

@MainActor
@Test func cancelDropsATypedTitle() async throws {
    let f = try await Fixture()
    f.router.send(.enter(f.target("회의")))
    f.router.send(.tapTitle)
    f.editor.title = "다른 이름"
    f.router.send(.cancel)
    #expect(f.router.session == nil && f.editor.draft == nil)
    #expect(await f.stored("회의")?.title == "회의")
}
