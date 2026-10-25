import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)

/// Synthetic purchase and people: no real merchant, person or amount.
private func purchase(_ id: String, won: Int64, title: String = "테스트 저녁") throws -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: 1_140),
        amount: try Money(minorUnits: won, currency: "KRW"), flow: .spend, title: title
    )
}

@Test func receivablesStillOpenAreTakenOutOfMyShareButShownAsWaiting() throws {
    // 60,000 dinner, two friends asked for 20,000 each; one has paid.
    let dinner = try purchase("dinner", won: 60_000)
    let owes = { (id: String, who: String) in
        Obligation(
            id: ObligationID(rawValue: id), counterpartyID: PersonID(rawValue: who), direction: .receivable,
            amount: try AmountEntry(currency: "KRW", knowledge: .exact(20_000), provenance: provenance), provenance: provenance,
            createdAtUnixMilliseconds: 1, originTransactionID: dinner.id)
    }
    let life = try LifeState.empty.applying([
        .upsertPerson(Person(id: PersonID(rawValue: "min"), displayName: "테스트민")), .upsertPerson(Person(id: PersonID(rawValue: "ji"), displayName: "테스트지")),
        .createObligation(try owes("o1", "min")), .createObligation(try owes("o2", "ji")),
    ])
    let entries = LedgerList.sections([dinner], life: life, zone: zone).flatMap(\.entries)
    let rows = AnalysisInput.transactions(entries, life: life, zone: zone)
    #expect(rows.count == 1)
    #expect(rows[0].shareMinorUnits == 20_000 && rows[0].pendingMinorUnits == 40_000)     // nothing received yet: 40,000 waiting
    #expect(rows[0].date == day)
}

@Test func tagsComeFromTheUsersEditAndOnlyThoseForNow() throws {
    let dinner = try purchase("dinner", won: 10_000)
    var edit = TransactionOverride()
    edit.tags = ["데이트"]
    edit.category = CanonicalCategoryID(rawValue: "food")
    let entry = LedgerList.entry(dinner, life: .empty, override: edit)
    let row = try #require(AnalysisInput.transactions([entry], life: .empty, zone: zone).first)
    #expect(row.tags == ["데이트"] && row.category?.rawValue == "food" && row.pendingMinorUnits == 0 && row.activity == nil)
}

@Test func aConfirmedRecurringSeriesMarksMatchingPurchases() throws {
    let rows = try (0..<4).map { i -> TransactionMarker in
        TransactionMarker(
            id: LedgerEntryID(rawValue: "n\(i)"), occurredAtUnixMilliseconds: zone.instant(of: day.adding(days: 30 * i), minuteOfDay: 600),
            amount: try Money(minorUnits: 17_000, currency: "KRW"), flow: .spend, title: "테스트구독")
    }
    let entries = rows.map { LedgerList.entry($0, life: .empty) }
    let found = RecurringDetector.suggestions(AnalysisInput.recurringInputs(entries, zone: zone))
    #expect(found.count == 1 && found[0].cycle == .monthly)
    var decisions = RecurringDecisions()
    decisions.confirm(found[0])
    #expect(AnalysisInput.transactions(entries, life: .empty, zone: zone, recurring: decisions).allSatisfy { $0.isRecurring })
    #expect(AnalysisInput.transactions(entries, life: .empty, zone: zone).allSatisfy { !$0.isRecurring })
}
