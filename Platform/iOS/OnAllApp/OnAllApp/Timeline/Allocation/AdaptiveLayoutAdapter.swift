import NEOBudgetCalendar

/// Reads a `DayTimeline` (the calendar's read model) into the engine's input. It copies what the timeline already decided: which
/// transactions are linked to an event and which are not, and every amount as it is.
extension AllocationDay {
    init(_ timeline: DayTimeline) {
        func kind(_ flow: TransactionFlow) -> AmountKind {
            switch flow {
            case .spend: return .spend
            case .refund: return .refund
            }
        }
        func minute(_ instant: Int64) -> Int {
            min(max(Int((instant - timeline.dayStartUnixMilliseconds) / 60_000), 0), timeline.totalMinutes)
        }
        let events = timeline.blocks.map { block in
            AllocationEvent(
                id: block.id.rawValue, title: block.title, startMinute: block.displayStartMinute, endMinute: block.displayEndMinute,
                linked: block.allocations.map { item in
                    AllocationTransaction(
                        id: item.transactionID.rawValue, minute: minute(item.occurredAtUnixMilliseconds), kind: kind(item.flow),
                        currency: item.transactionAmount.currency, minorUnits: item.allocatedAmount.knownValue
                    )
                }
            )
        }
        let transactions = timeline.markers.map { marker in
            AllocationTransaction(
                id: marker.transactionID.rawValue, minute: marker.positionMinute, kind: kind(marker.flow),
                currency: marker.amount.currency, minorUnits: marker.amount.minorUnits,
                isPartlyLinked: marker.allocations.contains { $0.activityID != nil }
            )
        }
        self.init(day: timeline.day, totalMinutes: timeline.totalMinutes, events: events, transactions: transactions)
    }
}
