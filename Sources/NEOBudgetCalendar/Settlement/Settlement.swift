import NEOBudgetCore

public enum TransferDirection: String, Codable, Hashable, Sendable {
    /// Money came to me from the counterparty.
    case incoming
    /// Money went from me to the counterparty.
    case outgoing

    public var sign: Int64 { self == .incoming ? 1 : -1 }
}

public enum SettlementValidationError: Error, Hashable, Sendable {
    case nonPositiveAmount
    case emptyAllocations
    case duplicateObligation(ObligationID)
    case nonPositiveApplied(ObligationID)
    case emptyObligationList
}

/// A real movement of money between me and a counterparty, already recorded as a transaction.
public struct ActualTransfer: Codable, Hashable, Sendable {
    public let transactionID: LedgerEntryID
    public let counterpartyID: PersonID
    public let direction: TransferDirection
    public let amount: Money
    public let occurredAtUnixMilliseconds: Int64

    public init(
        transactionID: LedgerEntryID,
        counterpartyID: PersonID,
        direction: TransferDirection,
        amount: Money,
        occurredAtUnixMilliseconds: Int64
    ) throws {
        guard amount.minorUnits > 0 else { throw SettlementValidationError.nonPositiveAmount }
        self.transactionID = transactionID
        self.counterpartyID = counterpartyID
        self.direction = direction
        self.amount = amount
        self.occurredAtUnixMilliseconds = occurredAtUnixMilliseconds
    }

    /// Positive when money came to me, negative when I sent it.
    public var signedMinorUnits: Int64 { direction.sign * amount.minorUnits }
}

/// How much of one obligation a settlement resolved. An obligation can be settled by several settlements,
/// and one settlement can resolve several obligations.
public struct SettlementAllocation: Codable, Hashable, Sendable {
    public let obligationID: ObligationID
    public let appliedMinorUnits: Int64

    public init(obligationID: ObligationID, appliedMinorUnits: Int64) throws {
        guard appliedMinorUnits > 0 else { throw SettlementValidationError.nonPositiveApplied(obligationID) }
        self.obligationID = obligationID
        self.appliedMinorUnits = appliedMinorUnits
    }
}

/// An amount that became known because of a settlement, kept so the inference can be undone with it.
public struct AppliedPromotion: Codable, Hashable, Sendable {
    public let obligationID: ObligationID
    public let previous: AmountEntry
    public let applied: AmountEntry

    public init(obligationID: ObligationID, previous: AmountEntry, applied: AmountEntry) {
        self.obligationID = obligationID
        self.previous = previous
        self.applied = applied
    }
}

/// An actual transfer applied against obligations.
///
/// Matching is by **net balance**, never by comparing the transfer to a single obligation: the signed amounts
/// applied (receivable positive, payable negative) must add up to the signed transfer. A transfer that differs
/// from one obligation is therefore not evidence of failure; it may simply net other obligations off.
public struct Settlement: Codable, Hashable, Sendable {
    public let id: SettlementID
    public let transfer: ActualTransfer
    public let allocations: [SettlementAllocation]
    public let promotions: [AppliedPromotion]
    public let requestID: SettlementRequestID?
    public let provenance: AssignmentProvenance
    public let createdAtUnixMilliseconds: Int64

    public init(
        id: SettlementID,
        transfer: ActualTransfer,
        allocations: [SettlementAllocation],
        promotions: [AppliedPromotion] = [],
        requestID: SettlementRequestID? = nil,
        provenance: AssignmentProvenance,
        createdAtUnixMilliseconds: Int64
    ) throws {
        guard !allocations.isEmpty else { throw SettlementValidationError.emptyAllocations }
        var seen = Set<ObligationID>()
        for allocation in allocations where !seen.insert(allocation.obligationID).inserted {
            throw SettlementValidationError.duplicateObligation(allocation.obligationID)
        }
        self.id = id
        self.transfer = transfer
        self.allocations = allocations.sorted { $0.obligationID < $1.obligationID }
        self.promotions = promotions.sorted { $0.obligationID < $1.obligationID }
        self.requestID = requestID
        self.provenance = provenance
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, transfer, allocations, promotions, requestID, provenance, createdAtUnixMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(SettlementID.self, forKey: .id),
            transfer: values.decode(ActualTransfer.self, forKey: .transfer),
            allocations: values.decode([SettlementAllocation].self, forKey: .allocations),
            promotions: values.decode([AppliedPromotion].self, forKey: .promotions),
            requestID: values.decodeIfPresent(SettlementRequestID.self, forKey: .requestID),
            provenance: values.decode(AssignmentProvenance.self, forKey: .provenance),
            createdAtUnixMilliseconds: values.decode(Int64.self, forKey: .createdAtUnixMilliseconds)
        )
    }
}

public enum SettlementRequestStatus: String, Codable, Hashable, Sendable {
    case open
    case fulfilled
    case cancelled
}

/// A settlement ask that OnAll itself created for the user ("보내줘"). It is strong evidence about what a
/// later transfer was meant to settle. Only the record exists here: nothing is sent or read.
public struct SettlementRequest: Codable, Hashable, Sendable {
    public let id: SettlementRequestID
    public let counterpartyID: PersonID
    public let obligationIDs: [ObligationID]
    public let requestedAmount: Money?
    public let createdAtUnixMilliseconds: Int64
    public var status: SettlementRequestStatus

    public init(
        id: SettlementRequestID,
        counterpartyID: PersonID,
        obligationIDs: [ObligationID],
        requestedAmount: Money? = nil,
        createdAtUnixMilliseconds: Int64,
        status: SettlementRequestStatus = .open
    ) throws {
        guard !obligationIDs.isEmpty else { throw SettlementValidationError.emptyObligationList }
        var seen = Set<ObligationID>()
        for id in obligationIDs where !seen.insert(id).inserted { throw SettlementValidationError.duplicateObligation(id) }
        self.id = id
        self.counterpartyID = counterpartyID
        self.obligationIDs = obligationIDs.sorted()
        self.requestedAmount = requestedAmount
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, counterpartyID, obligationIDs, requestedAmount, createdAtUnixMilliseconds, status
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(SettlementRequestID.self, forKey: .id),
            counterpartyID: values.decode(PersonID.self, forKey: .counterpartyID),
            obligationIDs: values.decode([ObligationID].self, forKey: .obligationIDs),
            requestedAmount: values.decodeIfPresent(Money.self, forKey: .requestedAmount),
            createdAtUnixMilliseconds: values.decode(Int64.self, forKey: .createdAtUnixMilliseconds),
            status: values.decode(SettlementRequestStatus.self, forKey: .status)
        )
    }
}
