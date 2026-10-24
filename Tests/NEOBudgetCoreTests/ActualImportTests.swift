import Foundation
import Testing
@testable import NEOBudgetCore
import NEOBudgetInMemoryStorage

/// Every name, amount and id here is made up. The shapes follow what Actual Budget's `list_transactions` returns.
enum ActualFixture {
    static let through = "2026-10-19"

    static func row(
        _ id: String, _ date: String, _ account: String, _ amount: Int64, payee: String? = nil, category: String? = nil,
        notes: String? = nil, imported: String? = nil, transfer: String? = nil
    ) -> ImportedTransaction {
        ImportedTransaction(id: id, date: date, account: account, amount: amount, payee: payee, category: category, notes: notes, importedPayee: imported, transfer: transfer)
    }

    /// Balances are what Actual would show: the sum of every row, including the ones the ledger can only hold in review.
    static func history() -> ImportedHistory {
        ImportedHistory(
            through: through,
            accounts: [
                ImportedAccount(name: "급여통장", kind: .bank, balance: 835_000),
                ImportedAccount(name: "생활비", kind: .bank, balance: 160_001),
                ImportedAccount(name: "티머니", kind: .prepaid, balance: 14_000),
                ImportedAccount(name: "카카오페이", kind: .prepaid, balance: -38_266),
                ImportedAccount(name: "현대카드", kind: .card, balance: -15_000),
                ImportedAccount(name: "증권", kind: .bank, onBudget: false, balance: 100_000),
            ],
            transactions: [
                row("s1", "2026-09-30", "급여통장", 1_000_000, payee: "Starting Balance", category: "Starting Balances"),
                row("s2", "2026-09-30", "티머니", 10_000, payee: "Starting Balance", category: "Starting Balances"),
                row("a1", "2026-10-01", "생활비", 1, category: "잔액 조정"),
                // A shared dinner and a coffee on the card, paid back by one deposit that Actual split in two.
                row("e1", "2026-10-06", "현대카드", -60_000, payee: "식당가", category: "🍜 식비", imported: "식당가 본점"),
                row("e2", "2026-10-06", "현대카드", -10_000, payee: "카페나", category: "☕ 카페"),
                row("c1", "2026-10-07", "생활비", 20_000, payee: "식당가", category: "🍜 식비", notes: "#정산 입금 · 원거래 e1 · 입금거래 dep1", imported: "김가상"),
                row("c2", "2026-10-07", "생활비", 10_000, payee: "카페나", category: "☕ 카페", notes: "#정산 입금 · 원거래 e2 · 입금거래 dep1", imported: "김가상"),
                // Two identical bus fares on one day.
                row("b1", "2026-10-08", "티머니", -1_500, payee: "티머니", category: "🚉 교통", imported: "티머니 승차"),
                row("b2", "2026-10-08", "티머니", -1_500, payee: "티머니", category: "🚉 교통", imported: "티머니 승차"),
                // Transfers: between two own accounts, a card bill, out of the budget, and one with no other leg.
                row("t1", "2026-10-09", "급여통장", -10_000, transfer: "→ 티머니"),
                row("t2", "2026-10-09", "티머니", 10_000, transfer: "← 급여통장"),
                row("p1", "2026-10-10", "급여통장", -50_000, transfer: "→ 현대카드"),
                row("p2", "2026-10-10", "현대카드", 50_000, transfer: "← 급여통장"),
                row("o1", "2026-10-11", "급여통장", -100_000, transfer: "→ 증권"),
                row("o2", "2026-10-11", "증권", 100_000, transfer: "← 급여통장"),
                row("x1", "2026-10-12", "급여통장", -5_000, transfer: "→ 생활비"),
                // Rows the user has not handled yet.
                row("u1", "2026-10-13", "생활비", 130_000, payee: "박가상", imported: "박가상"),
                row("u2", "2026-10-14", "티머니", -3_000, payee: "편의점다"),
                row("u3", "2026-10-15", "카카오페이", -37_566, notes: "카톡 송금 추정 (상대 미상)"),
                row("u4", "2026-10-16", "카카오페이", -700, category: "🛒 생활"),
                row("r1", "2026-10-17", "현대카드", 5_000, payee: "식당가"),
            ]
        )
    }

    static func ledger(_ history: ImportedHistory = history(), notifications: [RawNotification] = [], setup: IntakeSetup = IntakeSetup()) throws -> IntakeLedger {
        try IntakeLedger(notifications: notifications, setup: setup, intake: NotificationIntake(timeZoneIdentifier: "Asia/Seoul"), history: history)
    }
}

