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
        harness.editor.timelineDidChange(timeline)
        harness.box.reload = { [unowned harness] in
            harness.reloads += 1
            if let fresh = try? await service.dayTimeline(for: day) {
                harness.timeline = fresh
                harness.editor.timelineDidChange(fresh)      // what AppModel does after every reload
            }
        }
        return harness
    }

    var geometry: TimelineGeometry { TimelineGeometry(totalMinutes: timeline.totalMinutes) }

    /// A reload as AppModel does it: read the day again and tell the editor.
    func editorReload() async {
        if let fresh = try? await service.dayTimeline(for: day) {
            timeline = fresh
            editor.timelineDidChange(fresh)
        }
    }

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


// MARK: Browse and edit modes

private func busyDay() -> [CalendarEvent] {
    func event(_ id: String, _ title: String, _ from: Int64, _ to: Int64) -> CalendarEvent {
        CalendarEvent(id: CalendarEventID(rawValue: id), calendarID: writable, title: title, time: .timed(range(from, to)), revisionToken: "r0")
    }
    return [event("a", "수업", at(9), at(10, 30)), event("b", "회의", at(10), at(11)), event("c", "저녁", at(19), at(20))]
}

@MainActor @Test func aLongPressEnlargesTheSurroundingsOfTheEventAndSelectsIt() async throws {
    let h = try await Harness.make(events: busyDay())
    let block = try h.block("회의")
    let browse = h.editor.geometry
    #expect(!h.editor.isEditing && h.editor.selectedKey == nil)
    #expect(browse.axis.isFolded(minute: 14 * 60))                              // the quiet afternoon is folded in browse mode

    #expect(h.editor.enterEditMode(for: block, pressMinute: 10 * 60 + 20))
    #expect(h.editor.isEditing && h.editor.isSelected(block))
    let editing = h.editor.geometry
    #expect(h.editor.enlargedZones == [(9 * 60 + 15)...(11 * 60 + 45)])           // only around the two handles
    #expect(editing.y(minute: 10 * 60 + 15) - editing.y(minute: 10 * 60) >= 24)       // a 15 minute step is easy to hit
    #expect(editing.contentHeight > browse.contentHeight)
    #expect(editing.axis.isFolded(minute: 14 * 60))                                     // far away stays folded: the enlargement is local
    // The press stays under the finger: the scroll request equals how far that minute moved.
    let request = try #require(h.editor.scrollRequest)
    #expect(abs(request.delta - (editing.y(minute: 10 * 60 + 20) - browse.y(minute: 10 * 60 + 20))) < 0.001)
}

@MainActor @Test func leavingEditModeFoldsTheDayBackToExactlyTheBrowseShape() async throws {
    let h = try await Harness.make(events: busyDay())
    let browse = h.editor.geometry
    #expect(h.editor.enterEditMode(for: try h.block("회의"), pressMinute: 10 * 60 + 20))
    let enlarged = h.editor.scrollRequest
    h.editor.exitEditMode()
    #expect(!h.editor.isEditing && h.editor.selectedKey == nil && h.editor.editAnchors == nil)
    #expect(h.editor.geometry == browse)                                                 // the browse axis was never mutated
    let back = try #require(h.editor.scrollRequest)
    #expect(back != enlarged && back.delta < 0)                                          // scrolls back by what was added
}

@MainActor @Test func aReadOnlyEventNeverEntersEditMode() async throws {
    let h = try await Harness.make(events: [meeting("ro-event", calendar: readOnly, editable: false)])
    #expect(h.editor.enterEditMode(for: try h.block("회의"), pressMinute: 10 * 60) == false)
    #expect(!h.editor.isEditing && h.editor.editAnchors == nil)
    #expect(h.editor.feedback?.message.contains("읽기 전용") == true)
}

