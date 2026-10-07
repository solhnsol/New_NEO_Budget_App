import NEOBudgetCore

// What a settlement leaves unexplained. "The transfer is not the obligation" is not a failure: the difference
// is stored as its own record and stays **unresolved** until the user says what it was. Nothing here decides
// that it was a gift, a waiver, or a rounding, and nothing here feeds spending analysis on its own.

public enum ResidualDirection: String, Codable, Hashable, Sendable {
    /// More money moved than the obligations account for (20,000 received against 18,000 owed).
    case surplus
    /// Less money moved than an obligation asked for (17,000 received against 18,000 owed). The obligation
    /// keeps its open remainder; this record is the question "what is that remainder?".
    case shortfall
}

public enum ResidualClassification: String, Codable, Hashable, Sendable {
    /// Nobody has said what it is. The default, and the only value automation may ever store.
    case unresolved
    /// Surplus only: given on purpose.
    case gift
    /// Part of another obligation, or an offset against one.
    case otherObligation
    /// A rounding habit explains the difference. For a shortfall this closes the remainder.
    case roundingAdjustment
    /// Shortfall only: the user forgives the remainder. This closes the obligation's remainder.
    case waived
    /// Understood but none of the above.
    case other

    public func isApplicable(to direction: ResidualDirection) -> Bool {
        switch self {
        case .gift: return direction == .surplus
        case .waived: return direction == .shortfall
        default: return true
        }
    }

    /// Whether a shortfall with this meaning no longer counts as owed.
    public var closesShortfall: Bool { self == .waived || self == .roundingAdjustment }
}

public struct SettlementResidual: Codable, Hashable, Sendable {
    public let id: ResidualID
    public let settlementID: SettlementID
    /// For a shortfall, the obligation that is left short. `nil` for a surplus.
    public let obligationID: ObligationID?
    public let amount: Money
    public let direction: ResidualDirection
    public var classification: Assigned<ResidualClassification>
    public let createdAtUnixMilliseconds: Int64

    public init(
        id: ResidualID,
        settlementID: SettlementID,
        obligationID: ObligationID?,
        amount: Money,
        direction: ResidualDirection,
        classification: Assigned<ResidualClassification>,
        createdAtUnixMilliseconds: Int64
    ) throws {
        guard amount.minorUnits > 0 else { throw SettlementValidationError.nonPositiveResidual }
        switch direction {
        case .surplus: guard obligationID == nil else { throw SettlementValidationError.invalidResidualTarget }
        case .shortfall: guard obligationID != nil else { throw SettlementValidationError.invalidResidualTarget }
        }
        guard classification.value.isApplicable(to: direction) else { throw SettlementValidationError.residualClassificationNotApplicable }
        self.id = id
        self.settlementID = settlementID
        self.obligationID = obligationID
        self.amount = amount
        self.direction = direction
        self.classification = classification
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, settlementID, obligationID, amount, direction, classification, createdAtUnixMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(ResidualID.self, forKey: .id),
            settlementID: values.decode(SettlementID.self, forKey: .settlementID),
            obligationID: values.decodeIfPresent(ObligationID.self, forKey: .obligationID),
            amount: values.decode(Money.self, forKey: .amount),
            direction: values.decode(ResidualDirection.self, forKey: .direction),
            classification: values.decode(Assigned<ResidualClassification>.self, forKey: .classification),
            createdAtUnixMilliseconds: values.decode(Int64.self, forKey: .createdAtUnixMilliseconds)
        )
    }

    public var isResolved: Bool { classification.value != .unresolved }

    /// Money that a shortfall classification has closed (waived or rounded away). Zero otherwise.
    public var closedMinorUnits: Int64 {
        direction == .shortfall && classification.value.closesShortfall ? amount.minorUnits : 0
    }

    /// The signed money this record adds to the settlement's balance (a surplus follows the transfer).
    func signedSurplus(transferDirection: TransferDirection) -> Int64 {
        direction == .surplus ? transferDirection.sign * amount.minorUnits : 0
    }
}

/// Plain totals of what is still unexplained, kept out of spending analysis on purpose.
public struct ResidualSummary: Hashable, Sendable {
    public let currency: String
    public let unresolvedSurplusMinorUnits: Int64
    public let unresolvedShortfallMinorUnits: Int64
    public let byClassification: [ResidualClassification: Int64]

    public static func summarize(_ residuals: [SettlementResidual]) -> [ResidualSummary] {
        var byCurrency: [String: [SettlementResidual]] = [:]
        for residual in residuals { byCurrency[residual.amount.currency, default: []].append(residual) }
        return byCurrency.keys.sorted().map { currency in
            let items = byCurrency[currency] ?? []
            var surplus: Int64 = 0, shortfall: Int64 = 0
            var buckets: [ResidualClassification: Int64] = [:]
            for item in items {
                buckets[item.classification.value, default: 0] += item.amount.minorUnits
                guard !item.isResolved else { continue }
                if item.direction == .surplus { surplus += item.amount.minorUnits } else { shortfall += item.amount.minorUnits }
            }
            return ResidualSummary(
                currency: currency, unresolvedSurplusMinorUnits: surplus, unresolvedShortfallMinorUnits: shortfall, byClassification: buckets
            )
        }
    }
}
