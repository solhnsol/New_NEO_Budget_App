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

/// What an Activity means, as words a person reads: names resolved from the life state so a UI never looks them up
/// itself. A name is absent when the Activity does not have that kind of meaning; an unknown or archived ID still
/// resolves while its definition exists, because history must stay readable.
public struct ActivityDisplay: Equatable, Sendable {
    public let typeName: String?
    public let areaName: String?
    /// The user first (if they took part), then the others by name.
    public let participantNames: [String]
    public let tagNames: [String]

    public init(typeName: String? = nil, areaName: String? = nil, participantNames: [String] = [], tagNames: [String] = []) {
        self.typeName = typeName
        self.areaName = areaName
        self.participantNames = participantNames
        self.tagNames = tagNames
    }

    public static let empty = ActivityDisplay()
}

public struct ActivityBadge: Equatable, Sendable {
    public let activityID: ActivityID
    public let activityType: ActivityTypeID?
    public let areaID: AreaID?
    public let tagIDs: [TagID]
    public let participantIDs: [PersonID]
    /// Obligations of this activity that are not yet settled.
    public let openObligationCount: Int
    /// The same meaning in words.
    public let display: ActivityDisplay

    public init(
        activityID: ActivityID, activityType: ActivityTypeID?, areaID: AreaID?, tagIDs: [TagID],
        participantIDs: [PersonID], openObligationCount: Int, display: ActivityDisplay = .empty
    ) {
        self.activityID = activityID
        self.activityType = activityType
        self.areaID = areaID
        self.tagIDs = tagIDs
        self.participantIDs = participantIDs
        self.openObligationCount = openObligationCount
        self.display = display
    }
}

/// One portion of a transaction that belongs to an activity. It is listed with the activity even when the
/// payment happened on another day, and `allocatedAmount` keeps how much is actually known.
public struct AllocationItem: Equatable, Sendable {
    public let allocationID: AllocationID
    public let transactionID: LedgerEntryID
    public let title: String?
    public let transactionAmount: Money
    public let flow: TransactionFlow
    public let occurredAtUnixMilliseconds: Int64
    public let timePrecision: TimePrecision
    /// False when the allocation is meaningful but the payment is outside the selected day.
    public let occursOnSelectedDay: Bool
    public let allocatedAmount: AmountKnowledge
    /// True unless the allocation is known to be the entire transaction.
    public let isPartOfTransaction: Bool
    public let source: AssignmentSource
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
    public let allocations: [AllocationItem]
    /// Spending allocated to this activity per currency, with uncertainty kept (never a falsely exact total).
    public let allocatedSpend: [AmountAggregate]
    public let allocatedRefunds: [AmountAggregate]
    public let isRecurringInstance: Bool
    public let isEditable: Bool
    /// The provider's revision of the event as it was when this timeline was built. A write that passes it as the
    /// expected revision is refused if the event changed since, so an edit never overwrites what the user did not see.
    /// `nil` for events that no longer exist.
    public let revisionToken: String?
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
    public let allocations: [AllocationItem]
    public let allocatedSpend: [AmountAggregate]
    public let allocatedRefunds: [AmountAggregate]
    public let isEditable: Bool
    public let revisionToken: String?
    public let state: BlockState
}

/// Where one portion of a transaction went, as shown next to a stray transaction marker.
public struct MarkerAllocation: Equatable, Sendable {
    public let allocationID: AllocationID
    /// `nil` is a deliberate "no activity" portion.
    public let activityID: ActivityID?
    public let activityTitle: String?
    public let amount: AmountKnowledge
    public let eventMissing: Bool
    /// Whether that activity is drawn on this day (so the portion is also visible inside a block).
    public let isShownToday: Bool
}

/// A transaction that happened on the selected day and is not completely accounted for inside the activity
/// blocks drawn today.
public struct TransactionMarkerItem: Equatable, Sendable {
    public let transactionID: LedgerEntryID
    public let title: String?
    public let amount: Money
    public let flow: TransactionFlow
    public let occurredAtUnixMilliseconds: Int64
    /// Whole minutes from the start of the selected day.
    public let positionMinute: Int
    public let timePrecision: TimePrecision
    /// Empty means no portion is allocated. That is a normal state: the spending counts as non-activity.
    public let allocations: [MarkerAllocation]
    /// What is left of the transaction after its allocations (widened by unknown portions).
    public let remainder: AmountBounds
    public let isFullyAllocated: Bool
}

public struct CurrencyTotals: Equatable, Sendable {
    public let currency: String
    /// Net spending (refunds subtract) of the day's transactions that is settled as belonging to activities.
    public let linkedNetMinorUnits: Int64
    /// Net spending certainly outside activities: explicit "no activity" portions and unallocated remainders.
    public let unlinkedNetMinorUnits: Int64
    /// Net spending whose placement is not yet known because some portion has no settled amount.
    public let uncertainNetMinorUnits: Int64
}

public struct DaySummary: Equatable, Sendable {
    public let eventCount: Int
    public let allDayCount: Int
    /// Today's transactions with no portion allocated to any activity.
    public let unlinkedTransactionCount: Int
    /// Today's transactions that are split or only partly allocated.
    public let partiallyAllocatedTransactionCount: Int
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
