import Foundation
import Testing
@testable import NEOBudgetCore
import NEOBudgetInMemoryStorage

private let seoul = TimeZone(identifier: "Asia/Seoul")!
/// 2026-10-02 19:14 KST: just after the synthetic payment below.
private let received: Int64 = 1_790_936_040_000

@Suite struct ShortcutNotificationDecoderTests {
    private let decoder = ShortcutNotificationDecoder(timeZone: seoul)

    @Test func digestMatchesTheStandardVectors() {
        #expect(SHA256.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256.hex(String(repeating: "a", count: 1_000)) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    @Test func theCurrentShortcutShapeKeepsEveryFieldAndReadsTheDeviceTimestamp() throws {
        let payload = #"{"app":"Toss","title":"9,900원 결제","subtitle":"","body":"가맹점A (M CHECK) | 일시불","timestamp":"Oct 8, 2026 at 11:41:17\#u{202F}PM","assosicated":""}"#
        let notification = try #require(try decoder.decode(payload, receivedAtUnixMilliseconds: received).first)
        #expect(notification.source.displayName == "Toss")
        #expect(notification.title == "9,900원 결제")
        #expect(notification.subtitle == nil)
        #expect(notification.body == "가맹점A (M CHECK) | 일시불")
        #expect(notification.notificationAtUnixMilliseconds == 1_791_470_477_000)
        #expect(notification.capturedAtUnixMilliseconds == received)
        #expect(notification.sourceDeliveryID == nil)
        #expect(notification.rawPayload == payload)
        #expect(ProviderCatalog.standard.provider(for: notification.source) == ProviderCatalog.toss)
    }

    @Test func olderShapesReadMessageAsTheBody() throws {
        let withApp = try #require(try decoder.decode(#"{"app":"Kakaopay","message":"10,000원 충전했어요","timestamp":"2026-10-08T14:41:17Z"}"#,
                                                      receivedAtUnixMilliseconds: received).first)
        #expect(withApp.body == "10,000원 충전했어요")
        #expect(withApp.notificationAtUnixMilliseconds == 1_791_470_477_000)
        let bare = try #require(try decoder.decode(#"{"message":"출금 1,000원","timestamp":"nonsense"}"#, receivedAtUnixMilliseconds: received).first)
        #expect(bare.source.displayName == nil)
        #expect(bare.notificationAtUnixMilliseconds == nil)
    }

    @Test func theSameNotificationSentTwiceIsOneRecordAndAnyDifferenceIsAnother() throws {
        let payload = #"{"app":"Toss","title":"9,900원 결제","body":"가맹점A","timestamp":"Oct 8, 2026 at 11:41:17 PM"}"#
        let first = try decoder.decode(payload, receivedAtUnixMilliseconds: received)[0]
        let resent = try decoder.decode(payload, receivedAtUnixMilliseconds: received + 60_000)[0]
        #expect(first.id == resent.id)
        let other = try decoder.decode(payload.replacingOccurrences(of: "9,900", with: "9,800"), receivedAtUnixMilliseconds: received)[0]
        #expect(other.id != first.id)
        // No timestamp: a resend can't be told from a second identical notification, so it is not merged.
        let untimed = #"{"app":"Toss","title":"9,900원 결제"}"#
        #expect(try decoder.decode(untimed, receivedAtUnixMilliseconds: received)[0].id
                != decoder.decode(untimed, receivedAtUnixMilliseconds: received + 1)[0].id)
    }

    @Test func anArrayIsSeveralNotifications() throws {
        let notifications = try decoder.decode(#"[{"app":"Toss","title":"a"},{"app":"Wallet","body":"b"}]"#, receivedAtUnixMilliseconds: received)
        #expect(notifications.map(\.source.displayName) == ["Toss", "Wallet"])
    }

    @Test func malformedInputIsRefused() {
        #expect(throws: ShortcutNotificationDecoder.DecodingError.notJSON) { try decoder.decode("not json", receivedAtUnixMilliseconds: received) }
        #expect(throws: ShortcutNotificationDecoder.DecodingError.notAnObject) { try decoder.decode("[1]", receivedAtUnixMilliseconds: received) }
        #expect(throws: ShortcutNotificationDecoder.DecodingError.empty) {
            try decoder.decode(#"{"app":"Toss","title":" ","timestamp":"x"}"#, receivedAtUnixMilliseconds: received)
        }
    }
}

