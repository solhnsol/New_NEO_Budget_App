import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private func key(_ id: String) -> CalendarEventKey { CalendarEventKey(calendarID: CalendarID(rawValue: "c"), eventID: CalendarEventID(rawValue: id)) }
private let lunch = FixedGridTransactionCarry.Card(eventKey: key("lunch"), title: "점심", frame: CGRect(x: 50, y: 100, width: 100, height: 60))
/// Drawn over `lunch` (later in the list: in front).
private let meeting = FixedGridTransactionCarry.Card(eventKey: key("meeting"), title: "회의", frame: CGRect(x: 100, y: 120, width: 80, height: 40))
private let cards = [lunch, meeting]

/// Synthetic transaction: no real merchant, card or amount.
private func carry(linkedTo event: CalendarEventKey? = nil, at point: CGPoint) throws -> FixedGridTransactionCarry {
    FixedGridTransactionCarry(
        transactionID: LedgerEntryID(rawValue: "t"), title: "테스트", amount: try Money(minorUnits: 9_000, currency: "KRW"), flow: .spend,
        linkedEvent: event, at: point, cards: cards
    )
}

@Test func putDownOnACardLinksToIt() throws {
    var carried = try carry(at: CGPoint(x: 10, y: 10))
    #expect(carried.outcome == .none)
    #expect(carried.move(to: CGPoint(x: 60, y: 110), cards: cards))
    #expect(carried.outcome == .link(LedgerEntryID(rawValue: "t"), key("lunch")))
}

@Test func theFrontCardWins() throws {
    let carried = try carry(at: CGPoint(x: 120, y: 130))
    #expect(carried.target?.eventKey == key("meeting"))
}

@Test func movingWithinOneCardIsNoStep() throws {
    var carried = try carry(at: CGPoint(x: 60, y: 110))
    #expect(!carried.move(to: CGPoint(x: 70, y: 150), cards: cards))
    #expect(carried.move(to: CGPoint(x: 10, y: 10), cards: cards))
    #expect(carried.outcome == .none)
}

@Test func backIntoItsOwnEventChangesNothing() throws {
    let carried = try carry(linkedTo: key("lunch"), at: CGPoint(x: 60, y: 110))
    #expect(carried.outcome == .none)
    #expect(!carried.willLink)
}
