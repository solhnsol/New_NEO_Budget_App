import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryCalendar

// The Phase 3A save adapter, run against the real command service and the scripted provider: the checks before the write, the write through
// the existing command path, what is kept when the calendar fails, and recurring scopes.

private func date(_ instant: Int64) -> Date { EventSaveTime.date(instant) }

private func meeting(_ id: String = "m", from start: Int64 = at(today, 10), to end: Int64 = at(today, 11), recurring: Bool = false, editable: Bool = true) -> CalendarEvent {
    event(id, title: "회의", from: start, to: end, recurring: recurring, editable: editable, revision: "r0")
}

private func pipeline(_ harness: Harness, scopes: Set<RecurrenceScope>? = nil) -> EventSavePipeline {
    EventSavePipeline(service: harness.service, supportedScopes: scopes ?? harness.provider.supportedRecurrenceScopes, zone: seoul)
}

private func original(of event: CalendarEvent) -> EventSaveOriginal { EventSaveOriginal(event: event)! }

private func request(_ event: CalendarEvent, from start: Int64, to end: Int64, scope: RecurrenceScope? = nil, endLimit: Int64? = nil) -> EventSaveRequest {
    EventSaveRequest(original: original(of: event), proposedStart: date(start), proposedEnd: date(end), scope: scope, endLimit: endLimit.map(date))
}

private func receipt(_ result: EventSaveResult) -> EventSaveReceipt? {
    if case let .saved(value) = result { return value }
    return nil
}

private func failure(_ result: EventSaveResult) -> EventSaveFailure? {
    if case let .failed(value) = result { return value }
    return nil
}

private func stored(_ harness: Harness, _ key: CalendarEventKey) async -> CalendarEvent? { await harness.provider.storedEvent(key) }

// MARK: The request

@Test func theRequestPicksTheSameCommandTheTimelineEditorSends() {
    let base = meeting()
    let target = EventTarget(key: base.key, expectedRevisionToken: "r0")
    let move = request(base, from: at(today, 13), to: at(today, 14))
    #expect(move.edit == .move)
    #expect(move.command(scope: nil) == .moveEvent(MoveEventInput(target: target, destination: .proposedStart(at(today, 13)))))
    let top = request(base, from: at(today, 9, 30), to: at(today, 11))
    #expect(top.command(scope: nil) == .resizeEvent(ResizeEventInput(target: target, edge: .start, proposedInstant: at(today, 9, 30))))
    let bottom = request(base, from: at(today, 10), to: at(today, 12), endLimit: at(today.adding(days: 1), 0))
    #expect(bottom.command(scope: .thisOccurrence) == .resizeEvent(ResizeEventInput(
        target: target, edge: .end, proposedInstant: at(today, 12), clampToDayEnd: at(today.adding(days: 1), 0), scope: .thisOccurrence
    )))
    let both = request(base, from: at(today, 9), to: at(today, 12))
    #expect(both.edit == .retime)
    #expect(both.command(scope: nil) == .editEvent(EditEventInput(target: target, update: CalendarEventUpdate(time: .timed(timed(at(today, 9), at(today, 12)))))))
    #expect(request(base, from: at(today, 10), to: at(today, 11)).command(scope: nil) == nil)
}

@Test func theOriginalIsTheRealRangeNotTheMinutesDrawnOnOneDay() async throws {
    // 23:00 to 01:00 the next day: the first day draws it to its end, but the original is the whole event.
    let late = meeting("late", from: at(today, 23), to: at(today.adding(days: 1), 1))
    let harness = Harness.make(events: [late])
    let timeline = try await harness.service.dayTimeline(for: today)
    let block = try #require(timeline.blocks.first { $0.eventKey == late.key })
    #expect(block.continuesToNextDay)
    let fromBlock = EventSaveOriginal(block: block)
    #expect(fromBlock == original(of: late))
    #expect(fromBlock.end == date(at(today.adding(days: 1), 1)))
    // The same revision with another time is not the original.
    let moved = event("late", title: "회의", from: at(today, 22), to: at(today.adding(days: 1), 1), revision: "r0")
    #expect(!fromBlock.matches(moved))
    #expect(fromBlock.matches(late))
}

// MARK: Saving a single event

