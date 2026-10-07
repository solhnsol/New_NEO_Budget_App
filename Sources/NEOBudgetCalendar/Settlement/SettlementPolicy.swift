// How a shared expense becomes per-person amounts.
//
// Two separate things are kept apart on purpose:
// - the **raw share**: what the person's part of the expense really is (an exact split of the total), and
// - the **requested share**: what is actually asked of them after the relationship's rounding habit.
// Losing the raw share would make later analysis see "23,000" where the real cost was 23,700.

public enum SettlementPolicyError: Error, Hashable, Sendable {
    case invalidRoundingUnit(Int64)
    case noParticipants
    case nonPositiveWeight(PersonID)
    case missingWeight(PersonID)
    case weightForNonParticipant(PersonID)
    case nonPositiveFixedAmount(PersonID)
    case fixedAmountForNonParticipant(PersonID)
    case fixedAmountsExceedTotal
    case fixedAmountsDoNotCoverTotal
    case amountOverflow
    case totalNotKnown
    case payerNotAPerson(PersonID)
}

public enum RoundingMode: String, Codable, Hashable, Sendable {
    /// No rounding: the requested share is the raw share.
    case exact
    /// Down to a multiple of the unit (what is owed gets smaller).
    case floor
    /// Up to a multiple of the unit.
    case ceil
    /// To the closest multiple of the unit, halves going up.
    case nearest
}

/// A rounding habit, for example "내림 1,000원" or "반올림 500원".
public struct RoundingRule: Codable, Hashable, Sendable {
    public let mode: RoundingMode
    /// In minor units; always at least 1. Meaningless for `.exact`.
    public let unitMinorUnits: Int64

    public static let exact = RoundingRule(uncheckedMode: .exact, unit: 1)

    public init(mode: RoundingMode, unitMinorUnits: Int64) throws {
        guard unitMinorUnits >= 1 else { throw SettlementPolicyError.invalidRoundingUnit(unitMinorUnits) }
        self.mode = mode
        self.unitMinorUnits = unitMinorUnits
    }

    private init(uncheckedMode mode: RoundingMode, unit: Int64) {
        self.mode = mode
        self.unitMinorUnits = unit
    }

    private enum CodingKeys: String, CodingKey { case mode, unitMinorUnits }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mode: values.decode(RoundingMode.self, forKey: .mode),
            unitMinorUnits: values.decode(Int64.self, forKey: .unitMinorUnits)
        )
    }

    public func apply(to raw: Int64) -> Int64 {
        guard raw > 0, unitMinorUnits > 1 else { return raw }
        switch mode {
        case .exact: return raw
        case .floor: return raw / unitMinorUnits * unitMinorUnits
        case .ceil: return (raw + unitMinorUnits - 1) / unitMinorUnits * unitMinorUnits
        case .nearest: return (raw + unitMinorUnits / 2) / unitMinorUnits * unitMinorUnits
        }
    }
}

/// How the cost of one expense is divided among its participants.
public enum SplitRule: Codable, Hashable, Sendable {
    /// Everyone pays the same (any odd minor units go to the earliest participant IDs).
    case equal
    /// Proportional to positive integer weights. Every participant needs a weight.
    case weights([PersonID: Int64])
    /// Some people pay a fixed amount (「C는 20,000원만」); the rest is split equally among the others.
    case fixedAmounts([PersonID: Int64])
}

/// A full, resolved policy: what applies once every level of precedence has been looked at.
public struct SettlementPolicy: Codable, Hashable, Sendable {
    public var splitRule: SplitRule
    public var rounding: RoundingRule

    public init(splitRule: SplitRule = .equal, rounding: RoundingRule = .exact) {
        self.splitRule = splitRule
        self.rounding = rounding
    }

    public static let `default` = SettlementPolicy()
}

/// A policy that only states what it wants to change. Missing fields are inherited from the level above.
///
/// Precedence, weakest to strongest:
/// 1. the global default (starts as equal split, no rounding),
/// 2. the **person** (rounding only: how this relationship rounds),
/// 3. the **activity** (its default split and rounding),
/// 4. the **expense component** (the most specific override).
/// A person's policy cannot carry a split rule, because one expense has many people.
public struct SettlementPolicyOverride: Codable, Hashable, Sendable {
    public var splitRule: SplitRule?
    public var rounding: RoundingRule?

    public init(splitRule: SplitRule? = nil, rounding: RoundingRule? = nil) {
        self.splitRule = splitRule
        self.rounding = rounding
    }

    public var isEmpty: Bool { splitRule == nil && rounding == nil }

    /// `self` wins over `base` where it states something.
    public func resolved(over base: SettlementPolicy) -> SettlementPolicy {
        SettlementPolicy(splitRule: splitRule ?? base.splitRule, rounding: rounding ?? base.rounding)
    }
}

/// Where a policy override applies.
public enum PolicyTarget: Codable, Hashable, Sendable {
    case global
    case person(PersonID)
    case activity(ActivityID)
}

/// What an obligation remembers about how its amount came to be, so the raw cost is never lost.
public struct ShareBreakdown: Codable, Hashable, Sendable {
    /// The person's real part of the expense, before any rounding.
    public let rawShareMinorUnits: Int64
    /// The rounding that produced the requested amount.
    public let rounding: RoundingRule
    /// The expense this share belongs to (a component of an activity).
    public let totalMinorUnits: Int64

    public init(rawShareMinorUnits: Int64, rounding: RoundingRule, totalMinorUnits: Int64) {
        self.rawShareMinorUnits = rawShareMinorUnits
        self.rounding = rounding
        self.totalMinorUnits = totalMinorUnits
    }
}