@MainActor @Test func draggingInsideTheEnlargedRegionMovesInExactFifteenMinuteSteps() async throws {
    let h = try await Harness.make(events: busyDay())
    let block = try h.block("회의")
    #expect(h.editor.enterEditMode(for: block, pressMinute: 10 * 60 + 20))
    let editing = h.editor.geometry
    #expect(h.editor.begin(.move, block: block, timeline: h.timeline, geometry: editing))
    let step = editing.y(minute: 10 * 60 + 15) - editing.y(minute: 10 * 60)
    h.editor.update(translationY: step)
    #expect(try #require(h.editor.preview).range == range(at(10, 15), at(11, 15)))
    h.editor.update(translationY: step * 4)
    #expect(try #require(h.editor.preview).range == range(at(11), at(12)))
    h.editor.update(translationY: -step * 2)
    #expect(try #require(h.editor.preview).range == range(at(9, 30), at(10, 30)))
    h.editor.cancel()
    #expect(h.editor.isEditing)                                                          // cancelling a drag keeps the event selected
}

@MainActor @Test func anEditedEventStaysSelectedAndTheEnlargedRegionFollowsItToItsNewTime() async throws {
    let h = try await Harness.make(events: busyDay())
    let block = try h.block("회의")
    #expect(h.editor.enterEditMode(for: block, pressMinute: 10 * 60 + 20))
    let editing = h.editor.geometry
    #expect(h.editor.begin(.move, block: block, timeline: h.timeline, geometry: editing))
    h.editor.update(translationY: editing.y(minute: 15 * 60) - editing.y(minute: 10 * 60))
    h.editor.finish()
    await h.editor.waitUntilSettled()
    #expect(h.editor.feedback == nil)
    #expect(try await h.stored(block.eventKey).time == .timed(range(at(15), at(16))))
    // Still editing the same event, now around 15:00.
    #expect(h.editor.isEditing && h.editor.selectedKey == block.eventKey)
    let zones = h.editor.enlargedZones
    #expect(zones.contains { $0.contains(15 * 60) } && zones.contains { $0.contains(16 * 60) } && !zones.contains { $0.contains(10 * 60) })
    #expect(h.editor.scrollRequest != nil)
}

@MainActor @Test func placingANewEventEnlargesTheMinuteAndFoldsBackWhetherSavedOrCancelled() async throws {
    let h = try await Harness.make(events: busyDay())
    let browse = h.editor.geometry
    #expect(h.editor.focusForCreate(atMinute: 14 * 60))
    #expect(h.editor.isEditing && h.editor.selectedKey == nil)
    #expect(!h.editor.geometry.axis.isFolded(minute: 14 * 60))                           // the folded afternoon is opened where it matters
    let editing = h.editor.geometry
    #expect(h.editor.beginCreate(atY: editing.y(minute: 14 * 60), timeline: h.timeline, geometry: editing))
    h.editor.updateCreate(toY: editing.y(minute: 14 * 60 + 45))
    #expect(try #require(h.editor.preview).range == range(at(14), at(14, 45)))
    h.editor.finish()
    #expect(h.editor.mode == .namingEvent)
    h.editor.cancel()
    #expect(!h.editor.isEditing && h.editor.geometry == browse)                          // cancelled: folded back

    #expect(h.editor.focusForCreate(atMinute: 14 * 60))
    let again = h.editor.geometry
    #expect(h.editor.beginCreate(atY: again.y(minute: 14 * 60), timeline: h.timeline, geometry: again))
    h.editor.updateCreate(toY: again.y(minute: 15 * 60))
    h.editor.finish()
    h.editor.confirmCreate(title: "산책", calendarID: writable)
    await h.editor.waitUntilSettled()
    #expect(!h.editor.isEditing)                                                         // saved: folded back, nothing stays selected
    #expect(h.timeline.blocks.contains { $0.title == "산책" })
}

@MainActor @Test func theSelectedEventIsFollowedWhenItChangesElsewhereAndEditModeEndsWhenItDisappears() async throws {
    let h = try await Harness.make(events: busyDay())
    let block = try h.block("저녁")
    #expect(h.editor.enterEditMode(for: block, pressMinute: 19 * 60 + 10))
    await h.provider.editExternally(block.eventKey, update: CalendarEventUpdate(time: .timed(range(at(21), at(22)))))
    await h.editorReload()
    #expect(h.editor.isEditing && h.editor.enlargedZones.contains { $0.contains(21 * 60) })
    await h.provider.removeExternally(block.eventKey)
    await h.editorReload()
    #expect(!h.editor.isEditing && h.editor.selectedKey == nil)
}