@Test func aMoveIsSavedThroughTheCommandServiceAndReturnsTheSavedEvent() async throws {
    let base = meeting()
    let harness = Harness.make(events: [base])
    let result = await pipeline(harness).save(request(base, from: at(today, 14), to: at(today, 15)))
    let saved = try #require(receipt(result))
    #expect(saved.start == date(at(today, 14)) && saved.end == date(at(today, 15)))
    #expect(saved.event.key == base.key)
    #expect(saved.event.revisionToken != "r0")
    #expect(saved.scope == .thisOccurrence && saved.matchesProposal && saved.localFailure == nil)
    #expect(saved.original == original(of: base))
    #expect(await stored(harness, base.key) == saved.event)
}

@Test func eachEdgeAndBothEdgesAreSaved() async throws {
    let base = meeting(from: at(today, 10), to: at(today, 12))
    let harness = Harness.make(events: [base])
    let saver = pipeline(harness)
    let top = try #require(receipt(await saver.save(request(base, from: at(today, 9), to: at(today, 12)))))
    #expect(top.start == date(at(today, 9)) && top.end == date(at(today, 12)))
    // The next edit is made against what was just saved.
    let bottom = try #require(receipt(await saver.save(request(top.event, from: at(today, 9), to: at(today, 13), endLimit: at(today.adding(days: 1), 0)))))
    #expect(bottom.end == date(at(today, 13)))
    let both = try #require(receipt(await saver.save(request(bottom.event, from: at(today, 8), to: at(today, 8, 45)))))
    #expect(both.start == date(at(today, 8)) && both.end == date(at(today, 8, 45)))
    #expect(await stored(harness, base.key)?.time == .timed(timed(at(today, 8), at(today, 8, 45))))
}

@Test func whatTheEditPolicyAdjustsIsWhatIsReturned() async throws {
    let base = meeting()
    let harness = Harness.make(events: [base])
    // A move snaps its start to 15 minutes; the receipt says what the calendar now holds.
    let saved = try #require(receipt(await pipeline(harness).save(request(base, from: at(today, 14, 7), to: at(today, 15, 7)))))
    #expect(saved.start == date(at(today, 14, 0)) && saved.end == date(at(today, 15, 0)))
    #expect(!saved.matchesProposal)
}

@Test func nothingIsWrittenWhenTheProposalIsTheOriginalOrInvalid() async {
    let base = meeting()
    let harness = Harness.make(events: [base])
    let saver = pipeline(harness)
    #expect(await saver.save(request(base, from: at(today, 10), to: at(today, 11))) == .unchanged(base))
    #expect(await saver.save(request(base, from: at(today, 12), to: at(today, 11))) == .refused(.invalid(.durationBelowMinimum)))
    #expect(await stored(harness, base.key) == base)
}

@Test func anEdgeDraggedBelowTheMinimumIsClampedAsTheTimelineEditorClampsIt() async throws {
    // The existing resize policy never refuses a too-short edge: it keeps the minimum duration. The adapter does not change that.
    let base = meeting()
    let harness = Harness.make(events: [base])
    let saved = try #require(receipt(await pipeline(harness).save(request(base, from: at(today, 10), to: at(today, 10, 5)))))
    #expect(saved.start == date(at(today, 10)) && saved.end == date(at(today, 10, 15)))
    #expect(!saved.matchesProposal)
}

// MARK: The target changed or went away

@Test func aTargetChangedElsewhereIsNotOverwritten() async {
    let base = meeting()
    let harness = Harness.make(events: [base])
    await harness.provider.editExternally(base.key, update: CalendarEventUpdate(title: "다른 앱에서 바꿈"))
    let current = await stored(harness, base.key)!
    let result = await pipeline(harness).save(request(base, from: at(today, 14), to: at(today, 15)))
    #expect(result == .refused(.targetChanged(current: current)))
    #expect(await stored(harness, base.key) == current)
}

@Test func aTargetMovedElsewhereIsNotOverwrittenEvenIfTheProposalMatchesItsNewTime() async {
    let base = meeting()
    let harness = Harness.make(events: [base])
    await harness.provider.editExternally(base.key, update: CalendarEventUpdate(time: .timed(timed(at(today, 14), at(today, 15)))))
    let current = await stored(harness, base.key)!
    #expect(await pipeline(harness).save(request(base, from: at(today, 14), to: at(today, 15))) == .refused(.targetChanged(current: current)))
}

@Test func aDeletedTargetIsRefused() async {
    let base = meeting()
    let harness = Harness.make(events: [base])
    await harness.provider.removeExternally(base.key)
    #expect(await pipeline(harness).save(request(base, from: at(today, 14), to: at(today, 15))) == .refused(.targetGone))
    #expect(await stored(harness, base.key) == nil)
}

