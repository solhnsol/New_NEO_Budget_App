import NEOBudgetCore

public enum LifeValidationError: Error, Hashable, Sendable {
    case emptyIdentifier(entity: String)
    case emptyName(entity: String)
    case duplicateIdentifier(entity: String, id: String)
    case duplicateTagName(String)
    case duplicateAreaAlias(String)
    case unknownBroaderArea(AreaID)
    case areaCycle(AreaID)
    case unknownActivity(ActivityID)
    case unknownActivityType(ActivityTypeID)
    case activityTypeArchived(ActivityTypeID)
    case unknownTag(TagID)
    case tagArchived(TagID)
    case unknownArea(AreaID)
    case eventAlreadyAssociated(CalendarEventKey)
    case notCalendarActivity(ActivityID)
    case activityHasAllocations(ActivityID)
    case activityHasObligations(ActivityID)
    case presetImmutable(ActivityTypeID)
    case invalidConfidence
    case userAssignmentProtected

    // People
    case unknownPerson(PersonID)
    case duplicateSelf
    case relationshipLabelRequiresUser
    case counterpartyIsSelf(PersonID)

    // Allocations
    case unknownAllocation(AllocationID)
    case allocationExceedsTransaction(LedgerEntryID)
    case transactionTotalMismatch(LedgerEntryID)
    case allocationCurrencyMismatch(AllocationID)
    case duplicateAllocationTarget(LedgerEntryID)
    case allocationIdentityChanged(AllocationID)

    // Amounts and groups
    case amountUpdateRejected(AmountUpdateDecision)
    case unknownAmountGroup(AmountGroupID)
    case unknownGroupMember(AmountMemberRef)
    case memberAlreadyInGroup(AmountMemberRef)
    case memberOfAmountGroup(AmountMemberRef)
    case groupCurrencyMismatch(AmountMemberRef)
    case amountGroupContradiction(AmountGroupID, AmountGroupContradiction)

    // Obligations and settlements
    case unknownObligation(ObligationID)
    case obligationNotSettleable(ObligationID)
    case obligationHasSettlements(ObligationID)
    case obligationMustStartOpen(ObligationID)
    case obligationCounterpartyMismatch(ObligationID)
    case obligationCurrencyMismatch(ObligationID)
    case amountBelowAppliedSettlements(ObligationID)
    case unknownSettlement(SettlementID)
    case transferAlreadySettled(LedgerEntryID)
    case settlementNetMismatch
    case appliedExceedsObligation(ObligationID)
    case unknownSettlementRequest(SettlementRequestID)
    case requestCounterpartyMismatch(SettlementRequestID)
    case staleAmountPromotion(ObligationID)
    case automatedPromotionMustBeInferred(ObligationID)

    // Corrections
    case unknownCorrectionGroup(CorrectionGroupID)
    case correctionRequiresUser
    case transactionAlreadyCorrected(LedgerEntryID)
    case correctionSourceAlreadySettled(LedgerEntryID)
    case correctionSourceNotRaw(LedgerEntryID)
    case correctionHasSettlement(CorrectionGroupID)
    case transferInCorrectionGroup(LedgerEntryID)
    case correctionTransferMismatch(CorrectionGroupID)

    // Residuals
    case unknownResidual(ResidualID)
    case residualClassificationNotApplicable(ResidualID)
    case automatedResidualClassification(ResidualID)
    case residualMismatch(ResidualID)
    /// An automated settlement tried to call a difference unexplained while an obligation with the same
    /// person still has an amount that is not settled knowledge and could be what the difference is.
    case residualWhileUncertainObligationsOpen(ResidualID)

    // Money-flow roles: one transaction is either a settlement transfer or spending, never both
    case settlementTransferIsAllocated(LedgerEntryID)
    case allocationOnSettlementTransfer(LedgerEntryID)

    // Policies and shared expenses
    case policyRequiresUser
    case personPolicyCannotSetSplitRule(PersonID)
    case invalidPolicy(SettlementPolicyError)
    case unknownComponent(ExpenseComponentID)
    case componentHasObligations(ExpenseComponentID)
    case activityHasComponents(ActivityID)
    case componentIdentityChanged(ExpenseComponentID)
    case duplicateComponentObligation(ExpenseComponentID, PersonID)
    case selfNotDefined

    // Spending nature
    case unknownNatureTarget(NatureTarget)

    // Category uncertainty
    case confirmedUnknownRequiresUser
}

/// A single validated mutation of life state. Removals and clears carry who is asking so that automation
/// cannot undo a user's decision.
public enum LifeChange: Hashable, Sendable {
    case upsertActivityType(ActivityTypeDefinition)
    case upsertTag(Tag)
    case upsertArea(Area)
    case upsertPerson(Person)

    case createActivity(Activity)
    case updateAssociation(ActivityID, CalendarEventAssociation)
    case removeActivity(ActivityID)

    case setActivityType(ActivityID, Assigned<ActivityTypeID>)
    case clearActivityType(ActivityID, by: AssignmentProvenance)
    case setActivityArea(ActivityID, Assigned<AreaID>)
    case clearActivityArea(ActivityID, by: AssignmentProvenance)
    case setActivityTag(ActivityID, TagAssignment)
    case removeActivityTag(ActivityID, TagID, by: AssignmentProvenance)
    case addParticipant(ActivityID, ParticipantAssignment)
    case removeParticipant(ActivityID, PersonID, by: AssignmentProvenance)

    /// Adds or updates one portion of a transaction. `transactionTotal` and `flow` describe the immutable
    /// ledger entry and must match any earlier allocation of the same transaction.
    case upsertAllocation(TransactionAllocation, transactionTotal: Money, flow: TransactionFlow)
    case removeAllocation(AllocationID, by: AssignmentProvenance)
    case setAllocationAmount(AllocationID, AmountEntry)

    case setTransactionTag(LedgerEntryID, TagAssignment)
    case removeTransactionTag(LedgerEntryID, TagID, by: AssignmentProvenance)

    case createObligation(Obligation)
    case setObligationAmount(ObligationID, AmountEntry)
    case cancelObligation(ObligationID, by: AssignmentProvenance)

    case defineAmountGroup(AmountGroup)
    case removeAmountGroup(AmountGroupID, by: AssignmentProvenance)

