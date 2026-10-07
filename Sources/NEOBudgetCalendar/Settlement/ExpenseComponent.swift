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

/// Everything a component works out for me: the split, and the obligations that follow from it.
///
/// Uncertainty is carried through, not refused: an exact total gives exact shares, an inferred total inferred
/// shares, a range a range of shares, an estimate estimated shares, and an unknown total unknown shares.
/// How strongly the result may be matched automatically is a separate matter (see `SettlementMatcher`).
public struct ObligationDerivation: Hashable, Sendable {
    /// What is known about the expense total, which every draft inherits.
    public let totalKnowledge: AmountKnowledge
    /// The point split, for a settled total or (as a non-binding illustration) an estimate. `nil` when the
    /// total is only a range or unknown, because no single split exists.
    public let shares: ComponentShares?
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

    /// The obligations that follow from a component for me. Nothing is created: the caller decides.
    public func deriveObligations(forComponent id: ExpenseComponentID) throws -> ObligationDerivation {
        guard let component = components[id] else { throw LifeValidationError.unknownComponent(id) }
        guard let me = selfPersonID else { throw LifeValidationError.selfNotDefined }
        guard persons[component.payerID] != nil else { throw SettlementPolicyError.payerNotAPerson(component.payerID) }
        let payer = component.payerID
        let people = participants(of: component)
        let currency = component.amount.currency
        let evidence = InferenceEvidence(summary: "A share of an expense total that was itself inferred.")
        let total = component.amount.knowledge
        var drafts: [ObligationDraft] = []
        var zeroed: [PersonID] = []

        // Who asks whom: I ask each participant when I paid, otherwise only I owe the payer (if I took part).
        func counterparties() -> [(person: PersonID, counterparty: PersonID, direction: ObligationDirection)] {
            if payer == me { return people.filter { $0 != me }.map { ($0, $0, .receivable) } }
            return people.contains(me) ? [(me, payer, .payable)] : []
        }
        func rounding(for person: PersonID, counterparty: PersonID) -> RoundingRule {
            // Whoever asks for money is the payer; rounding is the habit of the person on the other side.
            effectivePolicy(for: component, counterparty: counterparty).rounding
        }

        switch total {
        case .unknown:
            guard !people.isEmpty else { throw SettlementPolicyError.noParticipants }
            for item in counterparties() {
                drafts.append(ObligationDraft(
                    counterpartyID: item.counterparty, direction: item.direction, amount: .unknown, currency: currency,
                    share: ShareBreakdown(rawShare: .unknown, rounding: rounding(for: item.person, counterparty: item.counterparty), total: .unknown)
                ))
            }
            return ObligationDerivation(totalKnowledge: total, shares: nil, drafts: drafts, roundedToZero: [])

        case let .range(range):
            let bounds = try SplitCalculator.rawShareBounds(
                totalMin: range.minMinorUnits, totalMax: range.maxMinorUnits, participants: people,
                rule: effectivePolicy(for: component, counterparty: nil).splitRule
            )
            for item in counterparties() {
                guard let raw = bounds[item.person] else { continue }
                let habit = rounding(for: item.person, counterparty: item.counterparty)
                let requestedMax = habit.apply(to: raw.max)
                guard requestedMax > 0 else {
                    zeroed.append(item.person)
                    continue
                }
                drafts.append(ObligationDraft(
                    counterpartyID: item.counterparty, direction: item.direction,
                    amount: .range(try AmountRange(minMinorUnits: habit.apply(to: raw.min), maxMinorUnits: requestedMax)),
                    currency: currency,
                    share: ShareBreakdown(
                        rawShare: .range(try AmountRange(minMinorUnits: raw.min, maxMinorUnits: raw.max)), rounding: habit, total: total
                    )
                ))
            }
            return ObligationDerivation(totalKnowledge: total, shares: nil, drafts: drafts, roundedToZero: zeroed.sorted())

        case let .exact(value), let .inferred(value, _), let .estimated(value):
            func level(_ minorUnits: Int64) -> AmountKnowledge {
                switch total {
                case .inferred: return .inferred(minorUnits, evidence)
                case .estimated: return .estimated(minorUnits)
                default: return .exact(minorUnits)
                }
            }
            let split = try SplitCalculator.shares(
                total: value, payer: payer, participants: people,
                rule: effectivePolicy(for: component, counterparty: nil).splitRule,
                roundingFor: { person in rounding(for: person, counterparty: payer == me ? person : payer) }
            )
            for item in counterparties() {
                guard let share = split.share(of: item.person) else { continue }
                guard share.requestedMinorUnits > 0 else {
                    zeroed.append(share.personID)
                    continue
                }
                drafts.append(ObligationDraft(
                    counterpartyID: item.counterparty, direction: item.direction, amount: level(share.requestedMinorUnits),
                    currency: currency,
                    share: ShareBreakdown(rawShare: level(share.rawMinorUnits), rounding: share.rounding, total: total)
                ))
            }
            return ObligationDerivation(totalKnowledge: total, shares: split, drafts: drafts, roundedToZero: zeroed.sorted())
        }
    }

    /// The whole split of a component at a settled or estimated total, with raw and requested shares side by
    /// side. A range or an unknown total has no single split, so this throws `totalNotKnown` for them; use
    /// `deriveObligations` to carry such uncertainty into obligations.
    public func shares(ofComponent id: ExpenseComponentID) throws -> ComponentShares {
        guard components[id] != nil else { throw LifeValidationError.unknownComponent(id) }
        guard let shares = try deriveObligations(forComponent: id).shares else { throw SettlementPolicyError.totalNotKnown }
        return shares
    }

    var selfPersonID: PersonID? { persons.values.first { $0.isSelf }?.id }
}