@MainActor @Test func movesReportedWhileTheAxisIsStillSettlingAreIgnoredSoThePreviewDoesNotJump() async throws {
    let h = try await Harness.make(events: busyDay())
    let block = try h.block("회의")
    #expect(h.editor.enterEditMode(for: block, pressMinute: 10 * 60 + 20))
    #expect(h.editor.begin(.move, block: block, timeline: h.timeline, geometry: h.editor.geometry))
    let before = try #require(h.editor.preview)
    h.editor.setFingerAnchor(y: 0)
    h.editor.update(fingerY: 5_000)               // the scroll offset is still animating: this reading is not a real drag
    #expect(h.editor.preview == before)
    h.editor.cancel()
}

// MARK: Touch targets

@Test func aHandleBeatsTheBodyWhereTheyOverlapAndAnythingOutsideIsNotAHit() {
    let frame = CGRect(x: 60, y: 200, width: 220, height: 40)
    let top = EditHit.startHandle(of: frame)
    let bottom = EditHit.endHandle(of: frame)
    #expect(EditHit.hit(top, frame: frame, canResizeStart: true, canResizeEnd: true) == .resizeStart)
    #expect(EditHit.hit(bottom, frame: frame, canResizeStart: true, canResizeEnd: true) == .resizeEnd)
    #expect(EditHit.hit(CGPoint(x: 150, y: 220), frame: frame, canResizeStart: true, canResizeEnd: true) == .body)
    // A dot sits half outside the block, so a short block still has something to grab.
    #expect(EditHit.hit(CGPoint(x: top.x, y: top.y - 12), frame: frame, canResizeStart: true, canResizeEnd: true) == .resizeStart)
    #expect(EditHit.hit(CGPoint(x: 20, y: 400), frame: frame, canResizeStart: true, canResizeEnd: true) == nil)
    // An event that continues from yesterday has no start handle: that touch falls back to the body.
    #expect(EditHit.hit(top, frame: frame, canResizeStart: false, canResizeEnd: true) == .body)
    #expect(EditHit.hit(CGPoint(x: top.x, y: top.y - 12), frame: frame, canResizeStart: false, canResizeEnd: true) == nil)
}


// MARK: Opening an event in place

@MainActor @Test func tappingAnEventOpensItInPlaceAndTappingAgainClosesIt() async throws {
    let h = try await Harness.make(events: busyDay())
    let block = try h.block("회의")
    let browse = h.editor.geometry
    h.editor.toggleExpanded(block)
    #expect(h.editor.isExpanded(block) && h.editor.expandedKey == block.eventKey)
    let opened = h.editor.geometry
    // The block's own minutes are drawn tall enough for its content, and it takes the full width.
    let height = opened.y(minute: block.displayEndMinute) - opened.y(minute: block.displayStartMinute)
    #expect(height >= ExpandedBlockPlan.height(for: block) - 1)
    let frame = opened.blockFrame(block, totalWidth: 400, expanded: true)
    #expect(frame.minX == opened.gutterWidth && frame.width >= 400 - opened.gutterWidth - opened.markerRailWidth - opened.columnSpacing - 0.001)
    // Opening only grows the event's own minutes, so everything above it, including its top edge, stays exactly where it
    // was on screen and no scroll correction is needed.
    #expect(abs(opened.y(minute: block.displayStartMinute) - browse.y(minute: block.displayStartMinute)) < 0.001)
    #expect(h.editor.scrollRequest == nil)

    h.editor.toggleExpanded(block)
    #expect(h.editor.expandedKey == nil && h.editor.geometry == browse)
}

@MainActor @Test func openingAnotherEventClosesTheFirstSoOnlyOneIsOpen() async throws {
    let h = try await Harness.make(events: busyDay())
    let first = try h.block("수업")
    let second = try h.block("저녁")
    h.editor.toggleExpanded(first)
    h.editor.toggleExpanded(second)
    #expect(h.editor.expandedKey == second.eventKey && !h.editor.isExpanded(first))
    let geometry = h.editor.geometry
    #expect(geometry.y(minute: first.displayEndMinute) - geometry.y(minute: first.displayStartMinute) < ExpandedBlockPlan.height(for: first))
}

