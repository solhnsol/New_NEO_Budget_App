import NEOBudgetCore

/// What the calendar last reported about an event. Kept so an Activity can still be shown, and explained
/// to the user, after its event disappears from the calendar.
public struct EventSummary: Codable, Hashable, Sendable {
    public let title: String
    public let time: EventTimeRange
    public let timeZoneIdentifier: String?

    public init(title: String, time: EventTimeRange, timeZoneIdentifier: String? = nil) {
        self.title = title
        self.time = time
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public init(event: CalendarEvent) {
        self.init(title: event.title, time: event.time, timeZoneIdentifier: event.timeZoneIdentifier)
    }
}

/// The optional pointer from an Activity to an event owned by an external calendar.
public struct CalendarEventAssociation: Codable, Hashable, Sendable {
    public enum Status: Codable, Hashable, Sendable {
        case present
        /// The event could no longer be found at `sinceUnixMilliseconds`. The Activity and its links stay.
        case missing(sinceUnixMilliseconds: Int64)
    }

    public let key: CalendarEventKey
    public let lastKnown: EventSummary
    public let status: Status

    public init(key: CalendarEventKey, lastKnown: EventSummary, status: Status = .present) {
        self.key = key
        self.lastKnown = lastKnown
        self.status = status
    }

    public init(event: CalendarEvent) {
        self.init(key: event.key, lastKnown: EventSummary(event: event), status: .present)
    }

    public var isMissing: Bool {
        if case .missing = status { return true }
        return false
    }

    public func refreshed(from event: CalendarEvent) -> CalendarEventAssociation {
        CalendarEventAssociation(key: event.key, lastKnown: EventSummary(event: event), status: .present)
    }

    public func markedMissing(at unixMilliseconds: Int64) -> CalendarEventAssociation {
        if isMissing { return self }
        return CalendarEventAssociation(key: key, lastKnown: lastKnown, status: .missing(sinceUnixMilliseconds: unixMilliseconds))
    }
}

/// An Activity that has no calendar event behind it (for example one observed some other way in future).
/// Nothing creates these yet; the type exists so Activity is not hard-wired to a calendar.
public struct StandaloneActivityInfo: Codable, Hashable, Sendable {
    public let title: String
    public let time: EventTimeRange
    public let timeZoneIdentifier: String?

    public init(title: String, time: EventTimeRange, timeZoneIdentifier: String? = nil) {
        self.title = title
        self.time = time
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public enum ActivityOrigin: Codable, Hashable, Sendable {
    case calendarEvent(CalendarEventAssociation)
    case standalone(StandaloneActivityInfo)
}

/// An OnAll-owned record of a real-life activity, independent of any calendar.
///
/// It exists so meaning (type, area, tags, linked spending) has a stable home that survives calendar-side
/// changes. It is created lazily, only when the user attaches something to an event. "No Activity" is a
/// normal state: spending without one is analyzed as non-activity spending.
public struct Activity: Codable, Hashable, Sendable {
    public let id: ActivityID
    public var origin: ActivityOrigin
    public var activityType: Assigned<ActivityTypeID>?
    public var area: Assigned<AreaID>?
    public var tags: [TagAssignment]
    public let createdAtUnixMilliseconds: Int64

    public init(
        id: ActivityID,
        origin: ActivityOrigin,
        activityType: Assigned<ActivityTypeID>? = nil,
        area: Assigned<AreaID>? = nil,
        tags: [TagAssignment] = [],
        createdAtUnixMilliseconds: Int64
    ) {
        self.id = id
        self.origin = origin
        self.activityType = activityType
        self.area = area
        self.tags = tags
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
    }

    /// A fresh Activity for an event, with no meaning attached yet.
    public static func materialized(from event: CalendarEvent, id: ActivityID, at unixMilliseconds: Int64) -> Activity {
        Activity(id: id, origin: .calendarEvent(CalendarEventAssociation(event: event)), createdAtUnixMilliseconds: unixMilliseconds)
    }

    public var association: CalendarEventAssociation? {
        if case let .calendarEvent(association) = origin { return association }
        return nil
    }

    public var isEventMissing: Bool { association?.isMissing ?? false }

    public var displayTitle: String {
        switch origin {
        case let .calendarEvent(association): return association.lastKnown.title
        case let .standalone(info): return info.title
        }
    }

    public var time: EventTimeRange {
        switch origin {
        case let .calendarEvent(association): return association.lastKnown.time
        case let .standalone(info): return info.time
        }
    }

    /// True when nothing but the association itself would be lost by deleting this Activity.
    public var carriesNoMeaning: Bool { activityType == nil && area == nil && tags.isEmpty }
}

/// Connects one transaction to one Activity.
///
/// The link means "this spending belongs to that activity". It does **not** mean the transaction happened
/// while the activity was going on: a movie ticket bought days earlier, train tickets before a trip, or a
/// registration fee before a contest are all legitimately linked. No code may require time containment.
public struct TransactionActivityLink: Codable, Hashable, Sendable {
    public let transactionID: LedgerEntryID
    public let activityID: ActivityID
    public let createdAtUnixMilliseconds: Int64
    public let provenance: AssignmentProvenance

    public init(
        transactionID: LedgerEntryID,
        activityID: ActivityID,
        createdAtUnixMilliseconds: Int64,
        provenance: AssignmentProvenance
    ) {
        self.transactionID = transactionID
        self.activityID = activityID
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
        self.provenance = provenance
    }
}
