import NEOBudgetCore

/// What came back, or was asked of someone, for a purchase (a settlement deposit, a refund, a surplus, a pending request) comes off the amount
/// the calendar shows: the user's own share. Display only; the ledger and the life state are untouched. `reductions` maps a purchase to the
/// minor units to take off (always in the purchase's own currency).
extension DayTimeline {
    public func reducingSpend(by reductions: [LedgerEntryID: Int64]) -> DayTimeline {
        guard !reductions.isEmpty else { return self }
        func reduced(_ money: Money, _ id: LedgerEntryID) -> Money {
            let off = reductions[id] ?? 0
            guard off > 0, let next = try? Money(minorUnits: max(0, money.minorUnits - off), currency: money.currency) else { return money }
            return next
        }
        // Only an amount that was the whole purchase moves with it; a part given to an event stays as it was.
        func knowledge(_ value: AmountKnowledge, whole: Money, _ id: LedgerEntryID) -> AmountKnowledge {
            if case let .exact(units) = value, units == whole.minorUnits { return .exact(reduced(whole, id).minorUnits) }
            return value
        }
        func items(_ list: [AllocationItem]) -> [AllocationItem] {
            list.map { item in
                guard item.flow == .spend, reductions[item.transactionID] != nil else { return item }
                var item = item
                item.allocatedAmount = knowledge(item.allocatedAmount, whole: item.transactionAmount, item.transactionID)
                item.transactionAmount = reduced(item.transactionAmount, item.transactionID)
                return item
            }
        }
        func aggregates(_ list: [AllocationItem]) -> [AmountAggregate] {
            AmountAggregate.summarize(list.filter { $0.flow == .spend }.map { ($0.transactionAmount.currency, $0.allocatedAmount) })
        }
        var result = self
        var linkedIDs = Set<LedgerEntryID>()
        for i in result.blocks.indices {
            result.blocks[i].allocations.forEach { linkedIDs.insert($0.transactionID) }
            result.blocks[i].allocations = items(result.blocks[i].allocations)
            result.blocks[i].allocatedSpend = aggregates(result.blocks[i].allocations)
        }
        for i in result.allDay.indices {
            result.allDay[i].allocations.forEach { linkedIDs.insert($0.transactionID) }
            result.allDay[i].allocations = items(result.allDay[i].allocations)
            result.allDay[i].allocatedSpend = aggregates(result.allDay[i].allocations)
        }
        var seen = Set<LedgerEntryID>()
        var taken: [String: (linked: Int64, unlinked: Int64)] = [:]
        func take(_ id: LedgerEntryID, currency: String, linked: Bool) {
            guard seen.insert(id).inserted, let off = reductions[id], off > 0 else { return }
            if linked { taken[currency, default: (0, 0)].linked += off } else { taken[currency, default: (0, 0)].unlinked += off }
        }
        for i in result.markers.indices {
            let marker = result.markers[i]
            guard marker.flow == .spend else { continue }
            let hasActivity = marker.allocations.contains { $0.activityID != nil }
            take(marker.transactionID, currency: marker.amount.currency, linked: hasActivity)
            guard reductions[marker.transactionID] != nil else { continue }
            result.markers[i].allocations = marker.allocations.map { part in
                var part = part
                part.amount = knowledge(part.amount, whole: marker.amount, marker.transactionID)
                return part
            }
            result.markers[i].amount = reduced(marker.amount, marker.transactionID)
        }
        for id in linkedIDs {
            guard let item = (blocks.flatMap(\.allocations) + allDay.flatMap(\.allocations)).first(where: { $0.transactionID == id && $0.flow == .spend }) else { continue }
            take(id, currency: item.transactionAmount.currency, linked: true)
        }
        for i in result.summary.totals.indices {
            let currency = result.summary.totals[i].currency
            result.summary.totals[i].linkedNetMinorUnits -= taken[currency]?.linked ?? 0
            result.summary.totals[i].unlinkedNetMinorUnits -= taken[currency]?.unlinked ?? 0
        }
        return result
    }
}

extension LifeState {
    /// The deposits that paid someone's share back. They belong to the purchase they settled, so the calendar and lists never show them as income.
    public var settledDepositIDs: Set<LedgerEntryID> {
        Set(settlements.values.filter { $0.transfer.direction == .incoming }.flatMap(\.transfer.coveredTransactionIDs))
    }
}
