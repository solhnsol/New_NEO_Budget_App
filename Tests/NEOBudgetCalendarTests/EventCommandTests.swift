import Testing
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryCalendar

private func meeting(_ id: String = "m", from start: Int64? = nil, to end: Int64? = nil, recurring: Bool = false, editable: Bool = true, notes: String? = "메모") -> CalendarEvent {
    event(id, title: "회의", from: start ?? at(today, 10), to: end ?? at(today, 11, 30), recurring: recurring, editable: editable, notes: notes)
}

private func target(_ id: String = "m", token: String? = nil) -> EventTarget {
    EventTarget(key: key("life", id), expectedRevisionToken: token)
}

private func storedTime(_ harness: Harness, _ id: String = "m") async -> EventTimeRange? {
    await harness.provider.storedEvent(key("life", id))?.time
}

private func appliedEvent(_ outcome: CalendarCommandOutcome) -> CalendarEvent? {
    if case let .applied(applied) = outcome { return applied.event }
    return nil
}

// MARK: Create

@Test func creatingAnEventWritesItToTheCalendarOnly() async {
    let harness = Harness.make()
    let draft = CalendarEventDraft(calendarID: calendarID("life"), title: "스터디", time: .timed(timed(at(today, 10), at(today, 11))))
    let outcome = await harness.service.perform(.createEvent(CreateEventInput(draft: draft)))
    guard case let .applied(applied) = outcome, let created = applied.event else {
        Issue.record("expected applied, got \(outcome)")
        return
    }
    #expect(created.title == "스터디")
    #expect(applied.lifeRevision == nil && applied.activityID == nil)        // nothing local is needed
    #expect(await harness.provider.storedEvent(created.key) != nil)
    #expect(await harness.life().activities.isEmpty)
}

@Test func creatingWithAnActivityTypeMaterializesTheActivityAfterTheCalendarWrite() async {
    let harness = Harness.make()
    let draft = CalendarEventDraft(calendarID: calendarID("life"), title: "데이트", time: .timed(timed(at(today, 19), at(today, 21))))
    let outcome = await harness.service.perform(.createEvent(CreateEventInput(draft: draft, initialActivityType: .date)))
    guard case let .applied(applied) = outcome, let created = applied.event, let activityID = applied.activityID else {
        Issue.record("expected applied with activity, got \(outcome)")
        return
    }
    let life = await harness.life()
    #expect(applied.lifeRevision == 1)
    #expect(life.activities[activityID]?.association?.key == created.key)
    #expect(life.activities[activityID]?.activityType?.value == .date)
    #expect(life.activities[activityID]?.activityType?.provenance.source == .user)
}

@Test func creatingValidatesBeforeTouchingTheCalendar() async {
    let harness = Harness.make()
    let tooShort = CalendarEventDraft(calendarID: calendarID("life"), title: "x", time: .timed(timed(at(today, 10), at(today, 10, 10))))
    #expect(await harness.service.perform(.createEvent(CreateEventInput(draft: tooShort))) == .rejected(.durationBelowMinimum))
    let badZone = CalendarEventDraft(calendarID: calendarID("life"), title: "x", time: .timed(timed(at(today, 10), at(today, 11))), timeZoneIdentifier: "Mars/Base")
    #expect(await harness.service.perform(.createEvent(CreateEventInput(draft: badZone))) == .rejected(.invalidTimeZone("Mars/Base")))
    let found = try? await harness.provider.events(from: 0, to: Int64.max / 2, calendarIDs: nil)
    #expect(found?.isEmpty == true)
}

