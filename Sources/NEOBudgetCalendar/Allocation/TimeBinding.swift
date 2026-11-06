import NEOBudgetCore

/// Spending that happened during an event belongs to it (`docs/ledger-behavior.md`, 1 and Q1). Pure: it only proposes; the command service
/// applies the proposals as automated allocations, which a user decision always outranks.
///
/// - Only spending is bound. A refund is shown with its original purchase, never on its own.
/// - Transit rides are left out: they are not part of an event unless the user links them.
/// - Only timed events. An all-day event never takes spending by time.
/// - A transaction with any allocation already, including a deliberate "no activity" one, is left alone: a user who took a transaction out of an
///   event is never overruled, and an earlier binding is never moved.
/// - When several events contain the time, the shortest one (the innermost) takes it; on a tie the later start, then the smaller key.
/// - A time known only from when the notification arrived is bound like an exact one.
public enum TimeBinding {
    /// The rule's name on the allocations it makes.
    public static let origin = "time-binding/1"
    /// The name on allocations that put a refund with its purchase.
    public static let refundOrigin = "refund-follows-purchase/1"

    public struct Proposal: Hashable, Sendable {
        public let transactionID: LedgerEntryID
        public let event: CalendarEventKey

        public init(transactionID: LedgerEntryID, event: CalendarEventKey) {
            self.transactionID = transactionID
            self.event = event
        }
    }

    /// Bindings this rule made earlier that no longer hold because the event's time moved (23:30 → 23:00 puts a 23:15 payment outside it). Only the
    /// rule's own automated allocations are named, and only for events that were fetched; a user's choice is never touched.
    public static func staleAllocations(events: [CalendarEvent], transactions: [TransactionMarker], life: LifeState) -> [(transactionID: LedgerEntryID, allocationID: AllocationID)] {
        var rangeOfActivity: [ActivityID: (start: Int64, end: Int64)] = [:]
        let byEvent = life.activitiesByEvent()
        for event in events {
            guard let activity = byEvent[event.key], case let .timed(range) = event.time else { continue }
            rangeOfActivity[activity.id] = (range.startUnixMilliseconds, range.endUnixMilliseconds)
        }
        return transactions.flatMap { transaction -> [(LedgerEntryID, AllocationID)] in
            (life.allocationSet(for: transaction.id)?.allocations ?? []).compactMap { allocation in
                guard allocation.provenance.source == .automated, allocation.provenance.origin == origin,
                      let activityID = allocation.activityID, let range = rangeOfActivity[activityID] else { return nil }
                let time = transaction.occurredAtUnixMilliseconds
                return range.start <= time && time < range.end ? nil : (transaction.id, allocation.id)
            }
        }
    }

    public static func proposals(events: [CalendarEvent], transactions: [TransactionMarker], life: LifeState) -> [Proposal] {
        let timed = events.compactMap { event -> (key: CalendarEventKey, start: Int64, end: Int64)? in
            guard case let .timed(range) = event.time, range.endUnixMilliseconds > range.startUnixMilliseconds else { return nil }
            return (event.key, range.startUnixMilliseconds, range.endUnixMilliseconds)
        }
        return transactions
            .filter { $0.flow == .spend && !$0.isTransit && (life.allocationSet(for: $0.id)?.isEmpty ?? true) }
            .sorted { ($0.occurredAtUnixMilliseconds, $0.id.rawValue) < ($1.occurredAtUnixMilliseconds, $1.id.rawValue) }
            .compactMap { transaction in
                let time = transaction.occurredAtUnixMilliseconds
                let containing = timed.filter { $0.start <= time && time < $0.end }
                let chosen = containing.min { a, b in
                    let (da, db) = (a.end - a.start, b.end - b.start)
                    if da != db { return da < db }
                    if a.start != b.start { return a.start > b.start }
                    return (a.key.calendarID.rawValue, a.key.eventID.rawValue) < (b.key.calendarID.rawValue, b.key.eventID.rawValue)
                }
                return chosen.map { Proposal(transactionID: transaction.id, event: $0.key) }
            }
    }

    /// A refund goes where its purchase went (`docs/ledger-behavior.md`, 2): an unallocated refund whose purchase belongs wholly to one activity
    /// is proposed for that activity. A purchase split among activities, or kept out of all, leaves its refund alone.
    public struct RefundProposal: Hashable, Sendable {
        public let transactionID: LedgerEntryID
        public let activityID: ActivityID

        public init(transactionID: LedgerEntryID, activityID: ActivityID) {
            self.transactionID = transactionID
            self.activityID = activityID
        }
    }

    public static func refundProposals(refunds: [TransactionMarker], refundOf: [LedgerEntryID: LedgerEntryID], life: LifeState) -> [RefundProposal] {
        refunds
            .filter { $0.flow == .refund && (life.allocationSet(for: $0.id)?.isEmpty ?? true) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .compactMap { refund in
                guard let original = refundOf[refund.id], let set = life.allocationSet(for: original) else { return nil }
                let activities = Set(set.allocations.map(\.activityID))
                guard activities.count == 1, let only = activities.first, let activityID = only else { return nil }
                return RefundProposal(transactionID: refund.id, activityID: activityID)
            }
    }
}
