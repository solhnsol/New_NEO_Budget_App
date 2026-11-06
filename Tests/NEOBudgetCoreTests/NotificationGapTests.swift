import Foundation
import Testing
@testable import NEOBudgetCore
import NEOBudgetInMemoryStorage

private let seoul = TimeZone(identifier: "Asia/Seoul")!
private let received: Int64 = 1_790_936_040_000
private let living = AccountID(rawValue: "living")
private let kakao = AccountID(rawValue: "kakao")
private let card = AccountID(rawValue: "check-card")

/// Gaps found in a real phone's notification history (synthetic names and amounts).
@Suite struct NotificationGapTests {
    private let intake = NotificationIntake(timeZoneIdentifier: "Asia/Seoul")
    private let decoder = ShortcutNotificationDecoder(timeZone: seoul)

    private func note(_ app: String, title: String = "", subtitle: String = "", body: String, time: String) throws -> RawNotification {
        let fields = ["app": app, "title": title, "subtitle": subtitle, "body": body, "timestamp": "Oct 2, 2026 at \(time)"]
        let text = String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
        return try decoder.decode(text, receivedAtUnixMilliseconds: received)[0]
    }

    private func woori(_ text: String, time: String = "2:22:07 PM") throws -> RawNotification {
        try note("우리WON뱅킹", title: "우리WON뱅킹 입출금알림", body: "\(text) 1002-663-019***계좌 잔액 3,861,435원 10/02 14:22:07", time: time)
    }