@Test func creatingInAReadOnlyOrBrokenCalendarReportsTheProviderFailureAndChangesNothing() async {
    let harness = Harness.make()
    let draft = { (calendar: String) in
        CalendarEventDraft(calendarID: calendarID(calendar), title: "x", time: .timed(timed(at(today, 10), at(today, 11))))
    }
    #expect(await harness.service.perform(.createEvent(CreateEventInput(draft: draft("readonly")))) == .providerFailure(.calendarNotWritable(calendarID("readonly"))))
    #expect(await harness.service.perform(.createEvent(CreateEventInput(draft: draft("gone")))) == .providerFailure(.calendarMissing(calendarID("gone"))))
    await harness.provider.failNextWrite(with: .saveFailed(retryable: true, reason: "disk"))
    let outcome = await harness.service.perform(.createEvent(CreateEventInput(draft: draft("life"), initialActivityType: .date)))
    #expect(outcome == .providerFailure(.saveFailed(retryable: true, reason: "disk")))
    #expect(await harness.life().activities.isEmpty)                      // no local state without the calendar write
}

@Test func ifTheLocalFollowUpFailsAfterTheCalendarWriteTheEventIsKeptAndTheOutcomeSaysSo() async {
    let flaky = FlakyLifeRepository(inner: InMemoryLifeRepository(), failCommits: true)
    let harness = Harness.make(repository: flaky)
    let draft = CalendarEventDraft(calendarID: calendarID("life"), title: "데이트", time: .timed(timed(at(today, 19), at(today, 21))))
    let outcome = await harness.service.perform(.createEvent(CreateEventInput(draft: draft, initialActivityType: .date)))
    guard case let .partiallyApplied(applied, failure) = outcome, let created = applied.event else {
        Issue.record("expected partiallyApplied, got \(outcome)")
        return
    }
    #expect(failure == .storageUnavailable)
    #expect(await harness.provider.storedEvent(created.key) != nil)       // the event itself is correct
    #expect(await harness.life().activities.isEmpty)                      // and nothing half-written locally
}

// MARK: Move

@Test func movingSnapsTheStartKeepsTheDurationAndWritesOnlyTheTime() async {
    let harness = Harness.make(events: [meeting()])
    let outcome = await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .proposedStart(at(today, 14, 7)))))
    let updated = appliedEvent(outcome)
    #expect(updated?.time == .timed(timed(at(today, 14), at(today, 15, 30))))
    #expect(updated?.notes == "메모" && updated?.title == "회의")             // untouched fields survive
    #expect(await storedTime(harness) == updated?.time)
}

@Test func movingToAnotherDayKeepsTheTimeOfDay() async {
    let harness = Harness.make(events: [meeting()])
    _ = await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .day(today.adding(days: 2)))))
    #expect(await storedTime(harness) == .timed(timed(at(today.adding(days: 2), 10), at(today.adding(days: 2), 11, 30))))
}

@Test func movingToWhereItAlreadyIsWritesNothing() async {
    let harness = Harness.make(events: [meeting()])
    let before = await harness.provider.storedEvent(key("life", "m"))
    let outcome = await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .proposedStart(at(today, 10, 4)))))
    #expect(appliedEvent(outcome) == before)
    #expect(await harness.provider.storedEvent(key("life", "m")) == before)   // same revision token: no write happened
}

@Test func movingRefusesMissingAndReadOnlyEvents() async {
    let harness = Harness.make(events: [meeting("ro", editable: false)])
    #expect(await harness.service.perform(.moveEvent(MoveEventInput(target: target("none"), destination: .day(today)))) == .rejected(.eventNotFound))
    #expect(await harness.service.perform(.moveEvent(MoveEventInput(target: target("ro"), destination: .day(today.adding(days: 1))))) == .rejected(.eventNotEditable))
}

@Test func aStaleRevisionIsAConflictAndNothingIsOverwritten() async {
    let harness = Harness.make(events: [meeting()])
    await harness.provider.editExternally(key("life", "m"), update: CalendarEventUpdate(title: "다른 앱에서 수정"))
    let outcome = await harness.service.perform(.moveEvent(MoveEventInput(target: target(token: "r0"), destination: .day(today.adding(days: 1)))))
    guard case let .conflict(current) = outcome else {
        Issue.record("expected conflict, got \(outcome)")
        return
    }
    #expect(current?.title == "다른 앱에서 수정")
    #expect(await storedTime(harness) == .timed(timed(at(today, 10), at(today, 11, 30))))
}

