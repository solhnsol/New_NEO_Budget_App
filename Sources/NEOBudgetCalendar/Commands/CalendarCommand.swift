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

public struct AssignActivityAreaInput: Hashable, Sendable {
    public let target: ActivityTarget
    /// `nil` clears the area.
    public let areaID: AreaID?
    public let provenance: AssignmentProvenance
    public init(target: ActivityTarget, areaID: AreaID?, provenance: AssignmentProvenance) {
        self.target = target
        self.areaID = areaID
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

/// Where one portion of a transaction goes: an activity, or deliberately to none.
public enum AllocationTarget: Hashable, Sendable {
    case activity(ActivityTarget)
    /// "This portion belongs to no activity" (활동 외 소비), as a decision. Money not yet allocated is different:
    /// it is simply the transaction's remainder.
    case nonActivity
}

public struct AllocationPartInput: Hashable, Sendable {
    public let target: AllocationTarget
    public let amount: AmountKnowledge
    public init(target: AllocationTarget, amount: AmountKnowledge) {
        self.target = target
        self.amount = amount
    }
}

/// Replaces how a transaction is divided. `[]` removes every allocation. Portions may cover only part of the
/// transaction; the rest stays unallocated.
public struct SetAllocationsInput: Hashable, Sendable {
    public let transactionID: LedgerEntryID
    public let parts: [AllocationPartInput]
    public let provenance: AssignmentProvenance
    public init(transactionID: LedgerEntryID, parts: [AllocationPartInput], provenance: AssignmentProvenance) {
        self.transactionID = transactionID
        self.parts = parts
        self.provenance = provenance
    }
}

public struct ParticipantInput: Hashable, Sendable {
    public let activity: ActivityTarget
    public let personID: PersonID
    public let provenance: AssignmentProvenance
    public init(activity: ActivityTarget, personID: PersonID, provenance: AssignmentProvenance) {
        self.activity = activity
        self.personID = personID
        self.provenance = provenance
    }
}

public struct CreateObligationInput: Hashable, Sendable {
    public let counterpartyID: PersonID
    public let activity: ActivityTarget?
    public let direction: ObligationDirection
    public let currency: String
    public let amount: AmountKnowledge
    public let originTransactionID: LedgerEntryID?
    public let label: String?
    public let provenance: AssignmentProvenance
    public init(
        counterpartyID: PersonID,
        activity: ActivityTarget? = nil,
        direction: ObligationDirection,
        currency: String,
        amount: AmountKnowledge,
        originTransactionID: LedgerEntryID? = nil,
        label: String? = nil,
        provenance: AssignmentProvenance
    ) {
        self.counterpartyID = counterpartyID
        self.activity = activity
        self.direction = direction
        self.currency = currency
        self.amount = amount
        self.originTransactionID = originTransactionID
        self.label = label
        self.provenance = provenance
    }
}

public struct SetObligationAmountInput: Hashable, Sendable {
    public let obligationID: ObligationID
    public let amount: AmountKnowledge
    public let provenance: AssignmentProvenance
    public init(obligationID: ObligationID, amount: AmountKnowledge, provenance: AssignmentProvenance) {
        self.obligationID = obligationID
        self.amount = amount
        self.provenance = provenance
    }
}

public struct CancelObligationInput: Hashable, Sendable {
    public let obligationID: ObligationID
    public let by: AssignmentProvenance
    public init(obligationID: ObligationID, by: AssignmentProvenance) {
        self.obligationID = obligationID
        self.by = by
    }
}

public struct DefineAmountGroupInput: Hashable, Sendable {
    public let members: [AmountMemberRef]
    public let currency: String
    /// Must be settled knowledge: exact (the user knows the total) or inferred (with evidence).
    public let total: AmountKnowledge
    public let provenance: AssignmentProvenance
    public init(members: [AmountMemberRef], currency: String, total: AmountKnowledge, provenance: AssignmentProvenance) {
        self.members = members
        self.currency = currency
        self.total = total
        self.provenance = provenance
    }
}

public struct RemoveAmountGroupInput: Hashable, Sendable {
    public let groupID: AmountGroupID
    public let by: AssignmentProvenance
    public init(groupID: AmountGroupID, by: AssignmentProvenance) {
        self.groupID = groupID
        self.by = by
    }
}

public struct CreateSettlementRequestInput: Hashable, Sendable {
    public let counterpartyID: PersonID
    public let obligationIDs: [ObligationID]
    public let requestedAmount: Money?
    public init(counterpartyID: PersonID, obligationIDs: [ObligationID], requestedAmount: Money? = nil) {
        self.counterpartyID = counterpartyID
        self.obligationIDs = obligationIDs
        self.requestedAmount = requestedAmount
    }
}

/// Accepts a uniquely explained proposal from `SettlementMatcher`.
public struct ApplySettlementInput: Hashable, Sendable {
    public let proposal: SettlementProposal
    public let provenance: AssignmentProvenance
    public init(proposal: SettlementProposal, provenance: AssignmentProvenance) {
        self.proposal = proposal
        self.provenance = provenance
    }
}

/// The user's own decision about how a transfer settles obligations, including when the matcher found it
/// ambiguous. `confirmedAmounts` are amounts the user states exactly (so they are `exact`, not inferred).
public struct ManualSettlementInput: Hashable, Sendable {
    public let transfer: ActualTransfer
    public let applications: [ProposedApplication]
    public let confirmedAmounts: [ObligationID: Int64]
    public let requestID: SettlementRequestID?
    public let provenance: AssignmentProvenance
    public init(
        transfer: ActualTransfer,
        applications: [ProposedApplication],
        confirmedAmounts: [ObligationID: Int64] = [:],
        requestID: SettlementRequestID? = nil,
        provenance: AssignmentProvenance
    ) {
        self.transfer = transfer
        self.applications = applications
        self.confirmedAmounts = confirmedAmounts
        self.requestID = requestID
        self.provenance = provenance
    }
}

public struct RemoveSettlementInput: Hashable, Sendable {
    public let settlementID: SettlementID
    public let by: AssignmentProvenance
    public init(settlementID: SettlementID, by: AssignmentProvenance) {
        self.settlementID = settlementID
        self.by = by
    }
}

public struct CreateCorrectionInput: Hashable, Sendable {
    /// The raw transfers the user says belong together (for example +12,000 and -4,000 with the same person).
    public let sources: [ActualTransfer]
    /// Must be the user: only a person can say that transfers were a mistake and its correction.
    public let provenance: AssignmentProvenance
    public init(sources: [ActualTransfer], provenance: AssignmentProvenance) {
        self.sources = sources
        self.provenance = provenance
    }
}

public struct RemoveCorrectionInput: Hashable, Sendable {
    public let groupID: CorrectionGroupID
    public let by: AssignmentProvenance
    public init(groupID: CorrectionGroupID, by: AssignmentProvenance) {
        self.groupID = groupID
        self.by = by
    }
}

public struct ClassifyResidualInput: Hashable, Sendable {
    public let residualID: ResidualID
    public let classification: ResidualClassification
    public let provenance: AssignmentProvenance
    public init(residualID: ResidualID, classification: ResidualClassification, provenance: AssignmentProvenance) {
        self.residualID = residualID
        self.classification = classification
        self.provenance = provenance
    }
}

public struct SetSettlementPolicyInput: Hashable, Sendable {
    public let target: PolicyTarget
    /// `nil` clears the override at that level.
    public let policy: SettlementPolicyOverride?
    public let provenance: AssignmentProvenance
    public init(target: PolicyTarget, policy: SettlementPolicyOverride?, provenance: AssignmentProvenance) {
        self.target = target
        self.policy = policy
        self.provenance = provenance
    }
}

/// Creates a shared-expense component of an Activity, or updates one when `componentID` is given.
public struct UpsertExpenseComponentInput: Hashable, Sendable {
    public let componentID: ExpenseComponentID?
    public let activity: ActivityTarget
    public let label: String?
    public let currency: String
    public let amount: AmountKnowledge
    public let payerID: PersonID
    public let participants: [PersonID]?
    public let excludedParticipants: [PersonID]
    public let policy: SettlementPolicyOverride?
    public let category: CategoryAssignment
    public let originTransactionID: LedgerEntryID?
    public let provenance: AssignmentProvenance
    public init(
        componentID: ExpenseComponentID? = nil,
        activity: ActivityTarget,
        label: String? = nil,
        currency: String,
        amount: AmountKnowledge,
        payerID: PersonID,
        participants: [PersonID]? = nil,
        excludedParticipants: [PersonID] = [],
        policy: SettlementPolicyOverride? = nil,
        category: CategoryAssignment = .initial,
        originTransactionID: LedgerEntryID? = nil,
        provenance: AssignmentProvenance
    ) {
        self.componentID = componentID
        self.activity = activity
        self.label = label
        self.currency = currency
        self.amount = amount
        self.payerID = payerID
        self.participants = participants
        self.excludedParticipants = excludedParticipants
        self.policy = policy
        self.category = category
        self.originTransactionID = originTransactionID
        self.provenance = provenance
    }
}

public struct RemoveExpenseComponentInput: Hashable, Sendable {
    public let componentID: ExpenseComponentID
    public let by: AssignmentProvenance
    public init(componentID: ExpenseComponentID, by: AssignmentProvenance) {
        self.componentID = componentID
        self.by = by
    }
}

/// Creates the obligations that follow from a component's computed shares (for me only).
public struct GenerateObligationsInput: Hashable, Sendable {
    public let componentID: ExpenseComponentID
    public let provenance: AssignmentProvenance
    public init(componentID: ExpenseComponentID, provenance: AssignmentProvenance) {
        self.componentID = componentID
        self.provenance = provenance
    }
}

public struct SetSpendingNatureInput: Hashable, Sendable {
    public let target: NatureTarget
    /// `nil` clears the statement at that level.
    public let nature: SpendingNature?
    public let provenance: AssignmentProvenance
    public init(target: NatureTarget, nature: SpendingNature?, provenance: AssignmentProvenance) {
        self.target = target
        self.nature = nature
        self.provenance = provenance
    }
}

public enum CategoryTarget: Hashable, Sendable {
    case allocation(AllocationID)
    case component(ExpenseComponentID)
}

public struct SetCategoryInput: Hashable, Sendable {
    public let target: CategoryTarget
    /// Carries its own provenance, so `classified`/`other`/`unknown` say who decided.
    public let assignment: CategoryAssignment
    public init(target: CategoryTarget, assignment: CategoryAssignment) {
        self.target = target
        self.assignment = assignment
    }
}

public enum IDKind: String, Sendable {
    case activity, allocation, obligation, amountGroup, settlement, settlementRequest, correctionGroup, expenseComponent
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
    case assignActivityArea(AssignActivityAreaInput)
    /// Adds a place (or renames one) so it can be chosen for an activity.
    case upsertArea(Area)
    case assignTag(AssignTagInput)
    case unassignTag(AssignTagInput)

    // Splitting and grouping what a transaction pays for.
    case setAllocations(SetAllocationsInput)

    // People.
    case upsertPerson(Person)
    case addParticipant(ParticipantInput)
    case removeParticipant(ParticipantInput)

    // Money still to be settled.
    case createObligation(CreateObligationInput)
    case setObligationAmount(SetObligationAmountInput)
    case cancelObligation(CancelObligationInput)
    case defineAmountGroup(DefineAmountGroupInput)
    case removeAmountGroup(RemoveAmountGroupInput)
    case resolveAmountGroup(AmountGroupID)
    case createSettlementRequest(CreateSettlementRequestInput)
    case applySettlement(ApplySettlementInput)
    case recordManualSettlement(ManualSettlementInput)
    case removeSettlement(RemoveSettlementInput)

    // Corrections and what a settlement leaves unexplained.
    case createCorrection(CreateCorrectionInput)
    case removeCorrection(RemoveCorrectionInput)
    case classifyResidual(ClassifyResidualInput)

    // Shared expenses, their policies, and the obligations that follow.
    case setSettlementPolicy(SetSettlementPolicyInput)
    case upsertExpenseComponent(UpsertExpenseComponentInput)
    case removeExpenseComponent(RemoveExpenseComponentInput)
    case generateObligations(GenerateObligationsInput)

    // Budget-facing meaning, independent of each other.
    case setSpendingNature(SetSpendingNatureInput)
    case setCategory(SetCategoryInput)
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
    case invalidAmount(AmountValidationError)
    case invalidAmountGroup(AmountGroupError)
    case invalidSettlement(SettlementValidationError)
    case invalidCorrection(CorrectionError)
    case invalidPolicy(SettlementPolicyError)
    /// Several members of the group are still unresolved, so no single value is forced. Nothing is guessed.
    case amountGroupNotUniquelySolvable
    case storageUnavailable
}

public struct AppliedCommand: Equatable, Sendable {
    public let event: CalendarEvent?
    public let activityID: ActivityID?
    /// The local life-state revision after this command, or `nil` if it wrote nothing locally.
    public let lifeRevision: UInt64?
    public let allocationIDs: [AllocationID]
    public let obligationID: ObligationID?
    public let amountGroupID: AmountGroupID?
    public let settlementID: SettlementID?
    public let settlementRequestID: SettlementRequestID?
    public let correctionGroupID: CorrectionGroupID?
    public let componentID: ExpenseComponentID?
    public let obligationIDs: [ObligationID]

    public init(
        event: CalendarEvent? = nil,
        activityID: ActivityID? = nil,
        lifeRevision: UInt64? = nil,
        allocationIDs: [AllocationID] = [],
        obligationID: ObligationID? = nil,
        amountGroupID: AmountGroupID? = nil,
        settlementID: SettlementID? = nil,
        settlementRequestID: SettlementRequestID? = nil,
        correctionGroupID: CorrectionGroupID? = nil,
        componentID: ExpenseComponentID? = nil,
        obligationIDs: [ObligationID] = []
    ) {
        self.event = event
        self.activityID = activityID
        self.lifeRevision = lifeRevision
        self.allocationIDs = allocationIDs
        self.obligationID = obligationID
        self.amountGroupID = amountGroupID
        self.settlementID = settlementID
        self.settlementRequestID = settlementRequestID
        self.correctionGroupID = correctionGroupID
        self.componentID = componentID
        self.obligationIDs = obligationIDs
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