@Suite struct NotificationIntakeTests {
    private let intake = NotificationIntake(timeZoneIdentifier: "Asia/Seoul")
    private let decoder = ShortcutNotificationDecoder(timeZone: seoul)

    private func payload(_ app: String, body: String) -> String {
        let fields = ["app": app, "title": "", "subtitle": "", "body": body, "timestamp": "Oct 2, 2026 at 7:13:30 PM"]
        return String(data: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
    }

    private var cardApproval: RawNotification {
        get throws { try decoder.decode(payload("현대카드", body: "김가명 님, 현대 체크 승인 \r\n51,000원 일시불, 10/02 19:13 \r\n가맹점A"), receivedAtUnixMilliseconds: received)[0] }
    }

    private var bankWithdrawal: RawNotification {
        get throws {
            try decoder.decode(payload("우리WON뱅킹", body: "[Web발신]\n우리 출금 51,000원 1002-123-456*** 잔액 1,234,000원 10/02 19:13:20"),
                               receivedAtUnixMilliseconds: received + 2_000)[0]
        }
    }

    private func replay(_ notifications: [RawNotification], setup: inout IntakeSetup) throws -> (CandidateProcessingSnapshot, [NotificationIntakeOutcome]) {
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        let outcomes = try notifications.map { try intake.ingest($0, setup: &setup, repository: &repository) }
        return (try repository.processingSnapshot(), outcomes)
    }

    @Test func withNoAccountsEveryPaymentWaitsAndItsAccountBecomesACandidate() throws {
        var setup = IntakeSetup()
        let (snapshot, outcomes) = try replay([try cardApproval, try bankWithdrawal], setup: &setup)
        #expect(snapshot.ledger.entries.isEmpty)
        #expect(outcomes.allSatisfy { if case .processed(_, .stored) = $0 { true } else { false } })
        #expect(Set(setup.registry.openCandidates.map(\.key.institution)) == [.woori, .hyundaiCard])
    }

    @Test func afterTheUserConfirmsTheAccountsAReplayRecordsTheCheckCardPaymentOnce() throws {
        var setup = IntakeSetup()
        let notifications = [try cardApproval, try bankWithdrawal]
        _ = try replay(notifications, setup: &setup)
        let bank = try #require(setup.registry.openCandidates.first { $0.key.institution == .woori })
        let card = try #require(setup.registry.openCandidates.first { $0.key.institution == .hyundaiCard })
        let target = try setup.confirmAsNew(bank.id, displayName: "생활비", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")),
                                            makeID: { "account-1" })
        try setup.link(card.id, to: target.binding)
        #expect(setup.configuration.accounts.map(\.name) == ["생활비"])

        for order in [notifications, notifications.reversed()] {
            var replayed = setup
            let (snapshot, _) = try replay(order, setup: &replayed)
            #expect(snapshot.ledger.entries.map(\.kind) == [.expense])
            #expect(snapshot.ledger.accountBalances[AccountID(rawValue: "account-1")] == (try Money(minorUnits: -51_000, currency: "KRW")))
            #expect(snapshot.candidates.values.filter { $0.promotedEntryID == nil && $0.corroborates == nil }.isEmpty)
            #expect(replayed == setup)
        }
    }

    @Test func aNotificationThatIsNotAPaymentChangesNothing() throws {
        var setup = IntakeSetup()
        let ad = try decoder.decode(payload("Toss", body: "이번 주 혜택을 확인해 보세요"), receivedAtUnixMilliseconds: received)[0]
        let (snapshot, outcomes) = try replay([ad], setup: &setup)
        #expect(snapshot.candidates.isEmpty)
        #expect(outcomes.count == 1)
        if case .processed = outcomes[0] { Issue.record("an ad became a candidate") }
        #expect(setup == IntakeSetup())
    }

    @Test func theSameNotificationReceivedTwiceIsProcessedOnce() throws {
        var setup = IntakeSetup()
        let approval = try cardApproval
        let (snapshot, outcomes) = try replay([approval, approval], setup: &setup)
        #expect(snapshot.candidates.count == 1)
        #expect(outcomes.last.map { if case .processed(_, .alreadyStored) = $0 { true } else { false } } == true)
    }
}

@Suite struct IntakeLedgerTests {
    private let decoder = ShortcutNotificationDecoder(timeZone: seoul)

