import NEOBudgetCalendar
import NEOBudgetCore

/// Money that came in and nothing has explained yet (`docs/ledger-behavior.md`, Q6): an `income` entry that no reversal undid (a transfer
/// between the user's own accounts) and no settlement has used. Only these can be put on a purchase.
struct LedgerDeposit: Identifiable, Equatable {
    let id: LedgerEntryID
    let occurredAtUnixMilliseconds: Int64
    let amount: Money
    /// Who sent it, as the notification named them, when it did.
    let title: String?
}

/// Putting a deposit on a purchase (`docs/ledger-behavior.md`, 4 and Q4): the sender paid back part of what the user spent. One deposit to one
/// purchase, and never more than the purchase still costs the user; a deposit that pays back several purchases is settled from the event's
/// settlement screen instead. The ledger is not touched: the deposit becomes a settlement of what the sender owed for the purchase.
enum DepositMerge {
    enum Refusal: Error, Equatable {
        case notAPurchase
        case currencyDiffers
        /// The deposit is larger than what the purchase still costs the user.
        case moreThanLeft(leftMinorUnits: Int64)
    }

    /// What putting the deposit on the purchase will record.
    struct Plan: Equatable {
        let deposit: LedgerDeposit
        let purchaseID: LedgerEntryID
        /// The activity the purchase belongs to wholly, if one: the debt is recorded on it.
        let activityID: ActivityID?
        let senderName: String
        /// The sender when a person by that name exists.
        let personID: PersonID?
        /// An open request to the sender for this activity that the deposit can pay, if there is one.
        let obligationID: ObligationID?
    }

    static func unclassified(in snapshot: CandidateProcessingSnapshot, life: LifeState) -> [LedgerDeposit] {
        unclassified(entries: snapshot.ledger.entries, titles: LedgerTimelineProjection.details(from: snapshot).titles, life: life)
    }

    static func unclassified(entries: [LedgerEntry], titles: [LedgerEntryID: String], life: LifeState) -> [LedgerDeposit] {
        let reversed = Set(entries.compactMap(\.reverses))
        let settled = Set(life.settlements.values.flatMap(\.transfer.coveredTransactionIDs))
        return entries
            .filter { $0.kind == .income && !reversed.contains($0.id) && !settled.contains($0.id) }
            .compactMap { entry -> LedgerDeposit? in
                let incoming = entry.postings.filter { $0.delta.minorUnits > 0 }
                guard let currency = incoming.first?.delta.currency, incoming.allSatisfy({ $0.delta.currency == currency }),
                      let amount = try? Money(minorUnits: incoming.reduce(0) { $0 + $1.delta.minorUnits }, currency: currency) else { return nil }
                return LedgerDeposit(id: entry.id, occurredAtUnixMilliseconds: entry.occurredAtUnixMilliseconds, amount: amount, title: titles[entry.id])
            }
            .sorted { ($0.occurredAtUnixMilliseconds, $0.id.rawValue) > ($1.occurredAtUnixMilliseconds, $1.id.rawValue) }
    }

    static func plan(_ deposit: LedgerDeposit, onto purchase: LedgerListEntry, senderName: String, life: LifeState) -> Result<Plan, Refusal> {
        guard purchase.transaction.flow == .spend else { return .failure(.notAPurchase) }
        guard purchase.transaction.amount.currency == deposit.amount.currency else { return .failure(.currencyDiffers) }
        let left = purchase.netMinorUnits ?? purchase.transaction.amount.minorUnits
        guard deposit.amount.minorUnits <= left else { return .failure(.moreThanLeft(leftMinorUnits: max(left, 0))) }

        let activities = Set((life.allocationSet(for: purchase.id)?.allocations ?? []).map(\.activityID))
        let activityID = activities.count == 1 ? activities.first ?? nil : nil
        let person = life.persons.values.filter { !$0.isSelf && $0.displayName == senderName }.min { $0.id < $1.id }
        let obligation = person.flatMap { person in
            activityID.flatMap { activityID in
                life.obligations(forActivity: activityID).first { obligation in
                    guard obligation.counterpartyID == person.id, obligation.direction == .receivable, obligation.status != .cancelled,
                          obligation.status != .settled, obligation.currency == deposit.amount.currency,
                          case let .exact(owed) = obligation.amount.knowledge else { return false }
                    return owed - life.closedMinorUnits(for: obligation.id) >= deposit.amount.minorUnits
                }
            }
        }
        return .success(Plan(
            deposit: deposit, purchaseID: purchase.id, activityID: activityID, senderName: senderName,
            personID: person?.id, obligationID: obligation?.id
        ))
    }

    /// Records the plan: the sender (made if new), what they owed for the purchase (unless an open request already says so), and the deposit
    /// settling it. Stops at the first refusal and says which step it was; what was recorded before it stays (a person or a request is harmless).
    static func apply(
        _ plan: Plan, provenance: AssignmentProvenance, newID: (String) -> String, perform: (CalendarCommand) async -> CalendarCommandOutcome?,
        isolation: isolated (any Actor)? = #isolation        // runs where the caller is, so the caller's own closures need not be Sendable
    ) async -> Bool {
        var personID = plan.personID
        if personID == nil {
            let person = Person(id: PersonID(rawValue: newID("person")), displayName: plan.senderName)
            guard case .applied? = await perform(.upsertPerson(person)) else { return false }
            personID = person.id
        }
        guard let personID else { return false }
        var obligationID = plan.obligationID
        if obligationID == nil {
            let input = CreateObligationInput(
                counterpartyID: personID, activity: plan.activityID.map { .activity($0) }, direction: .receivable,
                currency: plan.deposit.amount.currency, amount: .exact(plan.deposit.amount.minorUnits),
                originTransactionID: plan.purchaseID, label: "정산", provenance: provenance
            )
            guard case let .applied(applied)? = await perform(.createObligation(input)), let created = applied.obligationID else { return false }
            obligationID = created
        }
        guard let obligationID,
              let transfer = try? ActualTransfer(
                  transactionID: plan.deposit.id, counterpartyID: personID, direction: .incoming,
                  amount: plan.deposit.amount, occurredAtUnixMilliseconds: plan.deposit.occurredAtUnixMilliseconds
              ) else { return false }
        let settle = ManualSettlementInput(
            transfer: transfer, applications: [ProposedApplication(obligationID: obligationID, appliedMinorUnits: plan.deposit.amount.minorUnits)],
            confirmedAmounts: [:], requestID: nil, provenance: provenance
        )
        guard case .applied? = await perform(.recordManualSettlement(settle)) else { return false }
        return true
    }
}
