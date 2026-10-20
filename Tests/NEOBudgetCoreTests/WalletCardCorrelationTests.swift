import Foundation
import Testing
@testable import NEOBudgetCore
import NEOBudgetInMemoryStorage

private let seoul = TimeZone(identifier: "Asia/Seoul")!
private let received: Int64 = 1_790_936_040_000

/// A Wallet card payment and the Hyundai Card app's alert of the same payment are one payment (synthetic shops only).
@Suite struct WalletCardCorrelationTests {
    private let intake = NotificationIntake(timeZoneIdentifier: "Asia/Seoul")
    private let decoder = ShortcutNotificationDecoder(timeZone: seoul)
    private let cardAccount = AccountID(rawValue: "check-card")

    private func note(_ app: String, title: String = "", subtitle: String = "", body: String, time: String) throws -> RawNotification {
        let fields = ["app": app, "title": title, "subtitle": subtitle, "body": body, "timestamp": "Oct 2, 2026 at \(time)"]
        let text = String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
        return try decoder.decode(text, receivedAtUnixMilliseconds: received)[0]
    }

    private func appAlert(_ amount: String, _ shop: String, time: String = "7:13:30 PM") throws -> RawNotification {
        try note("현대카드", body: "김가명 님, 현대 체크 승인 \r\n\(amount)원 일시불, 10/02 19:13 \r\n\(shop)", time: time)
    }

    private func walletTap(_ amount: String, _ shop: String, time: String = "7:13:41 PM") throws -> RawNotification {
        try note("Wallet", title: "현대카드", subtitle: "\(shop), 서울특별시", body: "₩\(amount)", time: time)
    }

    /// A setup in which the check card is already linked to a ledger account (as after the user confirmed it once).
    private func linkedSetup() throws -> IntakeSetup {
        var setup = IntakeSetup()
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        _ = try intake.ingest(try appAlert("1,000", "설정용가게"), setup: &setup, repository: &repository)
        let card = try #require(setup.registry.openCandidates.first { $0.key.institution == .hyundaiCard })
        try setup.confirmAsNew(card.id, displayName: "체크카드", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")),
                               makeID: { "check-card" })
        return setup
    }

    private func replay(_ notifications: [RawNotification]) throws -> CandidateProcessingSnapshot {
        var setup = try linkedSetup()
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        for notification in notifications { _ = try intake.ingest(notification, setup: &setup, repository: &repository) }
        return try repository.processingSnapshot()
    }

    private func open(_ snapshot: CandidateProcessingSnapshot) -> Int {
        snapshot.candidates.values.filter { $0.promotedEntryID == nil && $0.corroborates == nil }.count
    }

    @Test func oneRealPaymentIsCountedOnceInEitherArrivalOrder() throws {
        let app = try appAlert("9,900", "가상샐러드가게미아점")
        let tap = try walletTap("9,900", "가상샐러드가게미아점")
        for order in [[app, tap], [tap, app]] {
            let snapshot = try replay(order)
            #expect(snapshot.ledger.entries.map(\.kind) == [.expense])
            #expect(snapshot.ledger.accountBalances[cardAccount] == (try Money(minorUnits: -9_900, currency: "KRW")))
            #expect(open(snapshot) == 0)
            #expect(snapshot.candidates.values.filter { $0.corroborates?.rule == .walletTap }.count == 1)
        }
    }

    @Test func theAppAlertMerchantIsTheShopNotTheGreeting() throws {
        let snapshot = try replay([try appAlert("9,900", "가상샐러드가게미아점")])
        let draft = try #require(snapshot.candidates.values.compactMap(\.candidate.sourceDraft).first { $0.amount.minorUnits == 9_900 })
        #expect(draft.counterparty.merchantRaw == "가상샐러드가게미아점")
    }

    @Test func aWalletPaymentAloneStillAsksForTheAccount() throws {
        let snapshot = try replay([try walletTap("9,900", "가상샐러드가게미아점")])
        #expect(snapshot.ledger.entries.isEmpty)
        #expect(open(snapshot) == 1)
    }

    @Test func aDifferentShopOrAFarTimeIsNotTheSamePayment() throws {
        let app = try appAlert("9,900", "가상샐러드가게미아점")
        for tap in [try walletTap("9,900", "다른가상식당"), try walletTap("9,900", "가상샐러드가게미아점", time: "7:17:41 PM")] {
            for order in [[app, tap], [tap, app]] {
                let snapshot = try replay(order)
                #expect(snapshot.ledger.entries.count == 1)
                #expect(open(snapshot) == 1)
            }
        }
    }

    @Test func aSameAmountRepeatInTheSameAppStillWaitsForReviewAndOnlyOneWalletAlertIsAbsorbed() throws {
        let first = try appAlert("4,500", "가상카페", time: "7:13:30 PM")
        let firstTap = try walletTap("4,500", "가상카페", time: "7:13:41 PM")
        let second = try appAlert("4,500", "가상카페", time: "7:15:30 PM")
        let secondTap = try walletTap("4,500", "가상카페", time: "7:15:41 PM")
        let snapshot = try replay([first, firstTap, second, secondTap])
        #expect(snapshot.ledger.entries.count == 1)
        #expect(open(snapshot) == 2)
        #expect(snapshot.candidates.values.filter { $0.corroborates?.rule == .walletTap }.count == 1)
    }
}
