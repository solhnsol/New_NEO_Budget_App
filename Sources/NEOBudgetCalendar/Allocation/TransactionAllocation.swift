import NEOBudgetCore

/// One portion of a transaction, assigned to an Activity or, with `activityID == nil`, explicitly to no
/// Activity ("활동 외 소비").
///
/// This replaces the earlier 1:1 transaction link. A transaction can be split across several Activities, an
/// Activity can hold portions of several transactions, and a portion can be partly or wholly unknown. Like
/// before, an allocation is meaning, not a time window: the transaction need not fall inside the Activity's
/// time range. The ledger entry itself is never modified.
public struct TransactionAllocation: Codable, Hashable, Sendable {
    public let id: AllocationID
    public let transactionID: LedgerEntryID
    /// `nil` is a deliberate "this portion belongs to no Activity". Not-yet-allocated money is different: it is
    /// simply the transaction's remainder (see `TransactionAllocationSet`).
    public let activityID: ActivityID?
    public var amount: AmountEntry
    /// Who decided that this portion belongs there.
    public let provenance: AssignmentProvenance
    public let createdAtUnixMilliseconds: Int64

    public init(
        id: AllocationID,
        transactionID: LedgerEntryID,
        activityID: ActivityID?,
        amount: AmountEntry,
        provenance: AssignmentProvenance,
        createdAtUnixMilliseconds: Int64
    ) {
        self.id = id
        self.transactionID = transactionID
        self.activityID = activityID
        self.amount = amount
        self.provenance = provenance
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
    }
}

/// All allocations of one transaction, with the transaction's total fixed at the time of first allocation.
/// (A ledger entry is immutable, so its total cannot change; a refund is a separate entry.)
public struct TransactionAllocationSet: Codable, Hashable, Sendable {
    public let transactionTotal: Money
    public let flow: TransactionFlow
    public private(set) var allocations: [TransactionAllocation]

    public init(transactionTotal: Money, flow: TransactionFlow, allocations: [TransactionAllocation] = []) {
        self.transactionTotal = transactionTotal
        self.flow = flow
        self.allocations = allocations.sorted { $0.id < $1.id }
    }

    mutating func replace(_ allocations: [TransactionAllocation]) {
        self.allocations = allocations.sorted { $0.id < $1.id }
    }

    public var isEmpty: Bool { allocations.isEmpty }

    /// Sum of what is known to be allocated at the least, per hard bounds.
    public var allocatedLowerBound: Int64 { allocations.reduce(0) { $0 + $1.amount.knowledge.bounds.lower } }

    /// `nil` when some allocation has no hard upper limit.
    public var allocatedUpperBound: Int64? {
        var total: Int64 = 0
        for allocation in allocations {
            guard let upper = allocation.amount.knowledge.bounds.upper else { return nil }
            total += upper
        }
        return total
    }

    /// What is left of the transaction after its allocations, as bounds (an unknown allocation widens it).
    public var remainder: AmountBounds {
        let total = transactionTotal.minorUnits
        let upperRemainder = max(0, total - allocatedLowerBound)
        let lowerRemainder = allocatedUpperBound.map { max(0, total - $0) } ?? 0
        return AmountBounds(lower: lowerRemainder, upper: upperRemainder)
    }

    /// The remainder as one number, only when every allocation is settled knowledge.
    public var knownRemainderMinorUnits: Int64? {
        guard allocations.allSatisfy({ $0.amount.knowledge.isKnown }) else { return nil }
        return transactionTotal.minorUnits - allocatedLowerBound
    }

    /// True when the allocations are certain to cover the whole transaction.
    public var isFullyAllocated: Bool { remainder.upper == 0 }

    public func allocation(forActivity activityID: ActivityID?) -> TransactionAllocation? {
        allocations.first { $0.activityID == activityID }
    }
}
