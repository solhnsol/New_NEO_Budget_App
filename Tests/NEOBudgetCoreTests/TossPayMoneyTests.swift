import Foundation
import Testing
@testable import NEOBudgetCore
import NEOBudgetInMemoryStorage

private let seoul = TimeZone(identifier: "Asia/Seoul")!
private let received: Int64 = 1_790_936_040_000
private let living = AccountID(rawValue: "living")
private let wallet = AccountID(rawValue: "tosspay")

/// Toss Pay Money is its own wallet account: a top-up and the money coming back are transfers, only what is paid
/// from it is spending (synthetic shops and amounts only).
@Suite struct TossPayMoneyTests {
    private let intake = NotificationIntake(timeZoneIdentifier: "Asia/Seoul")
    private let decoder = ShortcutNotificationDecoder(timeZone: seoul)

    private func note(_ app: String, title: String = "", body: String, time: String) throws -> RawNotification {
        let fields = ["app": app, "title": title, "subtitle": "", "body": body, "timestamp": "Oct 2, 2026 at \(time)"]
        let text = String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
        return try decoder.decode(text, receivedAtUnixMilliseconds: received)[0]
    }

    private func topUp(_ amount: String = "50,000", time: String = "7:00:00 PM") throws -> RawNotification {
        try note("우리WON뱅킹", body: "[Web발신]\n우리 출금 \(amount)원 1002-123-456*** 토스페이충전 잔액 1,234,000원 10/02 19:00:00", time: time)
    }

    private func payment(_ amount: String = "13,924", shop: String = "가상가게", time: String = "7:05:00 PM") throws -> RawNotification {
        try note("Toss", title: "\(amount)원 결제", body: "토스페이머니 · \(shop)", time: time)
    }

    private func comeBack(_ amount: String = "36,076", time: String = "7:10:00 PM") throws -> RawNotification {
        try note("우리WON뱅킹", body: "[Web발신]\n우리 입금 \(amount)원 1002-123-456*** 본인 잔액 1,234,000원 10/02 19:10:00", time: time)
    }

    /// The bank account is registered, the wallet is registered with its Toss payments bound to it, and the user has
    /// confirmed which words mean the wallet when `aliases` says so.
    private func setup(aliases: [String]) throws -> IntakeSetup {
        var setup = IntakeSetup()
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        _ = try intake.ingest(try note("우리WON뱅킹", body: "[Web발신]\n우리 출금 1,000원 1002-123-456*** 설정용가게 잔액 1,234,000원 10/02 18:00:00", time: "6:00:00 PM"),
                              setup: &setup, repository: &repository)
        let bank = try #require(setup.registry.openCandidates.first { $0.key.institution == .woori })
        try setup.confirmAsNew(bank.id, displayName: "생활비", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "living" })
        let target = try setup.addAccount(displayName: "토스페이머니", institution: .tossPay,
                                          kind: .account(.prepaid, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "tosspay" })
        let evidence = AccountEvidenceExtractor().evidence(from: try payment())
        #expect(evidence.instrument.institution == .tossPay && evidence.instrument.kind == .prepaidWallet)
        try setup.addSourceRule(for: evidence, binding: target.binding, createdAtUnixMilliseconds: 1)
        for phrase in aliases { try setup.addCounterpartAlias(phrase, to: target.binding) }
        return setup
    }

    private func replay(_ notifications: [RawNotification], aliases: [String] = ["토스페이충전", "본인"]) throws -> CandidateProcessingSnapshot {
        var setup = try setup(aliases: aliases)
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        for notification in notifications { _ = try intake.ingest(notification, setup: &setup, repository: &repository) }
        return try repository.processingSnapshot()
    }

    private func balance(_ snapshot: CandidateProcessingSnapshot, _ id: AccountID) -> Int64 {
        snapshot.ledger.accountBalances[id]?.minorUnits ?? 0
    }

    private func spent(_ snapshot: CandidateProcessingSnapshot) -> Int64 {
        snapshot.ledger.entries.filter { $0.kind == .expense }.reduce(0) { $0 + (-($1.postings.first?.delta.minorUnits ?? 0)) }
    }

    @Test func aTopUpIsATransferToTheWalletNotSpending() throws {
        let snapshot = try replay([try topUp()])
        #expect(snapshot.ledger.entries.map(\.kind) == [.transfer])
        #expect(balance(snapshot, living) == -50_000 && balance(snapshot, wallet) == 50_000)
        #expect(spent(snapshot) == 0)
    }

    @Test func onlyThePaymentFromTheWalletIsSpending() throws {
        let snapshot = try replay([try topUp(), try payment()])
        #expect(snapshot.ledger.entries.map(\.kind).sorted { "\($0)" < "\($1)" } == [.expense, .transfer])
        #expect(spent(snapshot) == 13_924)
        #expect(balance(snapshot, wallet) == 36_076)
    }

    @Test func theMoneyComingBackIsATransferAndSpendingStaysOnePayment() throws {
        let notifications = [try topUp(), try payment(), try comeBack()]
        for order in [notifications, notifications.reversed()] {
            let snapshot = try replay(Array(order))
            #expect(spent(snapshot) == 13_924)
            #expect(balance(snapshot, wallet) == 0)
            #expect(balance(snapshot, living) == -13_924)
            #expect(snapshot.ledger.entries.filter { $0.kind == .income }.isEmpty)
        }
    }

    @Test func aTopUpEqualToAPaymentIsStillATransferWhenTheUserConfirmedTheWord() throws {
        let snapshot = try replay([try topUp("13,924", time: "7:05:00 PM"), try payment(time: "7:05:03 PM")])
        #expect(snapshot.ledger.entries.map(\.kind).sorted { "\($0)" < "\($1)" } == [.expense, .transfer])
        #expect(balance(snapshot, wallet) == 0 && balance(snapshot, living) == -13_924)
    }

    @Test func withoutTheUsersWordATopUpIsSpendingAndAnOwnNameDepositIsIncome() throws {
        let snapshot = try replay([try topUp(), try comeBack()], aliases: [])
        // The deposit comes ten minutes later: by then the unexplained withdrawal is spending (`settleStaleWithdrawals`).
        #expect(snapshot.ledger.entries.map(\.kind).sorted { "\($0)" < "\($1)" } == [.expense, .income])
    }

    @Test func theSameNotificationTwiceChangesNothing() throws {
        let once = try replay([try topUp()])
        let twice = try replay([try topUp(), try topUp()])
        #expect(once.ledger.entries.count == 1 && twice.ledger.entries.count == 1)
        #expect(balance(twice, wallet) == 50_000)
    }

    @Test func aRegistrySavedBeforeAliasesStillOpens() throws {
        let old = try JSONEncoder().encode(AccountRegistry())
        var json = try #require(try JSONSerialization.jsonObject(with: old) as? [String: Any])
        json["counterpartAliases"] = nil
        let decoded = try JSONDecoder().decode(AccountRegistry.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.counterpartAliases.isEmpty)
    }

    @Test func anAliasMatchesWholeWordsOnly() throws {
        var registry = AccountRegistry()
        let target = try registry.addAccount(displayName: "지갑", institution: .tossPay,
                                             kind: .account(.prepaid, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "w" })
        try registry.addCounterpartAlias("본인", to: target.binding)
        #expect(registry.counterpartAlias(in: "입금 36,076원 본인 잔액") == AccountID(rawValue: "w"))
        #expect(registry.counterpartAlias(in: "입금 36,076원 본인부담금 잔액") == nil)
        #expect(registry.counterpartAlias(in: "입금 36,076원 홍길동 잔액") == nil)
    }
}
