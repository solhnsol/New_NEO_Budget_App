import Testing
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryCalendar

// MARK: Life repository contract

private let anEvent = event("e", title: "점심", from: at(today, 12), to: at(today, 13))
private func createActivity(_ id: String = "a") -> LifeChange {
    .createActivity(Activity.materialized(from: anEvent, id: ActivityID(rawValue: id), at: 1))
}

@Test func committingAdvancesTheRevisionByOne() throws {
    var repository = InMemoryLifeRepository()
    #expect(try repository.snapshot().revision == 0)
    #expect(try repository.commit([createActivity()], expectedRevision: 0) == .committed(revision: 1))
    #expect(try repository.snapshot().revision == 1)
    #expect(try repository.snapshot().state.activities.count == 1)
}

@Test func aStaleExpectedRevisionIsRefusedWithoutChangingAnything() throws {
    var repository = InMemoryLifeRepository()
    _ = try repository.commit([createActivity("a")], expectedRevision: 0)
    let before = try repository.snapshot()
    #expect(throws: LifeStorageError.staleRevision(expected: 0, actual: 1)) {
        _ = try repository.commit([.createActivity(Activity.materialized(from: event("other", from: 1, to: 2), id: ActivityID(rawValue: "b"), at: 1))], expectedRevision: 0)
    }
    #expect(try repository.snapshot() == before)
}

@Test func anInvalidChangeLeavesTheRevisionAndStateUnchanged() throws {
    var repository = InMemoryLifeRepository()
    let before = try repository.snapshot()
    let bad: [LifeChange] = [
        createActivity("a"),
        .setActivityType(ActivityID(rawValue: "a"), Assigned(ActivityTypeID(rawValue: "nope"), provenance: userProvenance()))
    ]
    #expect(throws: LifeStorageError.invalid(.unknownActivityType(ActivityTypeID(rawValue: "nope")))) {
        _ = try repository.commit(bad, expectedRevision: 0)
    }
    #expect(try repository.snapshot() == before)                   // the valid first change was not kept
}

@Test func theRepositoryStartsFromTheGivenStateAndKeepsSnapshotsIndependent() throws {
    let seeded = try LifeState.empty.applying([createActivity("seed")])
    var repository = InMemoryLifeRepository(initialState: seeded)
    let first = try repository.snapshot()
    _ = try repository.commit([createActivity("later").withEvent(event("x", from: 5, to: 6))], expectedRevision: 0)
    #expect(first.state.activities.count == 1)                     // an earlier snapshot is a value and does not change
    #expect(try repository.snapshot().state.activities.count == 2)
}

private extension LifeChange {
    func withEvent(_ event: CalendarEvent) -> LifeChange {
        if case let .createActivity(activity) = self { return .createActivity(Activity.materialized(from: event, id: activity.id, at: 1)) }
        return self
    }
}

// MARK: Calendar provider contract (the in-memory provider defines the behavior real adapters must match)

private func provider(events: [CalendarEvent] = [], scopes: Set<RecurrenceScope> = [.thisOccurrence]) -> InMemoryCalendarProvider {
    InMemoryCalendarProvider(calendars: defaultCalendars, events: events, supportedRecurrenceScopes: scopes)
}

@Test func providerReturnsOnlyOverlappingEventsInTheRequestedCalendars() async throws {
    let p = provider(events: [
        event("in", calendar: "life", from: at(today, 10), to: at(today, 11)),
        event("other-calendar", calendar: "school", from: at(today, 10), to: at(today, 11)),
        event("next-day", calendar: "life", from: at(today.adding(days: 1), 10), to: at(today.adding(days: 1), 11))
    ])
    let bounds = seoul.dayBounds(today)
    #expect(try await p.events(from: bounds.start, to: bounds.end, calendarIDs: nil).map(\.id.rawValue).sorted() == ["in", "other-calendar"])
    #expect(try await p.events(from: bounds.start, to: bounds.end, calendarIDs: [calendarID("life")]).map(\.id.rawValue) == ["in"])
}

@Test func providerUpdatesArePatchesThatKeepUnmentionedFields() async {
    let original = event("e", title: "회의", from: at(today, 10), to: at(today, 11), notes: "메모")
    let p = provider(events: [original])
    let result = await p.updateEvent(original.key, update: CalendarEventUpdate(title: "새 제목"), scope: .thisOccurrence, expectedRevision: "r0")
    guard case let .success(updated) = result else { Issue.record("expected success, got \(result)"); return }
    #expect(updated.title == "새 제목" && updated.notes == "메모" && updated.time == original.time)
    #expect(updated.revisionToken != original.revisionToken)
}

