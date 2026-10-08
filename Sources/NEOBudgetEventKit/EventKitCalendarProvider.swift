#if canImport(EventKit)
import CryptoKit
import EventKit
import Foundation
import NEOBudgetCalendar

/// What the app may do with the device calendar, without asking.
public enum CalendarAccessState: Sendable, Equatable {
    case notDetermined
    case fullAccess
    /// The user allowed adding events but not reading them. The app cannot show a timeline in this state.
    case writeOnly
    case denied
    case restricted
}

/// `CalendarProvider` backed by the device calendar (EventKit). It owns one `EKEventStore` inside the actor and
/// never lets an `EK*` object leave it. Behavior follows what `docs/eventkit-spike.md` observed.
///
/// Identity: a non-recurring event's key is its `eventIdentifier`. A recurring occurrence is addressed as
/// `<master eventIdentifier>|<original local date>` so the key survives moving that occurrence (EventKit
/// re-identifies a moved occurrence and reports its *new* time as `occurrenceDate`) and `allInSeries` time shifts.
/// An occurrence moved more than a year away from its original day stops resolving and reads as missing.
///
/// Scopes: `.thisOccurrence` and `.allInSeries` (master lookup + `.futureEvents`). `.thisAndFuture` is not
/// declared because EventKit gives the future occurrences new identifiers.
///
/// All-day: EventKit stores the last day as 23:59:59 regardless of what is written, so `DayRange.lastDay` is the
/// day containing `endDate`, and writes use 23:59:59 of the last day.
public actor EventKitCalendarProvider: CalendarProvider {
    public nonisolated let supportedRecurrenceScopes: Set<RecurrenceScope> = [.thisOccurrence, .allInSeries]

    private let store: EKEventStore
    private let dayZone: DisplayTimeZone
    private var zoneCache: [String: DisplayTimeZone] = [:]

    /// - Parameter dayZoneIdentifier: the zone that places all-day events on local days. Defaults to the device zone,
    ///   which is the zone EventKit itself uses for all-day events.
    public init(dayZoneIdentifier: String? = nil) throws {
        let identifier = dayZoneIdentifier ?? TimeZone.current.identifier
        dayZone = try DisplayTimeZone(identifier: identifier)
        store = EKEventStore()
    }

    /// The current authorization, read without prompting.
    public nonisolated static func accessState() -> CalendarAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .restricted: return .restricted
        default: return .denied
        }
    }

    /// Asks the user for full calendar access. Returns whether it was granted.
    public func requestFullAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
            }
        }
    }

    // MARK: Reading

    public func calendars() async throws -> [CalendarDescriptor] {
        try requireAccess()
        store.refreshSourcesIfNecessary()
        return store.calendars(for: .event).map(descriptor).sorted { $0.id < $1.id }
    }

    public func events(from: Int64, to: Int64, calendarIDs: Set<CalendarID>?) async throws -> [CalendarEvent] {
        try requireAccess()
        guard from < to else { return [] }
        store.refreshSourcesIfNecessary()
        var selected = store.calendars(for: .event)
        if let calendarIDs {
            selected = selected.filter { calendarIDs.contains(CalendarID(rawValue: $0.calendarIdentifier)) }
            guard !selected.isEmpty else { return [] }
        }
        let predicate = store.predicateForEvents(withStart: date(from), end: date(to), calendars: selected)
        return store.events(matching: predicate)
            .compactMap(snapshot)
            .filter { $0.time.overlaps(from: from, to: to, in: dayZone) }
            .sorted { $0.key < $1.key }
    }

    public func event(_ key: CalendarEventKey) async throws -> CalendarEvent? {
        try requireAccess()
        return load(key).flatMap(snapshot)
    }

    public func changes() async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Not tied to one store object: another process or store instance changing the database notifies too.
        let observer = ObserverBox(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: nil) { _ in
            continuation.yield()
        })
        continuation.onTermination = { _ in NotificationCenter.default.removeObserver(observer.token) }
        return stream
    }

    // MARK: Writing

    public func createEvent(_ draft: CalendarEventDraft) async -> CalendarProviderResult<CalendarEvent> {
        do { try requireAccess() } catch { return .failure(.accessUnavailable) }
        guard let calendar = calendar(withID: draft.calendarID.rawValue) else { return .failure(.calendarMissing(draft.calendarID)) }
        guard calendar.allowsContentModifications else { return .failure(.calendarNotWritable(draft.calendarID)) }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        if let failure = apply(
            CalendarEventUpdate(time: draft.time, timeZoneIdentifier: draft.timeZoneIdentifier.map { .set($0) } ?? .clear,
                                location: draft.location.map { .set($0) } ?? .clear, notes: draft.notes.map { .set($0) } ?? .clear),
            to: event
        ) { return .failure(failure) }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return .failure(map(error, calendarID: draft.calendarID))
        }
        guard let created = snapshot(event) else { return .failure(.saveFailed(retryable: true, reason: "saved event could not be read back")) }
        return .success(created)
    }

    public func updateEvent(
        _ key: CalendarEventKey,
        update: CalendarEventUpdate,
        scope: RecurrenceScope,
        expectedRevision: String?
    ) async -> CalendarProviderResult<CalendarEvent> {
        do { try requireAccess() } catch { return .failure(.accessUnavailable) }
        if let failure = calendarGate(key.calendarID) { return .failure(failure) }
        guard let target = load(key) else { return .failure(.eventMissing) }
        guard supportedRecurrenceScopes.contains(scope) else { return .failure(.unsupported("scope \(scope.rawValue)")) }
        if let expectedRevision, expectedRevision != token(of: target) { return .conflict(current: snapshot(target)) }

        let recurring = target.hasRecurrenceRules
        if scope == .allInSeries && recurring {
            return updateWholeSeries(target, key: key, update: update)
        }
        if let failure = apply(update, to: target) { return .failure(failure) }
        do {
            try store.save(target, span: .thisEvent, commit: true)
        } catch {
            return .failure(map(error, calendarID: key.calendarID))
        }
        return savedResult(key)
    }

    public func deleteEvent(
        _ key: CalendarEventKey,
        scope: RecurrenceScope,
        expectedRevision: String?
    ) async -> CalendarProviderResult<Bool> {
        do { try requireAccess() } catch { return .failure(.accessUnavailable) }
        if let failure = calendarGate(key.calendarID) { return .failure(failure) }
        guard let target = load(key) else { return .failure(.eventMissing) }
        guard supportedRecurrenceScopes.contains(scope) else { return .failure(.unsupported("scope \(scope.rawValue)")) }
        if let expectedRevision, expectedRevision != token(of: target) { return .conflict(current: snapshot(target)) }
        do {
            if scope == .allInSeries && target.hasRecurrenceRules {
                guard let master = store.event(withIdentifier: masterIdentifier(of: target)) else { return .failure(.eventMissing) }
                try store.remove(master, span: .futureEvents, commit: true)
            } else {
                try store.remove(target, span: .thisEvent, commit: true)
            }
        } catch {
            return .failure(map(error, calendarID: key.calendarID))
        }
        return .success(true)
    }

    // MARK: Series

    private func updateWholeSeries(_ occurrence: EKEvent, key: CalendarEventKey, update: CalendarEventUpdate) -> CalendarProviderResult<CalendarEvent> {
        guard update.timeZoneIdentifier.isKeep else { return .failure(.unsupported("series time zone change")) }
        guard let master = store.event(withIdentifier: masterIdentifier(of: occurrence)), master.hasRecurrenceRules else {
            return .failure(.eventMissing)
        }
        var fieldsOnly = update
        fieldsOnly.time = nil
        if let time = update.time {
            guard case let .timed(new) = time, !occurrence.isAllDay else { return .failure(.unsupported("series time change must stay timed")) }
            let oldStart = milliseconds(occurrence.startDate)
            let zone = zone(for: occurrence)
            guard zone.localDate(of: oldStart) == zone.localDate(of: new.startUnixMilliseconds) else {
                return .failure(.unsupported("a date change applies to one occurrence"))
            }
            let shift = Double(new.startUnixMilliseconds - oldStart) / 1_000
            master.startDate = master.startDate.addingTimeInterval(shift)
            master.endDate = master.startDate.addingTimeInterval(Double(new.durationMilliseconds) / 1_000)
        }
        if let failure = apply(fieldsOnly, to: master) { return .failure(failure) }
        do {
            try store.save(master, span: .futureEvents, commit: true)
        } catch {
            return .failure(map(error, calendarID: key.calendarID))
        }
        return savedResult(key)
    }

    // MARK: Identity

    private func masterIdentifier(of event: EKEvent) -> String {
        let identifier = event.eventIdentifier ?? ""
        return identifier.components(separatedBy: "/RID=").first ?? identifier
    }

    /// The instant the occurrence had before anyone moved it. A moved occurrence encodes it in its identifier.
    private func originalStart(of event: EKEvent) -> Date {
        if let identifier = event.eventIdentifier, let range = identifier.range(of: "/RID="),
           let seconds = TimeInterval(identifier[range.upperBound...]) {
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return event.occurrenceDate ?? event.startDate
    }

    private func zone(for event: EKEvent) -> DisplayTimeZone {
        guard let identifier = event.timeZone?.identifier, !event.isAllDay else { return dayZone }
        if let cached = zoneCache[identifier] { return cached }
        guard let created = try? DisplayTimeZone(identifier: identifier) else { return dayZone }
        zoneCache[identifier] = created
        return created
    }

    private func originalDay(of event: EKEvent) -> LocalDate {
        zone(for: event).localDate(of: milliseconds(originalStart(of: event)))
    }

    private func isOccurrence(_ event: EKEvent) -> Bool { event.hasRecurrenceRules || event.isDetached }

    private func eventID(_ event: EKEvent) -> CalendarEventID? {
        guard event.eventIdentifier != nil else { return nil }
        guard isOccurrence(event) else { return CalendarEventID(rawValue: event.eventIdentifier ?? "") }
        let day = originalDay(of: event)
        return CalendarEventID(rawValue: "\(masterIdentifier(of: event))|\(day.year)-\(day.month)-\(day.day)")
    }

    private func parseDay(_ text: Substring) -> LocalDate? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return try? LocalDate(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Resolves a key to the event as EventKit presents it now, or `nil` if it no longer exists.
    private func load(_ key: CalendarEventKey) -> EKEvent? {
        guard let calendar = calendar(withID: key.calendarID.rawValue) else { return nil }
        let raw = key.eventID.rawValue
        guard let bar = raw.lastIndex(of: "|") else {
            guard let event = store.event(withIdentifier: raw), !isOccurrence(event),
                  event.calendar?.calendarIdentifier == calendar.calendarIdentifier else { return nil }
            return event
        }
        let master = String(raw[..<bar])
        guard let day = parseDay(raw[raw.index(after: bar)...]) else { return nil }
        for spanDays in [(-1, 2), (-366, 367)] {
            let start = date(dayZone.startOfDay(day.adding(days: spanDays.0)))
            let end = date(dayZone.startOfDay(day.adding(days: spanDays.1)))
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
            if let match = store.events(matching: predicate).first(where: {
                isOccurrence($0) && masterIdentifier(of: $0) == master && originalDay(of: $0) == day
            }) { return match }
        }
        return nil
    }

    /// The event as EventKit presents it after a save, or a failure if it cannot be found again.
    private func savedResult(_ key: CalendarEventKey) -> CalendarProviderResult<CalendarEvent> {
        guard let event = load(key).flatMap(snapshot) else {
            return .failure(.saveFailed(retryable: true, reason: "the saved event could not be read back"))
        }
        return .success(event)
    }

    // MARK: Conversion

    /// Looks a calendar up, refreshing the store once if it is not found: another app or store instance may have
    /// created it after this store last synced.
    private func calendar(withID id: String) -> EKCalendar? {
        if let calendar = store.calendar(withIdentifier: id) { return calendar }
        store.refreshSourcesIfNecessary()
        if let calendar = store.calendar(withIdentifier: id) { return calendar }
        store.reset()
        return store.calendar(withIdentifier: id)
    }

    private func requireAccess() throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return
        default: throw CalendarProviderFailure.accessUnavailable
        }
    }

    private func calendarGate(_ id: CalendarID) -> CalendarProviderFailure? {
        guard let calendar = calendar(withID: id.rawValue) else { return .calendarMissing(id) }
        return calendar.allowsContentModifications ? nil : .calendarNotWritable(id)
    }

    private func descriptor(_ calendar: EKCalendar) -> CalendarDescriptor {
        CalendarDescriptor(
            id: CalendarID(rawValue: calendar.calendarIdentifier),
            title: calendar.title,
            colorHex: hex(calendar.cgColor),
            isWritable: calendar.allowsContentModifications,
            sourceTitle: calendar.source?.title
        )
    }

    private func hex(_ color: CGColor?) -> String? {
        guard let components = color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components,
              components.count >= 3 else { return nil }
        let value = components.prefix(3).map { Int((max(0, min(1, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", value[0], value[1], value[2])
    }

    private func snapshot(_ event: EKEvent) -> CalendarEvent? {
        guard let calendar = event.calendar, let id = eventID(event), let start = event.startDate, let end = event.endDate else { return nil }
        let time: EventTimeRange
        if event.isAllDay {
            let first = dayZone.localDate(of: milliseconds(start))
            let last = max(first, dayZone.localDate(of: milliseconds(end)))
            guard let range = try? DayRange(firstDay: first, lastDay: last) else { return nil }
            time = .allDay(range)
        } else {
            let from = milliseconds(start)
            // A zero-length event is shown as one minute so the half-open range stays valid.
            guard let range = try? TimedRange(startUnixMilliseconds: from, endUnixMilliseconds: max(milliseconds(end), from + 60_000)) else { return nil }
            time = .timed(range)
        }
        return CalendarEvent(
            id: id,
            calendarID: CalendarID(rawValue: calendar.calendarIdentifier),
            title: event.title ?? "",
            time: time,
            timeZoneIdentifier: event.isAllDay ? nil : event.timeZone?.identifier,
            location: nonEmpty(event.location),
            notes: nonEmpty(event.notes),
            isRecurringInstance: isOccurrence(event),
            isEditable: calendar.allowsContentModifications,
            revisionToken: token(of: event)
        )
    }

    private func nonEmpty(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }

    /// A fingerprint of every modeled field plus the modification time. The timestamp has one-second resolution,
    /// so the fields are what detect two edits inside the same second.
    private func token(of event: EKEvent) -> String {
        let parts: [String] = [
            event.eventIdentifier ?? "", String(milliseconds(originalStart(of: event))), String(milliseconds(event.lastModifiedDate ?? .distantPast)),
            event.title ?? "", String(milliseconds(event.startDate)), String(milliseconds(event.endDate)), event.isAllDay ? "A" : "T",
            event.timeZone?.identifier ?? "-", event.location ?? "", event.notes ?? "", event.calendar?.calendarIdentifier ?? "",
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Applies a patch to an `EKEvent` in place, so fields the domain does not model survive the save.
    private func apply(_ update: CalendarEventUpdate, to event: EKEvent) -> CalendarProviderFailure? {
        if let title = update.title { event.title = title }
        switch update.timeZoneIdentifier {
        case .keep: break
        case .clear: event.timeZone = nil
        case let .set(identifier):
            guard let zone = TimeZone(identifier: identifier) else { return .saveFailed(retryable: false, reason: "unknown time zone \(identifier)") }
            event.timeZone = zone
        }
        switch update.location {
        case .keep: break
        case .clear: event.location = nil
        case let .set(value): event.location = value
        }
        switch update.notes {
        case .keep: break
        case .clear: event.notes = nil
        case let .set(value): event.notes = value
        }
        switch update.time {
        case nil: break
        case let .timed(range)?:
            event.isAllDay = false
            event.startDate = date(range.startUnixMilliseconds)
            event.endDate = date(range.endUnixMilliseconds)
        case let .allDay(range)?:
            event.isAllDay = true
            event.startDate = date(dayZone.startOfDay(range.firstDay))
            event.endDate = date(dayZone.startOfDay(range.lastDay.adding(days: 1)) - 1_000)
        }
        return nil
    }

    private func map(_ error: Error, calendarID: CalendarID) -> CalendarProviderFailure {
        let nsError = error as NSError
        if nsError.domain == EKErrorDomain, let code = EKError.Code(rawValue: nsError.code) {
            switch code {
            case .calendarReadOnly, .eventNotMutable: return .calendarNotWritable(calendarID)
            case .noCalendar: return .calendarMissing(calendarID)
            case .invalidSpan: return .saveFailed(retryable: false, reason: nsError.localizedDescription)
            default: break
            }
        }
        return .saveFailed(retryable: true, reason: nsError.localizedDescription)
    }

    private func date(_ unixMilliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(unixMilliseconds) / 1_000) }
    private func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }
}

private final class ObserverBox: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
}
#endif
