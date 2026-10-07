import NEOBudgetCalendar

/// A scripted calendar system for tests. It can simulate what a real calendar does around the app: events
/// edited or deleted elsewhere, calendars removed, access revoked, and saves that fail.
///
/// It models only the provider contract. It does not claim to behave like any real platform calendar, and
/// recurring-event semantics are deliberately not simulated: `isRecurringInstance` is just a flag.
public actor InMemoryCalendarProvider: CalendarProvider {
    public nonisolated let supportedRecurrenceScopes: Set<RecurrenceScope>

    private var calendarsByID: [CalendarID: CalendarDescriptor] = [:]
    private var eventsByKey: [CalendarEventKey: CalendarEvent] = [:]
    private var nextEventNumber = 1
    private var nextRevision = 1
    private var accessAvailable = true
    private var queuedSaveFailures: [CalendarProviderFailure] = []

    public init(
        calendars: [CalendarDescriptor] = [],
        events: [CalendarEvent] = [],
        supportedRecurrenceScopes: Set<RecurrenceScope> = [.thisOccurrence]
    ) {
        self.supportedRecurrenceScopes = supportedRecurrenceScopes
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
    }

    public func removeExternally(_ key: CalendarEventKey) { eventsByKey[key] = nil }

    public func removeCalendarExternally(_ id: CalendarID) {
        calendarsByID[id] = nil
        for key in eventsByKey.keys where key.calendarID == id { eventsByKey[key] = nil }
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
                return Self.overlaps(event, from: from, to: to)
            }
            .sorted { $0.key < $1.key }
    }

    public func event(_ key: CalendarEventKey) async throws -> CalendarEvent? {
        guard accessAvailable else { throw CalendarProviderFailure.accessUnavailable }
        return eventsByKey[key]
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
        return .success(event)
    }

    public func updateEvent(
        _ key: CalendarEventKey,
        update: CalendarEventUpdate,
        scope: RecurrenceScope,
        expectedRevision: String?
    ) async -> CalendarProviderResult<CalendarEvent> {
        if let failure = writeGate(calendarID: key.calendarID) { return .failure(failure) }
        guard supportedRecurrenceScopes.contains(scope) else { return .failure(.unsupported("scope \(scope.rawValue)")) }
        guard let event = eventsByKey[key] else { return .failure(.eventMissing) }
        guard event.isEditable else { return .failure(.unsupported("read-only event")) }
        if let expectedRevision, expectedRevision != event.revisionToken { return .conflict(current: event) }
        let updated = withNewRevision(update.applied(to: event))
        eventsByKey[key] = updated
        return .success(updated)
    }

    public func deleteEvent(
        _ key: CalendarEventKey,
        scope: RecurrenceScope,
        expectedRevision: String?
    ) async -> CalendarProviderResult<Bool> {
        if let failure = writeGate(calendarID: key.calendarID) { return .failure(failure) }
        guard supportedRecurrenceScopes.contains(scope) else { return .failure(.unsupported("scope \(scope.rawValue)")) }
        guard let event = eventsByKey[key] else { return .failure(.eventMissing) }
        guard event.isEditable else { return .failure(.unsupported("read-only event")) }
        if let expectedRevision, expectedRevision != event.revisionToken { return .conflict(current: event) }
        eventsByKey[key] = nil
        return .success(true)
    }

    // MARK: Internals

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

    /// Overlap with an instant window. All-day events are widened by a day on each side because the fake has
    /// no time zone; callers that need exact all-day handling resolve it themselves.
    private static func overlaps(_ event: CalendarEvent, from: Int64, to: Int64) -> Bool {
        switch event.time {
        case let .timed(range):
            return range.overlaps(from: from, to: to)
        case let .allDay(range):
            let day: Int64 = 86_400_000
            let start = Int64(range.firstDay.daysSinceUnixEpoch) * day - day
            let end = Int64(range.lastDay.daysSinceUnixEpoch + 1) * day + day
            return start < to && end > from
        }
    }
}
