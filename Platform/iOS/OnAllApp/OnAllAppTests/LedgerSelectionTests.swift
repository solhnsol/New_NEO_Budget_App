import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private func entry(_ id: String) throws -> LedgerListEntry {
    LedgerListEntry(
        transaction: TransactionMarker(
            id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: 0, amount: try Money(minorUnits: 1_000, currency: "KRW"), flow: .spend, title: id
        ),
        portions: []
    )
}

@Test func longPressStartsSelectionAndTapsToggle() {
    var selection = LedgerSelection()
    let a = LedgerEntryID(rawValue: "a"), b = LedgerEntryID(rawValue: "b")
    selection.begin(with: a)
    #expect(selection.isActive && selection.ids == [a])
    selection.toggle(b)
    #expect(selection.ids == [a, b])
    selection.toggle(a)
    selection.toggle(b)
    #expect(!selection.isActive && selection.ids.isEmpty)
}

@Test func neighboursShareOneBox() throws {
    let entries = [try entry("a"), try entry("b"), try entry("c")]
    var selection = LedgerSelection()
    selection.begin(with: entries[0].id)
    selection.toggle(entries[1].id)
    #expect(selection.joins(in: entries, at: 0) == (false, true))
    #expect(selection.joins(in: entries, at: 1) == (true, false))
}
