import NEOBudgetCalendar
import NEOBudgetCore

/// One transaction as the ledger tab lists it: the ledger's spend or refund, and the portions it was split into
/// on the calendar side. A pure value, built by `LedgerList`.
struct LedgerListEntry: Identifiable, Equatable {
    /// A part of the transaction given to an activity (or deliberately to none).
    struct Portion: Equatable {
        let id: AllocationID
        /// `nil` for a portion that belongs to no activity.
        let activityTitle: String?
        let amount: AmountKnowledge
        let categoryID: CanonicalCategoryID?
        let eventMissing: Bool
    }

    let transaction: TransactionMarker
    let portions: [Portion]
    var id: LedgerEntryID { transaction.id }

    /// The category every portion agrees on; `nil` when there are none or they differ (as on the timeline).
    var categoryID: CanonicalCategoryID? {
        let categories = Set(portions.map(\.categoryID))
        guard categories.count == 1 else { return nil }
        return categories.first ?? nil
    }

    /// The titles of the activities it was split into, in allocation order, without repeats.
    var activityTitles: [String] {
        var seen: Set<String> = []
        return portions.compactMap(\.activityTitle).filter { seen.insert($0).inserted }
    }
}

/// Net spending of a list, per currency: spend counts positive and refunds negative.
struct LedgerTotal: Equatable {
    let currency: String
    let minorUnits: Int64
}

/// The transactions of one day, newest first.
struct LedgerDaySection: Identifiable, Equatable {
    let day: LocalDate
    let entries: [LedgerListEntry]
    var id: LocalDate { day }

    var totals: [LedgerTotal] { LedgerList.totals(entries.map(\.transaction)) }
}

/// Builds the ledger tab's list. Which ledger entries count as spending is decided by `LedgerTimelineProjection`
/// (the same transactions the timeline shows); this only groups them by day and attaches their allocations.
enum LedgerList {
    static func sections(_ transactions: [TransactionMarker], life: LifeState, zone: DisplayTimeZone) -> [LedgerDaySection] {
        let entries = transactions.map { entry($0, life: life) }
        let byDay = Dictionary(grouping: entries) { zone.localDate(of: $0.transaction.occurredAtUnixMilliseconds) }
        return byDay.keys.sorted(by: >).map { day in
            LedgerDaySection(day: day, entries: (byDay[day] ?? []).sorted(by: newestFirst))
        }
    }

    static func entry(_ transaction: TransactionMarker, life: LifeState) -> LedgerListEntry {
        let allocations = life.allocationSet(for: transaction.id)?.allocations ?? []
        let portions = allocations.map { allocation in
            let activity = allocation.activityID.flatMap { life.activities[$0] }
            return LedgerListEntry.Portion(
                id: allocation.id,
                activityTitle: activity?.displayTitle,
                amount: allocation.amount.knowledge,
                categoryID: allocation.category.categoryID,
                eventMissing: activity?.isEventMissing ?? false
            )
        }
        return LedgerListEntry(transaction: transaction, portions: portions)
    }

    static func totals(_ transactions: [TransactionMarker]) -> [LedgerTotal] {
        var sums: [String: Int64] = [:]
        for transaction in transactions { sums[transaction.amount.currency, default: 0] += transaction.signedMinorUnits }
        return sums.keys.sorted().map { LedgerTotal(currency: $0, minorUnits: sums[$0] ?? 0) }
    }

    private static func newestFirst(_ a: LedgerListEntry, _ b: LedgerListEntry) -> Bool {
        (a.transaction.occurredAtUnixMilliseconds, a.id.rawValue) > (b.transaction.occurredAtUnixMilliseconds, b.id.rawValue)
    }
}