@Test func withoutAnExpectedRevisionTheLatestStateIsUsedAndTheEditSucceeds() async {
    let harness = Harness.make(events: [meeting()])
    await harness.provider.editExternally(key("life", "m"), update: CalendarEventUpdate(notes: .set("외부 메모")))
    let outcome = await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .day(today.adding(days: 1)))))
    #expect(appliedEvent(outcome)?.notes == "외부 메모")                      // the external edit is preserved, not lost
}

@Test func movingAnAllDayEventUsesDaysAndRejectsAnInstant() async {
    let trip = allDayEvent("trip", title: "여행", from: today, to: today.adding(days: 1))
    let harness = Harness.make(events: [trip])
    let tripTarget = EventTarget(key: key("life", "trip"))
    #expect(await harness.service.perform(.moveEvent(MoveEventInput(target: tripTarget, destination: .proposedStart(at(today, 9))))) == .rejected(.destinationKindMismatch))
    _ = await harness.service.perform(.moveEvent(MoveEventInput(target: tripTarget, destination: .day(today.adding(days: 5)))))
    #expect(await harness.provider.storedEvent(key("life", "trip"))?.time == .allDay(allDayRange(today.adding(days: 5), today.adding(days: 6))))
}

// MARK: Recurrence scope

@Test func recurringEventsNeedAnExplicitSupportedScope() async {
    let harness = Harness.make(events: [meeting(recurring: true)], supportedScopes: [.thisOccurrence])
    let move = { (scope: RecurrenceScope?) in
        await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .proposedStart(at(today, 14)), scope: scope)))
    }
    #expect(await move(nil) == .rejected(.recurrenceScopeRequired))
    #expect(await move(.allInSeries) == .rejected(.recurrenceScopeUnsupported(.allInSeries)))
    #expect(await move(.thisAndFuture) == .rejected(.recurrenceScopeUnsupported(.thisAndFuture)))
    let moved = await move(.thisOccurrence)
    #expect(appliedEvent(moved) != nil)
}

@Test func aDateChangeOnARecurringEventOnlyAppliesToTheOccurrence() async {
    let harness = Harness.make(events: [meeting(recurring: true)], supportedScopes: Set(RecurrenceScope.allCases))
    let toNextDay = { (scope: RecurrenceScope) in
        await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .day(today.adding(days: 1)), scope: scope)))
    }
    #expect(await toNextDay(.allInSeries) == .rejected(.dateChangeRequiresThisOccurrence))
    #expect(await toNextDay(.thisAndFuture) == .rejected(.dateChangeRequiresThisOccurrence))
    let moved = await toNextDay(.thisOccurrence)
    #expect(appliedEvent(moved) != nil)
}

@Test func aTimeOfDayChangeMayApplyToTheWholeSeriesWhenTheProviderSupportsIt() async {
    let harness = Harness.make(events: [meeting(recurring: true)], supportedScopes: Set(RecurrenceScope.allCases))
    let outcome = await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .proposedStart(at(today, 14)), scope: .allInSeries)))
    #expect(appliedEvent(outcome)?.time == .timed(timed(at(today, 14), at(today, 15, 30))))
}

@Test func nonRecurringEventsIgnoreAnyRequestedScope() async {
    let harness = Harness.make(events: [meeting()], supportedScopes: [.thisOccurrence])
    let outcome = await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .proposedStart(at(today, 14)), scope: .allInSeries)))
    #expect(appliedEvent(outcome) != nil)
}

// MARK: Resize

