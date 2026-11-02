import Foundation
import NEOBudgetCalendar
import NEOBudgetCore

/// Turns the ledger tab's entries (already netted for refunds and settlements, and with the user's edits) into what `SpendingAnalysis` sums.
/// Read-only: nothing here changes the ledger, the life state or the overrides.
enum AnalysisInput {
    /// shortcut: Korean won only; other currencies are left out of the analysis until there is a reason to convert them.
    static let currency = "KRW"

    static func transactions(
        _ entries: [LedgerListEntry], life: LifeState, zone: DisplayTimeZone, recurring: RecurringDecisions = RecurringDecisions(),
        consumption: ConsumptionDateRule = ConsumptionDateRule(cutoffMinutes: 0, groupOvernightEvents: false)
    ) -> [AnalysisTransaction] {
        let entries = entries.filter { $0.transaction.amount.currency == currency }
        return entries.map { entry in
            // `netted` already takes what is still expected from others off the purchase (a `.pending` offset): it is shown as waiting, and can never take more than what is left.
            let expected = entry.offsets.reduce(0 as Int64) { if case .pending = $1.kind { $0 + $1.minorUnits } else { $0 } }
            let net = entry.signedNetMinorUnits + expected
            let waiting = max(0, min(expected, net))
            let activity = activity(of: entry, life: life)
            let nature = SpendingNatureResolver.resolve(transaction: entry.id, activityID: entry.portions.compactMap(\.activityID).first, category: entry.categoryID, in: life)
            return AnalysisTransaction(
                id: entry.id.rawValue, date: consumptionDate(of: entry, zone: zone, rule: consumption), shareMinorUnits: net - waiting,
                pendingMinorUnits: waiting, category: entry.categoryID, tags: tags(of: entry, life: life), activity: activity,
                isRecurring: entry.transaction.flow == .spend && recurring.isRecurring(
                    id: entry.id.rawValue, name: entry.transaction.title ?? "", amountMinorUnits: entry.transaction.amount.minorUnits),
                isIrregular: nature.nature == .irregular
            )
        }
    }

    /// The day the payment counts for (`ConsumptionDate`); the ledger date and time stay as they are.
    /// shortcut: the ledger keeps no "time unknown" flag, so exactly 00:00 is read as a date-only entry and is never moved to the day before.
    static func consumptionDate(of entry: LedgerListEntry, zone: DisplayTimeZone, rule: ConsumptionDateRule) -> LocalDate {
        let instant = entry.transaction.occurredAtUnixMilliseconds
        let minute = zone.minuteOfDay(of: instant)
        return ConsumptionDate.resolve(date: zone.localDate(of: instant), minuteOfDay: minute == 0 ? nil : minute, event: overnightEvent(of: entry, zone: zone), rule: rule)
    }

    /// The first timed event the payment belongs to, when it runs past midnight.
    private static func overnightEvent(of entry: LedgerListEntry, zone: DisplayTimeZone) -> OvernightEvent? {
        for portion in entry.portions {
            guard case let .timed(range)? = portion.activityTime else { continue }
            let start = zone.localDate(of: range.startUnixMilliseconds), end = zone.localDate(of: range.endUnixMilliseconds - 1)
            return OvernightEvent(startDate: start, endDate: end, durationMinutes: Int((range.endUnixMilliseconds - range.startUnixMilliseconds) / 60_000), isAllDay: false)
        }
        return nil
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