@Suite struct ActualImportPlanTests {
    @Test func startingBalancesAndAdjustmentsBecomeTheOpeningBalance() throws {
        let plan = try ActualImportPlanner.plan(ActualFixture.history())
        let byName = Dictionary(uniqueKeysWithValues: plan.accounts.map { ($0.name, $0) })
        #expect(byName["급여통장"]?.openingBalance == 1_000_000)
        #expect(byName["티머니"]?.openingBalance == 10_000)
        #expect(byName["생활비"]?.openingBalance == 1)
        #expect(byName["생활비"]?.balanceCorrection == 1)
        #expect(byName["현대카드"]?.openingBalance == 0)
        #expect(byName["현대카드"]?.binding == .creditInstrument(ActualImportPlanner.instrumentID(named: "현대카드")))
        #expect(plan.warnings.isEmpty)
    }

    @Test func theCutoverIsMidnightAfterTheLastDayInSeoul() throws {
        let plan = try ActualImportPlanner.plan(ActualFixture.history())
        // 2026-10-20 00:00 KST
        #expect(plan.cutoverUnixMilliseconds == 1_792_422_000_000)
    }

    @Test func aSettlementDepositIsOneIncomeAndNeverNamesTheSender() throws {
        let plan = try ActualImportPlanner.plan(ActualFixture.history())
        let settlement = try #require(plan.settlements.first)
        #expect(plan.settlements.count == 1)
        #expect(settlement.depositEntryID == ActualImportPlanner.entryID(forRow: "dep1"))
        #expect(settlement.total == 30_000)
        #expect(settlement.links.map(\.originEntryID) == [ActualImportPlanner.entryID(forRow: "e1"), ActualImportPlanner.entryID(forRow: "e2")])
        let deposit = try #require(plan.candidates.first { $0.id == TransactionCandidateID(rawValue: "actual/dep1") })
        #expect(deposit.proposedEntry?.kind == .income)
        #expect(deposit.proposedEntry?.postings.first?.delta.minorUnits == 30_000)
        #expect(deposit.evidenceIDs == ["actual:c1", "actual:c2"])
        let everyName = plan.candidates.compactMap(\.sourceDraft).flatMap { [$0.counterparty.merchantRaw, $0.counterparty.payeeRaw, $0.counterparty.memoRaw] }.compactMap { $0 }
        #expect(!everyName.contains { $0.contains("김가상") })
        #expect(!everyName.contains { $0.contains("입금거래") })
    }

    @Test func aDepositWhoseOriginalPurchaseIsMissingStaysAnUnexplainedIncome() throws {
        var history = ActualFixture.history()
        history = ImportedHistory(through: history.through, accounts: history.accounts,
                                  transactions: history.transactions.filter { $0.id != "e2" })
        let plan = try ActualImportPlanner.plan(history)
        #expect(plan.settlements.isEmpty)
        let pending = try #require(plan.pending.first { $0.candidateID.rawValue == "actual/dep1" })
        #expect(pending.reasons.contains(.settlementOriginMissing))
        #expect(pending.inLedger)
    }

    @Test func unknownAccountsDuplicateIdsAndZeroAmountsAreWarningsNotCrashes() throws {
        let history = ImportedHistory(
            through: "2026-10-19", accounts: [ImportedAccount(name: "A", kind: .bank)],
            transactions: [
                ActualFixture.row("1", "2026-10-01", "B", -100),
                ActualFixture.row("2", "2026-10-01", "A", 0),
                ActualFixture.row("3", "2026-10-01", "A", -100, payee: "가게"),
                ActualFixture.row("3", "2026-10-01", "A", -200, payee: "가게"),
                ActualFixture.row("4", "not-a-date", "A", -100, payee: "가게"),
            ]
        )
        let plan = try ActualImportPlanner.plan(history)
        #expect(Set(plan.warnings.map(\.code)) == [.unknownAccount, .zeroAmount, .duplicateRowID, .invalidDate])
        #expect(plan.candidates.count == 1)
    }

    @Test func theFileDecodesActualsOwnFieldNames() throws {
        let json = """
        {"version":1,"source":"actual","timeZone":"Asia/Seoul","through":"2026-10-19",
         "accounts":[{"name":"급여통장","kind":"bank","on_budget":true,"balance":1000},{"name":"증권","kind":"bank","on_budget":false}],
         "transactions":[{"id":"a","date":"2026-10-19","account":"급여통장","amount":-100,"payee":"가게","category":null,"notes":null,"imported_payee":"가게 본점"}]}
        """
        let history = try ImportedHistory.decode(Data(json.utf8))
        #expect(history.accounts[1].onBudget == false)
        #expect(history.transactions[0].importedPayee == "가게 본점")
        #expect(throws: ImportedHistoryError.unsupportedVersion(2)) {
            try ImportedHistory.decode(Data(json.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8))
        }
    }
}

