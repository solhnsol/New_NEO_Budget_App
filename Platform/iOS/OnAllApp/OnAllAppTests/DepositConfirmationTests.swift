import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryCalendar
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)

/// Synthetic: a 60,000 dinner, a friend asked for 30,000 of it, and a deposit of `won` from "테스트 별명".
private struct Scene {
    let service: CalendarCommandService
    let dinner: TransactionMarker
    let obligationID: ObligationID
    let friend: PersonID

    init(asking: Int64 = 30_000) async throws {
        dinner = TransactionMarker(
            id: LedgerEntryID(rawValue: "dinner"), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: 1_140),
            amount: try Money(minorUnits: 60_000, currency: "KRW"), flow: .spend, title: "테스트 저녁"
        )
        let counter = Counter()
        service = CalendarCommandService(
            provider: InMemoryCalendarProvider(calendars: [], events: []), repository: InMemoryLifeRepository(initialState: .empty),
            transactions: InMemoryTransactionSource([dinner]), configuration: CalendarServiceConfiguration(displayTimeZone: zone),
            makeID: { "\($0.rawValue)-\(counter.next())" }, now: { 2 }
        )
        let person = Person(id: PersonID(rawValue: "friend"), displayName: "테스트 친구")
        _ = await service.perform(.upsertPerson(person))
        friend = person.id
        let created = await service.perform(.createObligation(CreateObligationInput(
            counterpartyID: person.id, direction: .receivable, currency: "KRW", amount: .exact(asking), originTransactionID: dinner.id,
            label: SettlementLabel.request, provenance: provenance
        )))
        guard case let .applied(applied) = created, let id = applied.obligationID else { throw Failure() }
        obligationID = id
    }

    struct Failure: Error {}
    final class Counter: @unchecked Sendable { var value = 0; func next() -> Int { value += 1; return value } }

    func deposit(_ won: Int64, title: String? = "테스트 별명") throws -> LedgerDeposit {
        LedgerDeposit(
            id: LedgerEntryID(rawValue: "d\(won)"), occurredAtUnixMilliseconds: zone.instant(of: day.adding(days: 1), minuteOfDay: 600),
            amount: try Money(minorUnits: won, currency: "KRW"), title: title
        )
    }

    func confirm(_ won: Int64, _ choice: DepositConfirmation.ShortChoice = .keepOpen, alias: Bool = false) async throws -> LifeState {
        var life = try await service.lifeSnapshot().state
        let obligation = try #require(life.obligations[obligationID])
        let done = await DepositConfirmation.apply(try deposit(won), to: obligation, life: life, shortChoice: choice, rememberAlias: alias, provenance: provenance) {
            await service.perform($0)
        }
        #expect(done)
        life = try await service.lifeSnapshot().state
        return life
    }
}

@Test func anOpenRequestShowsAsPendingOnItsPurchaseAndLeavesTheNet() async throws {
    let scene = try await Scene()
    let life = try await scene.service.lifeSnapshot().state
    let entry = try #require(LedgerList.sections([scene.dinner], life: life, zone: zone).first?.entries.first)
    #expect(entry.offsets.map(\.kind) == [.pending(from: "테스트 친구")])
    #expect(entry.isWaitingForSettlement)
    #expect(entry.netMinorUnits == 30_000)
}

@Test func whenTheMoneyComesInThePendingTurnsIntoASettlement() async throws {
    let scene = try await Scene()
    let life = try await scene.confirm(30_000)
    let entry = try #require(LedgerList.sections([scene.dinner], life: life, zone: zone).first?.entries.first)
    #expect(entry.offsets.map(\.kind) == [.settlement(from: "테스트 친구")])
    #expect(!entry.isWaitingForSettlement)
    #expect(entry.netMinorUnits == 30_000)
}

@Test func aShortDepositLeavesTheRestPendingUnlessTheUserClosesIt() async throws {
    let open = try await Scene()
    let keptOpen = try await open.confirm(20_000)
    let openEntry = try #require(LedgerList.sections([open.dinner], life: keptOpen, zone: zone).first?.entries.first)
    #expect(openEntry.isWaitingForSettlement)
    #expect(openEntry.netMinorUnits == 30_000)       // 20,000 received + 10,000 still pending

    let closed = try await Scene()
    let waived = try await closed.confirm(20_000, .close)
    let closedEntry = try #require(LedgerList.sections([closed.dinner], life: waived, zone: zone).first?.entries.first)
    #expect(!closedEntry.isWaitingForSettlement)
    #expect(closedEntry.netMinorUnits == 40_000)      // the forgiven 10,000 stays in my share
}

@Test func fitSaysWhatTheDepositDoesToTheRequest() async throws {
    let scene = try await Scene()
    let life = try await scene.service.lifeSnapshot().state
    let obligation = try #require(life.obligations[scene.obligationID])
    #expect(DepositConfirmation.fit(try scene.deposit(30_000), obligation, in: life) == .exact)
    #expect(DepositConfirmation.fit(try scene.deposit(20_000), obligation, in: life) == .short(leftMinorUnits: 10_000))
    #expect(DepositConfirmation.fit(try scene.deposit(35_000), obligation, in: life) == .over(extraMinorUnits: 5_000))
}

@Test func anOverDepositKeepsTheExcessOutOfThePurchase() async throws {
    let scene = try await Scene()
    let life = try await scene.confirm(35_000)
    let entry = try #require(LedgerList.sections([scene.dinner], life: life, zone: zone).first?.entries.first)
    #expect(entry.netMinorUnits == 30_000)
    #expect(life.residuals.values.map(\.direction) == [.surplus])
}

@Test func anAliasIsRememberedOnlyWhenTheUserSaysSo() async throws {
    let scene = try await Scene()
    let before = try await scene.service.lifeSnapshot().state
    let person = try #require(before.persons[scene.friend])
    #expect(DepositConfirmation.isNewAlias(try scene.deposit(30_000), for: person))
    let kept = try await scene.confirm(30_000)
    #expect(kept.persons[scene.friend]?.aliases.isEmpty == true)

    let yes = try await Scene()
    let remembered = try await yes.confirm(30_000, alias: true)
    #expect(remembered.persons[yes.friend]?.matches(name: "테스트 별명") == true)
}

@Test func theSettingTakesTheExcessOffThePurchaseInsteadOfMakingIncome() async throws {
    let scene = try await Scene()
    let life = try await scene.confirm(35_000)
    let entry = try #require(LedgerList.sections([scene.dinner], life: life, zone: zone, surplus: .reduceSpending).first?.entries.first)
    #expect(entry.offsets.map(\.kind) == [.settlement(from: "테스트 친구"), .surplus(from: "테스트 친구")])
    #expect(entry.netMinorUnits == 25_000)                                    // 60,000 − 30,000 owed − 5,000 extra
    #expect(life.surplusIncomeMinorUnits(currency: "KRW", treatment: .reduceSpending) == 0)
    #expect(life.surplusIncomeMinorUnits(currency: "KRW") == 5_000)
}