    private func bankSetup(kakaoWallet: Bool = false, hyundaiCard: Bool = false) throws -> IntakeSetup {
        var setup = IntakeSetup()
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        _ = try intake.ingest(try note("우리WON뱅킹", body: "[Web발신]\n우리 출금 1,000원 1002-663-019*** 설정용가게 잔액 1,234,000원 10/02 14:00:00", time: "2:00:00 PM"),
                              setup: &setup, repository: &repository)
        let bank = try #require(setup.registry.openCandidates.first { $0.key.institution == .woori })
        try setup.confirmAsNew(bank.id, displayName: "생활비", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "living" })
        if kakaoWallet {
            try setup.addAccount(displayName: "카카오페이머니", institution: .kakaoPay,
                                 kind: .account(.prepaid, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "kakao" })
        }
        if hyundaiCard {
            _ = try intake.ingest(try note("현대카드", body: "김가명 님, 현대 체크 승인 \r\n1,000원 일시불, 10/02 14:00 \r\n설정용카드", time: "2:00:00 PM"),
                                  setup: &setup, repository: &repository)
            let open = try #require(setup.registry.openCandidates.first { $0.key.institution == .hyundaiCard })
            try setup.confirmAsNew(open.id, displayName: "체크카드", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "check-card" })
        }
        return setup
    }

    private func replay(_ notifications: [RawNotification], kakaoWallet: Bool = false, hyundaiCard: Bool = false) throws -> CandidateProcessingSnapshot {
        var setup = try bankSetup(kakaoWallet: kakaoWallet, hyundaiCard: hyundaiCard)
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        for n in notifications { _ = try intake.ingest(n, setup: &setup, repository: &repository) }
        return try repository.processingSnapshot()
    }

    private func balance(_ s: CandidateProcessingSnapshot, _ id: AccountID) -> Int64 { s.ledger.accountBalances[id]?.minorUnits ?? 0 }
    private func open(_ s: CandidateProcessingSnapshot) -> Int { s.candidates.values.filter { $0.promotedEntryID == nil && $0.corroborates == nil }.count }

    // MARK: 1. Wallet card tap -> the registered card

    private func appAlert(_ amount: String, _ shop: String, time: String = "2:30:00 PM") throws -> RawNotification {
        try note("현대카드", body: "김가명 님, 현대 체크 승인 \r\n\(amount)원 일시불, 10/02 14:30 \r\n\(shop)", time: time)
    }
    private func walletTap(_ amount: String, _ shop: String, time: String = "2:30:11 PM") throws -> RawNotification {
        try note("Wallet", title: "현대카드", subtitle: "\(shop), 서울특별시", body: "₩\(amount)", time: time)
    }

    @Test func aWalletTapAloneStaysUnknownAndAnUnregisteredCardAlertAbsorbsIt() throws {
        #expect(try open(replay([try walletTap("2,800", "가상카페")], hyundaiCard: true)) == 1)
        // The card is not registered: its alert waits for review, and the tap is evidence of it, not a second item.
        let snapshot = try replay([try appAlert("2,800", "가상카페"), try walletTap("2,800", "가상카페")])
        #expect(snapshot.ledger.entries.isEmpty)
        #expect(open(snapshot) == 1)
    }

    // MARK: 2. Kakao Pay top-up

    @Test func aKakaoPayTopUpIsATransferWhenTheWalletIsRegistered() throws {
        let snapshot = try replay([try woori("[출금] (주)카카오페이 10,000원")], kakaoWallet: true)
        #expect(snapshot.ledger.entries.map(\.kind) == [.transfer])
        #expect(balance(snapshot, kakao) == 10_000)
    }

    @Test func aKakaoPayTopUpStaysSpendingWhenTheWalletIsNotRegistered() throws {
        let snapshot = try replay([try woori("[출금] (주)카카오페이 10,000원")])
        #expect(snapshot.ledger.entries.map(\.kind) == [.expense])
        #expect(open(snapshot) == 0)
    }

    @Test func theSameKakaoPayAlertTwiceChangesNothing() throws {
        let alert = try woori("[출금] (주)카카오페이 10,000원")
        let snapshot = try replay([alert, alert])
        #expect(snapshot.ledger.entries.count == 1)
    }

    // MARK: 3. Toss transfer with no Toss alert

    @Test func aWithdrawalToTossAndANameIsMySpendingOnThatPerson() throws {
        let snapshot = try replay([try woori("[출금] 토스    김의근 10,000원", time: "1:01:00 PM")])
        #expect(snapshot.ledger.entries.map(\.kind) == [.expense])
        let draft = try #require(snapshot.candidates.values.compactMap(\.candidate.sourceDraft).first { $0.ruleID == NotificationIntake.tossPersonTransferRuleID })
        #expect(draft.counterparty.payeeRaw == "김의근")
        #expect(PayeeKind.classify(draft) == .person)
    }

    @Test func aTossServiceWordIsNotAPerson() throws {
        let snapshot = try replay([try woori("[출금] 토스 페이 10,000원")])
        #expect(snapshot.ledger.entries.isEmpty)
    }

    // MARK: Tmoney fare delivered twice vs. two rides

    private func fare(_ balance: String, time: String) throws -> RawNotification {
        try note("Wallet", title: "Tmoney", subtitle: "₩100 for Metro", body: "Your new balance is ₩\(balance).", time: time)
    }

    private func transitSetup() throws -> IntakeSetup {
        var setup = IntakeSetup()
        try setup.addAccount(displayName: "티머니", institution: .transit,
                             kind: .account(.prepaid, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "tmoney" })
        return setup
    }

    @Test func theSameFareAlertTwiceIsOnePaymentAndTwoRidesAreTwo() throws {
        var setup = try transitSetup()
        let evidence = AccountEvidenceExtractor().evidence(from: try fare("9,330", time: "11:27:00 AM"))
        try setup.addSourceRule(for: evidence, binding: .account(AccountID(rawValue: "tmoney")), createdAtUnixMilliseconds: 1)
        func run(_ list: [RawNotification]) throws -> CandidateProcessingSnapshot {
            var s = setup
            var repository = try InMemoryCandidateProcessingRepository(configuration: s.configuration)
            for n in list { _ = try intake.ingest(n, setup: &s, repository: &repository) }
            return try repository.processingSnapshot()
        }
        let twice = try run([try fare("9,330", time: "11:27:00 AM"), try fare("9,330", time: "11:27:02 AM")])
        #expect(twice.ledger.entries.count == 1 && open(twice) == 0)
        let rides = try run([try fare("9,330", time: "11:27:00 AM"), try fare("9,230", time: "11:29:00 AM")])
        #expect(rides.ledger.entries.count == 2 && open(rides) == 0)
    }

    // MARK: Own-account transfer: a withdrawal and a deposit of one amount at once

    private func twoBanks() throws -> IntakeSetup {
        var setup = try bankSetup()
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        _ = try intake.ingest(try note("우리WON뱅킹", body: "[입금] 설정용 1,000원 1002-777-888***계좌 잔액 5,000원 10/02 14:00:00", time: "2:00:00 PM"),
                              setup: &setup, repository: &repository)
        let other = try #require(setup.registry.openCandidates.first { $0.key.institution == .woori })
        try setup.confirmAsNew(other.id, displayName: "저축", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "saving" })
        return setup
    }

    private func replayTwoBanks(_ list: [RawNotification]) throws -> CandidateProcessingSnapshot {
        var setup = try twoBanks()
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        for n in list { _ = try intake.ingest(n, setup: &setup, repository: &repository) }
        return try repository.processingSnapshot()
    }

    private func out(_ name: String, time: String = "1:01:00 PM") throws -> RawNotification {
        try note("우리WON뱅킹", body: "[출금] \(name) 10,000원 1002-663-019***계좌 잔액 3,861,435원 10/02 13:01:00", time: time)
    }
    private func inn(time: String = "1:01:02 PM") throws -> RawNotification {
        try note("우리WON뱅킹", body: "[입금] 김의근 10,000원 1002-777-888***계좌 잔액 15,000원 10/02 13:01:02", time: time)
    }

    @Test func aWithdrawalAndADepositOfOneAmountOnTwoOwnAccountsAreOneTransferInEitherOrder() throws {
        for name in ["토스    김의근", "가상이체"] {
            let withdrawal = try out(name), deposit = try inn()
            for order in [[withdrawal, deposit], [deposit, withdrawal]] {
                let snapshot = try replayTwoBanks(order)
                #expect(balance(snapshot, living) == -10_000)
                #expect(balance(snapshot, AccountID(rawValue: "saving")) == 10_000)
                #expect(snapshot.ledger.entries.filter { $0.kind == .transfer }.count == 1)
                // Whatever was booked in between is cancelled out: nothing is left as spending.
                let spent = snapshot.ledger.entries.compactMap(\.budgetImpact).reduce(0) { $0 + ($1.kind == .expense ? $1.amount.minorUnits : -$1.amount.minorUnits) }
                #expect(spent == 0)
                #expect(open(snapshot) == 0)
            }
        }
    }

    @Test func aDepositFarFromTheWithdrawalIsNotATransfer() throws {
        let snapshot = try replayTwoBanks([try out("토스    김의근"), try inn(time: "1:05:00 PM")])
        #expect(snapshot.ledger.entries.filter { $0.kind == .transfer }.isEmpty)
    }
}