@Suite struct ActualImportLedgerTests {
    @Test func theReplayReproducesEveryBalanceActualHad() throws {
        let ledger = try ActualFixture.ledger()
        let snapshot = try ledger.repository.processingSnapshot().ledger
        let reconciliation = ledger.importReconciliation()
        #expect(reconciliation.count == 6)
        for account in reconciliation { #expect(account.matches, "\(account.accountName): \(account.unexplainedMinorUnits)") }
        func balance(_ name: String) -> Int64? { snapshot.accountBalances[ActualImportPlanner.accountID(named: name)]?.minorUnits }
        #expect(balance("급여통장") == 840_000)
        #expect(balance("티머니") == 14_000)
        #expect(balance("증권") == 100_000)
        #expect(snapshot.outstandingLiabilities[ActualImportPlanner.instrumentID(named: "현대카드")]?.minorUnits == 20_000)
    }

    @Test func twoIdenticalFaresOnOneDayAreTwoPurchases() throws {
        let ledger = try ActualFixture.ledger()
        let entries = try ledger.repository.processingSnapshot().ledger.entries
        #expect(entries.filter { $0.kind == .expense && $0.postings.first?.delta.minorUnits == -1_500 }.count == 2)
    }

    @Test func transfersCardBillsAndOffBudgetMovesKeepTheirShape() throws {
        let entries = try ActualFixture.ledger().repository.processingSnapshot().ledger.entries
        func entry(_ row: String) -> LedgerEntry? { entries.first { $0.id == ActualImportPlanner.entryID(forRow: row) } }
        #expect(entry("t1")?.kind == .transfer)
        #expect(entry("t1")?.evidenceIDs == ["actual:t1", "actual:t2"])
        #expect(entry("p1")?.kind == .cardPayment)
        #expect(entry("p1")?.liabilityChanges.first?.delta.minorUnits == -50_000)
        #expect(entry("o1")?.kind == .transfer)
        #expect(entry("x1") == nil)
        #expect(entry("t2") == nil)
    }

    @Test func rowsActualHadNotHandledWaitAsIfTheirNotificationHadJustArrived() throws {
        let ledger = try ActualFixture.ledger()
        let pending = Dictionary(uniqueKeysWithValues: ledger.pendingImports.map { ($0.candidateID.rawValue, $0) })

        // Money in with no category: counted, and listed under 정리할 입금.
        let deposit = try #require(pending["actual/u1"])
        #expect(deposit.reasons.contains(.unclassifiedDeposit) && deposit.inLedger)
        #expect(deposit.title == "박가상")
        // A purchase with a name but no category: counted.
        #expect(pending["actual/u2"]?.reasons == [.uncategorized])
        #expect(pending["actual/u2"]?.inLedger == true)
        // No name and no category: a withdrawal nothing explains, in review and not counted.
        let withdrawal = try #require(pending["actual/u3"])
        #expect(withdrawal.reasons.contains(.unexplainedWithdrawal) && !withdrawal.inLedger)
        #expect(withdrawal.title == "카톡 송금 추정 (상대 미상)")
        // Categorised but nameless: counted, flagged only for the missing name.
        #expect(pending["actual/u4"]?.reasons == [.noName])
        // A transfer with no other leg, and a card refund with no purchase.
        #expect(pending["actual/x1"]?.reasons == [.unpairedTransfer] && pending["actual/x1"]?.inLedger == false)
        #expect(pending["actual/r1"]?.reasons == [.refundWithoutPurchase] && pending["actual/r1"]?.inLedger == false)
        // Money across the budget line is a transfer in the ledger and still waits for a category.
        #expect(pending["actual/o1"]?.reasons == [.uncategorized] && pending["actual/o1"]?.inLedger == true)
        // Everything Hans had already handled is absent.
        #expect(pending["actual/e1"] == nil && pending["actual/b1"] == nil && pending["actual/t1"] == nil && pending["actual/dep1"] == nil)

        let snapshot = try ledger.repository.processingSnapshot()
        let u3 = try #require(snapshot.candidates[TransactionCandidateID(rawValue: "actual/u3")])
        #expect(u3.promotedEntryID == nil && u3.candidate.status == .needsReview && u3.candidate.issues == [.unsupportedEvent])
        let x1 = try #require(snapshot.candidates[TransactionCandidateID(rawValue: "actual/x1")])
        #expect(x1.candidate.issues == [.incompleteTransfer])
        let u1 = try #require(snapshot.candidates[TransactionCandidateID(rawValue: "actual/u1")])
        let entryID = try #require(u1.promotedEntryID)
        // The deposit is the kind of income 정리할 입금 lists: an income entry no settlement used.
        #expect(snapshot.ledger.entries.first { $0.id == entryID }?.kind == .income)
    }

    @Test func replayingOrReimportingNeverCountsAnythingTwice() throws {
        let first = try ActualFixture.ledger()
        let second = try ActualFixture.ledger(setup: first.setup)
        #expect(second.setup.configuration == first.setup.configuration)
        #expect(second.setup.configuration.accounts.count == 5)
        #expect(second.setup.configuration.creditInstruments.count == 1)
        #expect(try second.repository.processingSnapshot().ledger.entries == first.repository.processingSnapshot().ledger.entries)
        #expect(second.pendingImports == first.pendingImports)
    }

    @Test func notificationsBeforeTheCutoverAreCoveredAndLaterOnesAreProcessed() throws {
        let plan = try ActualImportPlanner.plan(ActualFixture.history())
        let source = NotificationSource(applicationIdentifier: "com.example.pay", displayName: "Toss")
        let late = RawNotification(id: "late", source: source, capturedAtUnixMilliseconds: plan.cutoverUnixMilliseconds - 60_000,
                                   title: "9,900원 결제", body: "가맹점A")
        let early = RawNotification(id: "early", source: source, capturedAtUnixMilliseconds: 1, notificationAtUnixMilliseconds: plan.cutoverUnixMilliseconds + 60_000,
                                    title: "9,900원 결제", body: "가맹점A")
        let ledger = try ActualFixture.ledger(notifications: [late, early])
        #expect(ledger.status(of: "late") == .coveredByImport)
        #expect(ledger.status(of: "early") != .coveredByImport)
        #expect(ledger.notifications.count == 2)
        // A covered notification adds no entry and no account question.
        #expect(ledger.setup.registry.openCandidates.count <= 1)
    }

    @Test func transfersToAClosedAccountKeepTheirShapeAndTheClosedAccountEndsAtZero() throws {
        // Actual's tools leave a closed account out, rows and all: only the live side of its transfers is in the file.
        let history = ImportedHistory(
            through: "2026-10-19",
            accounts: [ImportedAccount(name: "통장", kind: .bank, balance: 3_000_000)],
            transactions: [
                ActualFixture.row("s", "2026-10-01", "통장", 1_000_000, category: "Starting Balances"),
                ActualFixture.row("in", "2026-10-02", "통장", 2_500_000, transfer: "← 닫힌은행"),
                ActualFixture.row("out", "2026-10-03", "통장", -500_000, transfer: "→ 닫힌은행"),
            ]
        )
        let ledger = try ActualFixture.ledger(history)
        let plan = try #require(ledger.importPlan)
        #expect(plan.warnings.map(\.code) == [.counterpartNotExported])
        let closed = try #require(plan.accounts.first { $0.name == "닫힌은행" })
        #expect(closed.isPlaceholder && closed.openingBalance == 2_000_000)
        let balances = try ledger.repository.processingSnapshot().ledger.accountBalances
        #expect(balances[ActualImportPlanner.accountID(named: "통장")]?.minorUnits == 3_000_000)
        #expect(balances[ActualImportPlanner.accountID(named: "닫힌은행")]?.minorUnits == 0)
        #expect(ledger.importReconciliation().filter { !$0.matches }.isEmpty)
        #expect(ledger.pendingImports.isEmpty)
    }

    @Test func theSameAmountMovedBothWaysOnOneDayIsTwoTransfers() throws {
        let history = ImportedHistory(
            through: "2026-10-19",
            accounts: [ImportedAccount(name: "가", kind: .bank, balance: 0), ImportedAccount(name: "나", kind: .bank, balance: 0)],
            transactions: [
                ActualFixture.row("a1", "2026-10-05", "가", -10_000, transfer: "→ 나"),
                ActualFixture.row("a2", "2026-10-05", "나", 10_000, transfer: "← 가"),
                ActualFixture.row("b1", "2026-10-05", "나", -10_000, transfer: "→ 가"),
                ActualFixture.row("b2", "2026-10-05", "가", 10_000, transfer: "← 나"),
            ]
        )
        let ledger = try ActualFixture.ledger(history)
        #expect(try ledger.repository.processingSnapshot().ledger.entries.count == 2)
        #expect(ledger.pendingImports.isEmpty)
    }

    @Test func aLedgerWithoutAHistoryBehavesAsBefore() throws {
        let ledger = try IntakeLedger(notifications: [], setup: IntakeSetup(), intake: NotificationIntake(timeZoneIdentifier: "Asia/Seoul"))
        #expect(ledger.pendingImports.isEmpty && ledger.importReconciliation().isEmpty && ledger.importPlan == nil)
    }
}
