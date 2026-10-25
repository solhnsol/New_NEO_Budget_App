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
        /// The activity it went to, and when that activity happens; both `nil` for a portion that belongs to none.
        var activityID: ActivityID? = nil
        var activityTime: EventTimeRange? = nil
    }

    /// Money that came back for this purchase and is shown on it instead of on its own line (`docs/ledger-behavior.md`, 2 and Q2·Q3): a refund
    /// linked to it in the ledger, or what someone paid back toward it. Display only; the ledger and the statements keep every line as it was.
    struct Offset: Equatable, Identifiable {
        enum Kind: Equatable {
            case refund
            /// A settlement deposit, with who sent it.
            case settlement(from: String)
        }

        let id: String
        let kind: Kind
        /// A positive magnitude in the purchase's currency.
        let minorUnits: Int64
        let occurredAtUnixMilliseconds: Int64
    }

    let transaction: TransactionMarker
    let portions: [Portion]
    var offsets: [Offset] = []
    /// What the user changed for display (`TransactionOverride`); the title is already in `transaction`.
    var override: TransactionOverride? = nil
    var id: LedgerEntryID { transaction.id }

    /// What the purchase cost the user after what came back; `nil` when nothing did.
    var netMinorUnits: Int64? {
        guard transaction.flow == .spend, !offsets.isEmpty else { return nil }
        return transaction.amount.minorUnits - offsets.reduce(0) { $0 + $1.minorUnits }
    }

    /// Spend positive and refund negative, after offsets, so sums are net spending.
    var signedNetMinorUnits: Int64 { netMinorUnits ?? transaction.signedMinorUnits }

    /// The category every portion agrees on; `nil` when there are none or they differ (as on the timeline).
    var categoryID: CanonicalCategoryID? {
        if let chosen = override?.category { return chosen }
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

    var totals: [LedgerTotal] { LedgerList.totals(entries) }
}

/// Builds the ledger tab's list. Which ledger entries count as spending is decided by `LedgerTimelineProjection`
/// (the same transactions the timeline shows); this only groups them by day and attaches their allocations.
///
/// Refunds linked to a purchase in the list (`refundOf`, from the ledger's adjustment links) are folded into the purchase's line and its day, as are
/// settlement deposits applied to what someone owed for it: the obligation's own purchase if it has one, else the activity's largest purchase.
enum LedgerList {
    static func sections(
        _ transactions: [TransactionMarker], life: LifeState, zone: DisplayTimeZone, refundOf: [LedgerEntryID: LedgerEntryID] = [:],
        overrides: [LedgerEntryID: TransactionOverride] = [:]
    ) -> [LedgerDaySection] {
        let entries = netted(transactions.map { entry($0, life: life, override: overrides[$0.id]) }, life: life, refundOf: refundOf)
        let byDay = Dictionary(grouping: entries) { zone.localDate(of: $0.transaction.occurredAtUnixMilliseconds) }
        return byDay.keys.sorted(by: >).map { day in
            LedgerDaySection(day: day, entries: (byDay[day] ?? []).sorted(by: newestFirst))
        }
    }

    static func entry(_ transaction: TransactionMarker, life: LifeState, override: TransactionOverride? = nil) -> LedgerListEntry {
        let transaction = renamed(transaction, by: override)
        let allocations = life.allocationSet(for: transaction.id)?.allocations ?? []
        let portions = allocations.map { allocation in
            let activity = allocation.activityID.flatMap { life.activities[$0] }
            return LedgerListEntry.Portion(
                id: allocation.id,
                activityTitle: activity?.displayTitle,
                amount: allocation.amount.knowledge,
                categoryID: allocation.category.categoryID,
                eventMissing: activity?.isEventMissing ?? false,
                activityID: activity?.id,
                activityTime: activity?.time
            )
        }
        return LedgerListEntry(transaction: transaction, portions: portions, override: override)
    }

