import Foundation
import Testing
@testable import NEOBudgetCore
import NEOBudgetInMemoryStorage

private let received: Int64 = 1_790_936_040_000

@Suite struct BalanceChainUnitTests {
    private let bank = AccountID(rawValue: "bank")
    private func seen(_ id: String, at: Int64, _ balance: Int64, moved delta: Int64) -> BalanceObservation {
        BalanceObservation(accountID: bank, atUnixMilliseconds: at, minorUnits: balance, deltaMinorUnits: delta, notificationID: id)
    }

    @Test func aChainThatAddsUpHasNoBreakAndAGapReportsASignedDifference() {
        #expect(BalanceChain.breaks(observations: [seen("a", at: 10, 100, moved: -5), seen("b", at: 20, 80, moved: -20)]).isEmpty)
        let gap = BalanceChain.breaks(observations: [seen("b", at: 20, 80, moved: -3), seen("a", at: 10, 100, moved: -5)])
        #expect(gap.map(\.differenceMinorUnits) == [-17])
        #expect(gap.first?.id == "gap:a:b")
        // Money in that nothing reported is positive; a notice that moves no money continues the chain at its own balance.
        #expect(BalanceChain.breaks(observations: [seen("a", at: 10, 100, moved: 0), seen("b", at: 20, 150, moved: 0)]).first?.differenceMinorUnits == 50)
        #expect(BalanceChain.breaks(observations: [seen("a", at: 10, 100, moved: -5), seen("n", at: 15, 100, moved: 0)]).isEmpty)
    }

    @Test func accountsAreChainedApart() {
        let other = BalanceObservation(accountID: AccountID(rawValue: "wallet"), atUnixMilliseconds: 15, minorUnits: 5, deltaMinorUnits: -1, notificationID: "w")
        #expect(BalanceChain.breaks(observations: [seen("a", at: 10, 100, moved: -5), other, seen("b", at: 20, 97, moved: -3)]).isEmpty)
    }

    @Test func notificationsOfOneSecondAreChainedInWhicheverOrderFits() {
        // Two withdrawals in the same second: 100 -> 97 -> 95 has no break whichever is listed first.
        let found = BalanceChain.breaks(observations: [seen("a", at: 10, 100, moved: -5), seen("c", at: 20, 95, moved: -2), seen("b", at: 20, 97, moved: -3)])
        #expect(found.isEmpty)
    }

    @Test func waitingActsExplainADifferenceOnlyWhenOneToThreeOfThemAddUpToIt() throws {
        let gap = try #require(BalanceChain.breaks(observations: [seen("a", at: 10, 100, moved: -5), seen("b", at: 20, 80, moved: -3)]).first)
        #expect(BalanceChain.isExplained(gap, by: [-17]))
        #expect(BalanceChain.isExplained(gap, by: [-10, 5, -7]))
        #expect(!BalanceChain.isExplained(gap, by: [-16]))
        #expect(!BalanceChain.isExplained(gap, by: []))
        #expect(!BalanceChain.isExplained(gap, by: [-1, -1, -1, -14]))
    }

    @Test func aSetupSavedBeforeBreaksExistedStillLoads() throws {
        let saved = try JSONEncoder().encode(IntakeSetup())
        var object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        object.removeValue(forKey: "confirmedGaps")
        object.removeValue(forKey: "acknowledgedBreaks")
        let old = try JSONSerialization.data(withJSONObject: object)
        let setup = try JSONDecoder().decode(IntakeSetup.self, from: old)
        #expect(setup.confirmedGaps.isEmpty && setup.acknowledgedBreaks.isEmpty)
    }
}

@Suite struct BalanceBreakLedgerTests {
    private let decoder = ShortcutNotificationDecoder(timeZone: TimeZone(identifier: "Asia/Seoul")!)

    private func woori(_ kind: String, _ amount: String, balance: String, at hour: Int) throws -> RawNotification {
        let clock = String(format: "%02d:00:00", hour)
        let fields = ["app": "우리WON뱅킹", "title": "", "subtitle": "",
                      "body": "[Web발신]\n우리 \(kind) \(amount)원 1002-123-456*** 잔액 \(balance)원 10/02 \(clock)",
                      "timestamp": "Oct 2, 2026 at \(hour > 12 ? hour - 12 : hour):00:00 \(hour >= 12 ? "PM" : "AM")"]
        let text = String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
        return try decoder.decode(text, receivedAtUnixMilliseconds: received)[0]
    }

    private func note(_ app: String, title: String, body: String, hour: Int) throws -> RawNotification {
        let fields = ["app": app, "title": title, "subtitle": "", "body": body, "timestamp": "Oct 2, 2026 at \(hour - 12):00:00 PM"]
        let text = String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
        return try decoder.decode(text, receivedAtUnixMilliseconds: received)[0]
    }