@MainActor @Test func readingDetailsAndAdjustingTimeNeverHappenTogether() async throws {
    let h = try await Harness.make(events: busyDay())
    let block = try h.block("회의")
    h.editor.toggleExpanded(block)
    // A long press closes the opened event and enters time editing.
    #expect(h.editor.enterEditMode(for: block, pressMinute: 10 * 60 + 20))
    #expect(h.editor.expandedKey == nil && h.editor.isEditing && h.editor.isSelected(block))
    // A tap closes time editing and opens the event instead.
    h.editor.toggleExpanded(block)
    #expect(h.editor.expandedKey == block.eventKey && !h.editor.isEditing && h.editor.selectedKey == nil)
    // Placing a new event also closes it.
    #expect(h.editor.focusForCreate(atMinute: 15 * 60))
    #expect(h.editor.expandedKey == nil && h.editor.isEditing)
}

@MainActor @Test func tappingEmptyTimeFoldsEverythingBack() async throws {
    let h = try await Harness.make(events: busyDay())
    let browse = h.editor.geometry
    h.editor.toggleExpanded(try h.block("회의"))
    h.editor.collapseAll()
    #expect(h.editor.expandedKey == nil && h.editor.geometry == browse)
    #expect(h.editor.enterEditMode(for: try h.block("회의"), pressMinute: 10 * 60 + 20))
    h.editor.collapseAll()
    #expect(!h.editor.isEditing && h.editor.geometry == browse)
}

@MainActor @Test func tapsAreIgnoredWhileAGestureOrADecisionIsInProgress() async throws {
    let h = try await Harness.make(events: busyDay())
    let block = try h.block("회의")
    #expect(h.editor.enterEditMode(for: block, pressMinute: 10 * 60 + 20))
    #expect(h.editor.begin(.move, block: block, timeline: h.timeline, geometry: h.editor.geometry))
    h.editor.toggleExpanded(try h.block("저녁"))                  // mid-drag: nothing opens
    #expect(h.editor.expandedKey == nil && h.editor.isEditing)
    h.editor.cancel()
}

@MainActor @Test func anOpenedEventThatDisappearsElsewhereClosesQuietly() async throws {
    let h = try await Harness.make(events: busyDay())
    let block = try h.block("저녁")
    h.editor.toggleExpanded(block)
    await h.provider.removeExternally(block.eventKey)
    await h.editorReload()
    #expect(h.editor.expandedKey == nil)
}


// MARK: Editing events of every length

private func longEvent(_ id: String, _ title: String, from start: Int64, to end: Int64) -> CalendarEvent {
    CalendarEvent(id: CalendarEventID(rawValue: id), calendarID: writable, title: title, time: .timed(range(start, end)), revisionToken: "r0")
}

@MainActor @Test func enteringEditModeNeverUnfoldsALongEventAndKeepsTheTouchedSpotStill() async throws {
    let h = try await Harness.make(events: [longEvent("w", "워크숍", from: at(9), to: at(17))])
    let block = try h.block("워크숍")
    let browse = h.editor.geometry
    #expect(browse.axis.isFolded(minute: 13 * 60))                                // browse folds the middle of an eight hour event
    // The finger is in the folded middle when the long press fires.
    #expect(h.editor.enterEditMode(for: block, pressMinute: 13 * 60))
    let editing = h.editor.geometry
    #expect(editing.axis.isFolded(minute: 13 * 60))                               // still folded: the day did not unfold
    #expect(h.editor.enlargedZones.count == 2)                                    // one zone per handle, independent
    let growth = editing.contentHeight - browse.contentHeight
    #expect(growth < 400, "grew by \(growth)")                                          // a few hundred points at most, not eight hours (which would be ~770)
    #expect(editing.y(minute: 17 * 60) - editing.y(minute: 9 * 60) < 640)         // both handles on one screen
    #expect(editing.y(minute: 9 * 60 + 15) - editing.y(minute: 9 * 60) >= 24 && editing.y(minute: 17 * 60 + 15) - editing.y(minute: 17 * 60) >= 24)
    // The touched minute keeps its place on screen: the scroll request is how far it moved.
    let request = try #require(h.editor.scrollRequest)
    #expect(abs(request.delta - (editing.y(minute: 13 * 60) - browse.y(minute: 13 * 60))) < 0.001)
}

