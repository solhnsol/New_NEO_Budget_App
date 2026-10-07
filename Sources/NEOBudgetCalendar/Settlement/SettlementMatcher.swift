import NEOBudgetCore

// How an actual transfer is explained by open obligations.
//
// Three rules shape everything here:
// 1. A transfer that differs from one obligation is not evidence of failure; it may net other obligations.
//    Matching compares the transfer with the *net* of obligations (receivable +, payable -).
// 2. An unknown amount is promoted to `inferred` only when the data explain the transfer in exactly one way.
// 3. If there is more than one explanation, or an unknown cannot be isolated, the result says so and nothing
//    is decided automatically.

public struct ProposedApplication: Hashable, Sendable {
    public let obligationID: ObligationID
    public let appliedMinorUnits: Int64

    public init(obligationID: ObligationID, appliedMinorUnits: Int64) {
        self.obligationID = obligationID
        self.appliedMinorUnits = appliedMinorUnits
    }
}

public struct ProposedInference: Hashable, Sendable {
    public let obligationID: ObligationID
    public let minorUnits: Int64

    public init(obligationID: ObligationID, minorUnits: Int64) {
        self.obligationID = obligationID
        self.minorUnits = minorUnits
    }
}

/// A complete, uniquely explained way to apply one transfer. It becomes a `Settlement` only when accepted.
public struct SettlementProposal: Hashable, Sendable {
    public let transfer: ActualTransfer
    public let applications: [ProposedApplication]
    /// Unknown amounts that this explanation forces. Applying the proposal records them as `inferred`.
    public let inferences: [ProposedInference]
    public let requestID: SettlementRequestID?
    /// True when the transfer settles only part of an obligation (supported only with request evidence).
    public let isPartial: Bool

    /// Turns the proposal into a `Settlement`. Forced amounts become `inferred` (never `exact`) with evidence
    /// pointing at the settlement that justifies them.
    public func makeSettlement(
        id: SettlementID,
        life: LifeState,
        provenance: AssignmentProvenance,
        createdAtUnixMilliseconds: Int64
    ) throws -> Settlement {
        var promotions: [AppliedPromotion] = []
        for inference in inferences {
            guard let obligation = life.obligations[inference.obligationID] else { continue }
            let evidence = InferenceEvidence(
                settlementID: id,
                summary: "Forced by the net of this settlement; no other amount fits."
            )
            let applied = try AmountEntry(
                currency: obligation.currency,
                knowledge: .inferred(inference.minorUnits, evidence),
                provenance: .automated(origin: "settlement-inference", confidence: 1.0, at: createdAtUnixMilliseconds)
            )
            promotions.append(AppliedPromotion(obligationID: obligation.id, previous: obligation.amount, applied: applied))
        }
        return try Settlement(
            id: id,
            transfer: transfer,
            allocations: applications.map { try SettlementAllocation(obligationID: $0.obligationID, appliedMinorUnits: $0.appliedMinorUnits) },
            promotions: promotions,
            requestID: requestID,
            provenance: provenance,
            createdAtUnixMilliseconds: createdAtUnixMilliseconds
        )
    }
}

public struct AmbiguousAlternative: Hashable, Sendable {
    /// Every obligation this explanation would settle.
    public let obligationIDs: [ObligationID]
    /// Values forced for single unknowns inside this explanation.
    public let forcedAmounts: [ObligationID: Int64]
    /// True when several unknowns share an amount that cannot be split without guessing.
    public let isUnderdetermined: Bool
}

/// "These unknown amounts add up to this much", and nothing more. Can be recorded as an `AmountGroup`.
public struct UnderdeterminedConstraint: Hashable, Sendable {
    public let unknownObligationIDs: [ObligationID]
    public let knownObligationIDs: [ObligationID]
    public let totalMinorUnits: Int64
    public let currency: String
}