    private func ledger(_ notifications: [RawNotification]) throws -> IntakeLedger {
        var ledger = try IntakeLedger(notifications: [], setup: IntakeSetup(), intake: NotificationIntake(timeZoneIdentifier: "Asia/Seoul"))
        try ledger.receive(notifications)
        let candidate = try #require(ledger.setup.registry.openCandidates.first)
        try ledger.confirmAsNew(candidate.id, displayName: "생활비", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "bank" })
        return ledger
    }

    private func gapEntries(_ ledger: IntakeLedger) throws -> [LedgerEntry] {
        try ledger.repository.processingSnapshot().ledger.entries.filter { $0.evidenceIDs.contains { $0.hasPrefix("gap:") } }
    }

    @Test func aMissedWithdrawalIsSuggestedOnlyAndTheLedgerStaysUntilTheUserConfirms() throws {
        let ledger = try ledger([try woori("출금", "5,000", balance: "100,000", at: 10), try woori("출금", "3,000", balance: "80,000", at: 15)])
        let gap = try #require(ledger.balanceBreaks.first)
        #expect(ledger.balanceBreaks.count == 1 && gap.differenceMinorUnits == -17_000)
        let entries = try ledger.repository.processingSnapshot().ledger.entries
        #expect(entries.isEmpty)       // detection books nothing
    }

    @Test func confirmingBooksOneExpenseAndAnAlreadyBalancedChainSuggestsNothing() throws {
        var book = try ledger([try woori("출금", "5,000", balance: "100,000", at: 10), try woori("출금", "3,000", balance: "80,000", at: 15)])
        try book.confirmBalanceGap(try #require(book.balanceBreaks.first), label: "식비")
        let booked = try gapEntries(book)
        #expect(booked.count == 1 && booked[0].kind == .expense && booked[0].postings.first?.delta.minorUnits == -17_000)
        #expect(booked[0].budgetImpact?.amount.minorUnits == 17_000)
        #expect(book.balanceBreaks.isEmpty)
        // The same break is not booked twice, even if the setup is replayed again.
        try book.receive([])
        let again = try gapEntries(book)
        #expect(again.count == 1)

        let balanced = try ledger([try woori("출금", "5,000", balance: "100,000", at: 10), try woori("출금", "20,000", balance: "80,000", at: 15)])
        #expect(balanced.balanceBreaks.isEmpty)
    }

    @Test func aLateNotificationInsideTheGapTakesTheConfirmedEntryAwayInsteadOfCountingTwice() throws {
        var book = try ledger([try woori("출금", "5,000", balance: "100,000", at: 10), try woori("출금", "3,000", balance: "80,000", at: 15)])
        try book.confirmBalanceGap(try #require(book.balanceBreaks.first), label: "식비")
        let late = try woori("출금", "17,000", balance: "83,000", at: 12)
        try book.receive([late])
        let left = try gapEntries(book)
        #expect(left.isEmpty)
        #expect(book.balanceBreaks.isEmpty)
        // The three withdrawals wait for the user as before; the 17,000 is not also booked as a guess.
        let entries = try book.repository.processingSnapshot().ledger.entries
        #expect(entries.isEmpty)
    }

    @Test func anActWaitingForTheUserInsideTheGapExplainsItSoNothingIsSuggested() throws {
        let toss = try note("Toss", title: "17,000원 결제", body: "현대카드 체크 | 가게D | 일시불", hour: 12)
        let book = try ledger([try woori("출금", "5,000", balance: "100,000", at: 10), toss, try woori("출금", "3,000", balance: "80,000", at: 15)])
        #expect(book.balanceBreaks.isEmpty)
    }

    @Test func aDepositThatNothingRecordedBooksAsIncomeAndLeavingItAloneIsRemembered() throws {
        var income = try ledger([try woori("출금", "5,000", balance: "100,000", at: 10), try woori("입금", "1,000", balance: "151,000", at: 15)])
        let gap = try #require(income.balanceBreaks.first)
        #expect(gap.differenceMinorUnits == 50_000)
        try income.confirmBalanceGap(gap, label: "용돈")
        let incomeEntries = try gapEntries(income)
        #expect(incomeEntries.first?.kind == .income)

        var skipped = try ledger([try woori("출금", "5,000", balance: "100,000", at: 10), try woori("출금", "3,000", balance: "80,000", at: 15)])
        try skipped.acknowledgeBalanceBreak(try #require(skipped.balanceBreaks.first))
        #expect(skipped.balanceBreaks.isEmpty)
        let none = try gapEntries(skipped)
        #expect(none.isEmpty)
        #expect(skipped.setup.acknowledgedBreaks.count == 1)
    }
}