@Test func aReadOnlyTargetIsRefused() async {
    let base = meeting(editable: false)
    let harness = Harness.make(events: [base])
    #expect(await pipeline(harness).save(request(base, from: at(today, 14), to: at(today, 15))) == .refused(.notEditable))
}

@Test func aChangeBetweenTheCheckAndTheWriteIsStillAConflict() async {
    // The check passes, then another app edits the event before the write: the command service's revision check refuses it.
    let base = meeting()
    let harness = Harness.make(events: [base])
    let provider = harness.provider
    let service = harness.service
    let racing = EventSavePipeline(
        supportedScopes: provider.supportedRecurrenceScopes, zone: seoul,
        perform: { command in
            await provider.editExternally(base.key, update: CalendarEventUpdate(title: "끼어든 변경"))
            return await service.perform(command)
        },
        read: { try await service.event($0) }
    )
    let result = await racing.save(request(base, from: at(today, 14), to: at(today, 15)))
    let current = await stored(harness, base.key)!
    #expect(result == .refused(.targetChanged(current: current)))
    #expect(current.time == base.time)
}

// MARK: When the calendar fails

@Test func aFailedWriteKeepsTheOriginalAndCanBeSavedAgain() async throws {
    let base = meeting()
    let harness = Harness.make(events: [base])
    let saver = pipeline(harness)
    let asked = request(base, from: at(today, 14), to: at(today, 15))
    await harness.provider.failNextWrite(with: .saveFailed(retryable: true, reason: "EKErrorDomain 1"))
    let failed = try #require(failure(await saver.save(asked)))
    #expect(failed.stage == .writing)
    #expect(failed.failure == .saveFailed(retryable: true, reason: "EKErrorDomain 1"))
    #expect(failed.originalVerified)
    #expect(failed.retry == asked)
    #expect(await stored(harness, base.key) == base)                     // nothing changed, revision included
    let retry = try #require(failed.retry)
    let retried = try #require(receipt(await saver.save(retry)))
    #expect(retried.start == date(at(today, 14)))
}

@Test func aFailureThatCannotBeRetriedOffersNoRetry() async throws {
    let base = meeting()
    let harness = Harness.make(events: [base])
    await harness.provider.failNextWrite(with: .saveFailed(retryable: false, reason: "invalid span"))
    let failed = try #require(failure(await pipeline(harness).save(request(base, from: at(today, 14), to: at(today, 15)))))
    #expect(failed.originalVerified && failed.retry == nil)
    #expect(await stored(harness, base.key) == base)
}

@Test func aTargetChangedOrDeletedWhileTheWriteFailedIsReportedAsSuch() async {
    let base = meeting()
    let harness = Harness.make(events: [base])
    let provider = harness.provider
    let service = harness.service
    func failing(then sideEffect: @escaping @Sendable () async -> Void) -> EventSavePipeline {
        EventSavePipeline(
            supportedScopes: provider.supportedRecurrenceScopes, zone: seoul,
            perform: { _ in
                await sideEffect()
                return .providerFailure(.saveFailed(retryable: true, reason: "timeout"))
            },
            read: { try await service.event($0) }
        )
    }
    let asked = request(base, from: at(today, 14), to: at(today, 15))
    let edited = await failing { await provider.editExternally(base.key, update: CalendarEventUpdate(title: "x")) }.save(asked)
    #expect(edited == .refused(.targetChanged(current: await stored(harness, base.key)!)))
    let other = meeting("other")
    let harness2 = Harness.make(events: [other])
    let provider2 = harness2.provider
    let deleting = EventSavePipeline(
        supportedScopes: provider2.supportedRecurrenceScopes, zone: seoul,
        perform: { _ in
            await provider2.removeExternally(other.key)
            return .providerFailure(.saveFailed(retryable: true, reason: "timeout"))
        },
        read: { [service = harness2.service] in try await service.event($0) }
    )
    #expect(await deleting.save(request(other, from: at(today, 14), to: at(today, 15))) == .refused(.targetGone))
}

