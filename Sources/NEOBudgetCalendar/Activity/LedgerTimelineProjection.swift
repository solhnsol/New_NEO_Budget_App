import NEOBudgetCore

/// Turns ledger facts into the transactions the day timeline shows. A pure function: it reads a snapshot and
/// returns values, and it never changes the ledger.
///
/// What counts as a timeline transaction is decided by the ledger's own semantics, not by amount or sign:
/// - `expense` entries are spending, shown with their consumption amount (`budgetImpact`), not the cash that moved.
///   A card purchase therefore appears when the card is used, regardless of which account later pays the bill.
/// - `adjustment` entries (cancellations and refunds) are shown as refunds on the day the money actually came
///   back; the reduction in spending still belongs to the original purchase month in the ledger.
/// - `income`, `transfer` and `cardPayment` are money movement, not consumption, and are never shown. A card bill
///   payment would otherwise count the same purchases twice.
public enum LedgerTimelineProjection {
    /// Display details the ledger itself does not store. They come from the candidates that were promoted.
    public struct EntryDetails: Sendable, Equatable {
        public var titles: [LedgerEntryID: String]
        public var timePrecisions: [LedgerEntryID: TimePrecision]

        public init(titles: [LedgerEntryID: String] = [:], timePrecisions: [LedgerEntryID: TimePrecision] = [:]) {
            self.titles = titles
            self.timePrecisions = timePrecisions
        }

        public static let none = EntryDetails()
    }

    /// Projects a ledger snapshot. Without details every time is `approximate`, because the ledger does not record
    /// how its time was obtained and claiming precision it cannot back would misplace the marker.
    public static func transactions(in ledger: LedgerSnapshot, details: EntryDetails = .none) -> [TransactionMarker] {
        let titles = details.titles
        return ledger.entries.compactMap { entry -> TransactionMarker? in
            guard let impact = entry.budgetImpact else { return nil }
            let flow: TransactionFlow
            switch (entry.kind, impact.kind) {
            case (.expense, .expense): flow = .spend
            case (.adjustment, .return): flow = .refund
            default: return nil
            }
            var title = titles[entry.id]
            // A refund notice often omits the merchant; it takes the original purchase's name.
            if title == nil, let link = entry.adjustment { title = titles[link.originalEntryID] }
            return TransactionMarker(
                id: entry.id,
                occurredAtUnixMilliseconds: entry.occurredAtUnixMilliseconds,
                amount: impact.amount,
                flow: flow,
                title: title,
                timePrecision: details.timePrecisions[entry.id] ?? .approximate
            )
        }
        .sorted { ($0.occurredAtUnixMilliseconds, $0.id.rawValue) < ($1.occurredAtUnixMilliseconds, $1.id.rawValue) }
    }

    /// Projects the ledger of a processing snapshot, using the promoted candidates for titles and time precision.
    /// Candidates that were not promoted are not facts and contribute nothing.
    public static func transactions(in snapshot: CandidateProcessingSnapshot) -> [TransactionMarker] {
        transactions(in: snapshot.ledger, details: details(from: snapshot))
    }

    public static func details(from snapshot: CandidateProcessingSnapshot) -> EntryDetails {
        var details = EntryDetails()
        for stored in snapshot.candidates.values {
            guard let entryID = stored.promotedEntryID, let draft = stored.candidate.sourceDraft else { continue }
            if let title = title(of: draft.counterparty) { details.titles[entryID] = title }
            details.timePrecisions[entryID] = timePrecision(of: draft.occurredAt)
        }
        return details
    }

    /// A time is exact only when the notification text itself states it to the minute or second. A day-only time,
    /// or a fallback to when the notification arrived or was captured, says when the app learned of the payment.
    public static func timePrecision(of timestamp: ObservedTimestamp) -> TimePrecision {
        switch (timestamp.source, timestamp.precision) {
        case (.text, .second), (.text, .minute): return .exact
        default: return .approximate
        }
    }

    private static func title(of counterparty: DraftCounterparty) -> String? {
        [counterparty.merchantRaw, counterparty.payeeRaw, counterparty.memoRaw]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