    /// The transaction with the name the user gave it; everything else about it is the ledger's.
    private static func renamed(_ transaction: TransactionMarker, by override: TransactionOverride?) -> TransactionMarker {
        guard let title = override?.title else { return transaction }
        return TransactionMarker(
            id: transaction.id, occurredAtUnixMilliseconds: transaction.occurredAtUnixMilliseconds, amount: transaction.amount,
            flow: transaction.flow, title: title, timePrecision: transaction.timePrecision
        )
    }

    static func totals(_ entries: [LedgerListEntry]) -> [LedgerTotal] {
        var sums: [String: Int64] = [:]
        for entry in entries { sums[entry.transaction.amount.currency, default: 0] += entry.signedNetMinorUnits }
        return sums.keys.sorted().map { LedgerTotal(currency: $0, minorUnits: sums[$0] ?? 0) }
    }

    /// Moves linked refunds onto their purchases and adds settlement deposits to the purchases they paid back.
    static func netted(_ entries: [LedgerListEntry], life: LifeState, refundOf: [LedgerEntryID: LedgerEntryID]) -> [LedgerListEntry] {
        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        func isPurchase(_ id: LedgerEntryID) -> Bool { byID[id]?.transaction.flow == .spend }
        func add(_ offset: LedgerListEntry.Offset, to id: LedgerEntryID) { byID[id]?.offsets.append(offset) }

        for entry in entries where entry.transaction.flow == .refund {
            guard let original = refundOf[entry.id], isPurchase(original),
                  byID[original]?.transaction.amount.currency == entry.transaction.amount.currency else { continue }
            add(.init(id: entry.id.rawValue, kind: .refund, minorUnits: entry.transaction.amount.minorUnits,
                      occurredAtUnixMilliseconds: entry.transaction.occurredAtUnixMilliseconds), to: original)
            byID[entry.id] = nil
        }

        for settlement in life.settlements.values where settlement.transfer.direction == .incoming {
            for applied in settlement.allocations {
                guard let obligation = life.obligations[applied.obligationID], obligation.direction == .receivable,
                      let purchase = purchase(for: obligation, life: life, isPurchase: isPurchase),
                      byID[purchase]?.transaction.amount.currency == obligation.currency else { continue }
                let name = life.persons[obligation.counterpartyID]?.displayName ?? "알 수 없음"
                add(.init(id: "\(settlement.id.rawValue)/\(obligation.id.rawValue)", kind: .settlement(from: name), minorUnits: applied.appliedMinorUnits,
                          occurredAtUnixMilliseconds: settlement.transfer.occurredAtUnixMilliseconds), to: purchase)
            }
        }
        return entries.compactMap { byID[$0.id] }.map { entry in
            var sorted = entry
            sorted.offsets.sort { ($0.occurredAtUnixMilliseconds, $0.id) < ($1.occurredAtUnixMilliseconds, $1.id) }
            return sorted
        }
    }

    /// The purchase a receivable paid back: its own, or the largest purchase of its activity (ties: the smaller id).
    static func purchase(for obligation: Obligation, life: LifeState, isPurchase: (LedgerEntryID) -> Bool) -> LedgerEntryID? {
        if let origin = obligation.originTransactionID, isPurchase(origin) { return origin }
        guard let activityID = obligation.activityID else { return nil }
        let candidates = life.allocations(forActivity: activityID).map(\.transactionID).filter(isPurchase)
        return Set(candidates).sorted { $0.rawValue < $1.rawValue }.max { a, b in
            amount(a, life: life, activityID: activityID) < amount(b, life: life, activityID: activityID)
        }
    }

    private static func amount(_ id: LedgerEntryID, life: LifeState, activityID: ActivityID) -> Int64 {
        life.allocations(forActivity: activityID).filter { $0.transactionID == id }.reduce(0) { total, allocation in
            if case let .exact(value) = allocation.amount.knowledge { return total + value }
            return total
        }
    }

    private static func newestFirst(_ a: LedgerListEntry, _ b: LedgerListEntry) -> Bool {
        (a.transaction.occurredAtUnixMilliseconds, a.id.rawValue) > (b.transaction.occurredAtUnixMilliseconds, b.id.rawValue)
    }
}
