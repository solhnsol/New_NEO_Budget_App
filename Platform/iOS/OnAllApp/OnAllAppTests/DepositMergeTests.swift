import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryCalendar
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)

/// Synthetic purchase and deposit: no real merchant, person, account or amount.
private func purchase(_ id: String, won: Int64) throws -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: 1_140),
        amount: try Money(minorUnits: won, currency: "KRW"), flow: .spend, title: "테스트 저녁"
    )
}

private func deposit(_ id: String, won: Int64) throws -> LedgerDeposit {
    LedgerDeposit(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day.adding(days: 1), minuteOfDay: 600),
        amount: try Money(minorUnits: won, currency: "KRW"), title: "테스트 친구"
    )
}

@Test func onlyIncomeNoReversalOrSettlementExplainsIsUnclassified() throws {
    let account = AccountID(rawValue: "acct")
    let won = { (value: Int64) in try Money(minorUnits: value, currency: "KRW") }
    func income(_ id: String, _ value: Int64) throws -> LedgerEntry {
        LedgerEntry(id: LedgerEntryID(rawValue: id), kind: .income, occurredAtUnixMilliseconds: 1, postings: [Posting(accountID: account, delta: try won(value))])
    }
    let reversal = LedgerEntry(
        id: LedgerEntryID(rawValue: "undo"), kind: .reversal, occurredAtUnixMilliseconds: 2,
        postings: [Posting(accountID: account, delta: try won(-5_000))], reverses: LedgerEntryID(rawValue: "own-transfer")
    )
    let entries = [try income("friend", 30_000), try income("own-transfer", 5_000), reversal]
    let deposits = DepositMerge.unclassified(entries: entries, titles: [LedgerEntryID(rawValue: "friend"): "테스트 친구"], life: .empty)
    #expect(deposits.map(\.id.rawValue) == ["friend"])
    #expect(deposits.first?.title == "테스트 친구")
    #expect(deposits.first?.amount.minorUnits == 30_000)
}

@Test func aDepositLargerThanWhatThePurchaseStillCostsIsRefused() throws {
    let entry = LedgerList.entry(try purchase("dinner", won: 60_000), life: .empty)
    #expect(DepositMerge.plan(try deposit("d", won: 70_000), onto: entry, senderName: "테스트 친구", life: .empty) == .failure(.moreThanLeft(leftMinorUnits: 60_000)))
    let plan = try DepositMerge.plan(try deposit("d", won: 30_000), onto: entry, senderName: "테스트 친구", life: .empty).get()
    #expect(plan.personID == nil && plan.obligationID == nil && plan.activityID == nil)
}

@Test func applyingRecordsTheDepositAsASettlementOfThePurchase() async throws {
    let dinner = try purchase("dinner", won: 60_000)
    let service = CalendarCommandService(
        provider: InMemoryCalendarProvider(calendars: [], events: []),
        repository: InMemoryLifeRepository(initialState: .empty),
        transactions: InMemoryTransactionSource([dinner]),
        configuration: CalendarServiceConfiguration(displayTimeZone: zone),
        makeID: { "\($0.rawValue)-\(Int.random(in: 0..<Int.max))" },
        now: { 2 }
    )
    let incoming = try deposit("d", won: 30_000)
    let plan = try DepositMerge.plan(incoming, onto: LedgerList.entry(dinner, life: .empty), senderName: "테스트 친구", life: .empty).get()
    var counter = 0
    let applied = await DepositMerge.apply(plan, provenance: provenance, newID: { counter += 1; return "\($0)-\(counter)" }) { await service.perform($0) }
    #expect(applied)
    let life = try await service.lifeSnapshot().state
    #expect(life.persons.values.map(\.displayName) == ["테스트 친구"])
    #expect(life.settlements.values.first?.transfer.coveredTransactionIDs == [incoming.id])     // the deposit is no longer unclassified
    let shown = try #require(LedgerList.sections([dinner], life: life, zone: zone).first?.entries.first)
    #expect(shown.offsets.map(\.kind) == [.settlement(from: "테스트 친구")])
    #expect(shown.netMinorUnits == 30_000)
}
