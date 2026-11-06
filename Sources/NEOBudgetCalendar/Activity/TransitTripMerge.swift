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
    ///   - noChargeTaps: times of `Card Read … no charge` notices. They come at an alighting or a transfer, never at a boarding, so the trip is
    ///     still going: a tap keeps the trip open for another `gap`, and the surcharge at the very end (a long transfer ride) still joins it.
    // shortcut: a cheaper second boarding right after a dearer one (3,000 bus, then 1,550 subway) still merges, upgrade with learned base fares.
    public static func trips(
        in markers: [TransactionMarker], accountOf: (LedgerEntryID) -> String?, isTransit: (TransactionMarker) -> Bool,
        noChargeTaps: [Int64] = []
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
                   marker.occurredAtUnixMilliseconds - latestActivity(after: last.occurredAtUnixMilliseconds, before: marker.occurredAtUnixMilliseconds, taps: noChargeTaps) <= gap,
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

    /// The last moment of the trip before `end`: its last charge, or a later no-charge tap.
    private static func latestActivity(after start: Int64, before end: Int64, taps: [Int64]) -> Int64 {
        taps.filter { $0 > start && $0 <= end }.max() ?? start
    }
}

/// How a trip reads in a list: the group is called by its vehicle (지하철, 버스), the first charge is the 승차, every later one and every no-charge
/// tap inside the trip is a 하차 (a ₩0 하차 when nothing was charged). Display only: no-charge taps are not ledger entries.
public struct TransitTripLine: Equatable, Sendable {
    public enum Kind: String, Sendable { case boarding = "승차", alighting = "하차" }
    public let kind: Kind
    public let atUnixMilliseconds: Int64
    public let minorUnits: Int64
    /// The charge's ledger entry; `nil` for a no-charge tap.
    public let entryID: LedgerEntryID?

    public static func lines(of trip: [TransactionMarker], noChargeTaps: [Int64]) -> [TransitTripLine] {
        guard let first = trip.first, let last = trip.last else { return [] }
        let charges = trip.enumerated().map { TransitTripLine(kind: $0.offset == 0 ? .boarding : .alighting, atUnixMilliseconds: $0.element.occurredAtUnixMilliseconds, minorUnits: $0.element.amount.minorUnits, entryID: $0.element.id) }
        // A tap belongs to the trip when it lies between the boarding and the end of the trip's last charge's gap; the same instant as a charge is that charge.
        let chargeTimes = Set(trip.map(\.occurredAtUnixMilliseconds))
        let taps = noChargeTaps.filter { $0 > first.occurredAtUnixMilliseconds && $0 <= last.occurredAtUnixMilliseconds && !chargeTimes.contains($0) }
            .map { TransitTripLine(kind: .alighting, atUnixMilliseconds: $0, minorUnits: 0, entryID: nil) }
        return (charges + taps).sorted { $0.atUnixMilliseconds < $1.atUnixMilliseconds }
    }
}

public enum TransitMode {
    /// 지하철 for Metro/subway, 버스 for Bus, otherwise 교통 (the card's own word for the vehicle is in the charge's name).
    public static func groupName(for titles: [String?]) -> String {
        let text = titles.compactMap { $0 }.joined(separator: " ").lowercased()
        if text.contains("metro") || text.contains("subway") || text.contains("지하철") { return "지하철" }
        if text.contains("bus") || text.contains("버스") { return "버스" }
        return "교통"
    }
}
