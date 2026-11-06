import NEOBudgetCore

/// One boarding and the charges that followed it: the base fare at tap-in, then a distance surcharge at tap-out or a transfer
/// charge. Shown as one transaction at the boarding time; the ledger keeps every charge (`records/20261025-교통-승하차-합치기-설계.md`).
public struct TransitTrip: Equatable, Sendable {
    /// The boarding first, then what followed, in time order. Always two or more.
    public let legs: [LedgerEntryID]
    public var boarding: LedgerEntryID { legs[0] }
}

/// Finds trips among spending. A pure function over display values; it changes nothing.
///
/// A charge joins the open trip when all of these hold, and otherwise starts a new trip:
/// - it is on the same account, and no other spending of that account lies between (so two boardings with a coffee between stay apart);
/// - it comes within `gap` of the previous leg and within `span` of the boarding;
/// - its amount is below the boarding's. A surcharge is a fraction of the base fare; a second boarding pays a full fare again.
public enum TransitTripMerge {
    public static let gap: Int64 = 90 * 60_000
    public static let span: Int64 = 3 * 3_600_000

    /// - Parameters:
    ///   - accountOf: the account or card the entry was charged to; `nil` (unknown) never merges.
    ///   - isTransit: whether the spend is a transit charge.
    // shortcut: a cheaper second boarding right after a dearer one (3,000 bus, then 1,550 subway) still merges, upgrade with learned base fares.
    public static func trips(
        in markers: [TransactionMarker], accountOf: (LedgerEntryID) -> String?, isTransit: (TransactionMarker) -> Bool
    ) -> [TransitTrip] {
        var byAccount: [String: [TransactionMarker]] = [:]
        for marker in markers where marker.flow == .spend {
            if let account = accountOf(marker.id) { byAccount[account, default: []].append(marker) }
        }
        var trips: [TransitTrip] = []
        for account in byAccount.keys.sorted() {
            let spends = byAccount[account, default: []].sorted { ($0.occurredAtUnixMilliseconds, $0.id.rawValue) < ($1.occurredAtUnixMilliseconds, $1.id.rawValue) }
            var open: [TransactionMarker] = []
            func close() {
                if open.count > 1 { trips.append(TransitTrip(legs: open.map(\.id))) }
                open = []
            }
            for marker in spends {
                guard isTransit(marker) else { close(); continue }
                if let first = open.first, let last = open.last,
                   marker.amount.currency == first.amount.currency,
                   marker.occurredAtUnixMilliseconds - last.occurredAtUnixMilliseconds <= gap,
                   marker.occurredAtUnixMilliseconds - first.occurredAtUnixMilliseconds <= span,
                   marker.amount.minorUnits < first.amount.minorUnits {
                    open.append(marker)
                } else {
                    close()
                    open = [marker]
                }
            }
            close()
        }
        return trips
    }
}
