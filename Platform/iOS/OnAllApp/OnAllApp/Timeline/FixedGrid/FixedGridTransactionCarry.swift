import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore

/// A transaction picked up by a long press on its line and carried by the finger (`docs/ledger-behavior.md`, 3). Put down on an event's card it belongs to
/// that event (a user allocation of the whole transaction: the timeline then draws it inside the card); put down anywhere else nothing changes. Which card
/// is under the finger is decided from the cards on screen, the front one first. Pure, so it is tested.
struct FixedGridTransactionCarry: Equatable {
    /// An event's card on screen, in grid coordinates.
    struct Card: Equatable {
        let eventKey: CalendarEventKey
        let title: String
        let frame: CGRect
    }

    enum Outcome: Equatable {
        case none
        /// Link the transaction to this event (the event it is in already, or none, is replaced).
        case link(LedgerEntryID, CalendarEventKey)
    }

    let transactionID: LedgerEntryID
    let title: String?
    let amount: Money
    let flow: TransactionFlow
    /// The event the transaction belongs to now, if any: putting it down there again changes nothing.
    let linkedEvent: CalendarEventKey?
    private(set) var finger: CGPoint
    /// The card it would go into if the finger lifted now.
    private(set) var target: Card?

    init(transactionID: LedgerEntryID, title: String?, amount: Money, flow: TransactionFlow, linkedEvent: CalendarEventKey?, at finger: CGPoint, cards: [Card]) {
        self.transactionID = transactionID
        self.title = title
        self.amount = amount
        self.flow = flow
        self.linkedEvent = linkedEvent
        self.finger = finger
        target = Self.card(at: finger, in: cards)
    }

    /// The finger moved. Returns whether the card under it changed (a haptic).
    @discardableResult
    mutating func move(to point: CGPoint, cards: [Card]) -> Bool {
        finger = point
        let found = Self.card(at: point, in: cards)
        guard found?.eventKey != target?.eventKey else { target = found; return false }
        target = found
        return true
    }

    /// What lifting the finger now does.
    var outcome: Outcome {
        guard let target, target.eventKey != linkedEvent else { return .none }
        return .link(transactionID, target.eventKey)
    }

    /// Whether lifting the finger now links the transaction somewhere.
    var willLink: Bool { if case .link = outcome { true } else { false } }

    /// The front card under `point` (`cards` are back to front).
    static func card(at point: CGPoint, in cards: [Card]) -> Card? {
        cards.last { $0.frame.contains(point) }
    }
}
