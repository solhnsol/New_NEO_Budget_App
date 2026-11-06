import Foundation
import Testing
@testable import NEOBudgetCore
import NEOBudgetInMemoryStorage

private let seoul = TimeZone(identifier: "Asia/Seoul")!
private let received: Int64 = 1_790_936_040_000
private let living = AccountID(rawValue: "living")

/// One movement of money that both Toss and the bank report is one entry, whichever alert arrives first (synthetic shops only).
/// A Toss payment paid from a bank account is "N원 결제" from Toss plus a withdrawal whose counterparty starts with `토스`.
/// A person's Toss transfer is "<bank> 계좌로 입금" from Toss plus the bank's own deposit alert.
@Suite struct TossBankPairingTests {
    private let intake = NotificationIntake(timeZoneIdentifier: "Asia/Seoul")
    private let decoder = ShortcutNotificationDecoder(timeZone: seoul)

    private func note(_ app: String, title: String = "", body: String, time: String) throws -> RawNotification {
        let fields = ["app": app, "title": title, "subtitle": "", "body": body, "timestamp": "Oct 2, 2026 at \(time)"]
        let text = String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
        return try decoder.decode(text, receivedAtUnixMilliseconds: received)[0]
    }

    private func tossPayment(_ amount: String = "12,000", _ shop: String = "가상상점", time: String = "7:13:30 PM") throws -> RawNotification {
        try note("Toss", title: "\(amount)원 결제", body: shop, time: time)
    }

    private func withdrawal(_ amount: String = "12,000", to name: String = "토스퀵계좌이체", time: String = "7:13:35 PM") throws -> RawNotification {
        try note("우리WON뱅킹", body: "[Web발신]\n우리 출금 \(amount)원 1002-123-456*** \(name) 잔액 1,234,000원 10/02 19:13:35", time: time)
    }

    private func bankDeposit(_ amount: String = "12,000", time: String = "7:13:35 PM") throws -> RawNotification {
        try note("우리WON뱅킹", body: "[Web발신]\n우리 입금 \(amount)원 1002-123-456*** 잔액 1,234,000원 10/02 19:13:35", time: time)
    }

    private func tossDeposit(_ amount: String = "12,000", bank: String = "우리", time: String = "7:13:30 PM") throws -> RawNotification {
        try note("Toss", title: "입금됐어요", body: "김가명님이 \(amount)원을 \(bank) 계좌로 입금했어요.", time: time)
    }

    /// The Woori account is already registered (as after the user confirmed it once).
    private func registeredSetup() throws -> IntakeSetup {
        var setup = IntakeSetup()
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        _ = try intake.ingest(try withdrawal("1,000", to: "설정용가게", time: "6:00:00 PM"), setup: &setup, repository: &repository)
        let bank = try #require(setup.registry.openCandidates.first { $0.key.institution == .woori })
        try setup.confirmAsNew(bank.id, displayName: "생활비", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")),
                               makeID: { "living" })
        return setup
    }

    private func replay(_ notifications: [RawNotification]) throws -> CandidateProcessingSnapshot {
        var setup = try registeredSetup()
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        for notification in notifications { _ = try intake.ingest(notification, setup: &setup, repository: &repository) }
        return try repository.processingSnapshot()
    }

    private func open(_ snapshot: CandidateProcessingSnapshot) -> [StoredTransactionCandidate] {
        snapshot.candidates.values.filter { $0.promotedEntryID == nil && $0.corroborates == nil }
    }

