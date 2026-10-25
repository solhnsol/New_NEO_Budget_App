import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()

private func marker(_ id: String, minute: Int, won: Int64) throws -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: minute),
        amount: try Money(minorUnits: won, currency: "KRW"), flow: .spend, title: "테스트 \(id)"
    )
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

@Test func aTypedInTransactionIsListedBesideTheLedgerAndSurvivesSaving() throws {
    var store = TransactionOverrideStore()
    store.manual.append(.init(id: ManualTransaction.idPrefix + "1", title: "현금 점심", amount: 8_000, isRefund: false, occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: 700)))
    let decoded = try JSONDecoder().decode(TransactionOverrideStore.self, from: JSONEncoder().encode(store))
    #expect(decoded == store)
    let markers = decoded.manualMarkers
    #expect(markers.map(\.title) == ["현금 점심"])
    #expect(markers.first?.timePrecision == .exact)
    #expect(LedgerList.sections(markers, life: .empty, zone: zone).first?.totals == [LedgerTotal(currency: "KRW", minorUnits: 8_000)])
    // A file saved before typed-in transactions existed still reads.
    let old = try JSONDecoder().decode(TransactionOverrideStore.self, from: Data(#"{"byTransaction":{}}"#.utf8))
    #expect(old.manual.isEmpty)
}

@Test func tagCountsListMostUsedFirstThenByName() {
    var store = TransactionOverrideStore()
    store[LedgerEntryID(rawValue: "a")] = TransactionOverride(tags: ["모임", "데이트"])
    store[LedgerEntryID(rawValue: "b")] = TransactionOverride(tags: ["모임"])
    let counts = AppModel.tagCounts(store)
    #expect(counts.map(\.name) == ["모임", "데이트"] && counts.map(\.count) == [2, 1])
}
