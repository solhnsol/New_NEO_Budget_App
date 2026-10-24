import NEOBudgetCalendar
import NEOBudgetInMemoryCalendar

/// What a timeline gesture turns into once it ends: the commands the UI sends to `CalendarCommandService`, run against
/// any provider. It checks the whole path (policy, scope rules, revision check, provider write), not just the provider.
public enum CommandFlowContract {
    public static func run(rig: any CalendarProviderTestRig) async -> [ContractResult] {
        var results: [ContractResult] = []
        for (name, check) in cases {
            do {
                try await check(rig)
                results.append(ContractResult(name: name, failure: nil, skipped: nil))
            } catch let skip as FlowSkip {
                results.append(ContractResult(name: name, failure: nil, skipped: skip.reason))
            } catch let failure as FlowFailure {
                results.append(ContractResult(name: name, failure: failure.message, skipped: nil))
            } catch {
                results.append(ContractResult(name: name, failure: "threw \(error)", skipped: nil))
            }
        }
        await rig.cleanUp()
        return results
    }

    typealias Check = @Sendable (any CalendarProviderTestRig) async throws -> Void

    static let cases: [(String, Check)] = [
        ("move snaps the start, keeps the duration and every other field", moveKeepsEverythingElse),
        ("resize clamps to the minimum duration and snaps", resizeRules),
        ("create from a drag range", createFromDrag),
        ("a stale revision is refused and nothing is written", staleMoveIsRefused),
        ("a read-only calendar refuses creation", readOnlyCreate),
        ("a save failure leaves the event untouched", saveFailure),
        ("recurring: scope is required, one occurrence moves alone", recurringScope),
        ("recurring: whole-series time change keeps the day, a date change is refused", recurringSeries),
        ("recurring: thisAndFuture is not offered", thisAndFutureRefused),
    ]

    // MARK: Setup

    private static let base: Int64 = 1_803_081_600_000
    private static let hour: Int64 = 3_600_000
    private static let minute: Int64 = 60_000
    private static let dayMilliseconds: Int64 = 24 * hour

    private struct Fixture {
        let service: CalendarCommandService
        let calendar: CalendarID
        let day: LocalDate
        let zone: DisplayTimeZone

        func at(_ hour: Int, _ minute: Int = 0) -> Int64 { zone.instant(of: day, minuteOfDay: hour * 60 + minute) }
    }

    private static func fixture(_ rig: any CalendarProviderTestRig, _ name: String) async throws -> Fixture {
        let calendar = try await rig.makeWritableCalendar(title: "flow-\(name)")
        let zone = rig.dayZone
        let service = CalendarCommandService(
            provider: rig.provider,
            repository: InMemoryLifeRepository(),
            transactions: InMemoryTransactionSource(),
            configuration: CalendarServiceConfiguration(displayTimeZone: zone, editPolicy: .standard),
            makeID: { kind in "flow-\(kind.rawValue)-\(Int.random(in: 0..<1_000_000_000))" },
            now: { 1 }
        )
        return Fixture(service: service, calendar: calendar, day: zone.localDate(of: base + 3 * dayMilliseconds + 12 * hour), zone: zone)
    }

