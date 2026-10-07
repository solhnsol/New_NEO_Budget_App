import NEOBudgetCore

// Read model for one day of the life timeline. A UI renders these values directly; it never combines
// calendar-provider or ledger objects itself. Block size reflects time, never money.

public struct BlockID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: BlockID, rhs: BlockID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct TimelineDisplayPolicy: Equatable, Sendable {
    /// Visual floor so very short events stay tappable. It changes only the displayed range, never the event.
    public let minimumVisualDurationMinutes: Int
    /// Show events that were deleted elsewhere but still carry an Activity (and its spending) as ghosts.
    public let includeMissingEventGhosts: Bool

    public init(minimumVisualDurationMinutes: Int = 15, includeMissingEventGhosts: Bool = true) {
        self.minimumVisualDurationMinutes = max(1, minimumVisualDurationMinutes)
        self.includeMissingEventGhosts = includeMissingEventGhosts
    }

    public static let standard = TimelineDisplayPolicy()
}

public struct OverlapLayout: Equatable, Sendable {
    /// Zero-based column inside the overlap cluster.
    public let column: Int
    /// Number of columns in the cluster this block belongs to (1 when it overlaps nothing).
    public let columnCount: Int

    public init(column: Int, columnCount: Int) {
        self.column = column
        self.columnCount = columnCount
    }
}

public enum BlockState: String, Equatable, Sendable {
    case normal
    /// The event is gone from the calendar; shown from its last-known summary.
    case eventMissing
}

public struct ActivityBadge: Equatable, Sendable {
    public let activityID: ActivityID
    public let activityType: ActivityTypeID?
    public let areaID: AreaID?
    public let tagIDs: [TagID]

    public init(activityID: ActivityID, activityType: ActivityTypeID?, areaID: AreaID?, tagIDs: [TagID]) {
        self.activityID = activityID
        self.activityType = activityType
        self.areaID = areaID
        self.tagIDs = tagIDs
    }
}

/// A transaction linked to an activity. It is listed with the activity even when it happened on another day.
public struct LinkedTransactionItem: Equatable, Sendable {
    public let transactionID: LedgerEntryID
    public let title: String?
    public let amount: Money
    public let flow: TransactionFlow
    public let occurredAtUnixMilliseconds: Int64
    public let timePrecision: TimePrecision
    /// False when the link is meaningful but the payment is outside the selected day (a ticket bought earlier).
    public let occursOnSelectedDay: Bool
    public let linkSource: AssignmentSource

    public init(
        transactionID: LedgerEntryID,
        title: String?,
        amount: Money,
        flow: TransactionFlow,
        occurredAtUnixMilliseconds: Int64,
        timePrecision: TimePrecision,
        occursOnSelectedDay: Bool,
        linkSource: AssignmentSource
    ) {
        self.transactionID = transactionID
        self.title = title
        self.amount = amount
        self.flow = flow
        self.occurredAtUnixMilliseconds = occurredAtUnixMilliseconds
        self.timePrecision = timePrecision
        self.occursOnSelectedDay = occursOnSelectedDay
        self.linkSource = linkSource
    }
}

public struct EventBlock: Equatable, Sendable {
    public let id: BlockID
    public let eventKey: CalendarEventKey
    public let calendarTitle: String?
    public let calendarColorHex: String?
    public let title: String
    /// The event's real range, unclipped.
    public let startUnixMilliseconds: Int64
    public let endUnixMilliseconds: Int64
    /// Range clipped to the selected day, in whole minutes from the start of that day.
    public let startMinute: Int
    public let endMinute: Int
    /// Range actually drawn after the minimum visual duration is applied; never overruns the day.
    public let displayStartMinute: Int
    public let displayEndMinute: Int
    public let continuesFromPreviousDay: Bool
    public let continuesToNextDay: Bool
    public let layout: OverlapLayout
    public let activity: ActivityBadge?
    public let linked: [LinkedTransactionItem]
    /// Net spending of the linked transactions per currency (refunds subtract).
    public let linkedTotals: [Money]
    public let isRecurringInstance: Bool
    public let isEditable: Bool
    public let state: BlockState
}

public struct AllDayItem: Equatable, Sendable {
    public let id: BlockID
    public let eventKey: CalendarEventKey
    public let calendarTitle: String?
    public let calendarColorHex: String?
    public let title: String
    public let firstDay: LocalDate
    public let lastDay: LocalDate
    public let isFirstDayOfEvent: Bool
    public let isLastDayOfEvent: Bool
    public let activity: ActivityBadge?
    public let linked: [LinkedTransactionItem]
    public let linkedTotals: [Money]
    public let isEditable: Bool
    public let state: BlockState
}

public enum MarkerLinkState: Equatable, Sendable {
    /// No Activity. This is a normal state: the spending counts as non-activity spending.
    case unlinked
    /// Linked to an Activity that is not drawn on this day.
    case linkedElsewhere(activityID: ActivityID, activityTitle: String, eventMissing: Bool)
}

/// A transaction that happened on the selected day and is not already shown inside an activity block.
public struct TransactionMarkerItem: Equatable, Sendable {
    public let transactionID: LedgerEntryID
    public let title: String?
    public let amount: Money
    public let flow: TransactionFlow
    public let occurredAtUnixMilliseconds: Int64
    /// Whole minutes from the start of the selected day.
    public let positionMinute: Int
    public let timePrecision: TimePrecision
    public let linkState: MarkerLinkState
}

public struct CurrencyTotals: Equatable, Sendable {
    public let currency: String
    /// Net spending (refunds subtract) of the day's transactions that are linked to an Activity.
    public let linkedNetMinorUnits: Int64
    /// Net spending of the day's transactions with no Activity: non-activity spending.
    public let unlinkedNetMinorUnits: Int64
}

public struct DaySummary: Equatable, Sendable {
    public let eventCount: Int
    public let allDayCount: Int
    public let unlinkedTransactionCount: Int
    public let totals: [CurrencyTotals]
}

public struct DayTimeline: Equatable, Sendable {
    public let day: LocalDate
    public let timeZoneIdentifier: String
    public let dayStartUnixMilliseconds: Int64
    public let dayEndUnixMilliseconds: Int64
    /// 1440 normally; 1380 or 1500 on a daylight-saving transition day.
    public let totalMinutes: Int
    public let allDay: [AllDayItem]
    public let blocks: [EventBlock]
    public let markers: [TransactionMarkerItem]
    public let summary: DaySummary
}