@MainActor @Test func aTimeAboveTheEventIsAlsoKeptWhereItWasWhenTheFirstHandleGrows() async throws {
    let h = try await Harness.make(events: [longEvent("w", "워크숍", from: at(9), to: at(17)), longEvent("a", "아침", from: at(6), to: at(6, 30))])
    let browse = h.editor.geometry
    #expect(h.editor.enterEditMode(for: try h.block("워크숍"), pressMinute: 9 * 60 + 20))
    let editing = h.editor.geometry
    // Everything above the first enlarged zone is untouched, so it does not move relative to the top of the content.
    #expect(abs(editing.y(minute: 6 * 60) - browse.y(minute: 6 * 60)) < 0.001)
    let request = try #require(h.editor.scrollRequest)
    #expect(abs(request.delta - (editing.y(minute: 9 * 60 + 20) - browse.y(minute: 9 * 60 + 20))) < 0.001)
}

@MainActor @Test func aFullDayEventKeepsBothHandlesOnOneScreenAndFoldsBackToTheTappedSpot() async throws {
    let h = try await Harness.make(events: [longEvent("d", "하루", from: at(0), to: at(0) + 86_400_000)])
    let block = try h.block("하루")
    let browse = h.editor.geometry
    #expect(h.editor.enterEditMode(for: block, pressMinute: 12 * 60))
    let editing = h.editor.geometry
    #expect(h.editor.editAnchors == [0, 1440])
    #expect(h.editor.enlargedZones == [0...45, 1395...1440])
    #expect(editing.axis.isFolded(minute: 12 * 60))
    #expect(editing.contentHeight < 400)                                          // the whole day is still under a screen
    #expect(editing.y(minute: 1440) - editing.y(minute: 0) < 640)
    // Dragging the end handle by one step moves it exactly 15 minutes, even at the very end of the day.
    #expect(h.editor.begin(.resizeEnd, block: block, timeline: h.timeline, geometry: editing))
    h.editor.update(translationY: editing.y(minute: 1440 - 15) - editing.y(minute: 1440))
    #expect(try #require(h.editor.preview).range == range(at(0), at(0) + 86_400_000 - 15 * 60_000))
    h.editor.cancel()
    // A tap outside leaves edit mode and keeps the tapped spot where it was.
    h.editor.exitEditMode(anchorMinute: 12 * 60)
    #expect(h.editor.geometry == browse)
    let back = try #require(h.editor.scrollRequest)
    #expect(abs(back.delta - (browse.y(minute: 12 * 60) - editing.y(minute: 12 * 60))) < 0.001)
}

@MainActor @Test func anEventThatContinuesBothWaysHasNoHandlesSoThePressedMinuteIsEnlarged() async throws {
    let h = try await Harness.make(events: [longEvent("s", "합숙", from: at(20) - 86_400_000, to: at(10) + 86_400_000)])
    let block = try h.block("합숙")
    #expect(block.continuesFromPreviousDay && block.continuesToNextDay)
    #expect(h.editor.enterEditMode(for: block, pressMinute: 14 * 60))
    #expect(h.editor.editAnchors == [14 * 60])
    #expect(h.editor.enlargedZones.count == 1 && h.editor.enlargedZones[0].contains(14 * 60))
    // It can still be moved in exact steps where the finger is.
    let editing = h.editor.geometry
    #expect(editing.y(minute: 14 * 60 + 15) - editing.y(minute: 14 * 60) >= 24)
}

@MainActor @Test func cancellingADragKeepsEditModeAndTheEnlargedZones() async throws {
    let h = try await Harness.make(events: busyDay())
    let block = try h.block("회의")
    #expect(h.editor.enterEditMode(for: block, pressMinute: 10 * 60 + 20))
    let zones = h.editor.enlargedZones
    #expect(h.editor.begin(.resizeStart, block: block, timeline: h.timeline, geometry: h.editor.geometry))
    h.editor.update(translationY: -30)
    h.editor.cancel()
    #expect(h.editor.isEditing && h.editor.enlargedZones == zones && h.editor.mode == .idle)
}

// MARK: Edge adjustment without a drag (VoiceOver)