@Test func providerRefusesAStaleRevisionWithoutWriting() async {
    let original = event("e", title: "회의", from: at(today, 10), to: at(today, 11))
    let p = provider(events: [original])
    await p.editExternally(original.key, update: CalendarEventUpdate(title: "외부"))
    let result = await p.updateEvent(original.key, update: CalendarEventUpdate(title: "내 수정"), scope: .thisOccurrence, expectedRevision: "r0")
    guard case let .conflict(current) = result else { Issue.record("expected conflict, got \(result)"); return }
    #expect(current?.title == "외부")
    #expect(await p.storedEvent(original.key)?.title == "외부")
    let deletion = await p.deleteEvent(original.key, scope: .thisOccurrence, expectedRevision: "r0")
    guard case .conflict = deletion else { Issue.record("expected conflict, got \(deletion)"); return }
    #expect(await p.storedEvent(original.key) != nil)
}

@Test func providerReportsTypedFailuresForUnwritableCalendarsReadOnlyEventsAndUnsupportedScopes() async {
    let readOnlyEvent = event("ro", title: "읽기", from: at(today, 10), to: at(today, 11), editable: false)
    let recurring = event("rec", title: "반복", from: at(today, 12), to: at(today, 13), recurring: true)
    let p = provider(events: [readOnlyEvent, recurring])
    let draft = CalendarEventDraft(calendarID: calendarID("readonly"), title: "x", time: .timed(timed(at(today, 10), at(today, 11))))
    #expect(await p.createEvent(draft) == .failure(.calendarNotWritable(calendarID("readonly"))))
    guard case .failure(.unsupported) = await p.updateEvent(readOnlyEvent.key, update: CalendarEventUpdate(title: "x"), scope: .thisOccurrence, expectedRevision: nil) else {
        Issue.record("expected unsupported for a read-only event")
        return
    }
    guard case .failure(.unsupported) = await p.updateEvent(recurring.key, update: CalendarEventUpdate(title: "x"), scope: .allInSeries, expectedRevision: nil) else {
        Issue.record("expected unsupported for an unsupported scope")
        return
    }
    #expect(await p.updateEvent(key("life", "ghost"), update: CalendarEventUpdate(title: "x"), scope: .thisOccurrence, expectedRevision: nil) == .failure(.eventMissing))
}

@Test func providerFailuresAreOneShotAndThenBehaviorReturnsToNormal() async {
    let p = provider()
    let draft = CalendarEventDraft(calendarID: calendarID("life"), title: "x", time: .timed(timed(at(today, 10), at(today, 11))))
    await p.failNextWrite(with: .saveFailed(retryable: true, reason: "once"))
    #expect(await p.createEvent(draft) == .failure(.saveFailed(retryable: true, reason: "once")))
    guard case .success = await p.createEvent(draft) else { Issue.record("expected success on retry"); return }
}

@Test func revokedAccessFailsEveryReadAndWriteUntilRestored() async throws {
    let original = event("e", title: "회의", from: at(today, 10), to: at(today, 11))
    let p = provider(events: [original])
    await p.setAccessAvailable(false)
    await #expect(throws: CalendarProviderFailure.accessUnavailable) { try await p.calendars() }
    await #expect(throws: CalendarProviderFailure.accessUnavailable) { try await p.event(original.key) }
    let draft = CalendarEventDraft(calendarID: calendarID("life"), title: "x", time: .timed(timed(at(today, 10), at(today, 11))))
    #expect(await p.createEvent(draft) == .failure(.accessUnavailable))
    await p.setAccessAvailable(true)
    #expect(try await p.event(original.key) != nil)
}

@Test func removingACalendarRemovesItsEventsAndFurtherWritesReportItMissing() async throws {
    let p = provider(events: [event("e", calendar: "school", title: "수업", from: at(today, 10), to: at(today, 11))])
    await p.removeCalendarExternally(calendarID("school"))
    #expect(try await p.calendars().map(\.id) == [calendarID("life"), calendarID("readonly")])
    #expect(try await p.event(key("school", "e")) == nil)
    let draft = CalendarEventDraft(calendarID: calendarID("school"), title: "x", time: .timed(timed(at(today, 10), at(today, 11))))
    #expect(await p.createEvent(draft) == .failure(.calendarMissing(calendarID("school"))))
}