    case createSettlementRequest(SettlementRequest)
    case setSettlementRequestStatus(SettlementRequestID, SettlementRequestStatus)

    case recordSettlement(Settlement)
    case removeSettlement(SettlementID, by: AssignmentProvenance)

    /// Only the user can say that raw transfers belong together. The ledger is not touched.
    case createCorrectionGroup(TransactionCorrectionGroup)
    case removeCorrectionGroup(CorrectionGroupID, by: AssignmentProvenance)

    /// Gives a residual its meaning. Automation can only leave it `unresolved`.
    case classifyResidual(ResidualID, ResidualClassification, by: AssignmentProvenance)

    /// Settlement habits. Preferences are the user's: automation cannot set or clear them.
    case setSettlementPolicy(PolicyTarget, Assigned<SettlementPolicyOverride>)
    case clearSettlementPolicy(PolicyTarget, by: AssignmentProvenance)

    case upsertExpenseComponent(ExpenseComponent)
    case removeExpenseComponent(ExpenseComponentID, by: AssignmentProvenance)
    case setComponentCategory(ExpenseComponentID, CategoryAssignment)
    case setAllocationCategory(AllocationID, CategoryAssignment)

    case setSpendingNature(NatureTarget, Assigned<SpendingNature>)
    case clearSpendingNature(NatureTarget, by: AssignmentProvenance)
}

/// All OnAll-owned meaning around calendar events, transactions, people, and money still to be settled, as
/// one value with enforced invariants. Pure and platform-independent: any repository can wrap it. `applying`
/// is all-or-nothing and never mutates the receiver.
public struct LifeState: Codable, Equatable, Sendable {
    public private(set) var activityTypes: [ActivityTypeID: ActivityTypeDefinition]
    public private(set) var tags: [TagID: Tag]
    public private(set) var areaCatalog: AreaCatalog
    public private(set) var persons: [PersonID: Person]
    public private(set) var activities: [ActivityID: Activity]
    public private(set) var allocationSets: [LedgerEntryID: TransactionAllocationSet]
    public private(set) var transactionTags: [LedgerEntryID: [TagAssignment]]
    public private(set) var amountGroups: [AmountGroupID: AmountGroup]
    public private(set) var obligations: [ObligationID: Obligation]
    public private(set) var settlements: [SettlementID: Settlement]
    public private(set) var settlementRequests: [SettlementRequestID: SettlementRequest]
    public private(set) var correctionGroups: [CorrectionGroupID: TransactionCorrectionGroup]
    public private(set) var residuals: [ResidualID: SettlementResidual]
    public private(set) var components: [ExpenseComponentID: ExpenseComponent]
    public private(set) var policyOverrides: [PolicyTarget: Assigned<SettlementPolicyOverride>]
    public private(set) var natureSignals: [NatureTarget: Assigned<SpendingNature>]

    /// Starts with the preset activity types and nothing else.
    public static var empty: LifeState {
        LifeState(
            activityTypes: Dictionary(uniqueKeysWithValues: ActivityTypeDefinition.presets.map { ($0.id, $0) }),
            tags: [:], areaCatalog: AreaCatalog(), persons: [:], activities: [:], allocationSets: [:],
            transactionTags: [:], amountGroups: [:], obligations: [:], settlements: [:], settlementRequests: [:],
            correctionGroups: [:], residuals: [:], components: [:], policyOverrides: [:], natureSignals: [:]
        )
    }

    // MARK: Queries

    public func activity(forEvent key: CalendarEventKey) -> Activity? {
        activities.values.first { $0.association?.key == key }
    }

    /// One pass index for callers that look up many events.
    public func activitiesByEvent() -> [CalendarEventKey: Activity] {
        var index: [CalendarEventKey: Activity] = [:]
        for activity in activities.values {
            if let key = activity.association?.key { index[key] = activity }
        }
        return index
    }

    public func allocationSet(for transactionID: LedgerEntryID) -> TransactionAllocationSet? { allocationSets[transactionID] }

    /// Every allocation that targets `activityID`, oldest first.
    public func allocations(forActivity activityID: ActivityID) -> [TransactionAllocation] {
        allocationSets.values
            .flatMap(\.allocations)
            .filter { $0.activityID == activityID }
            .sorted { ($0.createdAtUnixMilliseconds, $0.id) < ($1.createdAtUnixMilliseconds, $1.id) }
    }