@MainActor @Test func nudgingAnEdgeMovesItByFifteenMinutesThroughTheSameCommandAsADrag() async throws {
    let h = try await Harness.make(events: [meeting()])
    let block = try h.block("회의")
    #expect(h.editor.enterEditMode(for: block, pressMinute: 10 * 60 + 30))
    h.editor.nudge(.resizeEnd, block: block, minutes: 15)
    await h.editor.waitUntilSettled()
    #expect(try await h.stored(block.eventKey).time == .timed(range(at(10), at(11, 15))))
    let moved = try h.block("회의")
    h.editor.nudge(.resizeStart, block: moved, minutes: -15)
    await h.editor.waitUntilSettled()
    #expect(try await h.stored(block.eventKey).time == .timed(range(at(9, 45), at(11, 15))))
    #expect(h.editor.isEditing && h.editor.feedback == nil)
}

@MainActor @Test func nudgingNeverShrinksBelowTheMinimumOrOvershootsTheDay() async throws {
    let h = try await Harness.make(events: [meeting()])
    let block = try h.block("회의")
    h.editor.nudge(.resizeEnd, block: block, minutes: -60)                       // would make it zero long
    await h.editor.waitUntilSettled()
    let stored = try await h.stored(block.eventKey).time
    guard case let .timed(shrunk) = stored else { Issue.record("expected timed"); return }
    #expect(shrunk.durationMilliseconds >= 15 * 60_000 && shrunk.startUnixMilliseconds == at(10))
}

@MainActor @Test func nudgingARecurringEventAsksForScopeAndAFailedNudgeRollsBack() async throws {
    let h = try await Harness.make(series: true)
    let block = try h.block("스터디")
    h.editor.nudge(.resizeEnd, block: block, minutes: 15)
    #expect(h.editor.mode == .choosingScope && !h.editor.scopeOptions.isEmpty)
    #expect(!h.editor.scopeOptions.contains(.thisAndFuture))
    h.editor.chooseScope(nil)
    #expect(h.editor.mode == .idle)
    #expect(try await h.stored(block.eventKey).time == .timed(range(at(10), at(11))))

    await h.provider.failNextWrite(with: .saveFailed(retryable: true, reason: "test"))
    h.editor.nudge(.resizeEnd, block: block, minutes: 15)
    h.editor.chooseScope(.thisOccurrence)
    await h.editor.waitUntilSettled()
    #expect(h.editor.feedback != nil && h.editor.preview == nil)
    #expect(try await h.stored(block.eventKey).time == .timed(range(at(10), at(11))))      // rolled back
}

@MainActor @Test func nudgingIsIgnoredWhileAGestureIsInProgressAndForTheWrongKind() async throws {
    let h = try await Harness.make(events: [meeting()])
    let block = try h.block("회의")
    #expect(h.editor.begin(.move, block: block, timeline: h.timeline, geometry: h.geometry))
    h.editor.nudge(.resizeEnd, block: block, minutes: 15)
    #expect(h.editor.mode == .dragging)                                          // untouched
    h.editor.cancel()
    h.editor.nudge(.move, block: block, minutes: 15)                             // only edges can be nudged
    #expect(h.editor.mode == .idle)
    #expect(try await h.stored(block.eventKey).time == .timed(range(at(10), at(11))))
}

// MARK: Gestures and touch targets (pure)

@Test func theGestureTableSeparatesTapScrollHandleDragAndMove() {
    // Out of edit mode: a long press on an event enters it; on empty time it starts a new event.
    #expect(TimelineGestureRouter.longPress(on: .otherEvent, isEditing: false) == .enterEditMode)
    #expect(TimelineGestureRouter.longPress(on: .emptyTime, isEditing: false) == .startNewEvent)
    // In edit mode: the first long press never moves anything; only a long press on the selected event picks it up.
    #expect(TimelineGestureRouter.longPress(on: .otherEvent, isEditing: true) == .enterEditMode)
    #expect(TimelineGestureRouter.longPress(on: .selectedEvent, isEditing: true) == .pickUp)
    #expect(TimelineGestureRouter.longPress(on: .handle(.resizeEnd), isEditing: true) == .ignore)
    #expect(TimelineGestureRouter.longPress(on: .selectedEvent, isEditing: false) == .enterEditMode)
    // A plain drag is the scroll view's, everywhere except on a handle.
    for target in [TimelineTouchTarget.selectedEvent, .otherEvent, .emptyTime] {
        #expect(!TimelineGestureRouter.panBegins(on: target, isEditing: true), "\(target)")
    }
    #expect(TimelineGestureRouter.panBegins(on: .handle(.resizeStart), isEditing: true))
    #expect(TimelineGestureRouter.panBegins(on: .handle(.resizeEnd), isEditing: true))
    #expect(!TimelineGestureRouter.panBegins(on: .handle(.resizeStart), isEditing: false))      // handles exist only in edit mode
    // Only a tap on empty time ends edit mode; a tap on an event opens it instead.
    #expect(TimelineGestureRouter.tapEndsEditing(on: .emptyTime))
    #expect(!TimelineGestureRouter.tapEndsEditing(on: .selectedEvent) && !TimelineGestureRouter.tapEndsEditing(on: .otherEvent))
}

