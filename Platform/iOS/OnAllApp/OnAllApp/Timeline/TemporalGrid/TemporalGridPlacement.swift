import CoreGraphics
import NEOBudgetCalendar

/// The part of a day's drawing that does not depend on where time is on screen: which events and independent transactions there are, at
/// what real minutes, with how many transactions inside. Built once when the day's content changes. Nothing here ever changes with a
/// partition, a zoom, a progress or a frame.
struct GridDayEntities: Equatable, Sendable {
    struct Event: Equatable, Sendable {
        let id: String
        let title: String
        /// The real start and end, never moved. An event with no length stays zero long.
        let startMinute: Int
        let endMinute: Int
        let insideCount: Int
        /// How the event lies on others (the engine's own analysis, once per day): 0 or 1 step in from the left, and pulled in on the right
        /// when wholly inside another. Never a lane of its own.
        var indent = 0
        var pullsInOnRight = false
        var groupSize = 1
    }
    struct Transaction: Equatable, Sendable {
        let id: String
        let minute: Int
        /// Linked to an event and inside its time: drawn in the event, not on a line of its own.
        let isInsideEvent: Bool
        let eventID: String?
        /// The transaction's own amount, as the ledger counts it (nil: not settled).
        var minorUnits: Int64? = nil
    }

    let day: LocalDate
    let events: [Event]
    /// Every transaction of the day in time order: independent ones, linked ones outside their event's time, and those inside events.
    let transactions: [Transaction]
    var independentTransactions: [Transaction] { transactions.filter { !$0.isInsideEvent } }

    static func make(_ day: AllocationDay) -> GridDayEntities {
        let analysed = EventOverlapAnalysis.analyse(day.events.sorted { ($0.startMinute, -$0.endMinute, $0.id) < ($1.startMinute, -$1.endMinute, $1.id) })
        let events = day.events
            .map { event -> Event in
                let overlap = analysed[event.id]
                return Event(
                    id: event.id, title: event.title, startMinute: event.startMinute, endMinute: event.endMinute, insideCount: event.insideRange.count,
                    indent: overlap?.indent ?? 0, pullsInOnRight: overlap?.pullsInOnRight ?? false, groupSize: overlap?.groupSize ?? 1
                )
            }
            .sorted { ($0.startMinute, $0.endMinute, $0.id) < ($1.startMinute, $1.endMinute, $1.id) }
        var transactions: [Transaction] = []
        for event in day.events {
            for transaction in event.linked where transaction.dayOffset == 0 {
                transactions.append(Transaction(id: transaction.id, minute: transaction.minute, isInsideEvent: event.contains(transaction), eventID: event.id, minorUnits: transaction.minorUnits))
            }
        }
        for transaction in day.transactions where transaction.dayOffset == 0 {
            transactions.append(Transaction(id: transaction.id, minute: transaction.minute, isInsideEvent: false, eventID: nil, minorUnits: transaction.minorUnits))
        }
        transactions.sort { ($0.minute, $0.id) < ($1.minute, $1.id) }
        return GridDayEntities(day: day.day, events: events, transactions: transactions)
    }
}

struct GridEventPlacement: Equatable {
    let id: String
    let startMinute: Int
    let endMinute: Int
    /// From the y of the real start and end: the axis' own answer, with no minimum added for text.
    let top: CGFloat
    let bottom: CGFloat
    var height: CGFloat { bottom - top }
    /// `EventPresentation` of that height, nothing else.
    let presentation: EventPresentation
}

struct GridTransactionPlacement: Equatable {
    let id: String
    let minute: Int
    let y: CGFloat
    /// The distance to the nearest neighbouring independent transaction (infinite when there is none).
    let room: CGFloat
    /// 0 ... 1: how much of its text there is room for. The dot at the time is always there.
    let reveal: CGFloat
    let isInsideEvent: Bool
    var eventID: String? = nil
    var minorUnits: Int64? = nil
    var textShown: Bool { reveal >= 1 }
}

struct GridDayPlacement: Equatable {
    let events: [GridEventPlacement]
    let transactions: [GridTransactionPlacement]

    var independent: [GridTransactionPlacement] { transactions.filter { !$0.isInsideEvent } }
    var titlesShown: Int { events.filter { $0.presentation.title >= 1 }.count }
    var linesOnly: Int { events.filter { $0.presentation.level == .line }.count }
    var slivers: Int { events.filter { $0.presentation.level == .sliver }.count }
    var transactionTextShown: Int { independent.filter(\.textShown).count }
    /// Of the independent transactions, the part whose text is not fully there.
    var hiddenTransactionRatio: Double {
        let items = independent
        return items.isEmpty ? 0 : Double(items.filter { !$0.textShown }.count) / Double(items.count)
    }
}

/// The dynamic half: given where time is (`y`), where everything goes and what each thing can show. Cheap (one pass over the day's items), and
/// it does no overlap analysis and no text measuring; it is what runs per frame.
enum GridPlacement {
    static func place(_ entities: GridDayEntities, y: (Double) -> CGFloat, metrics: EventPresentation.Metrics, transactionPitch: CGFloat) -> GridDayPlacement {
        let events = entities.events.map { event -> GridEventPlacement in
            let top = y(Double(event.startMinute)), bottom = y(Double(event.endMinute))
            return GridEventPlacement(
                id: event.id, startMinute: event.startMinute, endMinute: event.endMinute, top: top, bottom: bottom,
                presentation: EventPresentation.make(height: bottom - top, insideCount: event.insideCount, metrics: metrics)
            )
        }
        let independent = entities.transactions.filter { !$0.isInsideEvent }
        let ys = independent.map { y(Double($0.minute)) }
        var placements: [GridTransactionPlacement] = []
        var index = 0
        for transaction in entities.transactions {
            if transaction.isInsideEvent {
                placements.append(GridTransactionPlacement(id: transaction.id, minute: transaction.minute, y: y(Double(transaction.minute)), room: .infinity, reveal: 1, isInsideEvent: true, eventID: transaction.eventID, minorUnits: transaction.minorUnits))
                continue
            }
            let here = ys[index]
            let before = index > 0 ? here - ys[index - 1] : .infinity
            let after = index + 1 < ys.count ? ys[index + 1] - here : .infinity
            let room = min(before, after)
            placements.append(GridTransactionPlacement(
                id: transaction.id, minute: transaction.minute, y: here, room: room,
                reveal: transactionPitch > 0 ? min(1, max(0, room / transactionPitch)) : 1, isInsideEvent: false,
                eventID: transaction.eventID, minorUnits: transaction.minorUnits
            ))
            index += 1
        }
        return GridDayPlacement(events: events, transactions: placements)
    }

    static func place(_ entities: GridDayEntities, partition: TemporalGridPartition, metrics: EventPresentation.Metrics, transactionPitch: CGFloat) -> GridDayPlacement {
        place(entities, y: { partition.timeToY($0) }, metrics: metrics, transactionPitch: transactionPitch)
    }

    static func transactionPitch(_ allocation: AllocationParameters, textScale: CGFloat) -> CGFloat {
        (allocation.transactionRow + allocation.lineGap) * max(0.5, textScale)
    }
}