    public func allocation(_ id: AllocationID) -> TransactionAllocation? {
        for set in allocationSets.values {
            if let found = set.allocations.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    public func tags(forTransaction id: LedgerEntryID) -> [TagAssignment] { transactionTags[id] ?? [] }

    public func obligations(forActivity id: ActivityID) -> [Obligation] {
        obligations.values.filter { $0.activityID == id }.sorted { $0.id < $1.id }
    }

    /// How much of an obligation settlements have already applied.
    public func appliedMinorUnits(for id: ObligationID) -> Int64 {
        settlements.values.reduce(0) { total, settlement in
            total + (settlement.allocations.first { $0.obligationID == id }?.appliedMinorUnits ?? 0)
        }
    }

    /// Applied settlements plus any shortfall the user has closed (waived or rounded away): everything that no
    /// longer counts as owed on this obligation.
    public func closedMinorUnits(for id: ObligationID) -> Int64 {
        appliedMinorUnits(for: id) + residuals.values.reduce(0) { $0 + ($1.obligationID == id ? $1.closedMinorUnits : 0) }
    }

    public func correctionGroup(containing transactionID: LedgerEntryID) -> TransactionCorrectionGroup? {
        correctionGroups.values.first { $0.sources.contains { $0.coveredTransactionIDs.contains(transactionID) } }
    }

    /// Residuals nobody has explained yet. A shortfall disappears from here once its obligation is settled.
    public var unresolvedResiduals: [SettlementResidual] {
        residuals.values
            .filter { residual in
                guard !residual.isResolved else { return false }
                if let target = residual.obligationID { return obligations[target]?.status != .settled }
                return true
            }
            .sorted { $0.id < $1.id }
    }

    /// Obligations with `counterpartyID` that can still be settled, in a stable order.
    public func settleableObligations(with counterpartyID: PersonID) -> [Obligation] {
        obligations.values.filter { $0.counterpartyID == counterpartyID && $0.isSettleable }.sorted { $0.id < $1.id }
    }

    public func group(containing member: AmountMemberRef) -> AmountGroup? {
        amountGroups.values.first { $0.members.contains(member) }
    }

    public func amount(of member: AmountMemberRef) -> AmountEntry? {
        switch member {
        case let .obligation(id): return obligations[id]?.amount
        case let .allocation(id): return allocation(id)?.amount
        }
    }

    /// What the group constraint currently implies about its members.
    public func analysis(ofGroup id: AmountGroupID) -> AmountGroupAnalysis? {
        guard let group = amountGroups[id] else { return nil }
        return analyze(group)
    }

    private func analyze(_ group: AmountGroup) -> AmountGroupAnalysis {
        var members: [AmountMemberRef: AmountKnowledge] = [:]
        for member in group.members { members[member] = amount(of: member)?.knowledge ?? .unknown }
        return AmountGroupSolver.analyze(totalMinorUnits: group.totalMinorUnits, members: members)
    }

    // MARK: Mutation

    /// Applies every change in order or none of them.
    public func applying(_ changes: [LifeChange]) throws -> LifeState {
        var next = self
        for change in changes { try next.apply(change) }
        return next
    }

    private mutating func apply(_ change: LifeChange) throws {
        switch change {
        case let .upsertActivityType(definition):
            guard !definition.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "activityType") }
            guard !NameNormalizer.normalize(definition.displayName).isEmpty else { throw LifeValidationError.emptyName(entity: "activityType") }
            if let existing = activityTypes[definition.id], existing.isPreset != definition.isPreset {
                throw LifeValidationError.presetImmutable(definition.id)
            }
            activityTypes[definition.id] = definition

        case let .upsertTag(tag):
            guard !tag.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "tag") }
            let normalized = NameNormalizer.normalize(tag.name)
            guard !normalized.isEmpty else { throw LifeValidationError.emptyName(entity: "tag") }
            if !tag.isArchived,
               tags.values.contains(where: { $0.id != tag.id && !$0.isArchived && NameNormalizer.normalize($0.name) == normalized }) {
                throw LifeValidationError.duplicateTagName(normalized)
            }
            tags[tag.id] = tag

        case let .upsertArea(area):
            areaCatalog = try areaCatalog.inserting(area)

