import Testing
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryStorage

/// Made-up rows in the shape Actual Budget exports: one dinner on a card, paid back by a deposit Actual split in two.
private func history() -> ImportedHistory {
    func row(_ id: String, _ date: String, _ account: String, _ amount: Int64, payee: String, notes: String? = nil) -> ImportedTransaction {
        ImportedTransaction(id: id, date: date, account: account, amount: amount, payee: payee, category: "🍜 식비", notes: notes)
    }
    return ImportedHistory(
        through: "2026-10-19",
        accounts: [ImportedAccount(name: "생활비", kind: .bank), ImportedAccount(name: "카드", kind: .card)],
        transactions: [
            row("e1", "2026-10-06", "카드", -60_000, payee: "식당가"),
            row("e2", "2026-10-06", "카드", -10_000, payee: "카페나"),
            row("c1", "2026-10-07", "생활비", 20_000, payee: "식당가", notes: "#정산 입금 · 원거래 e1 · 입금거래 dep1"),
            row("c2", "2026-10-07", "생활비", 10_000, payee: "카페나", notes: "#정산 입금 · 원거래 e2 · 입금거래 dep1"),
        ]
    )
}

@Test func importedSettlementsBecomeReceivablesPaidByTheDeposit() throws {
    let plan = try ActualImportPlanner.plan(history())
    let life = try ImportedSettlementSeed.life(from: plan, at: 1_000)

    #expect(life.persons[ImportedSettlementSeed.unnamedPersonID]?.displayName == "이름 없는 사람")
    #expect(life.obligations.count == 2)
    #expect(life.settlements.count == 1)
    let settlement = try #require(life.settlements.values.first)
    #expect(settlement.transfer.coveredTransactionIDs == [ActualImportPlanner.entryID(forRow: "dep1")])
    #expect(settlement.transfer.amount.minorUnits == 30_000)

    let dinner = try #require(life.obligations.values.first { $0.originTransactionID == ActualImportPlanner.entryID(forRow: "e1") })
    #expect(dinner.direction == .receivable)
    #expect(dinner.status == .settled)
    #expect(life.closedMinorUnits(for: dinner.id) == 20_000)
    // The deposit is spent on nothing: it is a settlement transfer, so it can no longer be put on a purchase again.
    #expect(life.allocationSet(for: ActualImportPlanner.entryID(forRow: "dep1")) == nil)
}

@Test func theSeedIsDeterministicAndAnEmptyPlanLeavesLifeAlone() throws {
    let plan = try ActualImportPlanner.plan(history())
    #expect(try ImportedSettlementSeed.life(from: plan, at: 1) == ImportedSettlementSeed.life(from: plan, at: 1))
    let none = try ActualImportPlanner.plan(ImportedHistory(through: "2026-10-19", accounts: [], transactions: []))
    #expect(try ImportedSettlementSeed.life(from: none, at: 1) == .empty)
}

@Test func theSeedAppliesToTheLedgerTheReplayProduces() throws {
    let ledger = try IntakeLedger(notifications: [], setup: IntakeSetup(), intake: NotificationIntake(timeZoneIdentifier: "Asia/Seoul"), history: history())
    let snapshot = try ledger.repository.processingSnapshot()
    let plan = try #require(ledger.importPlan)
    let life = try ImportedSettlementSeed.life(from: plan, at: 1)
    // Every entry a settlement names exists in the ledger, with the real signs untouched.
    let ids = Set(snapshot.ledger.entries.map(\.id))
    for settlement in life.settlements.values { #expect(ids.isSuperset(of: settlement.transfer.coveredTransactionIDs)) }
    for obligation in life.obligations.values { #expect(obligation.originTransactionID.map(ids.contains) == true) }
    #expect(snapshot.ledger.outstandingLiabilities[ActualImportPlanner.instrumentID(named: "카드")]?.minorUnits == 70_000)
    #expect(snapshot.ledger.accountBalances[ActualImportPlanner.accountID(named: "생활비")]?.minorUnits == 30_000)
}
