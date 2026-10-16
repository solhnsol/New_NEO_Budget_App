import NEOBudgetCore

/// Spending that happened during an event belongs to it (`docs/ledger-behavior.md`, 1 and Q1). Pure: it only proposes; the command service
/// applies the proposals as automated allocations, which a user decision always outranks.
///
/// - Only spending is bound. A refund is shown with its original purchase, never on its own.
/// - Only timed events. An all-day event never takes spending by time.
/// - A transaction with any allocation already, including a deliberate "no activity" one, is left alone: a user who took a transaction out of an
///   event is never overruled, and an earlier binding is never moved.
/// - When several events contain the time, the shortest one (the innermost) takes it; on a tie the later start, then the smaller key.
/// - A time known only from when the notification arrived is bound like an exact one.
public enum TimeBinding {
    /// The rule's name on the allocations it makes.
    public static let origin = "time-binding/1"

    public struct Proposal: Hashable, Sendable {
        public let transactionID: LedgerEntryID
        public let event: CalendarEventKey

        public init(transactionID: LedgerEntryID, event: CalendarEventKey) {
            self.transactionID = transactionID
            self.event = event
        }
    }

    public static func proposals(events: [CalendarEvent], transactions: [TransactionMarker], life: LifeState) -> [Proposal] {
        let timed = events.compactMap { event -> (key: CalendarEventKey, start: Int64, end: Int64)? in
            guard case let .timed(range) = event.time, range.endUnixMilliseconds > range.startUnixMilliseconds else { return nil }
            return (event.key, range.startUnixMilliseconds, range.endUnixMilliseconds)
        }
        return transactions
            .filter { $0.flow == .spend && (life.allocationSet(for: $0.id)?.isEmpty ?? true) }
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
}
