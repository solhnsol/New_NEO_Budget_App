import Foundation
import NEOBudgetCalendar
import NEOBudgetCore

/// Turns the ledger tab's entries (already netted for refunds and settlements, and with the user's edits) into what `SpendingAnalysis` sums.
/// Read-only: nothing here changes the ledger, the life state or the overrides.
enum AnalysisInput {
    /// shortcut: Korean won only; other currencies are left out of the analysis until there is a reason to convert them.
    static let currency = "KRW"

    static func transactions(
        _ entries: [LedgerListEntry], life: LifeState, zone: DisplayTimeZone, recurring: RecurringDecisions = RecurringDecisions()
    ) -> [AnalysisTransaction] {
        let entries = entries.filter { $0.transaction.amount.currency == currency }
        let pending = pendingByPurchase(entries, life: life)
        return entries.map { entry in
            let net = entry.signedNetMinorUnits
            // What is still expected from others is taken out of my share now, and shown as waiting; it can never take more than what is left.
            let waiting = max(0, min(pending[entry.id] ?? 0, net))
            let activity = activity(of: entry, life: life)
            return AnalysisTransaction(
                id: entry.id.rawValue, date: zone.localDate(of: entry.transaction.occurredAtUnixMilliseconds), shareMinorUnits: net - waiting,
                pendingMinorUnits: waiting, category: entry.categoryID, tags: tags(of: entry, life: life), activity: activity,
                isRecurring: entry.transaction.flow == .spend && recurring.isRecurring(
                    id: entry.id.rawValue, name: entry.transaction.title ?? "", amountMinorUnits: entry.transaction.amount.minorUnits)
            )
        }
    }

    /// What the detector reads: purchases at their full price, so the usual amount does not move when a friend pays their part back.
    static func recurringInputs(_ entries: [LedgerListEntry], zone: DisplayTimeZone) -> [RecurringInput] {
        entries.compactMap { entry in
            guard entry.transaction.flow == .spend, entry.transaction.amount.currency == currency, let title = entry.transaction.title else { return nil }
            return RecurringInput(
                id: entry.id.rawValue, name: title, date: zone.localDate(of: entry.transaction.occurredAtUnixMilliseconds),
                amountMinorUnits: entry.transaction.amount.minorUnits
            )
        }
    }

    /// Open receivables, by the purchase they would pay back (the same purchase `LedgerList.netted` puts a received settlement on).
    private static func pendingByPurchase(_ entries: [LedgerListEntry], life: LifeState) -> [LedgerEntryID: Int64] {
        let spends = Set(entries.filter { $0.transaction.flow == .spend }.map(\.id))
        var pending: [LedgerEntryID: Int64] = [:]
        for obligation in life.obligations.values where obligation.direction == .receivable && obligation.currency == currency {
            guard obligation.status == .open || obligation.status == .partiallySettled,
                  let remaining = life.balance(of: obligation.id)?.remainingMinorUnits, remaining > 0,
                  let purchase = LedgerList.purchase(for: obligation, life: life, isPurchase: { spends.contains($0) }) else { continue }
            pending[purchase, default: 0] += remaining
        }
        return pending
    }

    /// shortcut: a transaction split across several activities is analysed with the first one; split by activity when this matters.
    private static func activity(of entry: LedgerListEntry, life: LifeState) -> AnalysisActivity? {
        guard let id = entry.portions.compactMap(\.activityID).first, let activity = life.activities[id] else { return nil }
        let people = activity.participants.map(\.personID)
        return AnalysisActivity(id: id, title: activity.displayTitle, headcount: activity.headcount?.value ?? people.count + 1, participants: people)
    }

    /// The user's own tags on the transaction, the tags given to it in the life state, and the tags of the activities it belongs to.
    private static func tags(of entry: LedgerListEntry, life: LifeState) -> Set<String> {
        func name(_ id: TagID) -> String? { life.tags[id].flatMap { $0.isArchived ? nil : $0.name } }
        var result = Set(entry.override?.tags ?? [])
        result.formUnion(life.tags(forTransaction: entry.id).compactMap { name($0.tagID) })
        for id in entry.portions.compactMap(\.activityID) {
            result.formUnion((life.activities[id]?.tags ?? []).compactMap { name($0.tagID) })
        }
        return result
    }
}