    private func balance(_ snapshot: CandidateProcessingSnapshot) -> Int64 {
        snapshot.ledger.accountBalances[living]?.minorUnits ?? 0
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    // MARK: Rule A: a Toss payment and the bank withdrawal that paid it

    @Test func aTossPaymentAndItsWithdrawalAreOneExpenseInEitherOrderWithTheTossShop() throws {
        let payment = try tossPayment()
        let draw = try withdrawal()
        for order in [[payment, draw], [draw, payment]] {
            let snapshot = try replay(order)
            #expect(snapshot.ledger.entries.map(\.kind) == [.expense])
            #expect(balance(snapshot) == -12_000)
            #expect(open(snapshot).isEmpty)
            #expect(snapshot.candidates.values.filter { $0.corroborates?.rule == .tossQuickPay }.count == 1)
            let expense = try #require(snapshot.candidates.values.first { $0.promotedEntryID != nil })
            #expect(expense.candidate.sourceDraft?.counterparty.merchantRaw == "가상상점")
        }
    }

    @Test func aWithdrawalToAPersonWhoseNameStartsWithTossPairsOnlyWithAMatchingTossPayment() throws {
        let draw = try withdrawal(to: "토스 홍길동")
        let paired = try replay([try tossPayment(), draw])
        #expect(paired.ledger.entries.map(\.kind) == [.expense])
        #expect(open(paired).isEmpty)
        // Without a Toss payment the same withdrawal could be a transfer to a friend: it still asks.
        let alone = try replay([draw])
        #expect(alone.ledger.entries.isEmpty)
        #expect(open(alone).count == 1)
    }

    @Test func withoutATossNameOrWithAnotherAmountNothingIsLinked() throws {
        for draw in [try withdrawal(to: "가상자동이체"), try withdrawal("11,000")] {
            for order in [[try tossPayment(), draw], [draw, try tossPayment()]] {
                let snapshot = try replay(order)
                #expect(snapshot.ledger.entries.isEmpty)
                #expect(open(snapshot).count == 2)
                #expect(snapshot.candidates.values.allSatisfy { $0.corroborates == nil })
            }
        }
    }

    @Test func tossBankIsTheBankItselfNotATossPayment() throws {
        let snapshot = try replay([try tossPayment(), try withdrawal(to: "토스뱅크 홍길동")])
        #expect(snapshot.ledger.entries.isEmpty)
        #expect(open(snapshot).count == 2)
    }

    @Test func aGapOfOneToTenMinutesIsOnlySuggestedAndTheLaterAlertCarriesTheSuggestion() throws {
        let payment = try tossPayment(time: "7:13:30 PM")
        let draw = try withdrawal(time: "7:16:30 PM")
        for order in [[payment, draw], [draw, payment]] {
            let snapshot = try replay(order)
            #expect(snapshot.ledger.entries.isEmpty)
            #expect(open(snapshot).count == 2)
            let later = try #require(snapshot.candidates.values.first { $0.suggestions.contains { $0.rule == .sameMoneySuggestion } })
            #expect(later.candidate.issues.contains(.possibleSameMoneyRecorded))
        }
    }

    @Test func afterTenMinutesNothingIsSuggested() throws {
        let snapshot = try replay([try tossPayment(time: "7:13:30 PM"), try withdrawal(time: "7:25:30 PM")])
        #expect(snapshot.ledger.entries.isEmpty)
        #expect(snapshot.candidates.values.allSatisfy { $0.suggestions.isEmpty })
    }

    @Test func aSameAmountPaymentTwiceCompletesOnlyTheNearestAndLeavesTheOtherToAsk() throws {
        let first = try tossPayment(time: "7:13:30 PM")
        let second = try tossPayment(time: "7:14:00 PM")
        let draw = try withdrawal(time: "7:13:35 PM")
        for order in permutations([first, second, draw]) {
            let snapshot = try replay(order)
            #expect(snapshot.ledger.entries.map(\.kind) == [.expense])
            #expect(balance(snapshot) == -12_000)
            #expect(open(snapshot).count == 1)
        }
    }

    @Test func twoDifferentPaymentsAndTheirWithdrawalsAreTwoExpensesInEveryOrder() throws {
        let notifications = [
            try tossPayment("12,000", "가상상점", time: "7:13:30 PM"), try tossPayment("7,000", "가상식당", time: "7:13:31 PM"),
            try withdrawal("12,000", time: "7:13:35 PM"), try withdrawal("7,000", to: "토스 홍길동", time: "7:13:36 PM"),
        ]
        for order in permutations(notifications) {
            let snapshot = try replay(order)
            #expect(snapshot.ledger.entries.map(\.kind) == [.expense, .expense])
            #expect(balance(snapshot) == -19_000)
            #expect(open(snapshot).isEmpty)
            let shops = Set(snapshot.candidates.values.filter { $0.promotedEntryID != nil }.compactMap { $0.candidate.sourceDraft?.counterparty.merchantRaw })
            #expect(shops == ["가상상점", "가상식당"])
        }
    }

    @Test func receivingTheSameAlertAgainAfterThePairIsRecordedChangesNothing() throws {
        let payment = try tossPayment()
        let draw = try withdrawal()
        for order in [[payment, draw, draw, payment], [draw, payment, payment, draw]] {
            let snapshot = try replay(order)
            #expect(snapshot.ledger.entries.map(\.kind) == [.expense])
            #expect(balance(snapshot) == -12_000)
            #expect(open(snapshot).isEmpty)
        }
    }

    // MARK: Rule B: a person's Toss transfer and the bank's own deposit alert

    @Test func aTossTransferAndTheBanksDepositAreOneIncomeInEitherOrder() throws {
        let toss = try tossDeposit()
        let bank = try bankDeposit()
        for order in [[toss, bank], [bank, toss]] {
            let snapshot = try replay(order)
            #expect(snapshot.ledger.entries.map(\.kind) == [.income])
            #expect(balance(snapshot) == 12_000)
            #expect(open(snapshot).isEmpty)
            #expect(snapshot.candidates.values.filter { $0.corroborates?.rule == .tossDepositEcho }.count == 1)
        }
    }

    @Test func aTossTransferToAnotherBankOrAnotherAmountIsNotTheSameDeposit() throws {
        for toss in [try tossDeposit(bank: "신한"), try tossDeposit("13,000")] {
            for order in [[toss, try bankDeposit()], [try bankDeposit(), toss]] {
                let snapshot = try replay(order)
                #expect(snapshot.ledger.entries.map(\.kind) == [.income])
                #expect(open(snapshot).count == 1)
                #expect(snapshot.candidates.values.allSatisfy { $0.corroborates == nil })
            }
        }
    }

    @Test func aTossTransferThreeMinutesAfterTheDepositIsOnlySuggestedAsTheSameMoney() throws {
        let snapshot = try replay([try bankDeposit(time: "7:13:35 PM"), try tossDeposit(time: "7:16:35 PM")])
        #expect(snapshot.ledger.entries.map(\.kind) == [.income])
        let toss = try #require(open(snapshot).first)
        #expect(toss.suggestions.map(\.rule) == [.sameMoneySuggestion])
        #expect(toss.candidate.issues.contains(.possibleSameMoneyRecorded))
    }
}
