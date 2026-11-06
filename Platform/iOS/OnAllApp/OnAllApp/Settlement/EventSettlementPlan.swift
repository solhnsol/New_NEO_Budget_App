import NEOBudgetCalendar
import NEOBudgetCore

/// How an event's spending is shared, as the settlement sheet shows it before anything is asked of anyone (`docs/ledger-behavior.md`, 정산 화면).
///
/// The user paid; the total is what is linked to the event (spending less refunds). It is split over the event's headcount: the user, the named
/// participants and, when the headcount is larger, people not named yet. A named person's share can be set by hand; the rest is split equally among
/// everyone else. Unnamed people owe nothing until they are named, so their shares stay with the user in the component that is saved. Pure, so it is
/// tested; saving goes through the existing expense-component and obligation commands (`component(…)`).
struct EventSettlementPlan: Equatable {
    struct Share: Equatable, Identifiable {
        let personID: PersonID
        let name: String
        let minorUnits: Int64
        /// Set by hand, not an equal share.
        let isFixed: Bool
        var id: PersonID { personID }
    }

    enum Problem: Error, Equatable {
        case nothingToSplit
        /// The hand-set shares add up to more than the total.
        case fixedExceedTotal
    }

    let totalMinorUnits: Int64
    let currency: String
    let headcount: Int
    /// The named participants other than the user, by name.
    let others: [Share]
    let myShareMinorUnits: Int64
    /// People counted in the headcount but not named, and the share each of them has.
    let unnamedCount: Int
    let unnamedShareMinorUnits: Int64

    /// What the user is left with while the unnamed people are not named: their own share and the unnamed ones'.
    var keptByMeMinorUnits: Int64 { myShareMinorUnits + Int64(unnamedCount) * unnamedShareMinorUnits }

    /// `headcount`: the event's, if set; never fewer than the named people and the user. `fixed`: hand-set shares of named people (others ignored).
    static func make(
        totalMinorUnits: Int64, currency: String, me: PersonID, others named: [(id: PersonID, name: String)], headcount: Int?, fixed: [PersonID: Int64] = [:]
    ) throws -> EventSettlementPlan {
        guard totalMinorUnits > 0 else { throw Problem.nothingToSplit }
        let named = named.filter { $0.id != me }
        let count = max(headcount ?? 0, named.count + 1)
        let guests = (0..<(count - 1 - named.count)).map { PersonID(rawValue: "~unnamed-\($0)") }
        let pinned = fixed.filter { person, value in value > 0 && named.contains { $0.id == person } }
        guard pinned.values.reduce(0, +) <= totalMinorUnits else { throw Problem.fixedExceedTotal }
        let people = [me] + named.map(\.id) + guests
        let shares: [PersonID: Int64]
        do {
            shares = try SplitCalculator.rawShares(total: totalMinorUnits, participants: people, rule: pinned.isEmpty ? .equal : .fixedAmounts(pinned))
        } catch {
            throw Problem.fixedExceedTotal
        }
        return EventSettlementPlan(
            totalMinorUnits: totalMinorUnits, currency: currency, headcount: count,
            others: named.map { Share(personID: $0.id, name: $0.name, minorUnits: shares[$0.id] ?? 0, isFixed: pinned[$0.id] != nil) },
            myShareMinorUnits: shares[me] ?? 0,
            unnamedCount: guests.count,
            unnamedShareMinorUnits: guests.first.flatMap { shares[$0] } ?? 0
        )
    }

    /// The expense component that asks each named person for exactly their share (the user is the payer and keeps the rest).
    func component(for event: CalendarEventKey, me: PersonID, existing: ExpenseComponentID?, provenance: AssignmentProvenance) -> UpsertExpenseComponentInput {
        let asked = others.filter { $0.minorUnits > 0 }
        return UpsertExpenseComponentInput(
            componentID: existing, activity: .event(event), label: "정산", currency: currency, amount: .exact(totalMinorUnits), payerID: me,
            participants: [me] + asked.map(\.personID),
            policy: asked.isEmpty ? nil : SettlementPolicyOverride(splitRule: .fixedAmounts(Dictionary(uniqueKeysWithValues: asked.map { ($0.personID, $0.minorUnits) }))),
            provenance: provenance
        )
    }
}
