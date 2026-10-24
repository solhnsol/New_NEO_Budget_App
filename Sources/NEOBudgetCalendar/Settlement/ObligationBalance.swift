import NEOBudgetCore

// One obligation, followed from what was asked to what is still open:
//
//     raw economic share → policy adjustment → requested (original) → settled / waived / cancelled / remaining
//
// Two identities hold for every obligation whose amount is known, and they are what keeps one won from being
// counted twice:
//
//     original = settled + waived + cancelled + remaining
//     requested = raw share + policy adjustment          (when a raw share was recorded)
//
// A shortfall record (`SettlementResidual` with direction `.shortfall`) is **not** a fifth bucket in the first
// identity. It is a reference to the same money that `remaining` already holds ("what is that remainder?"),
// so a balance never adds it to `remaining`. A surplus, in contrast, is money beyond every obligation and is
// accounted for on the settlement itself.

public struct ObligationBalance: Hashable, Sendable {
    public let obligationID: ObligationID
    public let currency: String
    /// What an exact or inferred amount asks for. `nil` while the amount is unknown, a range or an estimate.
    public let originalMinorUnits: Int64?
    /// The person's real share before rounding, when it is settled knowledge.
    public let rawShareMinorUnits: Int64?
    /// Requested minus raw: the outcome of a rounding habit, never a residual. `-700` for "23,700 asked as 23,000".
    public var policyAdjustmentMinorUnits: Int64? {
        guard let original = originalMinorUnits, let raw = rawShareMinorUnits else { return nil }
        return original - raw
    }
    /// Money that actually moved against this obligation, summed over its settlements.
    public let settledMinorUnits: Int64
    /// Remainder the user closed on purpose (a shortfall classified as waived or rounded away).
    public let waivedMinorUnits: Int64
    /// The part of the amount dropped because the obligation was cancelled (a cancelled obligation has no settlements).
    public let cancelledMinorUnits: Int64
    /// What is still owed. `nil` while the amount itself is not known.
    public let remainingMinorUnits: Int64?
    /// The open shortfall records pointing at this obligation. A reference to `remaining`, never added to it.
    public let openShortfallReferenceMinorUnits: Int64

    /// `original == settled + waived + cancelled + remaining`. Trivially true when the amount is not known.
    public var isConserved: Bool {
        guard let original = originalMinorUnits, let remaining = remainingMinorUnits else { return true }
        return original == settledMinorUnits + waivedMinorUnits + cancelledMinorUnits + remaining
    }
}

extension LifeState {
    /// The balance of one obligation, or `nil` when it does not exist.
    public func balance(of id: ObligationID) -> ObligationBalance? {
        guard let obligation = obligations[id] else { return nil }
        let settled = appliedMinorUnits(for: id)
        let waived = residuals.values.reduce(Int64(0)) { $0 + ($1.obligationID == id ? $1.closedMinorUnits : 0) }
        let original = obligation.amount.knowledge.knownValue
        let cancelled: Int64 = obligation.status == .cancelled ? max(0, (original ?? 0) - settled - waived) : 0
        let remaining = original.map { obligation.status == .cancelled ? 0 : max(0, $0 - settled - waived) }
        let reference = residuals.values.reduce(Int64(0)) { total, residual in
            guard residual.obligationID == id, residual.direction == .shortfall, !residual.isResolved else { return total }
            return total + min(residual.amount.minorUnits, remaining ?? 0)
        }
        return ObligationBalance(
            obligationID: id,
            currency: obligation.currency,
            originalMinorUnits: original,
            rawShareMinorUnits: obligation.share?.rawShareMinorUnits,
            settledMinorUnits: settled,
            waivedMinorUnits: waived,
            cancelledMinorUnits: cancelled,
            remainingMinorUnits: remaining,
            openShortfallReferenceMinorUnits: min(reference, remaining ?? 0)
        )
    }

    /// Balances of every obligation in a stable order.
    public func balances() -> [ObligationBalance] {
        obligations.keys.sorted().compactMap { balance(of: $0) }
    }

    /// What is still owed in total per currency and direction: the single place that answers "how much is
    /// outstanding", counting each won once. Obligations whose amount is not known are listed apart because
    /// they have no number yet.
    public func outstanding() -> [OutstandingBalance] {
        var table: [String: (receivable: Int64, payable: Int64, uncertain: Int)] = [:]
        for obligation in obligations.values where obligation.status != .cancelled && obligation.status != .settled {
            guard let balance = balance(of: obligation.id) else { continue }
            var row = table[obligation.currency] ?? (0, 0, 0)
            if let remaining = balance.remainingMinorUnits {
                if obligation.direction == .receivable { row.receivable += remaining } else { row.payable += remaining }
            } else {
                row.uncertain += 1
            }
            table[obligation.currency] = row
        }
        return table.keys.sorted().map {
            OutstandingBalance(
                currency: $0, receivableMinorUnits: table[$0]?.receivable ?? 0, payableMinorUnits: table[$0]?.payable ?? 0,
                obligationsWithoutAKnownAmount: table[$0]?.uncertain ?? 0
            )
        }
    }
}

public struct OutstandingBalance: Hashable, Sendable {
    public let currency: String
    public let receivableMinorUnits: Int64
    public let payableMinorUnits: Int64
    /// Open obligations whose amount is not settled knowledge. They are not in the two totals.
    public let obligationsWithoutAKnownAmount: Int
    public var netMinorUnits: Int64 { receivableMinorUnits - payableMinorUnits }
}