    private func note(_ app: String, _ body: String, at offset: Int64 = 0) throws -> RawNotification {
        let fields = ["app": app, "body": body, "timestamp": "Oct 2, 2026 at 7:13:30 PM"]
        let text = String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
        return try decoder.decode(text, receivedAtUnixMilliseconds: received + offset)[0]
    }

    @Test func confirmingAnAccountLaterBindsTheNotificationsThatArrivedBeforeIt() throws {
        var ledger = try IntakeLedger(notifications: [], setup: IntakeSetup(), intake: NotificationIntake(timeZoneIdentifier: "Asia/Seoul"))
        let approval = try note("현대카드", "김가명 님, 현대 체크 승인 \r\n51,000원 일시불, 10/02 19:13 \r\n가맹점A")
        let withdrawal = try note("우리WON뱅킹", "[Web발신]\n우리 출금 51,000원 1002-123-456*** 잔액 1,234,000원 10/02 19:13:20", at: 2_000)
        let ad = try note("Toss", "이번 주 혜택을 확인해 보세요")
        #expect(try ledger.receive([approval, withdrawal, ad, approval]).map(\.id) == [approval.id, withdrawal.id, ad.id])
        #expect(ledger.status(of: approval.id) == .waiting([.unknownAccount]))
        if case .notTransaction = ledger.status(of: ad.id) {} else { Issue.record("an ad is not a transaction") }

        let bank = try #require(ledger.setup.registry.openCandidates.first { $0.key.institution == .woori })
        try ledger.confirmAsNew(bank.id, displayName: "생활비", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")),
                                makeID: { "account-1" })
        let card = try #require(ledger.setup.registry.openCandidates.first { $0.key.institution == .hyundaiCard })
        try ledger.link(card.id, to: .account(AccountID(rawValue: "account-1")))

        let entries = try ledger.repository.processingSnapshot().ledger.entries
        #expect(entries.map(\.kind) == [.expense])
        #expect(ledger.status(of: approval.id) == .recorded(entries[0].id))
        #expect(ledger.status(of: withdrawal.id) == .recorded(entries[0].id))
        #expect(ledger.notifications.count == 3)
        #expect(ledger.setup.registry.openCandidates.isEmpty)
    }
}

@Suite struct IntakeRuleTests {
    private let decoder = ShortcutNotificationDecoder(timeZone: seoul)

    @Test func aWalletChargeThatNeverNamesItsAccountIsBoundByTheUsersRule() throws {
        var ledger = try IntakeLedger(notifications: [], setup: IntakeSetup(), intake: NotificationIntake(timeZoneIdentifier: "Asia/Seoul"))
        let text = #"{"app":"Kakaopay","title":"카카오페이","body":"10,000원 충전이 완료되었어요\n- 충전계좌 : 가상 0000","timestamp":"Oct 2, 2026 at 7:13:30 PM"}"#
        let charge = try decoder.decode(text, receivedAtUnixMilliseconds: received)[0]
        try ledger.receive([charge])
        guard case .waiting = ledger.status(of: charge.id) else { Issue.record("expected review, got \(ledger.status(of: charge.id))"); return }
        let question = try #require(ledger.ruleQuestion(for: charge.id))
        #expect(question.institution == .kakaoPay)
        #expect(question.choices.isEmpty)

        try ledger.answer(question, binding: nil, newAccount: ("카카오페이머니", .account(.prepaid, openingBalance: Money(minorUnits: 0, currency: "KRW"))),
                          at: received, makeID: { "wallet" })
        #expect(ledger.setup.registry.rules.count == 1)
        #expect(ledger.ruleQuestion(for: charge.id) == nil)
        // The charge now has its wallet; its source account (an unknown bank) is not one of the user's, so it still
        // waits as an incomplete transfer rather than becoming spending or income.
        #expect(ledger.status(of: charge.id) == .waiting([.incompleteTransfer]))
    }
}