@Test(arguments: [
    EventLength(name: "30 minutes", start: 10 * 60, end: 10 * 60 + 30),
    EventLength(name: "2 hours", start: 10 * 60, end: 12 * 60),
    EventLength(name: "8 hours", start: 9 * 60, end: 17 * 60),
    EventLength(name: "24 hours", start: 0, end: 1440),
])
func bothHandlesAreFullSizeTouchTargetsOnOneScreenForEveryEventLength(length: EventLength) {
    let standard = TimelineAxis.Parameters.standard
    let browse = TimelineAxis.browse(totalMinutes: 1440, anchors: [length.start, length.end], parameters: standard)
    let axis = browse.expandedLocally(around: [length.start, length.end], parameters: standard)
    // The frame the block gets on this axis, as TimelineGeometry computes it.
    let top = axis.y(minute: length.start)
    let frame = CGRect(x: 60, y: top, width: 220, height: max(24, axis.y(minute: length.end) - top - 1))
    let start = EditHit.startHandle(of: frame)
    let end = EditHit.endHandle(of: frame)

    // Each handle is reachable at its own centre and its touch target is at least 44 points square.
    #expect(EditHit.handle(at: start, frame: frame, canResizeStart: true, canResizeEnd: true) == .resizeStart, Comment(rawValue: length.name))
    #expect(EditHit.handle(at: end, frame: frame, canResizeStart: true, canResizeEnd: true) == .resizeEnd, Comment(rawValue: length.name))
    for center in [start, end] {
        let target = EditHit.touchFrame(around: center)
        #expect(target.width >= 44 && target.height >= 44, Comment(rawValue: length.name))
    }
    // Both targets fit one phone screen (a little over 640 points of grid) however long the event is.
    #expect(EditHit.touchFrame(around: end).maxY - EditHit.touchFrame(around: start).minY < 640 + 44, Comment(rawValue: length.name))
    // The body is not a handle: a drag that starts there scrolls. The middle of the event is far from both handles.
    let middle = CGPoint(x: frame.midX, y: frame.midY)
    if hypot(middle.x - start.x, middle.y - start.y) > EditHit.handleRadius, hypot(middle.x - end.x, middle.y - end.y) > EditHit.handleRadius {
        #expect(EditHit.handle(at: middle, frame: frame, canResizeStart: true, canResizeEnd: true) == nil, Comment(rawValue: length.name))
        #expect(EditHit.hit(middle, frame: frame, canResizeStart: true, canResizeEnd: true) == .body, Comment(rawValue: length.name))
    }
    // An event that continues into the next day has no end handle to grab.
    #expect(EditHit.handle(at: end, frame: frame, canResizeStart: true, canResizeEnd: false) == nil, Comment(rawValue: length.name))
}

@Test func whereTwoHandlesOverlapOnAShortEventTheNearerOneWins() {
    let frame = CGRect(x: 60, y: 200, width: 60, height: 24)               // a 15 minute event in a narrow column
    let start = EditHit.startHandle(of: frame)
    let end = EditHit.endHandle(of: frame)
    #expect(hypot(start.x - end.x, start.y - end.y) < EditHit.minimumTouchSide)   // the two circles overlap
    #expect(EditHit.handle(at: start, frame: frame, canResizeStart: true, canResizeEnd: true) == .resizeStart)
    #expect(EditHit.handle(at: end, frame: frame, canResizeStart: true, canResizeEnd: true) == .resizeEnd)
    let between = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    #expect(EditHit.handle(at: between, frame: frame, canResizeStart: true, canResizeEnd: true) != nil)
}
