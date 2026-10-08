import CoreGraphics
import Foundation
import NEOBudgetCalendar
import NEOBudgetInMemoryCalendar
import Testing
@testable import OnAllApp

// The editor is driven exactly as the gesture layer drives it, against the real CalendarCommandService and the
// in-memory provider. The same flows run against EventKit in `Platform/iOS/EventKitContractHost`.

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let writable = CalendarID(rawValue: "work")
private let readOnly = CalendarID(rawValue: "ro")

private func at(_ hour: Int, _ minute: Int = 0) -> Int64 { zone.instant(of: day, minuteOfDay: hour * 60 + minute) }
private func range(_ from: Int64, _ to: Int64) -> TimedRange { (try? TimedRange(startUnixMilliseconds: from, endUnixMilliseconds: to)) ?? { fatalError("range") }() }
private let pointsPerMinute = TimelineGeometry(totalMinutes: 1440).pointsPerMinute

@MainActor
private final class Harness {
    let provider: InMemoryCalendarProvider
    let service: CalendarCommandService
    let editor: TimelineEditor
    var timeline: DayTimeline
    private(set) var reloads = 0

    private init(provider: InMemoryCalendarProvider, service: CalendarCommandService, timeline: DayTimeline, scopes: Set<RecurrenceScope>, calendars: [CalendarDescriptor]) {
        self.provider = provider
        self.service = service
        self.timeline = timeline
        // The editor's environment captures this box so `reload` can refresh what the test reads.
        let box = Box()
        self.box = box
        editor = TimelineEditor(environment: TimelineEditor.Environment(
            perform: { await service.perform($0) },
            reload: { await box.reload?() },
            supportedScopes: scopes, zone: zone, policy: .standard, calendars: { calendars }
        ))
    }

    private final class Box: @unchecked Sendable { var reload: (@MainActor () async -> Void)? }
    private let box: Box

    static func make(
        events: [CalendarEvent] = [],
        scopes: Set<RecurrenceScope> = [.thisOccurrence, .allInSeries],
        series: Bool = false
    ) async throws -> Harness {
        let calendars = [
            CalendarDescriptor(id: writable, title: "업무", colorHex: "#4C8DF6"),
            CalendarDescriptor(id: readOnly, title: "공휴일", isWritable: false),
        ]
        let provider = InMemoryCalendarProvider(calendars: calendars, events: events, supportedRecurrenceScopes: scopes, dayZone: zone)
        if series {
            await provider.seedSeries(calendarID: writable, title: "스터디", firstStartUnixMilliseconds: at(10), durationMilliseconds: 3_600_000, count: 4)
        }
        let service = CalendarCommandService(
            provider: provider, repository: InMemoryLifeRepository(), transactions: InMemoryTransactionSource(),
            configuration: CalendarServiceConfiguration(displayTimeZone: zone),
            makeID: { "id-\($0.rawValue)-\(UUID().uuidString)" }, now: { 1 }
        )
        let timeline = try await service.dayTimeline(for: day)
        let harness = Harness(provider: provider, service: service, timeline: timeline, scopes: scopes, calendars: calendars)
        harness.box.reload = { [unowned harness] in
            harness.reloads += 1
            if let fresh = try? await service.dayTimeline(for: day) { harness.timeline = fresh }
        }
        return harness
    }

    var geometry: TimelineGeometry { TimelineGeometry(totalMinutes: timeline.totalMinutes) }

    func block(_ title: String) throws -> EventBlock {
        try #require(timeline.blocks.first { $0.title == title })
    }

    func stored(_ key: CalendarEventKey) async throws -> CalendarEvent {
        try #require(await provider.storedEvent(key))
    }

    func drag(_ kind: TimelineEditPlanner.Kind, _ block: EventBlock, minutes: Double) {
        #expect(editor.begin(kind, block: block, timeline: timeline, geometry: geometry))
        editor.update(translationY: CGFloat(minutes) * pointsPerMinute)
    }
}

private func meeting(_ id: String = "m", calendar: CalendarID = writable, editable: Bool = true) -> CalendarEvent {
    CalendarEvent(
        id: CalendarEventID(rawValue: id), calendarID: calendar, title: "회의", time: .timed(range(at(10), at(11))),
        location: "성수", notes: "메모", isEditable: editable, revisionToken: "r0"
    )
}

// MARK: Move

