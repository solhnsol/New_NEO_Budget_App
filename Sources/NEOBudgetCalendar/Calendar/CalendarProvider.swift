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
/// this contract. Contract notes any implementation must honor. They were revised after observing real
/// EventKit behavior (`docs/eventkit-spike.md`); `NEOBudgetCalendarContract` executes them against any provider.
///
/// **Reading**
/// - `events(from:to:calendarIDs:)` returns every event whose range overlaps `[from, to)`; order is unspecified.
///   A recurring series is returned **expanded into occurrences**, each with its own `CalendarEventKey`.
///   All-day events occupy whole local days in the provider's day zone, which is fixed when the provider is made.
/// - `event(_:)` returns `nil` when the key no longer resolves; a key that stopped resolving is "missing".
///
/// **Identity**
/// - A `CalendarEventKey` is opaque but must be **distinct per occurrence** of a recurring series and **stable
///   across `.thisOccurrence` edits of that occurrence**, including moving it to another time. A provider whose
///   platform changes the occurrence's identifier when it is moved must hide that behind its own token.
/// - An operation never silently changes the key of an event it touches. A provider that cannot keep keys stable
///   for a scope must not declare that scope (the domain has no re-binding result yet).
///
/// **Recurrence scopes** (`supportedRecurrenceScopes` states what the provider can do; any scope may still be
/// refused per event with `.unsupported`)
/// - `.thisOccurrence` changes exactly the addressed occurrence. Non-recurring events always use it.
/// - `.allInSeries` applies the change to the whole series. `CalendarEventUpdate.time` is the new range of the
///   **addressed occurrence**; the provider applies the same time-of-day shift and duration to the series.
///   A time that moves the occurrence to another local day is refused with `.unsupported`.
/// - `.thisAndFuture` splits a series and, on common platforms, re-identifies the future occurrences. It may
///   only be declared by a provider that can keep keys stable, which no current provider does.
///
/// **Writing**
/// - `updateEvent` is a **patch**: fields the update leaves at `.keep`/`nil` must not be modified or lost,
///   including fields the domain does not model (attendees, alarms, URLs, ...).
/// - Write checks run in this order: access (`.accessUnavailable`), the one-shot save failure queue, the
///   calendar exists (`.calendarMissing`), the calendar is writable (`.calendarNotWritable`), the event exists
///   (`.eventMissing`), the event is editable and the scope is supported (`.unsupported`), the revision matches.
/// - An event in a non-writable calendar reports `isEditable == false`.
///
/// **Conflict detection**
/// - `revisionToken` must change whenever any field the domain models changes, including edits made within the
///   same clock second, so a provider cannot rely on a modification timestamp alone.
/// - When `expectedRevision` is non-nil and no longer matches, return `.conflict` and write nothing. The check
///   cannot be atomic with every platform's write, so it is best effort against concurrent writers.
///
/// **Change signal**
/// - `changes()` yields a payload-free signal when the calendar data may have changed. Signals coalesce, carry no
///   detail, may also fire for this provider's own writes, and never promise ordering. Consumers re-read and diff.
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

    /// A stream of "something may have changed" signals. Each call returns an independent stream.
    func changes() async -> AsyncStream<Void>
}