@Test func resizingTheTopAndBottomEdgesFollowsThePolicy() async {
    let harness = Harness.make(events: [meeting(from: at(today, 10), to: at(today, 12))])
    let start = await harness.service.perform(.resizeEvent(ResizeEventInput(target: target(), edge: .start, proposedInstant: at(today, 9, 8))))
    #expect(appliedEvent(start)?.time == .timed(timed(at(today, 9, 15), at(today, 12))))
    let end = await harness.service.perform(.resizeEvent(ResizeEventInput(target: target(), edge: .end, proposedInstant: at(today, 13, 6))))
    #expect(appliedEvent(end)?.time == .timed(timed(at(today, 9, 15), at(today, 13))))
}

@Test func resizingNeverShrinksBelowTheMinimumOrFlips() async {
    let harness = Harness.make(events: [meeting(from: at(today, 10), to: at(today, 12))])
    let top = await harness.service.perform(.resizeEvent(ResizeEventInput(target: target(), edge: .start, proposedInstant: at(today, 15))))
    #expect(appliedEvent(top)?.time == .timed(timed(at(today, 11, 45), at(today, 12))))
    let bottom = await harness.service.perform(.resizeEvent(ResizeEventInput(target: target(), edge: .end, proposedInstant: at(today, 8))))
    #expect(appliedEvent(bottom)?.time == .timed(timed(at(today, 11, 45), at(today, 12))))
}

@Test func bottomResizeCanBeKeptInsideTheDayAndAllDayEventsCannotBeResized() async {
    let late = meeting(from: at(today, 22), to: at(today, 23))
    let harness = Harness.make(events: [late, allDayEvent("trip", from: today, to: today)])
    let dayEnd = seoul.dayBounds(today).end
    let outcome = await harness.service.perform(.resizeEvent(ResizeEventInput(
        target: target(), edge: .end, proposedInstant: at(today.adding(days: 1), 3), clampToDayEnd: dayEnd
    )))
    #expect(appliedEvent(outcome)?.time == .timed(timed(at(today, 22), dayEnd)))
    let resize = await harness.service.perform(.resizeEvent(ResizeEventInput(target: EventTarget(key: key("life", "trip")), edge: .end, proposedInstant: at(today, 5))))
    #expect(resize == .rejected(.allDayEventCannotResize))
}

@Test func zoomedPolicyUsesFiveMinuteSteps() async {
    let harness = Harness.make(events: [meeting(from: at(today, 10), to: at(today, 12))], editPolicy: .zoomed)
    let outcome = await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .proposedStart(at(today, 14, 3)))))
    #expect(appliedEvent(outcome)?.time == .timed(timed(at(today, 14, 5), at(today, 16, 5))))
}

// MARK: All-day conversion and edit

@Test func convertingBetweenTimedAndAllDay() async {
    let harness = Harness.make(events: [meeting(), allDayEvent("trip", from: today, to: today.adding(days: 1))])
    let toAllDay = await harness.service.perform(.changeAllDay(ChangeAllDayInput(target: target(), toAllDay: true)))
    #expect(appliedEvent(toAllDay)?.time == .allDay(allDayRange(today, today)))

    let tripTarget = EventTarget(key: key("life", "trip"))
    #expect(await harness.service.perform(.changeAllDay(ChangeAllDayInput(target: tripTarget, toAllDay: false))) == .rejected(.missingProposedStart))
    let toTimed = await harness.service.perform(.changeAllDay(ChangeAllDayInput(target: tripTarget, toAllDay: false, proposedStart: at(today, 14, 7))))
    #expect(appliedEvent(toTimed)?.time == .timed(timed(at(today, 14), at(today, 15))))
}

@Test func convertingToTheKindItAlreadyIsWritesNothing() async {
    let harness = Harness.make(events: [meeting()])
    let before = await harness.provider.storedEvent(key("life", "m"))
    let outcome = await harness.service.perform(.changeAllDay(ChangeAllDayInput(target: target(), toAllDay: false)))
    #expect(appliedEvent(outcome) == before)
}