public enum AmbiguityReason: Hashable, Sendable {
    /// Several different sets of obligations would each explain the transfer.
    case multipleExplanations
    /// One explanation, but it involves several unknown amounts that only add up to a total.
    case underdeterminedAmounts
}

public struct AmbiguityReport: Hashable, Sendable {
    public let reason: AmbiguityReason
    /// The first alternatives in a stable order (capped); `alternativeCount` is the real number.
    public let alternatives: [AmbiguousAlternative]
    public let alternativeCount: Int
    public let constraint: UnderdeterminedConstraint?
    /// True when a settlement request already ruled some explanations out.
    public let narrowedByRequest: Bool
}

public enum InsufficientEvidenceReason: Hashable, Sendable {
    /// The transfer is smaller than what one obligation still needs; it may be a partial payment, but nothing
    /// confirms that.
    case possiblePartialSettlement([ObligationID])
    case tooManyOpenObligations(Int)
}

public enum NoMatchReason: Hashable, Sendable {
    case noOpenObligations
    case noCombinationExplainsTransfer
    case transferAlreadySettled
}

public enum SettlementMatchResult: Equatable, Sendable {
    /// One obligation settles exactly (a partial application only when a request says so).
    case exactMatch(SettlementProposal)
    /// Several obligations, possibly in both directions, net to exactly the transfer.
    case netMatch(SettlementProposal)
    /// Exactly one unknown amount is forced by the transfer and promoted to `inferred`.
    case inferredUniqueSolution(SettlementProposal)
    case ambiguous(AmbiguityReport)
    case insufficientEvidence(InsufficientEvidenceReason)
    case noMatch(NoMatchReason)
}

public enum SettlementMatcher {
    /// How many open obligations are searched. Beyond this the answer would not be trustworthy or fast.
    public static let maxKnownObligations = 12
    public static let maxUnknownObligations = 6
    public static let maxReportedAlternatives = 5

    private struct Candidate {
        let id: ObligationID
        let sign: Int64
        /// Remaining amount when settled knowledge, else `nil`.
        let remaining: Int64?
        let lower: Int64
        let upper: Int64?
    }

    private struct Explanation {
        let known: [Candidate]
        let unknown: [Candidate]
        /// The forced value when exactly one unknown is involved.
        let forced: Int64?
        let isUnderdetermined: Bool
        let sumOfKnown: Int64

        var ids: [ObligationID] { (known + unknown).map(\.id).sorted() }
    }

    public static func match(
        _ transfer: ActualTransfer,
        in life: LifeState,
        requestID: SettlementRequestID? = nil
    ) -> SettlementMatchResult {
        if life.settlements.values.contains(where: { $0.transfer.transactionID == transfer.transactionID }) {
            return .noMatch(.transferAlreadySettled)
        }
        var request: SettlementRequest?
        if let requestID, let found = life.settlementRequests[requestID],
           found.counterpartyID == transfer.counterpartyID, found.status == .open {
            request = found
        }

        var known: [Candidate] = []
        var unknown: [Candidate] = []
        for obligation in life.settleableObligations(with: transfer.counterpartyID) where obligation.currency == transfer.amount.currency {
            let applied = life.appliedMinorUnits(for: obligation.id)
            let sign = obligation.direction.sign
            if let value = obligation.amount.knowledge.knownValue {
                let remaining = value - applied
                if remaining > 0 { known.append(Candidate(id: obligation.id, sign: sign, remaining: remaining, lower: remaining, upper: remaining)) }
            } else {
                let bounds = obligation.amount.knowledge.bounds
                let lower = max(1, bounds.lower - applied)
                let upper = bounds.upper.map { $0 - applied }
                if upper == nil || upper! >= lower {
                    unknown.append(Candidate(id: obligation.id, sign: sign, remaining: nil, lower: lower, upper: upper))
                }
            }
        }
        return evaluate(transfer: transfer, known: known, unknown: unknown, request: request)
    }

    // MARK: Search

