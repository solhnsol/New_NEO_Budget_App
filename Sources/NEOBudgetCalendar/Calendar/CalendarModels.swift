// Calendar domain. A calendar system (for example the device calendar) is the source of truth for event
// fields. These types are value snapshots of what such a system reported or is asked to store; they hold no
// reference to any platform object. A Calendar is an axis of its own and is never an ActivityType.

/// A half-open instant range `[start, end)` in unix milliseconds. Invalid ranges cannot be constructed.
public struct TimedRange: Codable, Hashable, Sendable {
    public let startUnixMilliseconds: Int64
    public let endUnixMilliseconds: Int64

    public init(startUnixMilliseconds: Int64, endUnixMilliseconds: Int64) throws {
        guard startUnixMilliseconds < endUnixMilliseconds else {
            throw CalendarValidationError.invalidTimedRange(start: startUnixMilliseconds, end: endUnixMilliseconds)
        }
        self.startUnixMilliseconds = startUnixMilliseconds
        self.endUnixMilliseconds = endUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey { case startUnixMilliseconds, endUnixMilliseconds }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            startUnixMilliseconds: values.decode(Int64.self, forKey: .startUnixMilliseconds),
            endUnixMilliseconds: values.decode(Int64.self, forKey: .endUnixMilliseconds)
        )
    }

    public var durationMilliseconds: Int64 { endUnixMilliseconds - startUnixMilliseconds }

    public func overlaps(from: Int64, to: Int64) -> Bool {
        startUnixMilliseconds < to && endUnixMilliseconds > from
    }
}

/// An inclusive range of whole local days, used by all-day events.
public struct DayRange: Codable, Hashable, Sendable {
    public let firstDay: LocalDate
    public let lastDay: LocalDate

    public init(firstDay: LocalDate, lastDay: LocalDate) throws {
        guard firstDay <= lastDay else { throw CalendarValidationError.invalidDayRange }
        self.firstDay = firstDay
        self.lastDay = lastDay
    }

    private enum CodingKeys: String, CodingKey { case firstDay, lastDay }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            firstDay: values.decode(LocalDate.self, forKey: .firstDay),
            lastDay: values.decode(LocalDate.self, forKey: .lastDay)
        )
    }

    public func contains(_ day: LocalDate) -> Bool { firstDay <= day && day <= lastDay }

    public var dayCount: Int { lastDay.daysSinceUnixEpoch - firstDay.daysSinceUnixEpoch + 1 }
}

/// When an event happens: a timed instant range, or a range of whole days (all-day).
public enum EventTimeRange: Codable, Hashable, Sendable {
    case timed(TimedRange)
    case allDay(DayRange)

    public var isAllDay: Bool {
        if case .allDay = self { return true }
        return false
    }

    /// Whether the range intersects the instant window `[from, to)`. All-day ranges are resolved in `timeZone`.
    public func overlaps(from: Int64, to: Int64, in timeZone: DisplayTimeZone) -> Bool {
        switch self {
        case let .timed(range):
            return range.overlaps(from: from, to: to)
        case let .allDay(range):
            let start = timeZone.startOfDay(range.firstDay)
            let end = timeZone.startOfDay(range.lastDay.adding(days: 1))
            return start < to && end > from
        }
    }
}

/// A calendar the user can see, such as 일상, 약속, 학교, 연구실, 운동. It says nothing about what an event
/// means; that is the ActivityType's job.
public struct CalendarDescriptor: Codable, Hashable, Sendable {
    public let id: CalendarID
    public let title: String
    public let colorHex: String?
    public let isWritable: Bool
    public let sourceTitle: String?

    public init(id: CalendarID, title: String, colorHex: String? = nil, isWritable: Bool = true, sourceTitle: String? = nil) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.isWritable = isWritable
        self.sourceTitle = sourceTitle
    }
}

/// The pair that identifies an event inside the provider. Used as a dictionary key.
public struct CalendarEventKey: Codable, Hashable, Comparable, Sendable {
    public let calendarID: CalendarID
    public let eventID: CalendarEventID

    public init(calendarID: CalendarID, eventID: CalendarEventID) {
        self.calendarID = calendarID
        self.eventID = eventID
    }