@Test func editingIsAPatchThatKeepsEverythingItDoesNotMention() async {
    let harness = Harness.make(events: [meeting()])
    #expect(await harness.service.perform(.editEvent(EditEventInput(target: target(), update: CalendarEventUpdate()))) == .rejected(.emptyUpdate))
    let retitled = await harness.service.perform(.editEvent(EditEventInput(target: target(), update: CalendarEventUpdate(title: "주간 회의"))))
    #expect(appliedEvent(retitled)?.title == "주간 회의")
    #expect(appliedEvent(retitled)?.notes == "메모")
    #expect(appliedEvent(retitled)?.time == .timed(timed(at(today, 10), at(today, 11, 30))))
    let cleared = await harness.service.perform(.editEvent(EditEventInput(target: target(), update: CalendarEventUpdate(location: .set("2층"), notes: .clear))))
    #expect(appliedEvent(cleared)?.notes == nil && appliedEvent(cleared)?.location == "2층")
}

@Test func editingValidatesTimeAndZoneBeforeWriting() async {
    let harness = Harness.make(events: [meeting()])
    let tooShort = CalendarEventUpdate(time: .timed(timed(at(today, 10), at(today, 10, 5))))
    #expect(await harness.service.perform(.editEvent(EditEventInput(target: target(), update: tooShort))) == .rejected(.durationBelowMinimum))
    let badZone = CalendarEventUpdate(timeZoneIdentifier: .set("Nowhere/Land"))
    #expect(await harness.service.perform(.editEvent(EditEventInput(target: target(), update: badZone))) == .rejected(.invalidTimeZone("Nowhere/Land")))
    let exact = CalendarEventUpdate(time: .timed(timed(at(today, 10, 7), at(today, 10, 52))))
    let edited = await harness.service.perform(.editEvent(EditEventInput(target: target(), update: exact)))
    #expect(appliedEvent(edited)?.time == exact.time)   // typed times are not snapped
}

@Test func theCalendarCanFailASaveWithoutAnyLocalSideEffects() async {
    let harness = Harness.make(events: [meeting()])
    await harness.provider.failNextWrite(with: .saveFailed(retryable: true, reason: "transient"))
    let outcome = await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .day(today.adding(days: 1)))))
    #expect(outcome == .providerFailure(.saveFailed(retryable: true, reason: "transient")))
    #expect(await storedTime(harness) == .timed(timed(at(today, 10), at(today, 11, 30))))
    // Retrying the same command afterwards succeeds.
    let retried = await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .day(today.adding(days: 1)))))
    #expect(appliedEvent(retried) != nil)
}

@Test func lostCalendarAccessIsReportedAndLocalDataStaysReadable() async throws {
    let harness = Harness.make(events: [meeting()])
    _ = await harness.service.perform(.assignActivityType(AssignActivityTypeInput(target: .event(key("life", "m")), typeID: .work, provenance: userProvenance())))
    await harness.provider.setAccessAvailable(false)
    #expect(await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .day(today.adding(days: 1))))) == .providerFailure(.accessUnavailable))
    await #expect(throws: (any Error).self) { try await harness.service.dayTimeline(for: today) }
    #expect(await harness.life().activities.count == 1)                   // meaning is OnAll's own and survives
    await harness.provider.setAccessAvailable(true)
    let timeline = try await harness.service.dayTimeline(for: today)
    #expect(timeline.blocks.first?.activity?.activityType == .work)
}

// MARK: Delete

@Test func deletingAnEventWithoutMeaningJustRemovesIt() async {
    let harness = Harness.make(events: [meeting()])
    let outcome = await harness.service.perform(.deleteEvent(DeleteEventInput(target: target())))
    #expect(outcome == .applied(AppliedCommand()))
    #expect(await harness.provider.storedEvent(key("life", "m")) == nil)
}

