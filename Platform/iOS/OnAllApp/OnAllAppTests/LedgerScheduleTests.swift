import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)

private func marker(_ id: String, minute: Int, won: Int64) throws -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: minute),
        amount: try Money(minorUnits: won, currency: "KRW"), flow: .spend, title: "테스트 \(id)"
    )
}

@Test func activityTransactionsGatherIntoOneCardInDayOrder() throws {
    let inside = try marker("in", minute: 735, won: 12_000)
    let loose = try marker("loose", minute: 600, won: 3_000)
    let range = try TimedRange(
        startUnixMilliseconds: zone.instant(of: day, minuteOfDay: 700), endUnixMilliseconds: zone.instant(of: day, minuteOfDay: 780)
    )
    let event = CalendarEvent(id: CalendarEventID(rawValue: "e"), calendarID: CalendarID(rawValue: "c"), title: "점심", time: .timed(range), revisionToken: "r")
    let activityID = ActivityID(rawValue: "A")
    let life = try LifeState.empty.applying([
        .createActivity(Activity.materialized(from: event, id: activityID, at: 1)),
        .upsertAllocation(
            TransactionAllocation(
                id: AllocationID(rawValue: "alloc"), transactionID: inside.id, activityID: activityID,
                amount: try AmountEntry(currency: "KRW", knowledge: .exact(12_000), provenance: provenance),
                provenance: provenance, createdAtUnixMilliseconds: 1),
            transactionTotal: inside.amount, flow: .spend),
    ])
    let sections = LedgerList.sections([inside, loose], life: life, zone: zone)
    let items = LedgerSchedule.items(try #require(sections.first), zone: zone)
    #expect(items.map(\.id) == ["entry/loose", "activity/A"])
    guard case let .activity(group) = items[1] else { Issue.record("expected an activity card"); return }
    #expect(group.title == "점심")
    #expect(group.totalMinorUnits == 12_000)
    #expect(group.entries.map(\.id.rawValue) == ["in"])
}

@Test func compactAmountUsesTenThousands() {
    #expect(LedgerSchedule.compactAmount(49_000) == "4.9만")
    #expect(LedgerSchedule.compactAmount(72_000) == "7.2만")
    #expect(LedgerSchedule.compactAmount(1_990) == "1,990")
    #expect(LedgerSchedule.compactAmount(100_000) == "10만")
    #expect(LedgerSchedule.compactAmount(nil) == "-")
    #expect(LedgerSchedule.compactAmount(-3_000) == "+3,000")
}

@Test func overridesRenameRecategorizeAndTag() throws {
    let t = try marker("o", minute: 600, won: 5_000)
    let o = TransactionOverride(title: "점심", category: CanonicalCategoryID(rawValue: "food"), memo: nil, tags: TransactionOverride.parseTags("#데이트 모임, #데이트"))
    #expect(o.tags == ["데이트", "모임"])
    let sections = LedgerList.sections([t], life: .empty, zone: zone, overrides: [t.id: o])
    let entry = try #require(sections.first?.entries.first)
    #expect(entry.transaction.title == "점심")
    #expect(entry.categoryID?.rawValue == "food")
    var store = TransactionOverrideStore()
    store[t.id] = o
    store[t.id] = TransactionOverride()
    #expect(store.lookup.isEmpty)
}