@MainActor @Test func dragMovesAPreviewOnlyAndCommitsOnceOnRelease() async throws {
    let h = try await Harness.make(events: [meeting()])
    let block = try h.block("회의")
    let before = try await h.stored(block.eventKey)

    h.drag(.move, block, minutes: 0)
    for minutes in stride(from: 5.0, through: 245.0, by: 20) { h.editor.update(translationY: CGFloat(minutes) * pointsPerMinute) }
    // Mid-gesture: a preview exists, the calendar is untouched, nothing was reloaded.
    #expect(h.editor.mode == .dragging && h.editor.preview != nil)
    #expect(try await h.stored(block.eventKey) == before)
    #expect(h.reloads == 0)

    let previewed = try #require(h.editor.preview).range
    h.editor.finish()
    await h.editor.waitUntilSettled()

    let after = try await h.stored(block.eventKey)
    #expect(after.time == .timed(previewed))                     // what was previewed is what was committed
    #expect(after.title == "회의" && after.location == "성수" && after.notes == "메모")
    #expect(h.editor.mode == .idle && h.editor.preview == nil && h.editor.feedback == nil)
    #expect(h.reloads == 1)
    // 10:00 + 245 minutes snaps to 14:05 -> 14:00 (nearest 15 minutes), keeping the one hour duration.
    #expect(previewed == range(at(14), at(15)))
}

@MainActor @Test func droppingWhereItStartedWritesNothing() async throws {
    let h = try await Harness.make(events: [meeting()])
    let block = try h.block("회의")
    h.drag(.move, block, minutes: 3)      // 3 minutes snaps back to the original start
    h.editor.finish()
    await h.editor.waitUntilSettled()
    #expect(h.editor.mode == .idle && h.editor.feedback == nil && h.reloads == 0)
    #expect(try await h.stored(block.eventKey).revisionToken == "r0")
}

// MARK: Resize

@MainActor @Test func resizeSnapsAndNeverShrinksBelowTheMinimum() async throws {
    let h = try await Harness.make(events: [meeting()])
    var block = try h.block("회의")
    h.drag(.resizeEnd, block, minutes: 100)          // 11:00 + 100 -> 12:40 -> snaps to 12:45 (12:37 would round down to 12:30)
    #expect(try #require(h.editor.preview).range == range(at(10), at(12, 45)))
    h.editor.finish()
    await h.editor.waitUntilSettled()
    #expect(try await h.stored(block.eventKey).time == .timed(range(at(10), at(12, 45))))

    block = try h.block("회의")
    h.drag(.resizeStart, block, minutes: 400)        // far below the end: stops 15 minutes before it
    let preview = try #require(h.editor.preview)
    #expect(preview.range == range(at(12, 30), at(12, 45)) && preview.wasClamped)
    h.editor.finish()
    await h.editor.waitUntilSettled()
    #expect(try await h.stored(block.eventKey).time == .timed(range(at(12, 30), at(12, 45))))
}

@MainActor @Test func theBottomEdgeStopsAtTheEndOfTheDay() async throws {
    let h = try await Harness.make(events: [meeting()])
    h.drag(.resizeEnd, try h.block("회의"), minutes: 5_000)
    #expect(try #require(h.editor.preview).range.endUnixMilliseconds == h.timeline.dayEndUnixMilliseconds)
    h.editor.cancel()
}

// MARK: Create

@MainActor @Test func draggingAcrossEmptySpaceCreatesAfterNamingAndCancelDiscards() async throws {
    let h = try await Harness.make()
    // Drag from 15:03 to 16:20.
    #expect(h.editor.beginCreate(atY: CGFloat(15 * 60 + 3) * pointsPerMinute, timeline: h.timeline, geometry: h.geometry))
    h.editor.updateCreate(toY: CGFloat(16 * 60 + 20) * pointsPerMinute)
    #expect(try #require(h.editor.preview).range == range(at(15), at(16, 15)))
    h.editor.finish()
    #expect(h.editor.mode == .namingEvent)               // asks for a title; still nothing written
    #expect(h.timeline.blocks.isEmpty)

    h.editor.cancel()
    await h.editor.waitUntilSettled()
    #expect(h.editor.mode == .idle && h.editor.preview == nil)
    #expect(try await h.provider.events(from: at(0), to: at(23, 59), calendarIDs: nil).isEmpty)

    #expect(h.editor.beginCreate(atY: CGFloat(15 * 60) * pointsPerMinute, timeline: h.timeline, geometry: h.geometry))
    h.editor.updateCreate(toY: CGFloat(16 * 60) * pointsPerMinute)
    h.editor.finish()
    h.editor.confirmCreate(title: "  새 약속  ", calendarID: writable)
    await h.editor.waitUntilSettled()
    let created = try #require(try await h.provider.events(from: at(0), to: at(23, 59), calendarIDs: nil).first)
    #expect(created.title == "새 약속" && created.time == .timed(range(at(15), at(16))) && created.calendarID == writable)
    #expect(h.timeline.blocks.map(\.title) == ["새 약속"])
}

