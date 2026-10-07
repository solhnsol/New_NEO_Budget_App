import NEOBudgetCore

// One-won conservation. Every won that moved is in exactly one economic role:
//
//   settlement transfer  →  applied to obligations (receivable +, payable −), or a surplus beyond them
//   spending             →  a TransactionAllocation
//   neither (yet)        →  unsettled / unrelated
//
// Netting a correction group does not create or destroy money: the effective transfer is the signed sum of its
// raw members. A shortfall is money that did **not** move, so it is never part of a transfer's balance.

/// Where the signed money of a set of raw transfers went, after the user's corrections are applied.
public struct MoneyFlowAudit: Hashable, Sendable {
    public let currency: String
    /// Signed sum of the raw transfers: money in is positive, money out negative.
    public let rawSignedMinorUnits: Int64
    /// Signed sum of the effective transfers (each correction group counted once, as its net).
    public let effectiveSignedMinorUnits: Int64
    /// Signed money applied to obligations by settlements.
    public let appliedToObligationsSignedMinorUnits: Int64
    /// Signed money beyond every obligation, resolved or not (see `unresolvedSurplusSignedMinorUnits`).
    public let surplusSignedMinorUnits: Int64
    public let unresolvedSurplusSignedMinorUnits: Int64
    /// Signed money of effective transfers that no settlement has taken up.
    public let unsettledSignedMinorUnits: Int64

    /// `raw == effective == applied + surplus + unsettled`.
    public var isConserved: Bool {
        rawSignedMinorUnits == effectiveSignedMinorUnits
            && effectiveSignedMinorUnits == appliedToObligationsSignedMinorUnits + surplusSignedMinorUnits + unsettledSignedMinorUnits
    }

    public static func audit(rawTransfers: [ActualTransfer], in life: LifeState) -> [MoneyFlowAudit] {
        var byCurrency: [String: [ActualTransfer]] = [:]
        for transfer in rawTransfers { byCurrency[transfer.amount.currency, default: []].append(transfer) }
        return byCurrency.keys.sorted().map { currency in
            let raw = byCurrency[currency] ?? []
            let effective = EffectiveTransfers.resolve(raw: raw, in: life)
            var applied: Int64 = 0, surplus: Int64 = 0, unresolvedSurplus: Int64 = 0, unsettled: Int64 = 0
            for transfer in effective {
                guard let settlement = life.settlements.values.first(where: {
                    !Set($0.transfer.coveredTransactionIDs).isDisjoint(with: transfer.coveredTransactionIDs)
                }) else {
                    unsettled += transfer.signedMinorUnits
                    continue
                }
                for allocation in settlement.allocations {
                    guard let obligation = life.obligations[allocation.obligationID] else { continue }
                    applied += obligation.direction.sign * allocation.appliedMinorUnits
                }
                for residual in settlement.residuals where residual.direction == .surplus {
                    let signed = residual.signedSurplus(transferDirection: settlement.transfer.direction)
                    surplus += signed
                    if !residual.isResolved { unresolvedSurplus += signed }
                }
            }
            return MoneyFlowAudit(
                currency: currency,
                rawSignedMinorUnits: raw.reduce(0) { $0 + $1.signedMinorUnits },
                effectiveSignedMinorUnits: effective.reduce(0) { $0 + $1.signedMinorUnits },
                appliedToObligationsSignedMinorUnits: applied,
                surplusSignedMinorUnits: surplus,
                unresolvedSurplusSignedMinorUnits: unresolvedSurplus,
                unsettledSignedMinorUnits: unsettled
            )
        }
    }
}

extension LifeState {
    /// Every obligation balance and every settlement keeps its own books; this reports the first thing that
    /// does not add up (an empty list means the whole state is consistent). Meant for tests and diagnostics.
    public func conservationViolations() -> [String] {
        var problems: [String] = []
        for balance in balances() where !balance.isConserved {
            problems.append("obligation \(balance.obligationID.rawValue): original != settled + waived + cancelled + remaining")
        }
        for settlement in settlements.values.sorted(by: { $0.id < $1.id }) {
            var net: Int64 = 0
            for allocation in settlement.allocations {
                if let obligation = obligations[allocation.obligationID] { net += obligation.direction.sign * allocation.appliedMinorUnits }
            }
            let surplus = settlement.residuals.reduce(Int64(0)) { $0 + $1.signedSurplus(transferDirection: settlement.transfer.direction) }
            if net + surplus != settlement.transfer.signedMinorUnits {
                problems.append("settlement \(settlement.id.rawValue): applied + surplus != transfer")
            }
            for covered in settlement.transfer.coveredTransactionIDs where allocationSets[covered] != nil {
                problems.append("transaction \(covered.rawValue): both a settlement transfer and spending")
            }
        }
        for group in correctionGroups.values.sorted(by: { $0.id < $1.id })
        where group.effectiveSignedMinorUnits != group.sources.reduce(Int64(0), { $0 + $1.signedMinorUnits }) {
            problems.append("correction \(group.id.rawValue): effective != signed sum of raw members")
        }
        return problems
    }
}
