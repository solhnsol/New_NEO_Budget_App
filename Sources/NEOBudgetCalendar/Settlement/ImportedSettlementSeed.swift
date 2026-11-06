import NEOBudgetCore

/// The settlements of an imported Actual ledger as OnAll's own meaning (`docs/actual-budget-import.md`, 5.4 and Q2/Q6): for each
/// deposit that paid back purchases, a receivable per purchase from one person with no name yet, and the settlement that the
/// deposit made against them. The ledger keeps every row at its real sign; this only says which deposit paid back which
/// purchase, so the ledger tab shows the purchase's net cost and the card's usage stays at what was charged.
///
/// Actual keeps nobody's name, so the counterparty is "이름 없는 사람" until the user names them. The decisions are the
/// user's own (they made them in Actual), so they carry user provenance and automation cannot undo them.
public enum ImportedSettlementSeed {
    public static let unnamedPersonID = PersonID(rawValue: "person:actual-import-unnamed")

    /// `life` plus the plan's persons, receivables and settlements. Throws if `life` already holds one of them.
    public static func life(from plan: ImportPlan, startingFrom life: LifeState = .empty, at now: Int64) throws -> LifeState {
        guard !plan.settlements.isEmpty else { return life }
        let provenance = AssignmentProvenance.user(at: now)
        var changes: [LifeChange] = [.upsertPerson(Person(id: unnamedPersonID, displayName: ImportPlan.unnamedPersonName))]
        for settlement in plan.settlements {
            var allocations: [SettlementAllocation] = []
            for link in settlement.links {
                let obligationID = ObligationID(rawValue: "obligation:actual:" + link.rowID)
                changes.append(.createObligation(Obligation(
                    id: obligationID, counterpartyID: unnamedPersonID, direction: .receivable,
                    amount: try .exact(link.amount, provenance: provenance), provenance: provenance,
                    createdAtUnixMilliseconds: settlement.occurredAtUnixMilliseconds, originTransactionID: link.originEntryID
                )))
                allocations.append(try SettlementAllocation(obligationID: obligationID, appliedMinorUnits: link.amount.minorUnits))
            }
            let transfer = try ActualTransfer(
                transactionID: settlement.depositEntryID, counterpartyID: unnamedPersonID, direction: .incoming,
                amount: try Money(minorUnits: settlement.total, currency: ImportPlan.currency),
                occurredAtUnixMilliseconds: settlement.occurredAtUnixMilliseconds
            )
            changes.append(.recordSettlement(try Settlement(
                id: SettlementID(rawValue: "settlement:" + settlement.depositEntryID.rawValue), transfer: transfer,
                allocations: allocations, provenance: provenance, createdAtUnixMilliseconds: settlement.occurredAtUnixMilliseconds
            )))
        }
        return try life.applying(changes)
    }
}
