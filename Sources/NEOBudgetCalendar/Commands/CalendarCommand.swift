import NEOBudgetCore

// The only way a UI (or a future platform adapter) changes calendar or life state. Commands carry intent;
// the command service validates them, applies the edit policy, and decides what the calendar provider and
// the local store must each write. Nothing here mentions any platform type.

/// Identifies an event for a write, optionally with the revision the user was looking at.
public struct EventTarget: Hashable, Sendable {
    public let key: CalendarEventKey
    /// If set and the event has changed since, the write is refused as a conflict instead of overwriting.
    public let expectedRevisionToken: String?

    public init(key: CalendarEventKey, expectedRevisionToken: String? = nil) {
        self.key = key
        self.expectedRevisionToken = expectedRevisionToken
    }
}

/// Either an existing Activity, or an event whose Activity is created on first use (lazy materialization).
public enum ActivityTarget: Hashable, Sendable {
    case activity(ActivityID)
    case event(CalendarEventKey)
}

public enum TaggableTarget: Hashable, Sendable {
    case activity(ActivityTarget)
    case transaction(LedgerEntryID)
}

public enum ResizeEdge: String, Hashable, Sendable {
    case start
    case end
}

public enum MoveDestination: Hashable, Sendable {
    /// Timed events only: drop at this raw instant; the policy snaps it.
    case proposedStart(Int64)
    /// Timed events keep their local time of day; all-day events start on this day.
    case day(LocalDate)
}

/// What happens to transactions linked to an event that the user deletes.
public enum LinkDisposition: String, Hashable, Sendable {
    /// The Activity stays (event marked missing) and keeps its links. The default; nothing is lost silently.
    case keepLinks
    /// Links are removed so the transactions become unlinked again.
    case removeLinks
}

public struct CreateEventInput: Hashable, Sendable {
    public let draft: CalendarEventDraft
    public let initialActivityType: ActivityTypeID?
    public init(draft: CalendarEventDraft, initialActivityType: ActivityTypeID? = nil) {
        self.draft = draft
        self.initialActivityType = initialActivityType
    }
}

public struct MoveEventInput: Hashable, Sendable {
    public let target: EventTarget
    public let destination: MoveDestination
    public let scope: RecurrenceScope?
    public init(target: EventTarget, destination: MoveDestination, scope: RecurrenceScope? = nil) {
        self.target = target
        self.destination = destination
        self.scope = scope
    }
}

public struct ResizeEventInput: Hashable, Sendable {
    public let target: EventTarget
    public let edge: ResizeEdge
    public let proposedInstant: Int64
    /// Keeps a bottom-edge resize inside the selected day.
    public let clampToDayEnd: Int64?
    public let scope: RecurrenceScope?
    public init(
        target: EventTarget,
        edge: ResizeEdge,
        proposedInstant: Int64,
        clampToDayEnd: Int64? = nil,
        scope: RecurrenceScope? = nil
    ) {
        self.target = target
        self.edge = edge
        self.proposedInstant = proposedInstant
        self.clampToDayEnd = clampToDayEnd
        self.scope = scope
    }
}

public struct ChangeAllDayInput: Hashable, Sendable {
    public let target: EventTarget
    public let toAllDay: Bool
    /// Required when converting an all-day event to a timed one: where it was dropped.
    public let proposedStart: Int64?
    public let scope: RecurrenceScope?
    public init(target: EventTarget, toAllDay: Bool, proposedStart: Int64? = nil, scope: RecurrenceScope? = nil) {
        self.target = target
        self.toAllDay = toAllDay
        self.proposedStart = proposedStart
        self.scope = scope
    }
}

public struct EditEventInput: Hashable, Sendable {
    public let target: EventTarget
    public let update: CalendarEventUpdate
    public let scope: RecurrenceScope?
    public init(target: EventTarget, update: CalendarEventUpdate, scope: RecurrenceScope? = nil) {
        self.target = target
        self.update = update
        self.scope = scope
    }
}

public struct DeleteEventInput: Hashable, Sendable {
    public let target: EventTarget
    public let scope: RecurrenceScope?
    public let linkDisposition: LinkDisposition
    public init(target: EventTarget, scope: RecurrenceScope? = nil, linkDisposition: LinkDisposition = .keepLinks) {
        self.target = target
        self.scope = scope
        self.linkDisposition = linkDisposition
    }
}

