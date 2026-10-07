/// Why a provider operation did not happen. Permanent failures are values, not thrown errors.
public enum CalendarProviderFailure: Error, Hashable, Sendable {
    case accessUnavailable
    case calendarNotWritable(CalendarID)
    case calendarMissing(CalendarID)
    case eventMissing
    case saveFailed(retryable: Bool, reason: String)
    case unsupported(String)
}

public enum CalendarProviderResult<Value: Sendable>: Sendable {
    case success(Value)
    /// The event changed since `expectedRevision`. Nothing was written. `current` is the latest state if known.
    case conflict(current: CalendarEvent?)
    case failure(CalendarProviderFailure)
}

extension CalendarProviderResult: Equatable where Value: Equatable {}

/// The boundary to an external calendar system, which stays the source of truth for event fields.
///
/// An implementation (for example one backed by the device calendar) must not leak platform objects through
/// this contract. Contract notes any implementation must honor:
/// - `events(from:to:calendarIDs:)` returns every event whose range overlaps `[from, to)`; order is unspecified.
/// - `updateEvent` is a **patch**: fields the update leaves at `.keep`/`nil` must not be modified or lost.
/// - When `expectedRevision` is non-nil and no longer matches, return `.conflict` and write nothing.
/// - Recurrence scope support differs per provider and must be declared in `supportedRecurrenceScopes`.
public protocol CalendarProvider: Sendable {
    var supportedRecurrenceScopes: Set<RecurrenceScope> { get }

    func calendars() async throws -> [CalendarDescriptor]
    func events(from: Int64, to: Int64, calendarIDs: Set<CalendarID>?) async throws -> [CalendarEvent]
    func event(_ key: CalendarEventKey) async throws -> CalendarEvent?

    func createEvent(_ draft: CalendarEventDraft) async -> CalendarProviderResult<CalendarEvent>
    func updateEvent(
        _ key: CalendarEventKey,
        update: CalendarEventUpdate,
        scope: RecurrenceScope,
        expectedRevision: String?
    ) async -> CalendarProviderResult<CalendarEvent>
    func deleteEvent(
        _ key: CalendarEventKey,
        scope: RecurrenceScope,
        expectedRevision: String?
    ) async -> CalendarProviderResult<Bool>
}
