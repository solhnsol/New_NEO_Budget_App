import NEOBudgetCore

// Architecture principle: OnAll never discards incomplete information and never forces it into a guess.
// It stores what is known at the level it is known, and sharpens it with later evidence.
// Amounts are therefore not a plain number: they carry how much is actually known.

public enum AmountValidationError: Error, Hashable, Sendable {
    case nonPositiveAmount
    case invalidRange
    case invalidCurrency(String)
    case currencyMismatch(expected: String, actual: String)
}

/// A closed range of possible amounts in minor units (`0 <= min <= max`).
public struct AmountRange: Codable, Hashable, Sendable {
    public let minMinorUnits: Int64
    public let maxMinorUnits: Int64

    public init(minMinorUnits: Int64, maxMinorUnits: Int64) throws {
        guard minMinorUnits >= 0, minMinorUnits <= maxMinorUnits else { throw AmountValidationError.invalidRange }
        self.minMinorUnits = minMinorUnits
        self.maxMinorUnits = maxMinorUnits
    }

    private enum CodingKeys: String, CodingKey { case minMinorUnits, maxMinorUnits }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minMinorUnits: values.decode(Int64.self, forKey: .minMinorUnits),
            maxMinorUnits: values.decode(Int64.self, forKey: .maxMinorUnits)
        )
    }

    public func contains(_ value: Int64) -> Bool { value >= minMinorUnits && value <= maxMinorUnits }

    public func isSubset(of other: AmountRange) -> Bool {
        minMinorUnits >= other.minMinorUnits && maxMinorUnits <= other.maxMinorUnits
    }
}

/// Why an inferred amount is believed. An inference is logical deduction from other facts, never a guess.
public struct InferenceEvidence: Codable, Hashable, Sendable {
    public let settlementID: SettlementID?
    public let amountGroupID: AmountGroupID?
    public let summary: String

    public init(settlementID: SettlementID? = nil, amountGroupID: AmountGroupID? = nil, summary: String) {
        self.settlementID = settlementID
        self.amountGroupID = amountGroupID
        self.summary = summary
    }
}

/// How much is known about an amount (currency lives in the container that holds it).
///
/// - `unknown`: the amount itself is not known.
/// - `range`: only the possible range is known.
/// - `estimated`: someone's rough value. A soft hint, never a hard bound.
/// - `inferred`: deduced from other facts, with evidence. **Not the same as `exact`.**
/// - `exact`: directly observed or confirmed by the user.
public enum AmountKnowledge: Codable, Hashable, Sendable {
    case unknown
    case range(AmountRange)
    case estimated(Int64)
    case inferred(Int64, InferenceEvidence)
    case exact(Int64)

    /// Higher means more informative. Automation may only move knowledge upward (see `AmountUpdatePolicy`).
    public var rank: Int {
        switch self {
        case .unknown: return 0
        case .range: return 1
        case .estimated: return 2
        case .inferred: return 3
        case .exact: return 4
        }
    }

    public func validate() throws {
        switch self {
        case .unknown, .range: return
        case let .estimated(value), let .exact(value):
            guard value > 0 else { throw AmountValidationError.nonPositiveAmount }
        case let .inferred(value, _):
            guard value > 0 else { throw AmountValidationError.nonPositiveAmount }
        }
    }

    /// The value when it is settled knowledge (exact or inferred).
    public var knownValue: Int64? {
        switch self {
        case let .exact(value): return value
        case let .inferred(value, _): return value
        default: return nil
        }
    }

    public var isKnown: Bool { knownValue != nil }

    /// Hard bounds. `upper == nil` means unbounded. An estimate is not a bound, so it adds no information here.
    public var bounds: AmountBounds {
        switch self {
        case .unknown, .estimated: return AmountBounds(lower: 0, upper: nil)
        case let .range(range): return AmountBounds(lower: range.minMinorUnits, upper: range.maxMinorUnits)
        case let .exact(value): return AmountBounds(lower: value, upper: value)
        case let .inferred(value, _): return AmountBounds(lower: value, upper: value)
        }
    }

    public var estimatedValue: Int64? {
        if case let .estimated(value) = self { return value }
        return nil
    }
}

public struct AmountBounds: Hashable, Sendable {
    public let lower: Int64
    /// `nil` means no upper limit.
    public let upper: Int64?

    public init(lower: Int64, upper: Int64?) {
        self.lower = lower
        self.upper = upper
    }

    public func contains(_ value: Int64) -> Bool {
        value >= lower && (upper.map { value <= $0 } ?? true)
    }
}

/// An amount together with its currency and who established the current level of knowledge.
public struct AmountEntry: Codable, Hashable, Sendable {
    public let currency: String
    public let knowledge: AmountKnowledge
    public let provenance: AssignmentProvenance

    public init(currency: String, knowledge: AmountKnowledge, provenance: AssignmentProvenance) throws {
        _ = try Money(minorUnits: 0, currency: currency)
        try knowledge.validate()
        self.currency = currency
        self.knowledge = knowledge
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey { case currency, knowledge, provenance }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            currency: values.decode(String.self, forKey: .currency),
            knowledge: values.decode(AmountKnowledge.self, forKey: .knowledge),
            provenance: values.decode(AssignmentProvenance.self, forKey: .provenance)
        )
    }

    public static func exact(_ money: Money, provenance: AssignmentProvenance) throws -> AmountEntry {
        try AmountEntry(currency: money.currency, knowledge: .exact(money.minorUnits), provenance: provenance)
    }

    public static func unknown(currency: String, provenance: AssignmentProvenance) throws -> AmountEntry {
        try AmountEntry(currency: currency, knowledge: .unknown, provenance: provenance)
    }
}

public enum AmountUpdateDecision: Hashable, Sendable {
    case accept
    /// An automated update would overwrite or contradict a user-confirmed exact amount.
    case rejectedProtectedUserAmount
    /// An automated update would make the knowledge less informative.
    case rejectedWeakening
    /// An automated update contradicts what is already known.
    case rejectedInconsistent
    case rejectedCurrencyMismatch
}

/// The one rule for changing what is known about an amount.
///
/// A user can always set any level of knowledge. Automation can only **refine** knowledge: it never
/// overwrites a user-confirmed exact amount, never weakens existing knowledge, and never contradicts a
/// known bound. An `inferred` value is never silently treated as `exact`.
public enum AmountUpdatePolicy {
    public static func evaluate(old: AmountEntry, new: AmountEntry) -> AmountUpdateDecision {
        guard old.currency == new.currency else { return .rejectedCurrencyMismatch }
        if new.provenance.source == .user { return .accept }
        if new.knowledge == old.knowledge { return .accept }

        if case .exact = old.knowledge {
            return old.provenance.source == .user ? .rejectedProtectedUserAmount : .rejectedInconsistent
        }
        if new.knowledge.rank < old.knowledge.rank { return .rejectedWeakening }

        if new.knowledge.rank == old.knowledge.rank {
            if case let (.range(oldRange), .range(newRange)) = (old.knowledge, new.knowledge), newRange.isSubset(of: oldRange) {
                return .accept
            }
            // Two different estimates or two different inferences: automation cannot pick one.
            return .rejectedInconsistent
        }

        // More informative than before: it must still fit any hard bound that was already known.
        if case let .range(oldRange) = old.knowledge {
            switch new.knowledge {
            case let .exact(value), let .inferred(value, _), let .estimated(value):
                return oldRange.contains(value) ? .accept : .rejectedInconsistent
            default:
                break
            }
        }
        return .accept
    }
}
