import NEOBudgetCore

// One Activity's spending is rarely shared one way: the 1차 is for everybody, the 2차 only for those who stayed,
// the drinks only for those who drank. An ExpenseComponent is one separately shared piece of an Activity's
// spending. It inherits the Activity's defaults and overrides only what differs, and its computed shares are
// the source from which obligations are derived.

/// One separately shared piece of an Activity's spending.
public struct ExpenseComponent: Codable, Hashable, Sendable {
    public let id: ExpenseComponentID
    public let activityID: ActivityID
    public var label: String?
    /// How much this piece cost, at the level it is known. Obligations come only from a settled amount.
    public var amount: AmountEntry
    public var payerID: PersonID
    /// `nil` means "everyone on the Activity, and me". A list replaces that (the 2차 was only for A, B, C).
    public var participants: [PersonID]?
    /// People left out of an otherwise inherited participant list (C did not drink).
    public var excludedParticipants: [PersonID]
    /// Overrides of the Activity's split and rounding. Missing fields inherit.
    public var policy: SettlementPolicyOverride?
    /// What was bought, separate from how much it cost.
    public var category: CategoryAssignment
    public var originTransactionID: LedgerEntryID?
    public let provenance: AssignmentProvenance
    public let createdAtUnixMilliseconds: Int64

    public init(
        id: ExpenseComponentID,
        activityID: ActivityID,
        label: String? = nil,
        amount: AmountEntry,
        payerID: PersonID,
        participants: [PersonID]? = nil,
        excludedParticipants: [PersonID] = [],
        policy: SettlementPolicyOverride? = nil,
        category: CategoryAssignment = .initial,
        originTransactionID: LedgerEntryID? = nil,
        provenance: AssignmentProvenance,
        createdAtUnixMilliseconds: Int64
    ) {
        self.id = id
        self.activityID = activityID
        self.label = label
        self.amount = amount
        self.payerID = payerID
        self.participants = participants.map { Array(Set($0)).sorted() }
        self.excludedParticipants = Array(Set(excludedParticipants)).sorted()
        self.policy = policy
        self.category = category
        self.originTransactionID = originTransactionID
        self.provenance = provenance
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
    }

    /// Checks what can be checked without knowing who is on the Activity.
    public func validateStructure() throws {
        try Self.validate(rule: policy?.splitRule)
    }

    public static func validate(rule: SplitRule?) throws {
        guard let rule else { return }
        switch rule {
        case .equal: break
        case let .weights(weights): for (person, weight) in weights where weight <= 0 { throw SettlementPolicyError.nonPositiveWeight(person) }
        case let .fixedAmounts(fixed): for (person, value) in fixed where value <= 0 { throw SettlementPolicyError.nonPositiveFixedAmount(person) }
        }
    }
}

/// What a component asks of one other person, before it becomes an obligation.
public struct ObligationDraft: Hashable, Sendable {
    public let counterpartyID: PersonID
    public let direction: ObligationDirection
    public let amount: AmountKnowledge
    public let currency: String
    public let share: ShareBreakdown
}

/// Everything a component works out for me: the full split, and the obligations that follow from it.
public struct ObligationDerivation: Hashable, Sendable {
    public let shares: ComponentShares
    /// One draft per counterparty that I owe or am owed by. People who owe each other but not me produce none.
    public let drafts: [ObligationDraft]
    /// People whose rounded request came to nothing. Their raw share is still in `shares`.
    public let roundedToZero: [PersonID]
}

extension LifeState {
    /// Who splits a component's cost: its own list, or the Activity's participants plus me, minus the excluded.
    public func participants(of component: ExpenseComponent) -> [PersonID] {
        var base: [PersonID]
        if let own = component.participants {
            base = own
        } else {
            base = activities[component.activityID]?.participants.map(\.personID) ?? []
            if let me = selfPersonID { base.append(me) }
        }
        let excluded = Set(component.excludedParticipants)
        return Array(Set(base).subtracting(excluded)).sorted()
    }