@Test func whenTheCalendarCannotBeReadNothingIsWrittenAndNothingIsClaimed() async throws {
    let base = meeting()
    let harness = Harness.make(events: [base])
    await harness.provider.setAccessAvailable(false)
    let failed = try #require(failure(await pipeline(harness).save(request(base, from: at(today, 14), to: at(today, 15)))))
    #expect(failed.stage == .verifying && failed.failure == .accessUnavailable && failed.retry == nil)
    // Access lost after the check: the write fails and the original cannot be confirmed, so no retry is offered.
    let provider = harness.provider
    let service = harness.service
    await provider.setAccessAvailable(true)
    let losing = EventSavePipeline(
        supportedScopes: provider.supportedRecurrenceScopes, zone: seoul,
        perform: { command in
            await provider.setAccessAvailable(false)
            return await service.perform(command)
        },
        read: { try await service.event($0) }
    )
    let lost = try #require(failure(await losing.save(request(base, from: at(today, 14), to: at(today, 15)))))
    #expect(lost.stage == .writing && !lost.originalVerified && lost.retry == nil)
    #expect(await stored(harness, base.key) == base)
}

@Test func aTransientReadErrorBeforeTheWriteCanBeRetried() async throws {
    struct Flaky: Error {}
    let base = meeting()
    let harness = Harness.make(events: [base])
    let service = harness.service
    let saver = EventSavePipeline(
        supportedScopes: [.thisOccurrence], zone: seoul,
        perform: { await service.perform($0) }, read: { _ in throw Flaky() }
    )
    let asked = request(base, from: at(today, 14), to: at(today, 15))
    let failed = try #require(failure(await saver.save(asked)))
    #expect(failed.stage == .verifying && failed.originalVerified && failed.retry == asked)
}

// MARK: Recurring events

/// A weekly series of four, 10:00–11:00 Seoul, starting today.
private func weeklySeries(_ harness: Harness) async -> [CalendarEvent] {
    await harness.provider.seedSeries(
        calendarID: calendarID("life"), title: "주간 회의", firstStartUnixMilliseconds: at(today, 10), durationMilliseconds: 3_600_000, count: 4
    )
}

