import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)

/// Synthetic transaction: no real merchant, card or amount.
private func marker(_ id: String, on date: LocalDate = day, minute: Int, won: Int64, flow: TransactionFlow = .spend) throws -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: date, minuteOfDay: minute),
        amount: try Money(minorUnits: won, currency: "KRW"), flow: flow, title: "테스트 \(id)"
    )
}

@Test func groupsByDayNewestFirst() throws {
    let previous = day.adding(days: -1)
    let markers = [
        try marker("a", on: previous, minute: 600, won: 1_000),
        try marker("b", minute: 540, won: 2_000),
        try marker("c", minute: 1_200, won: 3_000),
    ]
    let sections = LedgerList.sections(markers, life: .empty, zone: zone)
    #expect(sections.map(\.day) == [day, previous])
    #expect(sections[0].entries.map(\.id.rawValue) == ["c", "b"])
    #expect(sections[1].entries.map(\.id.rawValue) == ["a"])
}

@Test func dayTotalIsNetOfRefunds() throws {
    let markers = [try marker("s", minute: 600, won: 10_000), try marker("r", minute: 700, won: 4_000, flow: .refund)]
    let sections = LedgerList.sections(markers, life: .empty, zone: zone)
    #expect(sections[0].totals == [LedgerTotal(currency: "KRW", minorUnits: 6_000)])
}

@Test func entryCarriesItsActivities() throws {
    let transaction = try marker("t", minute: 720, won: 12_000)
    let range = try TimedRange(
        startUnixMilliseconds: zone.instant(of: day, minuteOfDay: 700), endUnixMilliseconds: zone.instant(of: day, minuteOfDay: 780)
    )
    let event = CalendarEvent(id: CalendarEventID(rawValue: "e"), calendarID: CalendarID(rawValue: "c"), title: "점심", time: .timed(range), revisionToken: "r")
    let activityID = ActivityID(rawValue: "A")
    let life = try LifeState.empty.applying([
        .createActivity(Activity.materialized(from: event, id: activityID, at: 1)),
        .upsertAllocation(
            TransactionAllocation(
                id: AllocationID(rawValue: "alloc"), transactionID: transaction.id, activityID: activityID,
                amount: try AmountEntry(currency: "KRW", knowledge: .exact(12_000), provenance: provenance),
                provenance: provenance, createdAtUnixMilliseconds: 1),
            transactionTotal: transaction.amount, flow: .spend),
    ])
    let entry = LedgerList.entry(transaction, life: life)
    #expect(entry.activityTitles == ["점심"])
    #expect(entry.portions.map(\.amount) == [.exact(12_000)])
}

@Test func unlinkedEntryHasNoPortions() throws {
    let entry = LedgerList.entry(try marker("u", minute: 60, won: 500), life: .empty)
    #expect(entry.portions.isEmpty)
    #expect(entry.categoryID == nil)
}