    /// The policy that applies to a component with a given counterparty: global, then person (rounding only),
    /// then activity, then the component's own override.
    public func effectivePolicy(for component: ExpenseComponent, counterparty: PersonID?) -> SettlementPolicy {
        var policy = SettlementPolicy.default
        if let global = policyOverrides[.global]?.value { policy = global.resolved(over: policy) }
        if let counterparty, let personal = policyOverrides[.person(counterparty)]?.value, let rounding = personal.rounding {
            policy.rounding = rounding
        }
        if let activity = policyOverrides[.activity(component.activityID)]?.value { policy = activity.resolved(over: policy) }
        if let own = component.policy { policy = own.resolved(over: policy) }
        return policy
    }

    /// The whole split of a component, with raw and requested shares side by side.
    public func shares(ofComponent id: ExpenseComponentID) throws -> ComponentShares {
        guard let component = components[id] else { throw LifeValidationError.unknownComponent(id) }
        return try computeShares(component).shares
    }

    /// The obligations that follow from a component for me. Nothing is created: the caller decides.
    public func deriveObligations(forComponent id: ExpenseComponentID) throws -> ObligationDerivation {
        guard let component = components[id] else { throw LifeValidationError.unknownComponent(id) }
        guard let me = selfPersonID else { throw LifeValidationError.selfNotDefined }
        let computed = try computeShares(component)
        let evidence = InferenceEvidence(summary: "A share of an expense total that was itself inferred.")
        func knowledge(_ minorUnits: Int64) -> AmountKnowledge {
            computed.totalIsInferred ? .inferred(minorUnits, evidence) : .exact(minorUnits)
        }
        let payer = component.payerID
        var drafts: [ObligationDraft] = []
        var zeroed: [PersonID] = []

        func draft(for share: PersonShare, counterparty: PersonID, direction: ObligationDirection) {
            guard share.requestedMinorUnits > 0 else {
                zeroed.append(share.personID)
                return
            }
            drafts.append(ObligationDraft(
                counterpartyID: counterparty, direction: direction, amount: knowledge(share.requestedMinorUnits),
                currency: component.amount.currency,
                share: ShareBreakdown(rawShareMinorUnits: share.rawMinorUnits, rounding: share.rounding, totalMinorUnits: computed.shares.totalMinorUnits)
            ))
        }

        if payer == me {
            for share in computed.shares.shares where share.personID != me {
                draft(for: share, counterparty: share.personID, direction: .receivable)
            }
        } else if let mine = computed.shares.share(of: me) {
            draft(for: mine, counterparty: payer, direction: .payable)
        }
        return ObligationDerivation(shares: computed.shares, drafts: drafts, roundedToZero: zeroed.sorted())
    }

    private func computeShares(_ component: ExpenseComponent) throws -> (shares: ComponentShares, totalIsInferred: Bool) {
        let total: Int64
        var inferred = false
        switch component.amount.knowledge {
        case let .exact(value): total = value
        case let .inferred(value, _):
            total = value
            inferred = true
        default: throw SettlementPolicyError.totalNotKnown
        }
        guard persons[component.payerID] != nil else { throw SettlementPolicyError.payerNotAPerson(component.payerID) }
        let me = selfPersonID
        let payer = component.payerID
        let basePolicy = effectivePolicy(for: component, counterparty: nil)
        let split = try SplitCalculator.shares(
            total: total,
            payer: payer,
            participants: participants(of: component),
            rule: basePolicy.splitRule,
            roundingFor: { person in
                // Whoever asks for money is the payer; rounding is the habit of the person on the other side.
                let counterparty = (payer == me) ? person : payer
                return self.effectivePolicy(for: component, counterparty: counterparty).rounding
            }
        )
        return (split, inferred)
    }

    var selfPersonID: PersonID? { persons.values.first { $0.isSelf }?.id }
}
