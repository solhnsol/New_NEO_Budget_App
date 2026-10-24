import NEOBudgetCalendar

/// A scripted calendar system for tests. It can simulate what a real calendar does around the app: events
/// edited or deleted elsewhere, calendars removed, access revoked, saves that fail, and recurring series.
///
/// It models only the provider contract. It does not claim to behave like any real platform calendar. A series
/// is a plain list of occurrences that share a series token: `.thisOccurrence` edits one, `.allInSeries` shifts
/// every member, and keys never change. There are no recurrence rules and no exceptions.
public actor InMemoryCalendarProvider: CalendarProvider {
    public nonisolated let supportedRecurrenceScopes: Set<RecurrenceScope>

    private let dayZone: DisplayTimeZone
    private var calendarsByID: [CalendarID: CalendarDescriptor] = [:]
    private var eventsByKey: [CalendarEventKey: CalendarEvent] = [:]
    private var seriesByKey: [CalendarEventKey: Int] = [:]
    private var nextEventNumber = 1
    private var nextSeriesNumber = 1
    private var nextRevision = 1
    private var accessAvailable = true
    private var queuedSaveFailures: [CalendarProviderFailure] = []
    private var listeners: [Int: AsyncStream<Void>.Continuation] = [:]
    private var nextListener = 0

    public init(
        calendars: [CalendarDescriptor] = [],
        events: [CalendarEvent] = [],
        supportedRecurrenceScopes: Set<RecurrenceScope> = [.thisOccurrence],
        dayZone: DisplayTimeZone? = nil
    ) {
        self.supportedRecurrenceScopes = supportedRecurrenceScopes
        self.dayZone = dayZone ?? Self.utc
        for calendar in calendars { calendarsByID[calendar.id] = calendar }
        for event in events { eventsByKey[event.key] = event }
    }

    // MARK: Test controls

    public func setAccessAvailable(_ available: Bool) { accessAvailable = available }

    /// The next write operation fails with `failure` (then behavior returns to normal).
    public func failNextWrite(with failure: CalendarProviderFailure) { queuedSaveFailures.append(failure) }

    /// Replaces an event as if another app edited it. The revision token changes.
    public func editExternally(_ key: CalendarEventKey, update: CalendarEventUpdate) {
        guard let event = eventsByKey[key] else { return }
        eventsByKey[key] = withNewRevision(update.applied(to: event))
        signalChange()
    }

    public func removeExternally(_ key: CalendarEventKey) {
        eventsByKey[key] = nil
        seriesByKey[key] = nil
        signalChange()
    }

    public func removeCalendarExternally(_ id: CalendarID) {
        calendarsByID[id] = nil
        for key in eventsByKey.keys where key.calendarID == id {
            eventsByKey[key] = nil
            seriesByKey[key] = nil
        }
        signalChange()
    }

    public func addCalendar(_ calendar: CalendarDescriptor) {
        calendarsByID[calendar.id] = calendar
        signalChange()
    }

    /// Adds a series of `count` occurrences, `intervalDays` apart, as a recurring calendar would expand it.
    @discardableResult
    public func seedSeries(
        calendarID: CalendarID,
        title: String,
        firstStartUnixMilliseconds: Int64,
        durationMilliseconds: Int64,
        count: Int,
        intervalDays: Int = 7
    ) -> [CalendarEvent] {
        let series = nextSeriesNumber
        nextSeriesNumber += 1
        var created: [CalendarEvent] = []
        for index in 0..<count {
            let start = firstStartUnixMilliseconds + Int64(index * intervalDays) * 86_400_000
            guard let range = try? TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: start + durationMilliseconds) else { continue }
            let event = CalendarEvent(
                id: CalendarEventID(rawValue: "mem-s\(series)-\(index)"),
                calendarID: calendarID,
                title: title,
                time: .timed(range),
                isRecurringInstance: true,
                revisionToken: "r\(nextRevision)"
            )
            nextRevision += 1
            eventsByKey[event.key] = event
            seriesByKey[event.key] = series
            created.append(event)
        }
        signalChange()
        return created
    }

    public func storedEvent(_ key: CalendarEventKey) -> CalendarEvent? { eventsByKey[key] }

    // MARK: CalendarProvider

    public func calendars() async throws -> [CalendarDescriptor] {
        guard accessAvailable else { throw CalendarProviderFailure.accessUnavailable }
        return calendarsByID.values.sorted { $0.id < $1.id }
    }

    public func events(from: Int64, to: Int64, calendarIDs: Set<CalendarID>?) async throws -> [CalendarEvent] {
        guard accessAvailable else { throw CalendarProviderFailure.accessUnavailable }
        return eventsByKey.values
            .filter { event in
                if let calendarIDs, !calendarIDs.contains(event.calendarID) { return false }
                return event.time.overlaps(from: from, to: to, in: dayZone)
            }
            .sorted { $0.key < $1.key }
    }

    public func event(_ key: CalendarEventKey) async throws -> CalendarEvent? {
        guard accessAvailable else { throw CalendarProviderFailure.accessUnavailable }
        return eventsByKey[key]
    }

    public func changes() async -> AsyncStream<Void> {
        let id = nextListener
        nextListener += 1
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        return stream
    }

    public func createEvent(_ draft: CalendarEventDraft) async -> CalendarProviderResult<CalendarEvent> {
        if let failure = writeGate(calendarID: draft.calendarID) { return .failure(failure) }
        let event = CalendarEvent(
            id: CalendarEventID(rawValue: "mem-\(nextEventNumber)"),
            calendarID: draft.calendarID,
            title: draft.title,
            time: draft.time,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            location: draft.location,
            notes: draft.notes,
            revisionToken: "r\(nextRevision)"
        )
        nextEventNumber += 1
        nextRevision += 1
        eventsByKey[event.key] = event
        signalChange()
        return .success(event)
    }

    public func updateEvent(
        _ key: CalendarEventKey,
        update: CalendarEventUpdate,
        scope: RecurrenceScope,
        expectedRevision: String?
    ) async -> CalendarProviderResult<CalendarEvent> {
        if let failure = writeGate(calendarID: key.calendarID) { return .failure(failure) }
        guard let event = eventsByKey[key] else { return .failure(.eventMissing) }
        guard event.isEditable else { return .failure(.unsupported("read-only event")) }
        guard supportedRecurrenceScopes.contains(scope) else { return .failure(.unsupported("scope \(scope.rawValue)")) }
        if let expectedRevision, expectedRevision != event.revisionToken { return .conflict(current: event) }

        guard scope == .allInSeries, let series = seriesByKey[key] else {
            let updated = withNewRevision(update.applied(to: event))
            eventsByKey[key] = updated
            signalChange()
            return .success(updated)
        }
        // allInSeries on a recurring occurrence.
        var shiftMilliseconds: Int64 = 0
        var newDuration: Int64?
        if let time = update.time {
            guard case let .timed(old) = event.time, case let .timed(new) = time else {
                return .failure(.unsupported("series time change must stay timed"))
            }
            guard dayZone.localDate(of: old.startUnixMilliseconds) == dayZone.localDate(of: new.startUnixMilliseconds) else {
                return .failure(.unsupported("a date change applies to one occurrence"))
            }
            shiftMilliseconds = new.startUnixMilliseconds - old.startUnixMilliseconds
            newDuration = new.durationMilliseconds
        }
        let fieldsOnly = CalendarEventUpdate(
            title: update.title,
            timeZoneIdentifier: update.timeZoneIdentifier,
            location: update.location,
            notes: update.notes
        )
        var result = event
        for (memberKey, member) in eventsByKey where seriesByKey[memberKey] == series {
            var changed = fieldsOnly.applied(to: member)
            if case let .timed(range) = member.time, let newDuration,
               let shifted = try? TimedRange(
                startUnixMilliseconds: range.startUnixMilliseconds + shiftMilliseconds,
                endUnixMilliseconds: range.startUnixMilliseconds + shiftMilliseconds + newDuration
               ) {
                changed = CalendarEventUpdate(time: .timed(shifted)).applied(to: changed)
            }
            let stored = withNewRevision(changed)
            eventsByKey[memberKey] = stored
            if memberKey == key { result = stored }
        }
        signalChange()
        return .success(result)
    }

    public func deleteEvent(
        _ key: CalendarEventKey,
        scope: RecurrenceScope,
        expectedRevision: String?
    ) async -> CalendarProviderResult<Bool> {
        if let failure = writeGate(calendarID: key.calendarID) { return .failure(failure) }
        guard let event = eventsByKey[key] else { return .failure(.eventMissing) }
        guard event.isEditable else { return .failure(.unsupported("read-only event")) }
        guard supportedRecurrenceScopes.contains(scope) else { return .failure(.unsupported("scope \(scope.rawValue)")) }
        if let expectedRevision, expectedRevision != event.revisionToken { return .conflict(current: event) }
        if scope == .allInSeries, let series = seriesByKey[key] {
            for memberKey in eventsByKey.keys where seriesByKey[memberKey] == series {
                eventsByKey[memberKey] = nil
                seriesByKey[memberKey] = nil
            }
        } else {
            eventsByKey[key] = nil
            seriesByKey[key] = nil
        }
        signalChange()
        return .success(true)
    }

    // MARK: Internals

    private func signalChange() {
        for continuation in listeners.values { continuation.yield() }
    }

    private func removeListener(_ id: Int) { listeners[id] = nil }

    /// Check order is part of the provider contract: access, queued failure, calendar exists, calendar writable.
    private func writeGate(calendarID: CalendarID) -> CalendarProviderFailure? {
        guard accessAvailable else { return .accessUnavailable }
        if !queuedSaveFailures.isEmpty { return queuedSaveFailures.removeFirst() }
        guard let calendar = calendarsByID[calendarID] else { return .calendarMissing(calendarID) }
        guard calendar.isWritable else { return .calendarNotWritable(calendarID) }
        return nil
    }

    private func withNewRevision(_ event: CalendarEvent) -> CalendarEvent {
        defer { nextRevision += 1 }
        return CalendarEvent(
            id: event.id,
            calendarID: event.calendarID,
            title: event.title,
            time: event.time,
            timeZoneIdentifier: event.timeZoneIdentifier,
            location: event.location,
            notes: event.notes,
            isRecurringInstance: event.isRecurringInstance,
            isEditable: event.isEditable,
            revisionToken: "r\(nextRevision)"
        )
    }
}

extension InMemoryCalendarProvider {
    /// "UTC" is valid on every platform, so the fallback is unreachable.
    fileprivate static var utc: DisplayTimeZone {
        (try? DisplayTimeZone(identifier: "UTC")) ?? (try! DisplayTimeZone(identifier: "GMT"))
    }
}