public struct LinkTransactionInput: Hashable, Sendable {
    public let transactionID: LedgerEntryID
    public let target: ActivityTarget
    public let provenance: AssignmentProvenance
    public init(transactionID: LedgerEntryID, target: ActivityTarget, provenance: AssignmentProvenance) {
        self.transactionID = transactionID
        self.target = target
        self.provenance = provenance
    }
}

public struct UnlinkTransactionInput: Hashable, Sendable {
    public let transactionID: LedgerEntryID
    public let by: AssignmentProvenance
    public init(transactionID: LedgerEntryID, by: AssignmentProvenance) {
        self.transactionID = transactionID
        self.by = by
    }
}

public struct AssignActivityTypeInput: Hashable, Sendable {
    public let target: ActivityTarget
    /// `nil` clears the type.
    public let typeID: ActivityTypeID?
    public let provenance: AssignmentProvenance
    public init(target: ActivityTarget, typeID: ActivityTypeID?, provenance: AssignmentProvenance) {
        self.target = target
        self.typeID = typeID
        self.provenance = provenance
    }
}

public struct AssignTagInput: Hashable, Sendable {
    public let tagID: TagID
    public let target: TaggableTarget
    public let provenance: AssignmentProvenance
    public init(tagID: TagID, target: TaggableTarget, provenance: AssignmentProvenance) {
        self.tagID = tagID
        self.target = target
        self.provenance = provenance
    }
}

public enum CalendarCommand: Hashable, Sendable {
    case createEvent(CreateEventInput)
    case moveEvent(MoveEventInput)
    case resizeEvent(ResizeEventInput)
    case changeAllDay(ChangeAllDayInput)
    case editEvent(EditEventInput)
    case deleteEvent(DeleteEventInput)
    case linkTransaction(LinkTransactionInput)
    case unlinkTransaction(UnlinkTransactionInput)
    case assignActivityType(AssignActivityTypeInput)
    case assignTag(AssignTagInput)
    case unassignTag(AssignTagInput)
}

/// Why a command was refused before anything was written.
public enum CommandRejection: Error, Hashable, Sendable {
    case invalidTimeZone(String)
    case durationBelowMinimum
    case eventNotFound
    case eventNotEditable
    case recurrenceScopeRequired
    case recurrenceScopeUnsupported(RecurrenceScope)
    case dateChangeRequiresThisOccurrence
    case destinationKindMismatch
    case allDayEventCannotResize
    case missingProposedStart
    case emptyUpdate
    case transactionNotFound
    case activityNotFound
    /// The target Activity's event no longer exists, so it cannot take new links.
    case activityEventMissing
    /// An automated assignment did not meet the confidence policy, so nothing is stored.
    case provenanceRejected
    case userAssignmentProtected
    case lifeValidation(LifeValidationError)
    case storageUnavailable
}

public struct AppliedCommand: Equatable, Sendable {
    public let event: CalendarEvent?
    public let activityID: ActivityID?
    /// The local life-state revision after this command, or `nil` if it wrote nothing locally.
    public let lifeRevision: UInt64?

    public init(event: CalendarEvent? = nil, activityID: ActivityID? = nil, lifeRevision: UInt64? = nil) {
        self.event = event
        self.activityID = activityID
        self.lifeRevision = lifeRevision
    }
}

/// The result of a command. Permanent problems are values; nothing here is thrown.
public enum CalendarCommandOutcome: Equatable, Sendable {
    case applied(AppliedCommand)
    /// Refused up front; nothing changed anywhere.
    case rejected(CommandRejection)
    /// The event changed elsewhere since the user last saw it; nothing was written.
    case conflict(current: CalendarEvent?)
    /// The calendar provider could not perform the write; local state is unchanged.
    case providerFailure(CalendarProviderFailure)
    /// The calendar write succeeded but the local follow-up did not. The event itself is correct; the local
    /// part (an Activity, a type, or link cleanup) can be retried and nothing was lost.
    case partiallyApplied(AppliedCommand, localFailure: CommandRejection)
}