public struct PersonShare: Hashable, Sendable {
    public let personID: PersonID
    public let rawMinorUnits: Int64
    public let requestedMinorUnits: Int64
    public let rounding: RoundingRule

    /// Requested minus raw: negative when the request was rounded down ("23,700 → 23,000 = -700").
    public var roundingAdjustmentMinorUnits: Int64 { requestedMinorUnits - rawMinorUnits }
}

public struct ComponentShares: Hashable, Sendable {
    public let totalMinorUnits: Int64
    public let payerID: PersonID
    /// Every participant, ordered by person ID.
    public let shares: [PersonShare]
    /// How much the payer's own cost moved because everyone else was rounded (raw minus requested, summed
    /// over the other participants). Positive means the payer absorbed it.
    public let roundingAbsorbedByPayerMinorUnits: Int64

    public func share(of person: PersonID) -> PersonShare? { shares.first { $0.personID == person } }
}

public enum SplitCalculator {
    /// Raw shares: an exact division of `total` among `participants` (sorted by ID) that always adds up to
    /// `total`. Remainders are distributed deterministically, never dropped.
    public static func rawShares(total: Int64, participants: [PersonID], rule: SplitRule) throws -> [PersonID: Int64] {
        let people = Array(Set(participants)).sorted()
        guard !people.isEmpty else { throw SettlementPolicyError.noParticipants }
        switch rule {
        case .equal:
            return equalSplit(total: total, among: people)

        case let .weights(weights):
            for (person, weight) in weights {
                guard weight > 0 else { throw SettlementPolicyError.nonPositiveWeight(person) }
                guard people.contains(person) else { throw SettlementPolicyError.weightForNonParticipant(person) }
            }
            for person in people where weights[person] == nil { throw SettlementPolicyError.missingWeight(person) }
            return try weightedSplit(total: total, weights: weights, people: people)

        case let .fixedAmounts(fixed):
            var fixedTotal: Int64 = 0
            for (person, amount) in fixed {
                guard amount > 0 else { throw SettlementPolicyError.nonPositiveFixedAmount(person) }
                guard people.contains(person) else { throw SettlementPolicyError.fixedAmountForNonParticipant(person) }
                let (sum, overflow) = fixedTotal.addingReportingOverflow(amount)
                guard !overflow else { throw SettlementPolicyError.amountOverflow }
                fixedTotal = sum
            }
            guard fixedTotal <= total else { throw SettlementPolicyError.fixedAmountsExceedTotal }
            let others = people.filter { fixed[$0] == nil }
            if others.isEmpty {
                guard fixedTotal == total else { throw SettlementPolicyError.fixedAmountsDoNotCoverTotal }
                return fixed
            }
            var result = equalSplit(total: total - fixedTotal, among: others)
            for (person, amount) in fixed { result[person] = amount }
            return result
        }
    }

    private static func equalSplit(total: Int64, among people: [PersonID]) -> [PersonID: Int64] {
        let count = Int64(people.count)
        let base = total / count
        var extra = total - base * count
        var result: [PersonID: Int64] = [:]
        for person in people {
            result[person] = base + (extra > 0 ? 1 : 0)
            if extra > 0 { extra -= 1 }
        }
        return result
    }

    /// Largest-remainder method: each person gets the floor of their proportion, and the leftover units go to
    /// the biggest fractional parts (ties by person ID).
    private static func weightedSplit(total: Int64, weights: [PersonID: Int64], people: [PersonID]) throws -> [PersonID: Int64] {
        var weightSum: Int64 = 0
        for person in people {
            let (sum, overflow) = weightSum.addingReportingOverflow(weights[person] ?? 0)
            guard !overflow else { throw SettlementPolicyError.amountOverflow }
            weightSum = sum
        }
        var result: [PersonID: Int64] = [:]
        var fractions: [(PersonID, Int64)] = []
        var assigned: Int64 = 0
        for person in people {
            let (product, overflow) = total.multipliedReportingOverflow(by: weights[person] ?? 0)
            guard !overflow else { throw SettlementPolicyError.amountOverflow }
            let share = product / weightSum
            result[person] = share
            assigned += share
            fractions.append((person, product % weightSum))
        }
        fractions.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        var leftover = total - assigned
        for (person, _) in fractions where leftover > 0 {
            result[person, default: 0] += 1
            leftover -= 1
        }
        return result
    }

    /// Raw shares plus what is actually requested of each person other than the payer. The payer asks
    /// nothing of themselves, so their share is never rounded.
    public static func shares(
        total: Int64,
        payer: PersonID,
        participants: [PersonID],
        rule: SplitRule,
        roundingFor: (PersonID) -> RoundingRule
    ) throws -> ComponentShares {
        let raw = try rawShares(total: total, participants: participants, rule: rule)
        var shares: [PersonShare] = []
        var absorbed: Int64 = 0
        for person in raw.keys.sorted() {
            let rawShare = raw[person] ?? 0
            if person == payer {
                shares.append(PersonShare(personID: person, rawMinorUnits: rawShare, requestedMinorUnits: rawShare, rounding: .exact))
            } else {
                let rounding = roundingFor(person)
                let requested = rounding.apply(to: rawShare)
                absorbed += rawShare - requested
                shares.append(PersonShare(personID: person, rawMinorUnits: rawShare, requestedMinorUnits: requested, rounding: rounding))
            }
        }
        return ComponentShares(totalMinorUnits: total, payerID: payer, shares: shares, roundingAbsorbedByPayerMinorUnits: absorbed)
    }
}