@Test func aRecurringEventAsksForAScopeBeforeWritingAnything() async {
    let harness = Harness.make(supportedScopes: [.thisOccurrence, .allInSeries])
    let series = await weeklySeries(harness)
    let saver = pipeline(harness)
    #expect(await saver.save(request(series[1], from: at(today.adding(days: 7), 14), to: at(today.adding(days: 7), 15))) == .needsScope([.thisOccurrence, .allInSeries]))
    // Moving it to another day can only apply to the occurrence.
    #expect(await saver.save(request(series[1], from: at(today.adding(days: 8), 10), to: at(today.adding(days: 8), 11))) == .needsScope([.thisOccurrence]))
    for occurrence in series { #expect(await stored(harness, occurrence.key) == occurrence) }
}

@Test func thisOccurrenceChangesOnlyThatOccurrenceAndKeepsItsKey() async throws {
    let harness = Harness.make(supportedScopes: [.thisOccurrence, .allInSeries])
    let series = await weeklySeries(harness)
    let saver = pipeline(harness)
    let week2 = today.adding(days: 7)
    let asked = request(series[1], from: at(week2, 14), to: at(week2, 15))
    guard case let .needsScope(options) = await saver.save(asked) else { Issue.record("expected a scope question"); return }
    let saved = try #require(receipt(await saver.save(asked.scoped(options[0]))))
    #expect(saved.scope == .thisOccurrence)
    #expect(saved.event.key == series[1].key && saved.event.isRecurringInstance)
    #expect(saved.start == date(at(week2, 14)))
    for (index, occurrence) in series.enumerated() where index != 1 { #expect(await stored(harness, occurrence.key) == occurrence) }
}

@Test func aDateChangeForOneOccurrenceIsSaved() async throws {
    let harness = Harness.make(supportedScopes: [.thisOccurrence, .allInSeries])
    let series = await weeklySeries(harness)
    let nextDay = today.adding(days: 8)
    let saved = try #require(receipt(await pipeline(harness).save(request(series[1], from: at(nextDay, 10), to: at(nextDay, 11), scope: .thisOccurrence))))
    #expect(saved.start == date(at(nextDay, 10)))
    #expect(await stored(harness, series[2].key) == series[2])
}

@Test func allInSeriesShiftsEveryOccurrenceAndReturnsTheEditedOne() async throws {
    let harness = Harness.make(supportedScopes: [.thisOccurrence, .allInSeries])
    let series = await weeklySeries(harness)
    let week3 = today.adding(days: 14)
    // Later and 30 minutes longer: 14:00–15:30.
    let saved = try #require(receipt(await pipeline(harness).save(request(series[2], from: at(week3, 14), to: at(week3, 15, 30), scope: .allInSeries))))
    #expect(saved.scope == .allInSeries)
    #expect(saved.event.key == series[2].key)
    #expect(saved.start == date(at(week3, 14)) && saved.end == date(at(week3, 15, 30)))
    for (index, occurrence) in series.enumerated() {
        let day = today.adding(days: 7 * index)
        #expect(await stored(harness, occurrence.key)?.time == .timed(timed(at(day, 14), at(day, 15, 30))))
    }
}

@Test func anOccurrenceWhoseSeriesWasChangedIsNoLongerTheOriginal() async throws {
    let harness = Harness.make(supportedScopes: [.thisOccurrence, .allInSeries])
    let series = await weeklySeries(harness)
    let saver = pipeline(harness)
    _ = try #require(receipt(await saver.save(request(series[0], from: at(today, 14), to: at(today, 15), scope: .allInSeries))))
    // A session still holding week 2 as it was must not overwrite the series change.
    let week2 = today.adding(days: 7)
    guard case let .refused(.targetChanged(current)) = await saver.save(request(series[1], from: at(week2, 9), to: at(week2, 10), scope: .thisOccurrence)) else {
        Issue.record("expected targetChanged"); return
    }
    #expect(current.time == .timed(timed(at(week2, 14), at(week2, 15))))
}

@Test func scopesThatAreNotOfferedAreRefusedBeforeWriting() async {
    let harness = Harness.make(supportedScopes: [.thisOccurrence, .allInSeries])
    let series = await weeklySeries(harness)
    let saver = pipeline(harness)
    let week2 = today.adding(days: 7)
    let toNextDay = request(series[1], from: at(week2.adding(days: 1), 10), to: at(week2.adding(days: 1), 11))
    #expect(await saver.save(toNextDay.scoped(.allInSeries)) == .refused(.scopeNotOffered(.allInSeries, offered: [.thisOccurrence])))
    let later = request(series[1], from: at(week2, 14), to: at(week2, 15))
    #expect(await saver.save(later.scoped(.thisAndFuture)) == .refused(.scopeNotOffered(.thisAndFuture, offered: [.thisOccurrence, .allInSeries])))
    for occurrence in series { #expect(await stored(harness, occurrence.key) == occurrence) }
}

@Test func aProviderWithoutSeriesSupportOffersOnlyTheOccurrence() async {
    let harness = Harness.make(supportedScopes: [.thisOccurrence])
    let series = await weeklySeries(harness)
    let week2 = today.adding(days: 7)
    let later = request(series[1], from: at(week2, 14), to: at(week2, 15))
    #expect(await pipeline(harness).save(later) == .needsScope([.thisOccurrence]))
    #expect(await pipeline(harness).save(later.scoped(.allInSeries)) == .refused(.scopeNotOffered(.allInSeries, offered: [.thisOccurrence])))
}

@Test func aFailedSeriesWriteChangesNoOccurrenceAndCanBeRetried() async throws {
    let harness = Harness.make(supportedScopes: [.thisOccurrence, .allInSeries])
    let series = await weeklySeries(harness)
    let saver = pipeline(harness)
    let asked = request(series[0], from: at(today, 14), to: at(today, 15), scope: .allInSeries)
    await harness.provider.failNextWrite(with: .saveFailed(retryable: true, reason: "busy"))
    let failed = try #require(failure(await saver.save(asked)))
    #expect(failed.originalVerified && failed.retry == asked)
    for occurrence in series { #expect(await stored(harness, occurrence.key) == occurrence) }
    let retry = try #require(failed.retry)
    let saved = try #require(receipt(await saver.save(retry)))
    #expect(saved.scope == .allInSeries)
    #expect(await stored(harness, series[3].key)?.time == .timed(timed(at(today.adding(days: 21), 14), at(today.adding(days: 21), 15))))
}

@Test func aDeletedOccurrenceIsRefusedWithoutTouchingTheRest() async {
    let harness = Harness.make(supportedScopes: [.thisOccurrence, .allInSeries])
    let series = await weeklySeries(harness)
    await harness.provider.removeExternally(series[1].key)
    let week2 = today.adding(days: 7)
    #expect(await pipeline(harness).save(request(series[1], from: at(week2, 14), to: at(week2, 15), scope: .allInSeries)) == .refused(.targetGone))
    #expect(await stored(harness, series[0].key) == series[0])
}