    private static func evaluate(
        transfer: ActualTransfer,
        known: [Candidate],
        unknown: [Candidate],
        request: SettlementRequest?
    ) -> SettlementMatchResult {
        if known.isEmpty && unknown.isEmpty { return .noMatch(.noOpenObligations) }
        if known.count > maxKnownObligations || unknown.count > maxUnknownObligations {
            return .insufficientEvidence(.tooManyOpenObligations(known.count + unknown.count))
        }

        let target = transfer.signedMinorUnits
        var explanations = enumerate(target: target, known: known, unknown: unknown)
        explanations.sort { lhs, rhs in
            if lhs.ids.count != rhs.ids.count { return lhs.ids.count > rhs.ids.count }
            return lhs.ids.map(\.rawValue).lexicographicallyPrecedes(rhs.ids.map(\.rawValue))
        }

        // A request is evidence, used only to choose among explanations that already fit.
        var chosen = explanations
        var narrowed = false
        let mustInclude = Set(request?.obligationIDs ?? [])
        if explanations.count > 1, !mustInclude.isEmpty {
            let filtered = explanations.filter { mustInclude.isSubset(of: Set($0.ids)) }
            if !filtered.isEmpty {
                chosen = filtered
                narrowed = filtered.count < explanations.count
            }
        }

        switch chosen.count {
        case 0:
            return noExplanation(transfer: transfer, known: known, request: request)
        case 1:
            return resolve(chosen[0], transfer: transfer, request: request, narrowed: narrowed)
        default:
            let alternatives = chosen.prefix(maxReportedAlternatives).map(alternative)
            let constraint = chosen.compactMap { constraint(of: $0, target: target, currency: transfer.amount.currency) }.first
            return .ambiguous(AmbiguityReport(
                reason: .multipleExplanations, alternatives: Array(alternatives), alternativeCount: chosen.count,
                constraint: constraint, narrowedByRequest: narrowed
            ))
        }
    }

    private static func enumerate(target: Int64, known: [Candidate], unknown: [Candidate]) -> [Explanation] {
        var result: [Explanation] = []
        for knownMask in 0..<(1 << known.count) {
            var chosenKnown: [Candidate] = []
            var knownSum: Int64 = 0
            for index in 0..<known.count where knownMask & (1 << index) != 0 {
                chosenKnown.append(known[index])
                knownSum += known[index].sign * (known[index].remaining ?? 0)
            }
            for unknownMask in 0..<(1 << unknown.count) {
                var chosenUnknown: [Candidate] = []
                for index in 0..<unknown.count where unknownMask & (1 << index) != 0 { chosenUnknown.append(unknown[index]) }
                if chosenKnown.isEmpty && chosenUnknown.isEmpty { continue }
                let rest = target - knownSum

                if chosenUnknown.isEmpty {
                    if rest == 0 {
                        result.append(Explanation(known: chosenKnown, unknown: [], forced: nil, isUnderdetermined: false, sumOfKnown: knownSum))
                    }
                    continue
                }
                // Range of what the chosen unknowns can add up to, with `nil` meaning no limit.
                var low: Int64? = 0
                var high: Int64? = 0
                for candidate in chosenUnknown {
                    if candidate.sign > 0 {
                        low = low.map { $0 + candidate.lower }
                        if let upper = candidate.upper, let current = high { high = current + upper } else { high = nil }
                    } else {
                        high = high.map { $0 - candidate.lower }
                        if let upper = candidate.upper, let current = low { low = current - upper } else { low = nil }
                    }
                }
                guard (low.map { rest >= $0 } ?? true), (high.map { rest <= $0 } ?? true) else { continue }
                if chosenUnknown.count == 1 {
                    result.append(Explanation(
                        known: chosenKnown, unknown: chosenUnknown, forced: rest * chosenUnknown[0].sign,
                        isUnderdetermined: false, sumOfKnown: knownSum
                    ))
                } else {
                    result.append(Explanation(known: chosenKnown, unknown: chosenUnknown, forced: nil, isUnderdetermined: true, sumOfKnown: knownSum))
                }
            }
        }
        return result
    }

