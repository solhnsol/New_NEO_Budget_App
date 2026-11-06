import Foundation
import Testing
import NEOBudgetCore

private func draft(title: String?, body: String) throws -> TransactionCandidateDraft {
    let raw = RawNotification(
        id: "raw-1", source: NotificationSource(applicationIdentifier: "fixture.finance.app"), sourceDeliveryID: nil,
        capturedAtUnixMilliseconds: 1_780_000_001_000, notificationAtUnixMilliseconds: 1_780_000_000_000,
        title: title, subtitle: nil, body: body
    )
    let context = try NotificationParsingContext(
        timeZoneIdentifier: "Asia/Seoul", referenceTimeUnixMilliseconds: 1_800_000_000_000, parserID: "korean-financial", parserVersion: "2"
    )
    guard case let .candidate(draft) = try KoreanFinancialNotificationParser().parse(raw, context: context) else {
        Issue.record("expected a candidate")
        throw NotificationParseFailure.amountUnparseable
    }
    return draft
}

@Test func depositNameIsTheSenderNotTheAppTitle() throws {
    let oneLine = try draft(title: "우리WON뱅킹 입출금알림", body: "[Web발신]\n우리 입금 67,035원 1002-123-456*** 차유진 잔액 1,234,000원 10/02 19:10:00")
    #expect(oneLine.counterparty.payeeRaw == "차유진")
    let lines = try draft(title: "우리WON뱅킹 입출금알림", body: "입금 67,035원\n차유진\n잔액 1,234,000원")
    #expect(lines.counterparty.payeeRaw == "차유진")
}

@Test func aStatusHeadlineIsNotTheShop() throws {
    let beforeAmount = try draft(title: "결제 완료", body: "쿠팡에서 76,570원 결제했어요")
    #expect(beforeAmount.counterparty.merchantRaw == "쿠팡")
    let nameless = try draft(title: "결제 완료", body: "76,570원 결제")
    #expect(nameless.counterparty.merchantRaw == nil)
}