@MainActor @Test func aTinyDragStillCreatesTheMinimumDuration() async throws {
    let h = try await Harness.make()
    #expect(h.editor.beginCreate(atY: CGFloat(9 * 60) * pointsPerMinute, timeline: h.timeline, geometry: h.geometry))
    #expect(try #require(h.editor.preview).range == range(at(9), at(9, 15)))
    h.editor.cancel()
}

// MARK: Recurring scope

@MainActor @Test func aRecurringMoveAsksForScopeOnlyOnReleaseAndNeverOffersThisAndFuture() async throws {
    // Even a provider that declares thisAndFuture must not have it offered.
    let h = try await Harness.make(scopes: [.thisOccurrence, .allInSeries, .thisAndFuture], series: true)
    let block = try #require(h.timeline.blocks.first { $0.title == "스터디" })
    #expect(block.isRecurringInstance)
    let before = try await h.stored(block.eventKey)

    h.drag(.move, block, minutes: 120)
    #expect(h.editor.mode == .dragging && h.editor.scopeOptions.isEmpty)    // no question while dragging
    h.editor.finish()
    #expect(h.editor.mode == .choosingScope)
    #expect(h.editor.scopeOptions == [.thisOccurrence, .allInSeries])
    #expect(try await h.stored(block.eventKey) == before)                  // still nothing written

    h.editor.chooseScope(.allInSeries)
    await h.editor.waitUntilSettled()
    #expect(h.editor.feedback == nil)
    for occurrence in await (try h.provider.events(from: at(0) - 40 * 86_400_000, to: at(0) + 120 * 86_400_000, calendarIDs: [writable])) {
        guard case let .timed(range) = occurrence.time else { continue }
        #expect(zone.minuteOfDay(of: range.startUnixMilliseconds) == 12 * 60, "every occurrence moved to 12:00")
    }
}

