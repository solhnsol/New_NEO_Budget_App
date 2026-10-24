import NEOBudgetCalendar

// Executable form of the `CalendarProvider` contract notes. It has no dependency on a test framework so the same
// checks run in Swift Testing (in-memory provider) and inside an iOS app host (EventKit provider).

/// Provider-specific setup the contract needs but the `CalendarProvider` protocol deliberately does not offer:
/// making calendars, seeding recurring series, and changing data "from outside" as another app would.
public protocol CalendarProviderTestRig: Sendable {
    var provider: any CalendarProvider { get }
    /// The zone the provider uses to place all-day events on local days.
    var dayZone: DisplayTimeZone { get }
    var supportsRecurrence: Bool { get }

    /// A new, empty, writable calendar owned by the rig.
    func makeWritableCalendar(title: String) async throws -> CalendarID
    /// A calendar that refuses writes, or `nil` if the platform has none to offer.
    func existingReadOnlyCalendar() async throws -> CalendarID?
    /// Edits a **non-recurring** event as another app would.
    func editExternally(_ key: CalendarEventKey, update: CalendarEventUpdate) async throws
    func removeExternally(_ key: CalendarEventKey) async throws
    func removeCalendarExternally(_ id: CalendarID) async throws
    /// Makes the provider's next write fail with a retryable save failure. Returns `false` if the platform cannot do that.
    func failNextWrite() async -> Bool
    /// Revokes (`false`) or restores (`true`) access. Returns `false` if the platform cannot simulate it.
    func setAccess(available: Bool) async -> Bool
    /// Seeds a weekly series of `count` timed occurrences in a rig-owned calendar.
    func seedWeeklySeries(calendarID: CalendarID, title: String, firstStartUnixMilliseconds: Int64, durationMilliseconds: Int64, count: Int) async throws
    /// Removes everything the rig created.
    func cleanUp() async
}

public struct ContractResult: Sendable, Equatable {
    public let name: String
    /// `nil` when the check passed, `skipped` when the platform cannot exercise it, otherwise the failure.
    public let failure: String?
    public let skipped: String?
    public var passed: Bool { failure == nil }
}

struct ContractFailure: Error { let message: String }

private struct Skip: Error { let reason: String }

private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw ContractFailure(message: message()) }
}

private func require<T>(_ value: T?, _ message: @autoclosure () -> String) throws -> T {
    guard let value else { throw ContractFailure(message: message()) }
    return value
}

private func success<T: Sendable>(_ result: CalendarProviderResult<T>, _ context: String) throws -> T {
    switch result {
    case let .success(value): return value
    case let .conflict(current): throw ContractFailure(message: "\(context): unexpected conflict (current: \(String(describing: current?.title)))")
    case let .failure(failure): throw ContractFailure(message: "\(context): unexpected failure \(failure)")
    }
}

private let hour: Int64 = 3_600_000
private let day: Int64 = 24 * hour

