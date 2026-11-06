import EventKit
import Foundation
import NEOBudgetCalendar
import NEOBudgetCalendarContract
import NEOBudgetEventKit

/// Test rig for the EventKit provider. It uses its **own** `EKEventStore`, so what it writes reaches the provider
/// the way another app's edits would.
actor EventKitRig: CalendarProviderTestRig {
    nonisolated let provider: any CalendarProvider
    nonisolated let dayZone: DisplayTimeZone
    nonisolated let supportsRecurrence = true

    private let store = EKEventStore()
    private var created: [String] = []

    init(provider: EventKitCalendarProvider) throws {
        self.provider = provider
        dayZone = try DisplayTimeZone(identifier: TimeZone.current.identifier)
    }

    func makeWritableCalendar(title: String) async throws -> CalendarID {
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        guard let source = store.sources.first(where: { $0.sourceType == .local }) ?? store.defaultCalendarForNewEvents?.source else {
            throw RigError.noSource
        }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        created.append(calendar.calendarIdentifier)
        return CalendarID(rawValue: calendar.calendarIdentifier)
    }

    func existingReadOnlyCalendar() async throws -> CalendarID? {
        store.calendars(for: .event).first { !$0.allowsContentModifications }.map { CalendarID(rawValue: $0.calendarIdentifier) }
    }

    func editExternally(_ key: CalendarEventKey, update: CalendarEventUpdate) async throws {
        let event = try find(key)
        if let title = update.title { event.title = title }
        switch update.location { case .keep: break; case .clear: event.location = nil; case let .set(v): event.location = v }
        switch update.notes { case .keep: break; case .clear: event.notes = nil; case let .set(v): event.notes = v }
        try store.save(event, span: .thisEvent, commit: true)
    }

    func removeExternally(_ key: CalendarEventKey) async throws {
        try store.remove(try find(key), span: .thisEvent, commit: true)
    }

    func removeCalendarExternally(_ id: CalendarID) async throws {
        guard let calendar = store.calendar(withIdentifier: id.rawValue) else { throw RigError.notFound }
        try store.removeCalendar(calendar, commit: true)
        created.removeAll { $0 == id.rawValue }
    }

    func failNextWrite() async -> Bool { false }
    func setAccess(available: Bool) async -> Bool { false }

    func seedWeeklySeries(calendarID: CalendarID, title: String, firstStartUnixMilliseconds: Int64, durationMilliseconds: Int64, count: Int) async throws {
        guard let calendar = store.calendar(withIdentifier: calendarID.rawValue) else { throw RigError.notFound }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = Date(timeIntervalSince1970: Double(firstStartUnixMilliseconds) / 1_000)
        event.endDate = Date(timeIntervalSince1970: Double(firstStartUnixMilliseconds + durationMilliseconds) / 1_000)
        event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: count)))
        try store.save(event, span: .futureEvents, commit: true)
    }

    func cleanUp() async {
        for id in created {
            if let calendar = store.calendar(withIdentifier: id) { try? store.removeCalendar(calendar, commit: true) }
        }
        created = []
    }

    private func find(_ key: CalendarEventKey) throws -> EKEvent {
        if let event = store.event(withIdentifier: key.eventID.rawValue) { return event }
        store.reset()
        guard let event = store.event(withIdentifier: key.eventID.rawValue) else { throw RigError.notFound }
        return event
    }
}

enum RigError: Error { case noSource, notFound }