@MainActor @Test func choosingThisOccurrenceMovesOnlyThatOne() async throws {
    let h = try await Harness.make(series: true)
    let block = try #require(h.timeline.blocks.first { $0.title == "스터디" })
    let others = try await h.provider.events(from: at(0) - 40 * 86_400_000, to: at(0) + 120 * 86_400_000, calendarIDs: [writable]).filter { $0.key != block.eventKey }
    h.drag(.move, block, minutes: 180)
    h.editor.finish()
    h.editor.chooseScope(.thisOccurrence)
    await h.editor.waitUntilSettled()
    #expect(try await h.stored(block.eventKey).time == .timed(range(at(13), at(14))))
    for other in others { #expect(try await h.stored(other.key).time == other.time) }
}

@MainActor @Test func aMoveToAnotherDayOffersOnlyThisOccurrence() async throws {
    let h = try await Harness.make(series: true)
    let block = try #require(h.timeline.blocks.first { $0.title == "스터디" })
    h.drag(.move, block, minutes: 15 * 60)       // 10:00 + 15h crosses midnight
    h.editor.finish()
    #expect(h.editor.mode == .choosingScope && h.editor.scopeOptions == [.thisOccurrence])
    h.editor.chooseScope(nil)                    // cancel
    #expect(h.editor.mode == .idle && h.editor.preview == nil)
    #expect(try await h.stored(block.eventKey).time == block.startUnixMilliseconds.asTimed(to: block.endUnixMilliseconds))
}

// MARK: Failures roll the preview back and say why

@MainActor @Test func aStaleRevisionIsRefusedRolledBackAndReloaded() async throws {
    let h = try await Harness.make(events: [meeting()])
    let block = try h.block("회의")
    h.drag(.move, block, minutes: 240)
    await h.provider.editExternally(block.eventKey, update: CalendarEventUpdate(title: "다른 곳에서 바꿈"))
    h.editor.finish()
    await h.editor.waitUntilSettled()
    let feedback = try #require(h.editor.feedback)
    #expect(feedback.tone == .error && !feedback.canRetry && feedback.message.contains("다른 곳에서"))
    #expect(h.editor.mode == .idle && h.editor.preview == nil)
    let after = try await h.stored(block.eventKey)
    #expect(after.time == .timed(range(at(10), at(11))) && after.title == "다른 곳에서 바꿈")
    #expect(h.timeline.blocks.first?.title == "다른 곳에서 바꿈")                    // shows the calendar's truth
}

@MainActor @Test func aReadOnlyEventCannotBePickedUp() async throws {
    let h = try await Harness.make(events: [meeting("ro-event", calendar: readOnly, editable: false)])
    let block = try h.block("회의")
    #expect(h.editor.begin(.move, block: block, timeline: h.timeline, geometry: h.geometry) == false)
    #expect(h.editor.mode == .idle && h.editor.preview == nil)
    #expect(h.editor.feedback?.message.contains("읽기 전용") == true)
}

@MainActor @Test func aCalendarThatTurnedReadOnlyAfterLoadingRefusesTheWriteAndRollsBack() async throws {
    let h = try await Harness.make(events: [meeting()])
    let block = try h.block("회의")
    h.drag(.move, block, minutes: 120)
    await h.provider.addCalendar(CalendarDescriptor(id: writable, title: "업무", isWritable: false))      // permissions changed under us
    h.editor.finish()
    await h.editor.waitUntilSettled()
    #expect(h.editor.feedback?.message.contains("읽기 전용") == true && h.editor.feedback?.canRetry == false)
    #expect(h.editor.preview == nil && h.editor.mode == .idle)
    #expect(try await h.stored(block.eventKey).time == .timed(range(at(10), at(11))))
}

@MainActor @Test func aSaveFailureRollsBackOffersRetryAndTheRetrySucceeds() async throws {
    let h = try await Harness.make(events: [meeting()])
    let block = try h.block("회의")
    h.drag(.move, block, minutes: 240)
    await h.provider.failNextWrite(with: .saveFailed(retryable: true, reason: "disk"))
    h.editor.finish()
    await h.editor.waitUntilSettled()
    #expect(h.editor.feedback?.canRetry == true && h.editor.preview == nil && h.editor.mode == .idle)
    #expect(try await h.stored(block.eventKey).time == .timed(range(at(10), at(11))))

    h.editor.retry()
    await h.editor.waitUntilSettled()
    #expect(h.editor.feedback == nil)
    #expect(try await h.stored(block.eventKey).time == .timed(range(at(14), at(15))))
}

@MainActor @Test func aSecondGestureCannotStartWhileOneIsInProgress() async throws {
    let h = try await Harness.make(events: [meeting(), meeting("m2")])
    let first = try #require(h.timeline.blocks.first)
    #expect(h.editor.begin(.move, block: first, timeline: h.timeline, geometry: h.geometry))
    #expect(h.editor.begin(.resizeEnd, block: first, timeline: h.timeline, geometry: h.geometry) == false)
    #expect(h.editor.beginCreate(atY: 100, timeline: h.timeline, geometry: h.geometry) == false)
    h.editor.cancel()
}

// MARK: Planner and messages

@MainActor @Test func theFeedbackNamesEveryFailureKindWithoutLeakingInternals() {
    let outcomes: [CalendarCommandOutcome] = [
        .conflict(current: nil), .rejected(.eventNotEditable), .rejected(.dateChangeRequiresThisOccurrence),
        .providerFailure(.calendarNotWritable(readOnly)), .providerFailure(.accessUnavailable),
        .providerFailure(.eventMissing), .providerFailure(.saveFailed(retryable: true, reason: "x")),
        .providerFailure(.saveFailed(retryable: false, reason: "x")), .providerFailure(.unsupported("scope")),
    ]
    for outcome in outcomes {
        let feedback = EditFeedback.make(for: outcome)
        #expect(feedback != nil && feedback?.message.isEmpty == false, "\(outcome)")
        #expect(feedback?.message.contains("saveFailed") == false)
    }
    #expect(EditFeedback.make(for: .applied(AppliedCommand())) == nil)
    #expect(EditFeedback.make(for: .providerFailure(.saveFailed(retryable: true, reason: "x")))?.canRetry == true)
    #expect(EditFeedback.make(for: .providerFailure(.saveFailed(retryable: false, reason: "x")))?.canRetry == false)
}

private extension Int64 {
    func asTimed(to end: Int64) -> EventTimeRange { .timed(range(self, end)) }
}
