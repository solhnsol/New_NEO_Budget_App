import NEOBudgetCore

// A person sometimes sends the wrong amount and takes part of it back: +12,000 in, -4,000 out. The ledger keeps
// both raw transactions untouched. Only the *user* can say "these belong together", and only then does OnAll
// treat them as one effective +8,000 for settlement and analysis. OnAll never decides on its own that a
// pair of transfers was a mistake, and removing the group brings the raw meaning straight back.

public enum CorrectionError: Error, Hashable, Sendable {
    case requiresUser
    case tooFewTransactions
    case duplicateTransaction(LedgerEntryID)
    case mixedCounterparties
    case mixedCurrencies
}

/// The user's statement that several raw transfers with one person are really one economic transfer.
///
/// The group stores the raw transfers as facts (the ledger is never edited) and the effective result is
/// derived from them, so the two cannot disagree. A correction can fold transfers together and net them; it
/// cannot declare an amount the ledger does not support.
public struct TransactionCorrectionGroup: Codable, Hashable, Sendable {
    public let id: CorrectionGroupID
    /// The raw transfers, ordered by (time, transaction ID).
    public let sources: [ActualTransfer]
    /// Who the money moved with and in which direction after netting.
    public let effectiveDirection: TransferDirection
    /// `0` when the transfers cancel out completely.
    public let effectiveAmount: Money
    public let provenance: AssignmentProvenance
    public let createdAtUnixMilliseconds: Int64

    public init(
        id: CorrectionGroupID,
        sources: [ActualTransfer],
        provenance: AssignmentProvenance,
        createdAtUnixMilliseconds: Int64
    ) throws {
        guard provenance.source == .user else { throw CorrectionError.requiresUser }
        guard sources.count >= 2 else { throw CorrectionError.tooFewTransactions }
        var seen = Set<LedgerEntryID>()
        for source in sources {
            for covered in source.coveredTransactionIDs where !seen.insert(covered).inserted {
                throw CorrectionError.duplicateTransaction(covered)
            }
        }
        guard Set(sources.map(\.counterpartyID)).count == 1 else { throw CorrectionError.mixedCounterparties }
        let currency = sources[0].amount.currency
        guard sources.allSatisfy({ $0.amount.currency == currency }) else { throw CorrectionError.mixedCurrencies }

        let net = sources.reduce(Int64(0)) { $0 + $1.signedMinorUnits }
        self.id = id
        self.sources = sources.sorted { ($0.occurredAtUnixMilliseconds, $0.transactionID.rawValue) < ($1.occurredAtUnixMilliseconds, $1.transactionID.rawValue) }
        self.effectiveDirection = net >= 0 ? .incoming : .outgoing
        self.effectiveAmount = try Money(minorUnits: abs(net), currency: currency)
        self.provenance = provenance
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, sources, provenance, createdAtUnixMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(CorrectionGroupID.self, forKey: .id),
            sources: values.decode([ActualTransfer].self, forKey: .sources),
            provenance: values.decode(AssignmentProvenance.self, forKey: .provenance),
            createdAtUnixMilliseconds: values.decode(Int64.self, forKey: .createdAtUnixMilliseconds)
        )
    }

    public var counterpartyID: PersonID { sources[0].counterpartyID }
    public var sourceTransactionIDs: [LedgerEntryID] { sources.map(\.transactionID) }
    public var effectiveSignedMinorUnits: Int64 { effectiveDirection.sign * effectiveAmount.minorUnits }

    /// The one transfer this group stands for. `nil` when the raw transfers cancel out and nothing is left to
    /// settle.
    public var effectiveTransfer: ActualTransfer? {
        guard effectiveAmount.minorUnits > 0, let latest = sources.last else { return nil }
        return try? ActualTransfer(
            transactionID: latest.transactionID,
            counterpartyID: counterpartyID,
            direction: effectiveDirection,
            amount: effectiveAmount,
            occurredAtUnixMilliseconds: latest.occurredAtUnixMilliseconds,
            coveredTransactionIDs: sourceTransactionIDs,
            correctionGroupID: id
        )
    }
}

/// Pure recalculation of what a set of raw transfers means once the user's corrections are applied. It is
/// the same view that settlement matching and analytics should use, and it changes nothing.
public enum EffectiveTransfers {
    /// Raw transfers outside any group stay as they are; each group contributes its single effective
    /// transfer (when it does not net to zero), ordered by time.
    public static func resolve(raw transfers: [ActualTransfer], in life: LifeState) -> [ActualTransfer] {
        var result: [ActualTransfer] = []
        var emitted = Set<CorrectionGroupID>()
        for transfer in transfers {
            if let group = life.correctionGroup(containing: transfer.transactionID) {
                if emitted.insert(group.id).inserted, let effective = group.effectiveTransfer { result.append(effective) }
            } else {
                result.append(transfer)
            }
        }
        return result.sorted { ($0.occurredAtUnixMilliseconds, $0.transactionID.rawValue) < ($1.occurredAtUnixMilliseconds, $1.transactionID.rawValue) }
    }

    /// Net signed amount of the given raw transfers once corrections are applied (money in minus money out).
    public static func netMinorUnits(of transfers: [ActualTransfer], in life: LifeState) -> Int64 {
        resolve(raw: transfers, in: life).reduce(0) { $0 + $1.signedMinorUnits }
    }
}
