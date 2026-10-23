import Foundation
import Testing
@testable import NEOBudgetCore
import NEOBudgetInMemoryStorage

private let seoul = TimeZone(identifier: "Asia/Seoul")!
private let received: Int64 = 1_790_936_040_000

/// What the app does today when one movement of money reaches it as a Toss notification and a Woori notification
/// (docs/toss-bank-pairing-design.md). Synthetic shops and amounts only. Each test records the CURRENT behaviour,
/// including the double counting; when a pairing rule lands, the expectations marked `// today` are what flips.
@Suite struct TossBankPairingCharacterizationTests {
    private let intake = NotificationIntake(timeZoneIdentifier: "Asia/Seoul")
    private let decoder = ShortcutNotificationDecoder(timeZone: seoul)
    private let woori = AccountID(rawValue: "woori")

    private func note(_ app: String, title: String = "", body: String, time: String) throws -> RawNotification {
        let fields = ["app": app, "title": title, "subtitle": "", "body": body, "timestamp": "Oct 2, 2026 at \(time)"]
        let text = String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
        return try decoder.decode(text, receivedAtUnixMilliseconds: received)[0]
    }

    // Shape 1: Toss "N원이 결제됐어요" (names no account) and Woori "[출금]" of the same money.
    private func tossPaid(_ amount: String, _ shop: String, time: String = "7:13:30 PM") throws -> RawNotification {
        try note("Toss", title: "\(amount)원이 결제됐어요", body: shop, time: time)
    }
    private func wooriQuickOut(_ amount: String, time: String = "7:13:35 PM") throws -> RawNotification {
        try note("우리WON뱅킹", title: "[출금]", body: "토스퀵계좌이체 \(amount)원 1002-123-456*** 잔액 1,234,000원 10/02 19:13:35", time: time)
    }
    // Shape 3: Toss "내 우리 계좌로 입금" and Woori "[입금]".
    private func tossToWoori(_ amount: String, time: String = "7:13:30 PM") throws -> RawNotification {
        try note("Toss", title: "송금", body: "\(amount)원이 내 우리 계좌로 입금됐어요", time: time)
    }
    private func wooriIn(_ amount: String, time: String = "7:13:35 PM") throws -> RawNotification {
        try note("우리WON뱅킹", title: "[입금]", body: "토스 \(amount)원 1002-123-456*** 잔액 1,234,000원 10/02 19:13:35", time: time)
    }

    /// The Woori account is already registered (as after the user confirmed it once).
    private func linkedSetup() throws -> IntakeSetup {
        var setup = IntakeSetup()
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        _ = try intake.ingest(try note("우리WON뱅킹", title: "[출금]", body: "설정용가게 1,000원 1002-123-456*** 잔액 1,234,000원 10/02 19:00:00", time: "7:00:00 PM"),
                              setup: &setup, repository: &repository)
        let bank = try #require(setup.registry.openCandidates.first { $0.key.institution == .woori })
        try setup.confirmAsNew(bank.id, displayName: "생활비", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "woori" })
        return setup
    }

    private struct Result: Equatable { let kinds: [LedgerEntry.Kind]; let balance: Int64; let open: Int; let corroborations: Int; let openSources: [String] }

    private func replay(_ notifications: [RawNotification]) throws -> Result {
        var setup = try linkedSetup()
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        for notification in notifications { _ = try intake.ingest(notification, setup: &setup, repository: &repository) }
        let snapshot = try repository.processingSnapshot()
        return Result(
            kinds: snapshot.ledger.entries.map(\.kind).sorted { $0.rawValue < $1.rawValue },
            balance: snapshot.ledger.accountBalances[woori]?.minorUnits ?? 0,
            open: snapshot.candidates.values.filter { $0.promotedEntryID == nil && $0.corroborates == nil }.count,
            corroborations: snapshot.candidates.values.filter { $0.corroborates != nil }.count,
            openSources: snapshot.candidates.values.filter { $0.promotedEntryID == nil && $0.corroborates == nil }.compactMap { $0.candidate.sourceDraft?.ruleID }.sorted()
        )
    }

    @Test func aTossPaymentAndTheBankWithdrawalOfTheSameMoneyAreNotPaired() throws {
        let toss = try tossPaid("12,000", "가상상점"), bank = try wooriQuickOut("12,000")
        for order in [[toss, bank], [bank, toss]] {
            let result = try replay(order)
            // today: neither side is tied to the other; both wait for review, so answering the Toss one with the
            // bank account would count the money twice
            #expect(result.corroborations == 0 && result.kinds.isEmpty && result.open == 2)
        }
    }

    @Test func aTossDepositToMyWooriAccountAndTheBankDepositAreNotPaired() throws {
        let toss = try tossToWoori("12,000"), bank = try wooriIn("12,000")
        for order in [[toss, bank], [bank, toss]] {
            let result = try replay(order)
            print("SHAPE3", order.count, result)
            // today: not tied. One deposit is recorded as income; the other waits for review (not yet counted, but
            // confirming it as income would double the income)
            #expect(result.corroborations == 0 && result.kinds == [.income] && result.open == 1)
        }
    }
}