@Test func deletingAnEventKeepsItsActivityAndLinksByDefault() async {
    let transactions = [marker("t1", at: at(today, 12), amount: 8_000)]
    let harness = Harness.make(events: [meeting()], transactions: transactions)
    _ = await harness.service.perform(.linkTransaction(LinkTransactionInput(transactionID: txID("t1"), target: .event(key("life", "m")), provenance: userProvenance())))
    let outcome = await harness.service.perform(.deleteEvent(DeleteEventInput(target: target())))
    guard case let .applied(applied) = outcome, let activityID = applied.activityID else {
        Issue.record("expected applied with activity, got \(outcome)")
        return
    }
    let life = await harness.life()
    #expect(life.activities[activityID]?.isEventMissing == true)
    #expect(life.link(for: txID("t1"))?.activityID == activityID)         // nothing silently lost
    #expect(await harness.provider.storedEvent(key("life", "m")) == nil)
}

@Test func deletingCanInsteadReleaseTheLinkedTransactions() async {
    let transactions = [marker("t1", at: at(today, 12), amount: 8_000)]
    let harness = Harness.make(events: [meeting("plain"), meeting("typed")], transactions: transactions)
    _ = await harness.service.perform(.linkTransaction(LinkTransactionInput(transactionID: txID("t1"), target: .event(key("life", "plain")), provenance: userProvenance())))
    _ = await harness.service.perform(.deleteEvent(DeleteEventInput(target: target("plain"), linkDisposition: .removeLinks)))
    var life = await harness.life()
    #expect(life.link(for: txID("t1")) == nil)
    #expect(life.activities.isEmpty)                                       // an Activity with no meaning left is dropped

    _ = await harness.service.perform(.assignActivityType(AssignActivityTypeInput(target: .event(key("life", "typed")), typeID: .social, provenance: userProvenance())))
    _ = await harness.service.perform(.deleteEvent(DeleteEventInput(target: target("typed"), linkDisposition: .removeLinks)))
    life = await harness.life()
    #expect(life.activities.count == 1)                                    // it still carries a type, so it stays (event missing)
    #expect(life.activities.values.first?.isEventMissing == true)
}

@Test func aFailedCalendarDeleteLeavesLocalStateUntouched() async {
    let harness = Harness.make(events: [meeting()], transactions: [marker("t1", at: at(today, 12), amount: 8_000)])
    _ = await harness.service.perform(.linkTransaction(LinkTransactionInput(transactionID: txID("t1"), target: .event(key("life", "m")), provenance: userProvenance())))
    await harness.provider.failNextWrite(with: .saveFailed(retryable: false, reason: "locked"))
    let outcome = await harness.service.perform(.deleteEvent(DeleteEventInput(target: target())))
    #expect(outcome == .providerFailure(.saveFailed(retryable: false, reason: "locked")))
    #expect(await harness.provider.storedEvent(key("life", "m")) != nil)
    #expect(await harness.life().activities.values.allSatisfy { !$0.isEventMissing })
}

@Test func deletingARecurringEventNeedsAScope() async {
    let harness = Harness.make(events: [meeting(recurring: true)])
    #expect(await harness.service.perform(.deleteEvent(DeleteEventInput(target: target()))) == .rejected(.recurrenceScopeRequired))
    #expect(await harness.service.perform(.deleteEvent(DeleteEventInput(target: target(), scope: .thisOccurrence))) == .applied(AppliedCommand()))
}

@Test func movingAnEventRefreshesTheActivitysLastKnownSummary() async {
    let harness = Harness.make(events: [meeting()])
    _ = await harness.service.perform(.assignActivityType(AssignActivityTypeInput(target: .event(key("life", "m")), typeID: .work, provenance: userProvenance())))
    _ = await harness.service.perform(.moveEvent(MoveEventInput(target: target(), destination: .proposedStart(at(today, 15)))))
    let activity = await harness.life().activities.values.first
    #expect(activity?.association?.lastKnown.time == .timed(timed(at(today, 15), at(today, 16, 30))))
}