    private static func range(_ start: Int64, _ end: Int64) throws -> TimedRange {
        try TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: end)
    }

    private static func create(_ f: Fixture, _ title: String, _ from: Int64, _ to: Int64, location: String? = nil, notes: String? = nil) async throws -> CalendarEvent {
        let draft = CalendarEventDraft(
            calendarID: f.calendar, title: title, time: .timed(try range(from, to)), timeZoneIdentifier: "Asia/Seoul", location: location, notes: notes
        )
        switch await f.service.perform(.createEvent(CreateEventInput(draft: draft))) {
        case let .applied(applied):
            guard let event = applied.event else { throw FlowFailure(message: "create returned no event") }
            return event
        case let outcome: throw FlowFailure(message: "create failed: \(outcome)")
        }
    }

    /// The block the user would be looking at, found the way the UI finds it: through the day timeline.
    private static func block(_ f: Fixture, _ event: CalendarEvent) async throws -> EventBlock {
        let timeline = try await f.service.dayTimeline(for: f.day)
        guard let block = timeline.blocks.first(where: { $0.eventKey == event.key }) else {
            throw FlowFailure(message: "the event is not on the day timeline")
        }
        return block
    }

    private static func target(_ block: EventBlock) -> EventTarget {
        EventTarget(key: block.eventKey, expectedRevisionToken: block.revisionToken)
    }

    private static func stored(_ rig: any CalendarProviderTestRig, _ key: CalendarEventKey) async throws -> CalendarEvent {
        guard let event = try await rig.provider.event(key) else { throw FlowFailure(message: "event \(key) no longer exists") }
        return event
    }

    private static func timedRange(_ event: CalendarEvent) throws -> TimedRange {
        guard case let .timed(range) = event.time else { throw FlowFailure(message: "expected a timed event") }
        return range
    }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw FlowFailure(message: message()) }
    }

    private static func applied(_ outcome: CalendarCommandOutcome, _ context: String) throws -> AppliedCommand {
        guard case let .applied(applied) = outcome else { throw FlowFailure(message: "\(context): expected applied, got \(outcome)") }
        return applied
    }

    // MARK: Cases

    private static let moveKeepsEverythingElse: Check = { rig in
        let f = try await fixture(rig, "move")
        let event = try await create(f, "회의", f.at(10), f.at(11, 30), location: "성수", notes: "메모")
        let b = try await block(f, event)
        // Dropped at 14:08: the policy snaps the start to 14:15 and keeps the 90 minute duration.
        let outcome = await f.service.perform(.moveEvent(MoveEventInput(target: target(b), destination: .proposedStart(f.at(14, 8)))))
        let result = try applied(outcome, "move").event
        let moved = try await stored(rig, event.key)
        let expected = try range(f.at(14, 15), f.at(15, 45))
        try expect(try timedRange(moved) == expected, "moved range \(moved.time), expected 14:15-15:45")
        try expect(result?.time == moved.time, "the command result must report what is stored")
        try expect(moved.title == "회의" && moved.location == "성수" && moved.notes == "메모", "a move must not lose other fields: \(moved)")
        try expect(moved.key == event.key, "a move keeps the event key")
        // The preview the UI shows before committing is exactly what the policy produces.
        try expect(TimelineEditPolicy.standard.move(try timedRange(event), toProposedStart: f.at(14, 8), in: f.zone) == expected, "preview and commit disagree")
    }

    private static let resizeRules: Check = { rig in
        let f = try await fixture(rig, "resize")
        let event = try await create(f, "수업", f.at(9), f.at(11))
        var current = try await block(f, event)
        // Bottom edge to 12:40 snaps to 12:45.
        _ = try applied(await f.service.perform(.resizeEvent(ResizeEventInput(
            target: target(current), edge: .end, proposedInstant: f.at(12, 40)))), "resize end")
        var now = try await stored(rig, event.key)
        try expect(try timedRange(now) == (try range(f.at(9), f.at(12, 45))), "bottom resize: \(now.time)")
        // Top edge dragged below the end keeps the 15 minute minimum.
        current = try await block(f, event)
        _ = try applied(await f.service.perform(.resizeEvent(ResizeEventInput(
            target: target(current), edge: .start, proposedInstant: f.at(13)))), "resize start")
        now = try await stored(rig, event.key)
        try expect(try timedRange(now) == (try range(f.at(12, 30), f.at(12, 45))), "top resize must keep 15 minutes: \(now.time)")
        // The bottom edge stays inside the selected day.
        current = try await block(f, event)
        let dayEnd = f.zone.dayBounds(f.day).end
        _ = try applied(await f.service.perform(.resizeEvent(ResizeEventInput(
            target: target(current), edge: .end, proposedInstant: dayEnd + 3 * hour, clampToDayEnd: dayEnd))), "resize to day end")
        now = try await stored(rig, event.key)
        try expect(try timedRange(now).endUnixMilliseconds == dayEnd, "clamped to the day end: \(now.time)")
    }

    private static let createFromDrag: Check = { rig in
        let f = try await fixture(rig, "create")
        // Dragging from 15:03 to 16:20 snaps to 15:00-16:15.
        let edit = TimelineEditPolicy.standard.create(dragFrom: f.at(15, 3), to: f.at(16, 20), in: f.zone, keepingInside: f.day)
        try expect(edit.range == (try range(f.at(15), f.at(16, 15))), "policy range \(edit.range)")
        let draft = CalendarEventDraft(calendarID: f.calendar, title: "새 일정", time: .timed(edit.range))
        let event = try applied(await f.service.perform(.createEvent(CreateEventInput(draft: draft))), "create").event
        let created = try await stored(rig, try require(event, "created event").key)
        try expect(try timedRange(created) == edit.range && created.title == "새 일정", "created event differs: \(created)")
        let timeline = try await f.service.dayTimeline(for: f.day)
        try expect(timeline.blocks.contains { $0.eventKey == created.key && $0.isEditable }, "the new event shows on the timeline")
    }

    private static let staleMoveIsRefused: Check = { rig in
        let f = try await fixture(rig, "stale")
        let event = try await create(f, "회의", f.at(10), f.at(11))
        let seen = try await block(f, event)
        try await rig.editExternally(event.key, update: CalendarEventUpdate(title: "다른 곳에서 바꿈"))
        let outcome = await f.service.perform(.moveEvent(MoveEventInput(target: target(seen), destination: .proposedStart(f.at(14)))))
        guard case let .conflict(current) = outcome else { throw FlowFailure(message: "expected conflict, got \(outcome)") }
        try expect(current?.title == "다른 곳에서 바꿈", "conflict reports the current event")
        let after = try await stored(rig, event.key)
        try expect(try timedRange(after) == (try range(f.at(10), f.at(11))) && after.title == "다른 곳에서 바꿈", "a refused write must change nothing")
    }

    private static let readOnlyCreate: Check = { rig in
        let f = try await fixture(rig, "readonly")
        guard let readOnly = try await rig.existingReadOnlyCalendar() else { throw FlowSkip(reason: "no read-only calendar on this platform") }
        let draft = CalendarEventDraft(calendarID: readOnly, title: "x", time: .timed(try range(f.at(10), f.at(11))))
        let outcome = await f.service.perform(.createEvent(CreateEventInput(draft: draft)))
        try expect(outcome == .providerFailure(.calendarNotWritable(readOnly)), "create in a read-only calendar: \(outcome)")
    }

    private static let saveFailure: Check = { rig in
        let f = try await fixture(rig, "failure")
        let event = try await create(f, "회의", f.at(10), f.at(11))
        let seen = try await block(f, event)
        guard await rig.failNextWrite() else { throw FlowSkip(reason: "the platform cannot inject a save failure") }
        let outcome = await f.service.perform(.moveEvent(MoveEventInput(target: target(seen), destination: .proposedStart(f.at(14)))))
        guard case .providerFailure(.saveFailed(retryable: true, _)) = outcome else { throw FlowFailure(message: "expected a retryable save failure, got \(outcome)") }
        let after = try await stored(rig, event.key)
        try expect(try timedRange(after) == (try range(f.at(10), f.at(11))), "a failed save must leave the event as it was")
        // The very same command succeeds once the failure is gone.
        let retry = await f.service.perform(.moveEvent(MoveEventInput(target: target(seen), destination: .proposedStart(f.at(14)))))
        _ = try applied(retry, "retry")
    }

    private static func series(_ rig: any CalendarProviderTestRig, _ name: String) async throws -> (Fixture, [CalendarEvent]) {
        guard rig.supportsRecurrence else { throw FlowSkip(reason: "the rig cannot seed recurring series") }
        let f = try await fixture(rig, name)
        try await rig.seedWeeklySeries(
            calendarID: f.calendar, title: name, firstStartUnixMilliseconds: f.at(10), durationMilliseconds: hour, count: 4)
        let events = try await rig.provider.events(from: base - 40 * dayMilliseconds, to: base + 120 * dayMilliseconds, calendarIDs: [f.calendar])
            .filter { $0.title == name }
            .sorted { $0.key < $1.key }
        try expect(events.count == 4, "expected 4 occurrences, got \(events.count)")
        return (f, events)
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw FlowFailure(message: message) }
        return value
    }

    private static let recurringScope: Check = { rig in
        let (f, events) = try await series(rig, "scope")
        let occurrence = events[1]
        let seen = CalendarEventKey(calendarID: occurrence.calendarID, eventID: occurrence.id)
        guard case let .timed(old) = occurrence.time else { throw FlowFailure(message: "expected timed") }
        let proposed = old.startUnixMilliseconds + 3 * hour
        let withoutScope = await f.service.perform(.moveEvent(MoveEventInput(
            target: EventTarget(key: seen, expectedRevisionToken: occurrence.revisionToken), destination: .proposedStart(proposed))))
        try expect(withoutScope == .rejected(.recurrenceScopeRequired), "a recurring move needs a scope: \(withoutScope)")
        try expect(try timedRange(try await stored(rig, seen)) == old, "a rejected command writes nothing")
        let one = await f.service.perform(.moveEvent(MoveEventInput(
            target: EventTarget(key: seen, expectedRevisionToken: occurrence.revisionToken), destination: .proposedStart(proposed), scope: .thisOccurrence)))
        _ = try applied(one, "move one occurrence")
        try expect(try timedRange(try await stored(rig, seen)).startUnixMilliseconds == old.startUnixMilliseconds + 3 * hour, "the occurrence moved")
        for other in events where other.key != seen {
            try expect(try await stored(rig, other.key).time == other.time, "the other occurrences must not move")
        }
    }

    private static let recurringSeries: Check = { rig in
        guard rig.provider.supportedRecurrenceScopes.contains(.allInSeries) else { throw FlowSkip(reason: "allInSeries is not declared") }
        let (f, events) = try await series(rig, "whole")
        let occurrence = events[2]
        guard case let .timed(old) = occurrence.time else { throw FlowFailure(message: "expected timed") }
        let target = EventTarget(key: occurrence.key, expectedRevisionToken: occurrence.revisionToken)
        // Same day, two hours later: the whole series shifts.
        _ = try applied(await f.service.perform(.moveEvent(MoveEventInput(
            target: target, destination: .proposedStart(old.startUnixMilliseconds + 2 * hour), scope: .allInSeries))), "whole series")
        for original in events {
            guard case let .timed(was) = original.time else { continue }
            try expect(try timedRange(try await stored(rig, original.key)).startUnixMilliseconds == was.startUnixMilliseconds + 2 * hour, "every occurrence shifts two hours")
        }
        // A change of date applies to one occurrence only.
        let fresh = try await stored(rig, occurrence.key)
        let moveDay = await f.service.perform(.moveEvent(MoveEventInput(
            target: EventTarget(key: fresh.key, expectedRevisionToken: fresh.revisionToken),
            destination: .day(f.day.adding(days: 1)), scope: .allInSeries)))
        try expect(moveDay == .rejected(.dateChangeRequiresThisOccurrence), "a date change cannot apply to the series: \(moveDay)")
    }

    private static let thisAndFutureRefused: Check = { rig in
        let (f, events) = try await series(rig, "future")
        let occurrence = events[1]
        let outcome = await f.service.perform(.moveEvent(MoveEventInput(
            target: EventTarget(key: occurrence.key, expectedRevisionToken: occurrence.revisionToken),
            destination: .proposedStart(try timedRange(occurrence).startUnixMilliseconds + hour), scope: .thisAndFuture)))
        try expect(outcome == .rejected(.recurrenceScopeUnsupported(.thisAndFuture)), "thisAndFuture must not be offered: \(outcome)")
    }
}

private struct FlowFailure: Error { let message: String }
private struct FlowSkip: Error { let reason: String }