        case let .upsertPerson(person):
            guard !person.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "person") }
            guard !NameNormalizer.normalize(person.displayName).isEmpty else { throw LifeValidationError.emptyName(entity: "person") }
            if person.isSelf, persons.values.contains(where: { $0.isSelf && $0.id != person.id }) {
                throw LifeValidationError.duplicateSelf
            }
            if let label = person.relationshipLabel {
                // Relationships are never inferred; only an explicit user statement may set one.
                guard label.provenance.source == .user else { throw LifeValidationError.relationshipLabelRequiresUser }
            }
            persons[person.id] = person

        case let .createActivity(activity):
            guard !activity.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "activity") }
            guard activities[activity.id] == nil else {
                throw LifeValidationError.duplicateIdentifier(entity: "activity", id: activity.id.rawValue)
            }
            switch activity.origin {
            case let .calendarEvent(association):
                guard activitiesByEvent()[association.key] == nil else {
                    throw LifeValidationError.eventAlreadyAssociated(association.key)
                }
            case let .standalone(info):
                guard !NameNormalizer.normalize(info.title).isEmpty else { throw LifeValidationError.emptyName(entity: "activity") }
            }
            if let type = activity.activityType { try validateType(type) }
            if let area = activity.area { try validateArea(area) }
            var seenTags = Set<TagID>()
            for tag in activity.tags {
                try validateTag(tag)
                guard seenTags.insert(tag.tagID).inserted else {
                    throw LifeValidationError.duplicateIdentifier(entity: "activityTag", id: tag.tagID.rawValue)
                }
            }
            var seenPeople = Set<PersonID>()
            for participant in activity.participants {
                try validateParticipant(participant)
                guard seenPeople.insert(participant.personID).inserted else {
                    throw LifeValidationError.duplicateIdentifier(entity: "participant", id: participant.personID.rawValue)
                }
            }
            activities[activity.id] = activity

        case let .updateAssociation(id, association):
            var activity = try existingActivity(id)
            guard activity.association != nil else { throw LifeValidationError.notCalendarActivity(id) }
            if let holder = activitiesByEvent()[association.key], holder.id != id {
                throw LifeValidationError.eventAlreadyAssociated(association.key)
            }
            activity.origin = .calendarEvent(association)
            activities[id] = activity

        case let .removeActivity(id):
            _ = try existingActivity(id)
            guard !allocationSets.values.contains(where: { $0.allocations.contains { $0.activityID == id } }) else {
                throw LifeValidationError.activityHasAllocations(id)
            }
            guard !obligations.values.contains(where: { $0.activityID == id }) else {
                throw LifeValidationError.activityHasObligations(id)
            }
            guard !components.values.contains(where: { $0.activityID == id }) else {
                throw LifeValidationError.activityHasComponents(id)
            }
            activities[id] = nil
            policyOverrides[.activity(id)] = nil
            natureSignals[.activity(id)] = nil

        case let .setActivityType(id, assigned):
            var activity = try existingActivity(id)
            try validateType(assigned)
            if let existing = activity.activityType, !assigned.provenance.mayReplace(existing.provenance) {
                throw LifeValidationError.userAssignmentProtected
            }
            activity.activityType = assigned
            activities[id] = activity

        case let .clearActivityType(id, by):
            var activity = try existingActivity(id)
            try requireValid(by)
            if let existing = activity.activityType {
                guard by.mayReplace(existing.provenance) else { throw LifeValidationError.userAssignmentProtected }
                activity.activityType = nil
                activities[id] = activity
            }

        case let .setActivityArea(id, assigned):
            var activity = try existingActivity(id)
            try validateArea(assigned)
            if let existing = activity.area, !assigned.provenance.mayReplace(existing.provenance) {
                throw LifeValidationError.userAssignmentProtected
            }
            activity.area = assigned
            activities[id] = activity

        case let .clearActivityArea(id, by):
            var activity = try existingActivity(id)
            try requireValid(by)
            if let existing = activity.area {
                guard by.mayReplace(existing.provenance) else { throw LifeValidationError.userAssignmentProtected }
                activity.area = nil
                activities[id] = activity
            }

        case let .setActivityTag(id, assignment):
            var activity = try existingActivity(id)
            try validateTag(assignment)
            if let index = activity.tags.firstIndex(where: { $0.tagID == assignment.tagID }) {
                guard assignment.provenance.mayReplace(activity.tags[index].provenance) else {
                    throw LifeValidationError.userAssignmentProtected
                }
                activity.tags[index] = assignment
            } else {
                activity.tags.append(assignment)
                activity.tags.sort { $0.tagID < $1.tagID }
            }
            activities[id] = activity

        case let .removeActivityTag(id, tagID, by):
            var activity = try existingActivity(id)
            try requireValid(by)
            if let index = activity.tags.firstIndex(where: { $0.tagID == tagID }) {
                guard by.mayReplace(activity.tags[index].provenance) else { throw LifeValidationError.userAssignmentProtected }
                activity.tags.remove(at: index)
                activities[id] = activity
            }

        case let .addParticipant(id, assignment):
            var activity = try existingActivity(id)
            try validateParticipant(assignment)
            if let index = activity.participants.firstIndex(where: { $0.personID == assignment.personID }) {
                guard assignment.provenance.mayReplace(activity.participants[index].provenance) else {
                    throw LifeValidationError.userAssignmentProtected
                }
                activity.participants[index] = assignment
            } else {
                activity.participants.append(assignment)
                activity.participants.sort { $0.personID < $1.personID }
            }
            activities[id] = activity

        case let .removeParticipant(id, personID, by):
            var activity = try existingActivity(id)
            try requireValid(by)
            if let index = activity.participants.firstIndex(where: { $0.personID == personID }) {
                guard by.mayReplace(activity.participants[index].provenance) else { throw LifeValidationError.userAssignmentProtected }
                activity.participants.remove(at: index)
                activities[id] = activity
            }

        case let .upsertAllocation(allocation, total, flow):
            try upsertAllocation(allocation, total: total, flow: flow)

        case let .removeAllocation(id, by):
            try requireValid(by)
            guard let existing = allocation(id) else { throw LifeValidationError.unknownAllocation(id) }
            guard by.mayReplace(existing.provenance) else { throw LifeValidationError.userAssignmentProtected }
            guard group(containing: .allocation(id)) == nil else { throw LifeValidationError.memberOfAmountGroup(.allocation(id)) }
            guard var set = allocationSets[existing.transactionID] else { return }
            set.replace(set.allocations.filter { $0.id != id })
            allocationSets[existing.transactionID] = set.isEmpty ? nil : set
            natureSignals[.allocation(id)] = nil

        case let .setAllocationAmount(id, entry):
            guard let existing = allocation(id), var set = allocationSets[existing.transactionID] else {
                throw LifeValidationError.unknownAllocation(id)
            }
            guard entry.currency == set.transactionTotal.currency else { throw LifeValidationError.allocationCurrencyMismatch(id) }
            try requireAcceptable(old: existing.amount, new: entry)
            var updated = existing
            updated.amount = entry
            set.replace(set.allocations.map { $0.id == id ? updated : $0 })
            guard set.allocatedLowerBound <= set.transactionTotal.minorUnits else {
                throw LifeValidationError.allocationExceedsTransaction(existing.transactionID)
            }
            allocationSets[existing.transactionID] = set
            try ensureGroupsConsistent(touching: [.allocation(id)])

        case let .setTransactionTag(transactionID, assignment):
            guard !transactionID.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "transaction") }
            try validateTag(assignment)
            var list = transactionTags[transactionID] ?? []
            if let index = list.firstIndex(where: { $0.tagID == assignment.tagID }) {
                guard assignment.provenance.mayReplace(list[index].provenance) else {
                    throw LifeValidationError.userAssignmentProtected
                }
                list[index] = assignment
            } else {
                list.append(assignment)
                list.sort { $0.tagID < $1.tagID }
            }
            transactionTags[transactionID] = list

        case let .removeTransactionTag(transactionID, tagID, by):
            try requireValid(by)
            var list = transactionTags[transactionID] ?? []
            if let index = list.firstIndex(where: { $0.tagID == tagID }) {
                guard by.mayReplace(list[index].provenance) else { throw LifeValidationError.userAssignmentProtected }
                list.remove(at: index)
                transactionTags[transactionID] = list.isEmpty ? nil : list
            }

        case let .createObligation(obligation):
            guard !obligation.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "obligation") }
            guard obligations[obligation.id] == nil else {
                throw LifeValidationError.duplicateIdentifier(entity: "obligation", id: obligation.id.rawValue)
            }
            try validateCounterparty(obligation.counterpartyID)
            if let activityID = obligation.activityID { _ = try existingActivity(activityID) }
            try requireValid(obligation.provenance)
            try requireValid(obligation.amount.provenance)
            guard obligation.status == .open else { throw LifeValidationError.obligationMustStartOpen(obligation.id) }
            if let componentID = obligation.componentID {
                guard components[componentID] != nil else { throw LifeValidationError.unknownComponent(componentID) }
                guard !obligations.values.contains(where: {
                    $0.componentID == componentID && $0.counterpartyID == obligation.counterpartyID && $0.status != .cancelled
                }) else {
                    throw LifeValidationError.duplicateComponentObligation(componentID, obligation.counterpartyID)
                }
            }
            obligations[obligation.id] = obligation

        case let .setObligationAmount(id, entry):
            try setObligationAmount(id, entry)

        case let .cancelObligation(id, by):
            try requireValid(by)
            guard var obligation = obligations[id] else { throw LifeValidationError.unknownObligation(id) }
            guard obligation.status != .cancelled else { return }
            guard by.mayReplace(obligation.provenance) else { throw LifeValidationError.userAssignmentProtected }
            guard appliedMinorUnits(for: id) == 0 else { throw LifeValidationError.obligationHasSettlements(id) }
            guard group(containing: .obligation(id)) == nil else { throw LifeValidationError.memberOfAmountGroup(.obligation(id)) }
            obligation.status = .cancelled
            obligations[id] = obligation

        case let .defineAmountGroup(group):
            try defineGroup(group)

        case let .removeAmountGroup(id, by):
            try requireValid(by)
            guard let group = amountGroups[id] else { throw LifeValidationError.unknownAmountGroup(id) }
            guard by.mayReplace(group.total.provenance) else { throw LifeValidationError.userAssignmentProtected }
            amountGroups[id] = nil

        case let .createSettlementRequest(request):
            guard !request.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "settlementRequest") }
            guard settlementRequests[request.id] == nil else {
                throw LifeValidationError.duplicateIdentifier(entity: "settlementRequest", id: request.id.rawValue)
            }
            try validateCounterparty(request.counterpartyID)
            for obligationID in request.obligationIDs {
                guard let obligation = obligations[obligationID] else { throw LifeValidationError.unknownObligation(obligationID) }
                guard obligation.counterpartyID == request.counterpartyID else {
                    throw LifeValidationError.obligationCounterpartyMismatch(obligationID)
                }
                if let requested = request.requestedAmount, requested.currency != obligation.currency {
                    throw LifeValidationError.obligationCurrencyMismatch(obligationID)
                }
            }
            settlementRequests[request.id] = request

        case let .setSettlementRequestStatus(id, status):
            guard var request = settlementRequests[id] else { throw LifeValidationError.unknownSettlementRequest(id) }
            request.status = status
            settlementRequests[id] = request

        case let .recordSettlement(settlement):
            try recordSettlement(settlement)

        case let .removeSettlement(id, by):
            try removeSettlement(id, by: by)

        case let .createCorrectionGroup(group):
            try createCorrectionGroup(group)

        case let .removeCorrectionGroup(id, by):
            try requireValid(by)
            guard let group = correctionGroups[id] else { throw LifeValidationError.unknownCorrectionGroup(id) }
            guard by.mayReplace(group.provenance) else { throw LifeValidationError.userAssignmentProtected }
            guard !settlements.values.contains(where: { $0.transfer.correctionGroupID == id }) else {
                throw LifeValidationError.correctionHasSettlement(id)
            }
            correctionGroups[id] = nil

        case let .classifyResidual(id, classification, by):
            try classifyResidual(id, classification, by: by)

        case let .setSettlementPolicy(target, assigned):
            try setPolicy(target, assigned)

        case let .clearSettlementPolicy(target, by):
            try requireValid(by)
            guard by.source == .user else { throw LifeValidationError.policyRequiresUser }
            policyOverrides[target] = nil

        case let .upsertExpenseComponent(component):
            try upsertComponent(component)

        case let .removeExpenseComponent(id, by):
            try requireValid(by)
            guard let existing = components[id] else { throw LifeValidationError.unknownComponent(id) }
            guard by.mayReplace(existing.provenance) else { throw LifeValidationError.userAssignmentProtected }
            guard !hasLiveObligations(forComponent: id) else { throw LifeValidationError.componentHasObligations(id) }
            components[id] = nil
            natureSignals[.component(id)] = nil

        case let .setComponentCategory(id, category):
            guard var component = components[id] else { throw LifeValidationError.unknownComponent(id) }
            try requireValidCategory(category)
            guard category.canReplace(component.category) || category == component.category else {
                throw LifeValidationError.userAssignmentProtected
            }
            component.category = category
            components[id] = component

        case let .setAllocationCategory(id, category):
            guard let existing = allocation(id), var set = allocationSets[existing.transactionID] else {
                throw LifeValidationError.unknownAllocation(id)
            }
            try requireValidCategory(category)
            guard category == existing.category || category.canReplace(existing.category) else {
                throw LifeValidationError.userAssignmentProtected
            }
            var updated = existing
            updated.category = category
            set.replace(set.allocations.map { $0.id == id ? updated : $0 })
            allocationSets[existing.transactionID] = set

        case let .setSpendingNature(target, assigned):
            try validateNatureTarget(target)
            try requireValid(assigned.provenance)
            if let existing = natureSignals[target], !assigned.provenance.mayReplace(existing.provenance) {
                throw LifeValidationError.userAssignmentProtected
            }
            natureSignals[target] = assigned

        case let .clearSpendingNature(target, by):
            try requireValid(by)
            if let existing = natureSignals[target] {
                guard by.mayReplace(existing.provenance) else { throw LifeValidationError.userAssignmentProtected }
                natureSignals[target] = nil
            }
        }
    }

    // MARK: Corrections, residuals, policies, components

    private mutating func createCorrectionGroup(_ group: TransactionCorrectionGroup) throws {
        guard !group.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "correctionGroup") }
        guard correctionGroups[group.id] == nil else {
            throw LifeValidationError.duplicateIdentifier(entity: "correctionGroup", id: group.id.rawValue)
        }
        // The user, and only the user, decides that transfers belong together.
        guard group.provenance.source == .user else { throw LifeValidationError.correctionRequiresUser }
        try requireValid(group.provenance)
        try validateCounterparty(group.counterpartyID)
        for source in group.sources {
            guard source.coveredTransactionIDs == [source.transactionID], source.correctionGroupID == nil else {
                throw LifeValidationError.correctionSourceNotRaw(source.transactionID)
            }
            guard correctionGroup(containing: source.transactionID) == nil else {
                throw LifeValidationError.transactionAlreadyCorrected(source.transactionID)
            }
            guard !settlements.values.contains(where: { $0.transfer.coveredTransactionIDs.contains(source.transactionID) }) else {
                throw LifeValidationError.correctionSourceAlreadySettled(source.transactionID)
            }
        }
        correctionGroups[group.id] = group
    }

    private mutating func classifyResidual(_ id: ResidualID, _ classification: ResidualClassification, by: AssignmentProvenance) throws {
        try requireValid(by)
        guard var residual = residuals[id] else { throw LifeValidationError.unknownResidual(id) }
        guard classification.isApplicable(to: residual.direction) else {
            throw LifeValidationError.residualClassificationNotApplicable(id)
        }
        // What a difference means is the user's call; automation may only leave it unexplained.
        if by.source == .automated, classification != .unresolved { throw LifeValidationError.automatedResidualClassification(id) }
        guard by.mayReplace(residual.classification.provenance) else { throw LifeValidationError.userAssignmentProtected }
        residual.classification = Assigned(classification, provenance: by)
        residuals[id] = residual
        if let target = residual.obligationID {
            refreshStatus(of: target)
            refreshRequests(affecting: [target], also: nil)
        }
    }

    private mutating func setPolicy(_ target: PolicyTarget, _ assigned: Assigned<SettlementPolicyOverride>) throws {
        try requireValid(assigned.provenance)
        guard assigned.provenance.source == .user else { throw LifeValidationError.policyRequiresUser }
        switch target {
        case .global: break
        case let .person(id):
            guard persons[id] != nil else { throw LifeValidationError.unknownPerson(id) }
            guard assigned.value.splitRule == nil else { throw LifeValidationError.personPolicyCannotSetSplitRule(id) }
        case let .activity(id):
            _ = try existingActivity(id)
        }
        do {
            try ExpenseComponent.validate(rule: assigned.value.splitRule)
        } catch let error as SettlementPolicyError {
            throw LifeValidationError.invalidPolicy(error)
        }
        policyOverrides[target] = assigned
    }

    private func hasLiveObligations(forComponent id: ExpenseComponentID) -> Bool {
        obligations.values.contains { $0.componentID == id && $0.status != .cancelled }
    }

    private mutating func upsertComponent(_ component: ExpenseComponent) throws {
        guard !component.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "expenseComponent") }
        _ = try existingActivity(component.activityID)
        try requireValid(component.provenance)
        try requireValid(component.amount.provenance)
        guard persons[component.payerID] != nil else { throw LifeValidationError.unknownPerson(component.payerID) }
        for person in (component.participants ?? []) + component.excludedParticipants {
            guard persons[person] != nil else { throw LifeValidationError.unknownPerson(person) }
        }
        do {
            try component.validateStructure()
        } catch let error as SettlementPolicyError {
            throw LifeValidationError.invalidPolicy(error)
        }
        try requireValidCategory(component.category)
        if let existing = components[component.id] {
            guard existing.activityID == component.activityID else { throw LifeValidationError.componentIdentityChanged(component.id) }
            guard component.provenance.mayReplace(existing.provenance) else { throw LifeValidationError.userAssignmentProtected }
            try requireAcceptable(old: existing.amount, new: component.amount)
            if component.category != existing.category, !component.category.canReplace(existing.category) {
                throw LifeValidationError.userAssignmentProtected
            }
            // Once obligations were derived, changing who pays what would silently contradict them. The one
            // exception is sharpening a total that was still uncertain (unknown, range, estimate): the
            // obligations were created at that same uncertainty, and generating them again refines them.
            let sharpensUncertainTotal = !existing.amount.knowledge.isKnown && existing.amount.currency == component.amount.currency
            let changesShares = existing.payerID != component.payerID
                || (existing.amount != component.amount && !sharpensUncertainTotal)
                || existing.participants != component.participants
                || existing.excludedParticipants != component.excludedParticipants
                || existing.policy != component.policy
            if changesShares, hasLiveObligations(forComponent: component.id) {
                throw LifeValidationError.componentHasObligations(component.id)
            }
        }
        components[component.id] = component
    }

    private func validateNatureTarget(_ target: NatureTarget) throws {
        let exists: Bool
        switch target {
        case let .allocation(id): exists = allocation(id) != nil
        case let .transaction(id): exists = !id.rawValue.isEmpty
        case let .component(id): exists = components[id] != nil
        case let .activity(id): exists = activities[id] != nil
        case let .tag(id): exists = tags[id] != nil
        case let .activityType(id): exists = activityTypes[id] != nil
        case let .category(id): exists = !id.rawValue.isEmpty
        }
        guard exists else { throw LifeValidationError.unknownNatureTarget(target) }
    }

    private func requireValidCategory(_ category: CategoryAssignment) throws {
        if let provenance = category.provenance { try requireValid(provenance) }
        // "I do not know" is something only the user can confirm.
        if case let .confirmedUnknown(provenance) = category, provenance.source != .user {
            throw LifeValidationError.confirmedUnknownRequiresUser
        }
    }

    // MARK: Allocation

    private mutating func upsertAllocation(_ allocation: TransactionAllocation, total: Money, flow: TransactionFlow) throws {
        guard !allocation.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "allocation") }
        guard !allocation.transactionID.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "transaction") }
        if let activityID = allocation.activityID { _ = try existingActivity(activityID) }
        try requireValid(allocation.provenance)
        try requireValid(allocation.amount.provenance)
        guard allocation.amount.currency == total.currency else {
            throw LifeValidationError.allocationCurrencyMismatch(allocation.id)
        }

        // Money that moved to settle an obligation, or that the user folded into a correction group, is not
        // consumption: allocating it as spending would count the same won as settlement and as spending.
        guard !settlements.values.contains(where: { $0.transfer.coveredTransactionIDs.contains(allocation.transactionID) }),
              correctionGroup(containing: allocation.transactionID) == nil else {
            throw LifeValidationError.allocationOnSettlementTransfer(allocation.transactionID)
        }
        var set = allocationSets[allocation.transactionID] ?? TransactionAllocationSet(transactionTotal: total, flow: flow)
        guard set.transactionTotal == total, set.flow == flow else {
            throw LifeValidationError.transactionTotalMismatch(allocation.transactionID)
        }
        var others = set.allocations.filter { $0.id != allocation.id }

        if let existing = self.allocation(allocation.id) {
            guard existing.transactionID == allocation.transactionID, existing.activityID == allocation.activityID else {
                throw LifeValidationError.allocationIdentityChanged(allocation.id)
            }
            guard allocation.provenance.mayReplace(existing.provenance) else { throw LifeValidationError.userAssignmentProtected }
            try requireAcceptable(old: existing.amount, new: allocation.amount)
            if allocation.category != existing.category, !allocation.category.canReplace(existing.category) {
                throw LifeValidationError.userAssignmentProtected
            }
        }
        try requireValidCategory(allocation.category)
        guard !others.contains(where: { $0.activityID == allocation.activityID }) else {
            throw LifeValidationError.duplicateAllocationTarget(allocation.transactionID)
        }
        others.append(allocation)
        set.replace(others)
        guard set.allocatedLowerBound <= total.minorUnits else {
            throw LifeValidationError.allocationExceedsTransaction(allocation.transactionID)
        }
        allocationSets[allocation.transactionID] = set
        try ensureGroupsConsistent(touching: [.allocation(allocation.id)])
    }

    // MARK: Obligations and settlements

    private mutating func setObligationAmount(_ id: ObligationID, _ entry: AmountEntry, checkGroups: Bool = true) throws {
        guard var obligation = obligations[id] else { throw LifeValidationError.unknownObligation(id) }
        guard obligation.isSettleable else { throw LifeValidationError.obligationNotSettleable(id) }
        try requireValid(entry.provenance)
        try requireAcceptable(old: obligation.amount, new: entry)
        let applied = appliedMinorUnits(for: id)
        if let upper = entry.knowledge.bounds.upper, upper < applied {
            throw LifeValidationError.amountBelowAppliedSettlements(id)
        }
        obligation.amount = entry
        obligations[id] = obligation
        refreshStatus(of: id)
        if checkGroups { try ensureGroupsConsistent(touching: [.obligation(id)]) }
    }

    private mutating func defineGroup(_ group: AmountGroup) throws {
        guard !group.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "amountGroup") }
        guard amountGroups[group.id] == nil else {
            throw LifeValidationError.duplicateIdentifier(entity: "amountGroup", id: group.id.rawValue)
        }
        try requireValid(group.total.provenance)
        for member in group.members {
            guard let entry = amount(of: member) else { throw LifeValidationError.unknownGroupMember(member) }
            guard entry.currency == group.currency else { throw LifeValidationError.groupCurrencyMismatch(member) }
            guard self.group(containing: member) == nil else { throw LifeValidationError.memberAlreadyInGroup(member) }
            if case let .obligation(id) = member, obligations[id]?.status == .cancelled {
                throw LifeValidationError.obligationNotSettleable(id)
            }
        }
        if case let .contradiction(reason) = analyze(group) {
            throw LifeValidationError.amountGroupContradiction(group.id, reason)
        }
        amountGroups[group.id] = group
    }

    private mutating func recordSettlement(_ settlement: Settlement) throws {
        guard !settlement.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "settlement") }
        guard settlements[settlement.id] == nil else {
            throw LifeValidationError.duplicateIdentifier(entity: "settlement", id: settlement.id.rawValue)
        }
        try requireValid(settlement.provenance)
        try validateCounterparty(settlement.transfer.counterpartyID)
        // A raw transaction that the user folded into a correction group is only ever settled through the
        // group's effective transfer; the effective transfer must be exactly what the group says.
        let transfer = settlement.transfer
        if let groupID = transfer.correctionGroupID {
            guard let group = correctionGroups[groupID] else { throw LifeValidationError.unknownCorrectionGroup(groupID) }
            guard group.effectiveTransfer == transfer else { throw LifeValidationError.correctionTransferMismatch(groupID) }
        } else {
            for covered in transfer.coveredTransactionIDs where correctionGroup(containing: covered) != nil {
                throw LifeValidationError.transferInCorrectionGroup(covered)
            }
        }
        for covered in transfer.coveredTransactionIDs
        where settlements.values.contains(where: { $0.transfer.coveredTransactionIDs.contains(covered) }) {
            throw LifeValidationError.transferAlreadySettled(covered)
        }
        // A transaction has one economic role. Money that settles an obligation is not also consumption.
        for covered in transfer.coveredTransactionIDs where allocationSets[covered] != nil {
            throw LifeValidationError.settlementTransferIsAllocated(covered)
        }
        if let requestID = settlement.requestID {
            guard let request = settlementRequests[requestID] else { throw LifeValidationError.unknownSettlementRequest(requestID) }
            guard request.counterpartyID == settlement.transfer.counterpartyID else {
                throw LifeValidationError.requestCounterpartyMismatch(requestID)
            }
        }

        // Amounts that the settlement made known are applied first, under the normal knowledge rules.
        for promotion in settlement.promotions {
            guard let current = obligations[promotion.obligationID] else { throw LifeValidationError.unknownObligation(promotion.obligationID) }
            guard current.amount == promotion.previous else { throw LifeValidationError.staleAmountPromotion(promotion.obligationID) }
            if promotion.applied.provenance.source == .automated {
                guard case .inferred = promotion.applied.knowledge else {
                    throw LifeValidationError.automatedPromotionMustBeInferred(promotion.obligationID)
                }
            }
            try setObligationAmount(promotion.obligationID, promotion.applied, checkGroups: false)
        }

        var signedNet: Int64 = 0
        for allocation in settlement.allocations {
            guard let obligation = obligations[allocation.obligationID] else {
                throw LifeValidationError.unknownObligation(allocation.obligationID)
            }
            guard obligation.counterpartyID == settlement.transfer.counterpartyID else {
                throw LifeValidationError.obligationCounterpartyMismatch(obligation.id)
            }
            guard obligation.currency == settlement.transfer.amount.currency else {
                throw LifeValidationError.obligationCurrencyMismatch(obligation.id)
            }
            guard obligation.isSettleable else { throw LifeValidationError.obligationNotSettleable(obligation.id) }
            let applied = appliedMinorUnits(for: obligation.id) + allocation.appliedMinorUnits
            if let upper = obligation.amount.knowledge.bounds.upper, applied > upper {
                throw LifeValidationError.appliedExceedsObligation(obligation.id)
            }
            signedNet += obligation.direction.sign * allocation.appliedMinorUnits
        }
        // Net balance, not one-to-one: receivables count for me, payables against me. A surplus residual is
        // money that moved beyond the obligations, and is accounted for explicitly rather than hidden.
        let surplus = settlement.residuals.reduce(Int64(0)) { $0 + $1.signedSurplus(transferDirection: settlement.transfer.direction) }
        guard signedNet + surplus == settlement.transfer.signedMinorUnits else { throw LifeValidationError.settlementNetMismatch }

        for residual in settlement.residuals {
            if settlement.provenance.source == .automated,
               hasUncertainObligation(with: settlement.transfer.counterpartyID, currency: settlement.transfer.amount.currency) {
                throw LifeValidationError.residualWhileUncertainObligationsOpen(residual.id)
            }
            guard residuals[residual.id] == nil else {
                throw LifeValidationError.duplicateIdentifier(entity: "residual", id: residual.id.rawValue)
            }
            if residual.classification.provenance.source == .automated, residual.classification.value != .unresolved {
                throw LifeValidationError.automatedResidualClassification(residual.id)
            }
            try requireValid(residual.classification.provenance)
            // A shortfall is exactly what the obligation still needs after this settlement; nothing else.
            if residual.direction == .shortfall, let target = residual.obligationID,
               let obligation = obligations[target], let value = obligation.amount.knowledge.knownValue,
               let applied = settlement.allocations.first(where: { $0.obligationID == target })?.appliedMinorUnits {
                guard value - closedMinorUnits(for: target) - applied == residual.amount.minorUnits else {
                    throw LifeValidationError.residualMismatch(residual.id)
                }
            } else if residual.direction == .shortfall {
                throw LifeValidationError.residualMismatch(residual.id)
            }
        }

        settlements[settlement.id] = settlement
        for residual in settlement.residuals { residuals[residual.id] = residual }
        for allocation in settlement.allocations { refreshStatus(of: allocation.obligationID) }
        try ensureGroupsConsistent(touching: settlement.promotions.map { .obligation($0.obligationID) })
        refreshRequests(affecting: settlement.allocations.map(\.obligationID), also: settlement.requestID)
    }

    /// Whether an obligation with `counterpartyID` is open and its amount is not settled knowledge (unknown,
    /// range or estimated). Such an obligation may be what a difference really is.
    private func hasUncertainObligation(with counterpartyID: PersonID, currency: String) -> Bool {
        settleableObligations(with: counterpartyID).contains {
            $0.currency == currency && !$0.amount.knowledge.isKnown
        }
    }

    private mutating func removeSettlement(_ id: SettlementID, by: AssignmentProvenance) throws {
        try requireValid(by)
        guard let settlement = settlements[id] else { throw LifeValidationError.unknownSettlement(id) }
        guard by.mayReplace(settlement.provenance) else { throw LifeValidationError.userAssignmentProtected }
        settlements[id] = nil
        for residual in settlement.residuals { residuals[residual.id] = nil }
        // Inferences that rested on this settlement go away with it.
        for promotion in settlement.promotions {
            if var obligation = obligations[promotion.obligationID], obligation.amount == promotion.applied {
                obligation.amount = promotion.previous
                obligations[promotion.obligationID] = obligation
            }
        }
        for allocation in settlement.allocations { refreshStatus(of: allocation.obligationID) }
        for promotion in settlement.promotions { refreshStatus(of: promotion.obligationID) }
        refreshRequests(affecting: settlement.allocations.map(\.obligationID), also: settlement.requestID)
    }

    /// Settled when the applied total reaches a known amount, partially settled when something has been
    /// applied, open otherwise. A cancelled obligation stays cancelled.
    private mutating func refreshStatus(of id: ObligationID) {
        guard var obligation = obligations[id], obligation.status != .cancelled else { return }
        let applied = appliedMinorUnits(for: id)
        let status: ObligationStatus
        if applied == 0 {
            status = .open
        } else if let known = obligation.amount.knowledge.knownValue, closedMinorUnits(for: id) >= known {
            status = .settled
        } else {
            status = .partiallySettled
        }
        if obligation.status != status {
            obligation.status = status
            obligations[id] = obligation
        }
    }

    /// A request is fulfilled once every obligation it names is settled or cancelled, no matter which
    /// settlements got it there (a request may be paid in several transfers, each recorded on its own).
    private mutating func refreshRequests(affecting obligationIDs: [ObligationID], also explicit: SettlementRequestID?) {
        let affected = Set(obligationIDs)
        var ids = settlementRequests.values.filter { !affected.isDisjoint(with: Set($0.obligationIDs)) }.map(\.id)
        if let explicit, !ids.contains(explicit) { ids.append(explicit) }
        for id in ids { refreshRequestStatus(id) }
    }

    private mutating func refreshRequestStatus(_ id: SettlementRequestID) {
        guard var request = settlementRequests[id], request.status != .cancelled else { return }
        let allDone = request.obligationIDs.allSatisfy {
            let status = obligations[$0]?.status
            return status == .settled || status == .cancelled
        }
        let status: SettlementRequestStatus = allDone ? .fulfilled : .open
        if request.status != status {
            request.status = status
            settlementRequests[id] = request
        }
    }

    // MARK: Validation helpers

    private func existingActivity(_ id: ActivityID) throws -> Activity {
        guard let activity = activities[id] else { throw LifeValidationError.unknownActivity(id) }
        return activity
    }

    private func requireValid(_ provenance: AssignmentProvenance) throws {
        guard provenance.hasValidConfidence else { throw LifeValidationError.invalidConfidence }
    }

    private func requireAcceptable(old: AmountEntry, new: AmountEntry) throws {
        try requireValid(new.provenance)
        let decision = AmountUpdatePolicy.evaluate(old: old, new: new)
        guard decision == .accept else { throw LifeValidationError.amountUpdateRejected(decision) }
    }

    private func validateType(_ assigned: Assigned<ActivityTypeID>) throws {
        try requireValid(assigned.provenance)
        guard let definition = activityTypes[assigned.value] else { throw LifeValidationError.unknownActivityType(assigned.value) }
        guard !definition.isArchived else { throw LifeValidationError.activityTypeArchived(assigned.value) }
    }

    private func validateArea(_ assigned: Assigned<AreaID>) throws {
        try requireValid(assigned.provenance)
        guard areaCatalog.area(assigned.value) != nil else { throw LifeValidationError.unknownArea(assigned.value) }
    }

    private func validateTag(_ assignment: TagAssignment) throws {
        try requireValid(assignment.provenance)
        guard let tag = tags[assignment.tagID] else { throw LifeValidationError.unknownTag(assignment.tagID) }
        guard !tag.isArchived else { throw LifeValidationError.tagArchived(assignment.tagID) }
    }

    private func validateParticipant(_ assignment: ParticipantAssignment) throws {
        try requireValid(assignment.provenance)
        guard persons[assignment.personID] != nil else { throw LifeValidationError.unknownPerson(assignment.personID) }
    }

    private func validateCounterparty(_ id: PersonID) throws {
        guard let person = persons[id] else { throw LifeValidationError.unknownPerson(id) }
        guard !person.isSelf else { throw LifeValidationError.counterpartyIsSelf(id) }
    }

    /// A change to a member's amount must not make its group constraint impossible.
    private func ensureGroupsConsistent(touching members: [AmountMemberRef]) throws {
        for member in members {
            guard let group = group(containing: member) else { continue }
            if case let .contradiction(reason) = analyze(group) {
                throw LifeValidationError.amountGroupContradiction(group.id, reason)
            }
        }
    }
}