    public static func < (lhs: CalendarEventKey, rhs: CalendarEventKey) -> Bool {
        (lhs.calendarID, lhs.eventID) < (rhs.calendarID, rhs.eventID)
    }
}

/// A snapshot of one event as reported by the calendar provider.
public struct CalendarEvent: Codable, Hashable, Sendable {
    public let id: CalendarEventID
    public let calendarID: CalendarID
    public let title: String
    public let time: EventTimeRange
    /// The event's own time zone. `nil` means floating (interpreted in the display zone).
    public let timeZoneIdentifier: String?
    public let location: String?
    public let notes: String?
    /// A flag only. The domain assumes nothing about how recurring series or occurrences are modeled.
    public let isRecurringInstance: Bool
    public let isEditable: Bool
    /// Opaque token the provider can use to detect that the event changed since this snapshot.
    public let revisionToken: String?

    public init(
        id: CalendarEventID,
        calendarID: CalendarID,
        title: String,
        time: EventTimeRange,
        timeZoneIdentifier: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        isRecurringInstance: Bool = false,
        isEditable: Bool = true,
        revisionToken: String? = nil
    ) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.time = time
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.notes = notes
        self.isRecurringInstance = isRecurringInstance
        self.isEditable = isEditable
        self.revisionToken = revisionToken
    }

    public var key: CalendarEventKey { CalendarEventKey(calendarID: calendarID, eventID: id) }
}

/// Input for creating an event. The provider assigns the event identity.
public struct CalendarEventDraft: Codable, Hashable, Sendable {
    public let calendarID: CalendarID
    public let title: String
    public let time: EventTimeRange
    public let timeZoneIdentifier: String?
    public let location: String?
    public let notes: String?

    public init(
        calendarID: CalendarID,
        title: String,
        time: EventTimeRange,
        timeZoneIdentifier: String? = nil,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.calendarID = calendarID
        self.title = title
        self.time = time
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.notes = notes
    }
}

/// A change to an optional field that distinguishes "leave it" from "set it" and "remove it".
public enum FieldUpdate<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    case keep
    case set(Value)
    case clear

    public func applied(to current: Value?) -> Value? {
        switch self {
        case .keep: return current
        case let .set(value): return value
        case .clear: return nil
        }
    }

    public var isKeep: Bool {
        if case .keep = self { return true }
        return false
    }
}

/// A patch for an existing event. Fields left at their default are not touched, so a provider can preserve
/// everything the domain does not model.
public struct CalendarEventUpdate: Codable, Hashable, Sendable {
    public var title: String?
    public var time: EventTimeRange?
    public var timeZoneIdentifier: FieldUpdate<String>
    public var location: FieldUpdate<String>
    public var notes: FieldUpdate<String>

    public init(
        title: String? = nil,
        time: EventTimeRange? = nil,
        timeZoneIdentifier: FieldUpdate<String> = .keep,
        location: FieldUpdate<String> = .keep,
        notes: FieldUpdate<String> = .keep
    ) {
        self.title = title
        self.time = time
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.notes = notes
    }

    public var isEmpty: Bool {
        title == nil && time == nil && timeZoneIdentifier.isKeep && location.isKeep && notes.isKeep
    }

    public func applied(to event: CalendarEvent) -> CalendarEvent {
        CalendarEvent(
            id: event.id,
            calendarID: event.calendarID,
            title: title ?? event.title,
            time: time ?? event.time,
            timeZoneIdentifier: timeZoneIdentifier.applied(to: event.timeZoneIdentifier),
            location: location.applied(to: event.location),
            notes: notes.applied(to: event.notes),
            isRecurringInstance: event.isRecurringInstance,
            isEditable: event.isEditable,
            revisionToken: event.revisionToken
        )
    }
}

/// How far a change to a recurring event reaches. This expresses the user's intent only; mapping it to a
/// provider operation, and which scopes a provider supports, is provider-specific (see the provider port).
public enum RecurrenceScope: String, Codable, CaseIterable, Sendable {
    case thisOccurrence
    case thisAndFuture
    case allInSeries
}
