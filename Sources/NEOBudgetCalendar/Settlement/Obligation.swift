import NEOBudgetCore

public enum ObligationDirection: String, Codable, Hashable, Sendable {
    /// I owe the counterparty.
    case payable
    /// The counterparty owes me.
    case receivable

    /// +1 when the money is owed to me, -1 when I owe it.
    public var sign: Int64 { self == .receivable ? 1 : -1 }
}

public enum ObligationStatus: String, Codable, Hashable, Sendable {
    case open
    case partiallySettled
    case settled
    case cancelled
}

/// An economic relationship that still has to be settled: money I will pay, or money someone will pay me.
///
/// **Transaction = money that actually moved. Obligation = something still to be settled.** An obligation can
/// exist with no transaction at all (a friend paid for lunch, so I owe them), and its amount may be only
/// partly known. The counterparty is a `Person` and never needs an OnAll account.
public struct Obligation: Codable, Hashable, Sendable {
    public let id: ObligationID
    public let counterpartyID: PersonID
    public let activityID: ActivityID?
    public let direction: ObligationDirection
    public var amount: AmountEntry
    public var status: ObligationStatus
    /// Who created the obligation (separate from who established the current amount).
    public let provenance: AssignmentProvenance
    public let createdAtUnixMilliseconds: Int64
    /// The transaction this obligation arose from, if any (for example the movie ticket I paid for both of us).
    public let originTransactionID: LedgerEntryID?
    public let label: String?

    public init(
        id: ObligationID,
        counterpartyID: PersonID,
        activityID: ActivityID? = nil,
        direction: ObligationDirection,
        amount: AmountEntry,
        status: ObligationStatus = .open,
        provenance: AssignmentProvenance,
        createdAtUnixMilliseconds: Int64,
        originTransactionID: LedgerEntryID? = nil,
        label: String? = nil
    ) {
        self.id = id
        self.counterpartyID = counterpartyID
        self.activityID = activityID
        self.direction = direction
        self.amount = amount
        self.status = status
        self.provenance = provenance
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
        self.originTransactionID = originTransactionID
        self.label = label
    }

    public var currency: String { amount.currency }
    public var isSettleable: Bool { status == .open || status == .partiallySettled }
}