    // MARK: Outcomes

    private static func resolve(
        _ explanation: Explanation,
        transfer: ActualTransfer,
        request: SettlementRequest?,
        narrowed: Bool
    ) -> SettlementMatchResult {
        if explanation.isUnderdetermined {
            return .ambiguous(AmbiguityReport(
                reason: .underdeterminedAmounts,
                alternatives: [alternative(explanation)],
                alternativeCount: 1,
                constraint: constraint(of: explanation, target: transfer.signedMinorUnits, currency: transfer.amount.currency),
                narrowedByRequest: narrowed
            ))
        }
        var applications = explanation.known.map { ProposedApplication(obligationID: $0.id, appliedMinorUnits: $0.remaining ?? 0) }
        var inferences: [ProposedInference] = []
        if let forced = explanation.forced, let unknown = explanation.unknown.first {
            applications.append(ProposedApplication(obligationID: unknown.id, appliedMinorUnits: forced))
            inferences.append(ProposedInference(obligationID: unknown.id, minorUnits: forced))
        }
        applications.sort { $0.obligationID < $1.obligationID }
        let touchesRequest = request.map { !Set($0.obligationIDs).isDisjoint(with: Set(explanation.ids)) } ?? false
        let proposal = SettlementProposal(
            transfer: transfer, applications: applications, inferences: inferences,
            requestID: touchesRequest ? request?.id : nil, isPartial: false
        )
        if !inferences.isEmpty { return .inferredUniqueSolution(proposal) }
        return explanation.known.count == 1 ? .exactMatch(proposal) : .netMatch(proposal)
    }

    private static func noExplanation(transfer: ActualTransfer, known: [Candidate], request: SettlementRequest?) -> SettlementMatchResult {
        let amount = transfer.amount.minorUnits
        let sign = transfer.direction.sign
        let sameDirection = known.filter { $0.sign == sign }

        // A request that names this exact amount and one obligation is evidence for a partial settlement.
        if let request, let requested = request.requestedAmount, requested == transfer.amount,
           let target = sameDirection.first(where: { request.obligationIDs.contains($0.id) && ($0.remaining ?? 0) > amount }),
           request.obligationIDs.filter({ id in known.contains { $0.id == id } }).count == 1 {
            let proposal = SettlementProposal(
                transfer: transfer,
                applications: [ProposedApplication(obligationID: target.id, appliedMinorUnits: amount)],
                inferences: [], requestID: request.id, isPartial: true
            )
            return .exactMatch(proposal)
        }
        let larger = sameDirection.filter { ($0.remaining ?? 0) > amount }.map(\.id).sorted()
        if !larger.isEmpty { return .insufficientEvidence(.possiblePartialSettlement(larger)) }
        return .noMatch(.noCombinationExplainsTransfer)
    }

    private static func alternative(_ explanation: Explanation) -> AmbiguousAlternative {
        var forced: [ObligationID: Int64] = [:]
        if let value = explanation.forced, let unknown = explanation.unknown.first { forced[unknown.id] = value }
        return AmbiguousAlternative(obligationIDs: explanation.ids, forcedAmounts: forced, isUnderdetermined: explanation.isUnderdetermined)
    }

    /// A plain "unknowns add up to N" statement, available only when all unknowns point the same way.
    private static func constraint(of explanation: Explanation, target: Int64, currency: String) -> UnderdeterminedConstraint? {
        guard explanation.isUnderdetermined, let sign = explanation.unknown.first?.sign,
              explanation.unknown.allSatisfy({ $0.sign == sign }) else { return nil }
        let total = (target - explanation.sumOfKnown) * sign
        guard total > 0 else { return nil }
        return UnderdeterminedConstraint(
            unknownObligationIDs: explanation.unknown.map(\.id).sorted(),
            knownObligationIDs: explanation.known.map(\.id).sorted(),
            totalMinorUnits: total,
            currency: currency
        )
    }
}