public enum CalendarProviderContract {
    /// Runs every contract check against `rig` and reports each outcome. Checks are independent; each makes its
    /// own calendar. The rig is cleaned up at the end.
    public static func run(rig: any CalendarProviderTestRig) async -> [ContractResult] {
        var results: [ContractResult] = []
        for (name, check) in cases {
            do {
                try await check(rig)
                results.append(ContractResult(name: name, failure: nil, skipped: nil))
            } catch let skip as Skip {
                results.append(ContractResult(name: name, failure: nil, skipped: skip.reason))
            } catch let failure as ContractFailure {
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
        ("timed event round trip", timedRoundTrip),
        ("time zone is kept and floating stays floating", timeZoneRoundTrip),
        ("all-day event round trip and day overlap", allDayRoundTrip),
        ("update is a patch", updatePatch),
        ("revision changes on every own write", revisionChangesOnWrite),
        ("stale revision conflicts without writing, even within one second", staleConflict),
        ("missing events and calendars are typed", missingTargets),
        ("read-only calendars refuse writes", readOnlyCalendar),
        ("write check order", writeCheckOrder),
        ("calendar removed from outside", calendarRemovedExternally),
        ("change signal", changeSignal),
        ("revoked access", revokedAccess),
        ("recurring: occurrence identity", recurringIdentity),
        ("recurring: thisOccurrence edits one and keeps keys", recurringThisOccurrence),
        ("recurring: allInSeries shifts the series and keeps keys", recurringAllInSeries),
        ("recurring: allInSeries refuses a date change", recurringDateChangeRefused),
        ("recurring: delete scopes", recurringDelete),
        ("recurring: thisAndFuture is not declared", thisAndFutureNotDeclared),
    ]

    // MARK: Helpers

    private static func timed(_ start: Int64, _ end: Int64) throws -> EventTimeRange {
        .timed(try TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: end))
    }

    /// A base instant far from "now" so rig data never mixes with real user data: 2027-03-01 00:00 UTC.
    private static let base: Int64 = 1_803_081_600_000

    private static func window(_ rig: any CalendarProviderTestRig, _ id: CalendarID) async throws -> [CalendarEvent] {
        try await rig.provider.events(from: base - 40 * day, to: base + 120 * day, calendarIDs: [id])
    }

    // MARK: Cases

    private static let timedRoundTrip: Check = { rig in
        let calendar = try await rig.makeWritableCalendar(title: "contract-timed")
        let draft = CalendarEventDraft(
            calendarID: calendar, title: "회의", time: try timed(base + 10 * hour, base + 11 * hour + 30 * 60_000),
            timeZoneIdentifier: "Asia/Seoul", location: "성수", notes: "메모"
        )
        let created = try success(await rig.provider.createEvent(draft), "create")
        try expect(created.title == "회의" && created.location == "성수" && created.notes == "메모", "created fields differ: \(created)")
        try expect(created.time == draft.time, "created time differs: \(created.time)")
        try expect(created.calendarID == calendar, "calendar differs")
        try expect(created.isEditable && !created.isRecurringInstance, "a new event is editable and not recurring")
        try expect(created.revisionToken != nil, "a created event needs a revision token")
        let read = try require(try await rig.provider.event(created.key), "created event cannot be read back")
        try expect(read == created, "read-back differs from created: \(read) vs \(created)")
        let listed = try await window(rig, calendar)
        try expect(listed.map(\.key) == [created.key], "window query should list exactly the event, got \(listed.map(\.title))")
        let before = try await rig.provider.events(from: base, to: base + 10 * hour, calendarIDs: [calendar])
        try expect(before.isEmpty, "an event starting exactly at `to` must not overlap")
        let after = try await rig.provider.events(from: base + 11 * hour + 30 * 60_000, to: base + 13 * hour, calendarIDs: [calendar])
        try expect(after.isEmpty, "an event ending exactly at `from` must not overlap")
        let other = try await rig.provider.events(from: base, to: base + day, calendarIDs: [])
        try expect(other.isEmpty, "an empty calendar filter matches nothing")
    }

    private static let timeZoneRoundTrip: Check = { rig in
        let calendar = try await rig.makeWritableCalendar(title: "contract-tz")
        let zoned = try success(await rig.provider.createEvent(CalendarEventDraft(
            calendarID: calendar, title: "zoned", time: try timed(base + hour, base + 2 * hour), timeZoneIdentifier: "Asia/Seoul")), "create zoned")
        try expect(zoned.timeZoneIdentifier == "Asia/Seoul", "zone lost: \(String(describing: zoned.timeZoneIdentifier))")
        let floating = try success(await rig.provider.createEvent(CalendarEventDraft(
            calendarID: calendar, title: "floating", time: try timed(base + 3 * hour, base + 4 * hour))), "create floating")
        try expect(floating.timeZoneIdentifier == nil, "floating must stay floating, got \(String(describing: floating.timeZoneIdentifier))")
        let reread = try require(try await rig.provider.event(floating.key), "floating event unreadable")
        try expect(reread.timeZoneIdentifier == nil, "floating changed after re-read")
    }

    private static let allDayRoundTrip: Check = { rig in
        let calendar = try await rig.makeWritableCalendar(title: "contract-allday")
        let first = rig.dayZone.localDate(of: base + 5 * day + 12 * hour)
        let range = try DayRange(firstDay: first, lastDay: first.adding(days: 2))
        let created = try success(await rig.provider.createEvent(CalendarEventDraft(calendarID: calendar, title: "여행", time: .allDay(range))), "create all-day")
        try expect(created.time == .allDay(range), "all-day range changed: \(created.time) vs \(range)")
        let read = try require(try await rig.provider.event(created.key), "all-day unreadable")
        try expect(read.time == .allDay(range), "all-day range changed on re-read: \(read.time)")
        let start = rig.dayZone.startOfDay(first)
        let lastEnd = rig.dayZone.startOfDay(first.adding(days: 3))
        let inside = try await rig.provider.events(from: start + hour, to: start + 2 * hour, calendarIDs: [calendar])
        try expect(inside.count == 1, "a window inside the first day must find the event")
        let lastDay = try await rig.provider.events(from: lastEnd - hour, to: lastEnd, calendarIDs: [calendar])
        try expect(lastDay.count == 1, "a window inside the last day must find the event")
        let dayBefore = try await rig.provider.events(from: start - day, to: start, calendarIDs: [calendar])
        try expect(dayBefore.isEmpty, "the day before must not find it (the all-day range is inclusive of whole days only)")
        let dayAfter = try await rig.provider.events(from: lastEnd, to: lastEnd + day, calendarIDs: [calendar])
        try expect(dayAfter.isEmpty, "the day after the inclusive last day must not find it")
        // Converting between all-day and timed through an update keeps the event.
        let toTimed = try success(await rig.provider.updateEvent(
            created.key, update: CalendarEventUpdate(time: try timed(start + 9 * hour, start + 10 * hour)),
            scope: .thisOccurrence, expectedRevision: nil), "all-day to timed")
        try expect(toTimed.time == (try timed(start + 9 * hour, start + 10 * hour)), "timed conversion differs: \(toTimed.time)")
        let back = try success(await rig.provider.updateEvent(
            created.key, update: CalendarEventUpdate(time: .allDay(range)), scope: .thisOccurrence, expectedRevision: nil), "timed to all-day")
        try expect(back.time == .allDay(range), "all-day conversion differs: \(back.time)")
    }

    private static let updatePatch: Check = { rig in
        let calendar = try await rig.makeWritableCalendar(title: "contract-patch")
        let created = try success(await rig.provider.createEvent(CalendarEventDraft(
            calendarID: calendar, title: "원본", time: try timed(base + hour, base + 2 * hour),
            timeZoneIdentifier: "Asia/Seoul", location: "장소", notes: "노트")), "create")
        let renamed = try success(await rig.provider.updateEvent(
            created.key, update: CalendarEventUpdate(title: "수정"), scope: .thisOccurrence, expectedRevision: nil), "rename")
        try expect(renamed.title == "수정", "title not applied")
        try expect(renamed.time == created.time && renamed.location == "장소" && renamed.notes == "노트" && renamed.timeZoneIdentifier == "Asia/Seoul",
                   "a title-only update must keep every other field: \(renamed)")
        let cleared = try success(await rig.provider.updateEvent(
            created.key, update: CalendarEventUpdate(location: .clear, notes: .set("새 노트")), scope: .thisOccurrence, expectedRevision: nil), "clear")
        try expect(cleared.location == nil, "location should be cleared, got \(String(describing: cleared.location))")
        try expect(cleared.notes == "새 노트" && cleared.title == "수정", "notes set / title kept failed: \(cleared)")
        let moved = try success(await rig.provider.updateEvent(
            created.key, update: CalendarEventUpdate(time: try timed(base + 3 * hour, base + 5 * hour)), scope: .thisOccurrence, expectedRevision: nil), "move")
        try expect(moved.time == (try timed(base + 3 * hour, base + 5 * hour)) && moved.key == created.key, "move failed or key changed")
    }

    private static let revisionChangesOnWrite: Check = { rig in
        let calendar = try await rig.makeWritableCalendar(title: "contract-revision")
        let created = try success(await rig.provider.createEvent(CalendarEventDraft(
            calendarID: calendar, title: "t", time: try timed(base + hour, base + 2 * hour))), "create")
        let again = try require(try await rig.provider.event(created.key), "unreadable")
        try expect(again.revisionToken == created.revisionToken, "an unchanged event keeps its revision token")
        var seen: Set<String?> = [created.revisionToken]
        for index in 1...3 {
            let updated = try success(await rig.provider.updateEvent(
                created.key, update: CalendarEventUpdate(title: "t\(index)"), scope: .thisOccurrence, expectedRevision: nil), "update \(index)")
            try expect(!seen.contains(updated.revisionToken), "write \(index) must yield a new revision token even if it happens within the same second")
            seen.insert(updated.revisionToken)
        }
    }

    private static let staleConflict: Check = { rig in
        let calendar = try await rig.makeWritableCalendar(title: "contract-conflict")
        let created = try success(await rig.provider.createEvent(CalendarEventDraft(
            calendarID: calendar, title: "회의", time: try timed(base + hour, base + 2 * hour))), "create")
        let token = created.revisionToken
        try await rig.editExternally(created.key, update: CalendarEventUpdate(title: "외부"))
        let result = await rig.provider.updateEvent(created.key, update: CalendarEventUpdate(title: "내 수정"), scope: .thisOccurrence, expectedRevision: token)
        guard case let .conflict(current) = result else { throw ContractFailure(message: "expected conflict, got \(result)") }
        try expect(current?.title == "외부", "conflict should carry the current event, got \(String(describing: current?.title))")
        let stored = try require(try await rig.provider.event(created.key), "event vanished")
        try expect(stored.title == "외부", "a conflicting update must not write")
        let deletion = await rig.provider.deleteEvent(created.key, scope: .thisOccurrence, expectedRevision: token)
        guard case .conflict = deletion else { throw ContractFailure(message: "expected delete conflict, got \(deletion)") }
        try expect(try await rig.provider.event(created.key) != nil, "a conflicting delete must not delete")
        let fresh = try success(await rig.provider.updateEvent(
            created.key, update: CalendarEventUpdate(title: "최신 기준"), scope: .thisOccurrence, expectedRevision: stored.revisionToken), "update with current token")
        try expect(fresh.title == "최신 기준", "update with the current token should apply")
    }

    private static let missingTargets: Check = { rig in
        let calendar = try await rig.makeWritableCalendar(title: "contract-missing")
        let ghost = CalendarEventKey(calendarID: calendar, eventID: CalendarEventID(rawValue: "does-not-exist"))
        try expect(try await rig.provider.event(ghost) == nil, "an unknown key reads as nil")
        let update = await rig.provider.updateEvent(ghost, update: CalendarEventUpdate(title: "x"), scope: .thisOccurrence, expectedRevision: nil)
        try expect(update == .failure(.eventMissing), "update of a missing event: \(update)")
        let deletion = await rig.provider.deleteEvent(ghost, scope: .thisOccurrence, expectedRevision: nil)
        try expect(deletion == .failure(.eventMissing), "delete of a missing event: \(deletion)")
        let created = try success(await rig.provider.createEvent(CalendarEventDraft(
            calendarID: calendar, title: "gone", time: try timed(base + hour, base + 2 * hour))), "create")
        try await rig.removeExternally(created.key)
        try expect(try await rig.provider.event(created.key) == nil, "an externally removed event reads as nil")
        let afterRemoval = await rig.provider.updateEvent(created.key, update: CalendarEventUpdate(title: "x"), scope: .thisOccurrence, expectedRevision: created.revisionToken)
        try expect(afterRemoval == .failure(.eventMissing), "update after external removal should be eventMissing, got \(afterRemoval)")
    }

    private static let readOnlyCalendar: Check = { rig in
        guard let readOnly = try await rig.existingReadOnlyCalendar() else { throw Skip(reason: "the platform offers no read-only calendar") }
        let descriptors = try await rig.provider.calendars()
        let descriptor = try require(descriptors.first { $0.id == readOnly }, "the read-only calendar is not listed")
        try expect(!descriptor.isWritable, "a read-only calendar must report isWritable == false")
        let create = await rig.provider.createEvent(CalendarEventDraft(calendarID: readOnly, title: "x", time: try timed(base + hour, base + 2 * hour)))
        try expect(create == .failure(.calendarNotWritable(readOnly)), "create in a read-only calendar: \(create)")
        // Any existing event there must be reported not editable and refuse writes with the same typed failure.
        let events = try await rig.provider.events(from: 0, to: base + 4000 * day, calendarIDs: [readOnly])
        if let existing = events.first {
            try expect(!existing.isEditable, "events of a read-only calendar report isEditable == false")
            let update = await rig.provider.updateEvent(existing.key, update: CalendarEventUpdate(title: "x"), scope: .thisOccurrence, expectedRevision: nil)
            try expect(update == .failure(.calendarNotWritable(readOnly)), "update in a read-only calendar: \(update)")
            let deletion = await rig.provider.deleteEvent(existing.key, scope: .thisOccurrence, expectedRevision: nil)
            try expect(deletion == .failure(.calendarNotWritable(readOnly)), "delete in a read-only calendar: \(deletion)")
        }
    }

    private static let writeCheckOrder: Check = { rig in
        let calendar = try await rig.makeWritableCalendar(title: "contract-order")
        let ghostCalendar = CalendarID(rawValue: "no-such-calendar")
        let draft = CalendarEventDraft(calendarID: ghostCalendar, title: "x", time: try timed(base + hour, base + 2 * hour))
        let create = await rig.provider.createEvent(draft)
        try expect(create == .failure(.calendarMissing(ghostCalendar)), "create in an unknown calendar: \(create)")
        let ghostKey = CalendarEventKey(calendarID: ghostCalendar, eventID: CalendarEventID(rawValue: "e"))
        let update = await rig.provider.updateEvent(ghostKey, update: CalendarEventUpdate(title: "x"), scope: .thisOccurrence, expectedRevision: nil)
        try expect(update == .failure(.calendarMissing(ghostCalendar)), "the calendar is checked before the event: \(update)")
        let notDeclared = RecurrenceScope.allCases.first { !rig.provider.supportedRecurrenceScopes.contains($0) }
        if let notDeclared {
            let missing = CalendarEventKey(calendarID: calendar, eventID: CalendarEventID(rawValue: "missing"))
            let result = await rig.provider.updateEvent(missing, update: CalendarEventUpdate(title: "x"), scope: notDeclared, expectedRevision: nil)
            try expect(result == .failure(.eventMissing), "a missing event is reported before an unsupported scope: \(result)")
        }
    }

    private static let calendarRemovedExternally: Check = { rig in
        let calendar = try await rig.makeWritableCalendar(title: "contract-removed")
        let created = try success(await rig.provider.createEvent(CalendarEventDraft(
            calendarID: calendar, title: "x", time: try timed(base + hour, base + 2 * hour))), "create")
        try await rig.removeCalendarExternally(calendar)
        try expect(try await rig.provider.event(created.key) == nil, "events of a removed calendar read as nil")
        let calendars = try await rig.provider.calendars()
        try expect(!calendars.contains { $0.id == calendar }, "a removed calendar is no longer listed")
        let listed = try await rig.provider.events(from: base - day, to: base + day, calendarIDs: [calendar])
        try expect(listed.isEmpty, "a removed calendar has no events")
        let write = await rig.provider.createEvent(CalendarEventDraft(calendarID: calendar, title: "y", time: try timed(base + hour, base + 2 * hour)))
        try expect(write == .failure(.calendarMissing(calendar)), "write to a removed calendar: \(write)")
    }

    private static let changeSignal: Check = { rig in
        let calendar = try await rig.makeWritableCalendar(title: "contract-signal")
        let stream = await rig.provider.changes()
        let waiter = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        defer { waiter.cancel() }
        _ = try success(await rig.provider.createEvent(CalendarEventDraft(
            calendarID: calendar, title: "signal", time: try timed(base + hour, base + 2 * hour))), "create")
        let created = try await withTimeout(seconds: 10) { await waiter.value }
        try expect(created == true, "no change signal arrived within 10 seconds of a write")
        // An external edit must also be signalled.
        let events = try await window(rig, calendar)
        let event = try require(events.first, "event missing")
        let next = await rig.provider.changes()
        let second = Task { () -> Bool in
            for await _ in next { return true }
            return false
        }
        defer { second.cancel() }
        try await rig.editExternally(event.key, update: CalendarEventUpdate(title: "from outside"))
        let external = try await withTimeout(seconds: 10) { await second.value }
        try expect(external == true, "no change signal arrived within 10 seconds of an external edit")
    }

    private static let revokedAccess: Check = { rig in
        let calendar = try await rig.makeWritableCalendar(title: "contract-access")
        let created = try success(await rig.provider.createEvent(CalendarEventDraft(
            calendarID: calendar, title: "x", time: try timed(base + hour, base + 2 * hour))), "create")
        guard await rig.setAccess(available: false) else { throw Skip(reason: "the platform cannot revoke access in a test") }
        do {
            _ = try await rig.provider.calendars()
            _ = await rig.setAccess(available: true)
            throw ContractFailure(message: "calendars() must throw accessUnavailable while access is revoked")
        } catch let failure as CalendarProviderFailure {
            try expect(failure == .accessUnavailable, "expected accessUnavailable, got \(failure)")
        }
        let write = await rig.provider.createEvent(CalendarEventDraft(calendarID: calendar, title: "y", time: try timed(base + hour, base + 2 * hour)))
        _ = await rig.setAccess(available: true)
        try expect(write == .failure(.accessUnavailable), "writes fail with accessUnavailable while revoked: \(write)")
        try expect(try await rig.provider.event(created.key) != nil, "the event is readable again after access returns")
    }

    private static func series(_ rig: any CalendarProviderTestRig, _ title: String, count: Int = 4) async throws -> (CalendarID, [CalendarEvent]) {
        guard rig.supportsRecurrence else { throw Skip(reason: "the rig cannot seed recurring series") }
        let calendar = try await rig.makeWritableCalendar(title: "contract-\(title)")
        // 10:00-11:00 in the day zone on a day well inside the window.
        let day0 = rig.dayZone.localDate(of: base + 3 * day + 12 * hour)
        let firstStart = rig.dayZone.instant(of: day0, minuteOfDay: 10 * 60)
        try await rig.seedWeeklySeries(calendarID: calendar, title: title, firstStartUnixMilliseconds: firstStart, durationMilliseconds: hour, count: count)
        let events = try await window(rig, calendar).filter { $0.title == title }.sorted { start(of: $0) < start(of: $1) }
        try expect(events.count == count, "expected \(count) occurrences, got \(events.count)")
        return (calendar, events)
    }

    private static func start(of event: CalendarEvent) -> Int64 {
        if case let .timed(range) = event.time { return range.startUnixMilliseconds }
        return 0
    }

    private static let recurringIdentity: Check = { rig in
        let (_, events) = try await series(rig, "ident")
        try expect(Set(events.map(\.key)).count == events.count, "every occurrence needs its own key")
        try expect(events.allSatisfy(\.isRecurringInstance), "occurrences of a series report isRecurringInstance")
        for event in events {
            let read = try require(try await rig.provider.event(event.key), "occurrence key does not resolve: \(event.key)")
            try expect(read.time == event.time, "a key must resolve to the same occurrence it was issued for")
        }
    }

    private static let recurringThisOccurrence: Check = { rig in
        guard rig.provider.supportedRecurrenceScopes.contains(.thisOccurrence) else { throw ContractFailure(message: "thisOccurrence must always be supported") }
        let (calendar, events) = try await series(rig, "one")
        let target = events[1]
        let newStart = start(of: target) + 5 * hour
        let result = try success(await rig.provider.updateEvent(
            target.key, update: CalendarEventUpdate(title: "one-moved", time: try timed(newStart, newStart + hour)),
            scope: .thisOccurrence, expectedRevision: target.revisionToken), "move one occurrence")
        try expect(result.key == target.key, "moving an occurrence must not change its key: \(target.key) -> \(result.key)")
        let after = try await window(rig, calendar).sorted { start(of: $0) < start(of: $1) }
        try expect(after.count == events.count, "still \(events.count) occurrences, got \(after.count)")
        let moved = try require(try await rig.provider.event(target.key), "the moved occurrence must resolve by its original key")
        try expect(moved.title == "one-moved" && start(of: moved) == newStart, "moved occurrence differs: \(moved.title) \(start(of: moved))")
        for other in events where other.key != target.key {
            let now = try require(try await rig.provider.event(other.key), "the other occurrences keep resolving")
            try expect(now.title == other.title && now.time == other.time, "other occurrences must be untouched: \(now.title)")
        }
    }

    private static let recurringAllInSeries: Check = { rig in
        guard rig.provider.supportedRecurrenceScopes.contains(.allInSeries) else { throw Skip(reason: "allInSeries is not declared by this provider") }
        let (calendar, events) = try await series(rig, "all")
        let target = events[2]
        let newStart = start(of: target) + 2 * hour
        let result = try success(await rig.provider.updateEvent(
            target.key, update: CalendarEventUpdate(title: "all-renamed", time: try timed(newStart, newStart + 90 * 60_000)),
            scope: .allInSeries, expectedRevision: target.revisionToken), "series update")
        try expect(result.key == target.key, "allInSeries must keep the addressed key")
        for original in events {
            let now = try require(try await rig.provider.event(original.key), "every occurrence keeps resolving after allInSeries: \(original.key)")
            try expect(now.title == "all-renamed", "title applies to the whole series, got \(now.title)")
            try expect(start(of: now) == start(of: original) + 2 * hour, "every occurrence shifts by the same time of day")
            if case let .timed(range) = now.time { try expect(range.durationMilliseconds == 90 * 60_000, "duration applies to the series") }
        }
        try expect(try await window(rig, calendar).filter { $0.title == "all-renamed" }.count == events.count, "series stays whole")
    }

    private static let recurringDateChangeRefused: Check = { rig in
        guard rig.provider.supportedRecurrenceScopes.contains(.allInSeries) else { throw Skip(reason: "allInSeries is not declared by this provider") }
        let (_, events) = try await series(rig, "date")
        let target = events[0]
        let next = start(of: target) + day
        let result = await rig.provider.updateEvent(
            target.key, update: CalendarEventUpdate(time: try timed(next, next + hour)), scope: .allInSeries, expectedRevision: nil)
        guard case .failure(.unsupported) = result else { throw ContractFailure(message: "a date change with allInSeries must be refused as unsupported, got \(result)") }
        let read = try require(try await rig.provider.event(target.key), "event unreadable")
        try expect(read.time == target.time, "a refused change must not write")
    }

    private static let recurringDelete: Check = { rig in
        let (calendar, events) = try await series(rig, "del")
        let one = events[1]
        let deleted = try success(await rig.provider.deleteEvent(one.key, scope: .thisOccurrence, expectedRevision: one.revisionToken), "delete one")
        try expect(deleted, "delete reports success")
        try expect(try await rig.provider.event(one.key) == nil, "the deleted occurrence is gone")
        let rest = try await window(rig, calendar).filter { $0.title == "del" }
        try expect(rest.count == events.count - 1, "deleting one occurrence leaves the others, got \(rest.count)")
        guard rig.provider.supportedRecurrenceScopes.contains(.allInSeries) else { return }
        let remaining = try require(rest.first, "an occurrence is left")
        _ = try success(await rig.provider.deleteEvent(remaining.key, scope: .allInSeries, expectedRevision: nil), "delete series")
        try expect(try await window(rig, calendar).filter { $0.title == "del" }.isEmpty, "allInSeries deletes the whole series")
    }

    private static let thisAndFutureNotDeclared: Check = { rig in
        try expect(!rig.provider.supportedRecurrenceScopes.contains(.thisAndFuture),
                   "thisAndFuture re-identifies future occurrences and no provider can keep keys stable for it yet")
    }
}

/// Runs `operation` and fails if it does not finish in time. The operation is not cancelled cooperatively; it
/// is abandoned, which is acceptable for a test.
private func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ContractFailure(message: "timed out after \(seconds) seconds")
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw ContractFailure(message: "no result") }
        return first
    }
}
