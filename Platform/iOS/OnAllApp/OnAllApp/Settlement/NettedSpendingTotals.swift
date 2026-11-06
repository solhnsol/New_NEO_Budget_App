import NEOBudgetCalendar

/// Netted payables (`LifeState.nettedSpending`) as extra spending on the day they were netted, and for a month. Display only: the ledger list,
/// the account statements and card usage never include these.
enum NettedSpendingTotals {
    static func byDay(_ items: [NettedSpending], zone: DisplayTimeZone) -> [LocalDate: [String: Int64]] {
        var sums: [LocalDate: [String: Int64]] = [:]
        for item in items { sums[zone.localDate(of: item.atUnixMilliseconds), default: [:]][item.currency, default: 0] += item.minorUnits }
        return sums
    }

    static func month(_ items: [NettedSpending], year: Int, month: Int, zone: DisplayTimeZone) -> [String: Int64] {
        var sums: [String: Int64] = [:]
        for item in items {
            let day = zone.localDate(of: item.atUnixMilliseconds)
            if day.year == year && day.month == month { sums[item.currency, default: 0] += item.minorUnits }
        }
        return sums
    }

    /// The ledger day header's totals with the day's netted spending added (a currency only netted still gets a total).
    static func adding(_ extra: [String: Int64], to totals: [LedgerTotal]) -> [LedgerTotal] {
        var sums = Dictionary(uniqueKeysWithValues: totals.map { ($0.currency, $0.minorUnits) })
        for (currency, units) in extra { sums[currency, default: 0] += units }
        return sums.keys.sorted().map { LedgerTotal(currency: $0, minorUnits: sums[$0] ?? 0) }
    }
}
