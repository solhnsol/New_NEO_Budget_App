import Foundation

/// 앱이 기본으로 주는 읽기 항목. 예전에 코드(`KoreanFinancialNotificationParser`)에 있던 규칙을 그대로 옮긴 것이다.
/// 특정 사람·가게에 맞춘 규칙은 여기에 두지 않는다(사용자 항목으로 만든다).
public enum OfficialReadingEntries {
    private static let region = #"{re:(?:,\s*(?:(?:서울|부산|대구|인천|광주|대전|울산)(?:특별시|광역시)|세종특별자치시|(?:경기|강원|충청[남북]|전라[남북]|경상[남북])도|(?:강원|전북)특별자치도|제주특별자치도))?}"#
    private static let tossName = #"(?<![가-힣A-Za-z0-9])토스(?!뱅크)\S*"#

    public static let walletCardPaymentRuleID = "wallet-card-payment"

    private static func ignore(_ id: String, _ name: String, _ rank: Int, _ reason: NotTransactionReason, _ terms: [String]) -> ReadingEntry {
        ReadingEntry(id: "official.\(id)", name: name, rank: rank, conditions: [.contains(.all, terms)], action: .ignore(reason))
    }

    private static func read(
        _ id: String, _ name: String, _ rank: Int, _ terms: [String], _ ruleID: String,
        _ kind: DraftEventKind, _ direction: TransactionDirection, memo: String? = nil
    ) -> ReadingEntry {
        ReadingEntry(
            id: "official.\(id)", name: name, rank: rank, conditions: [.contains(.all, terms)],
            action: .read(ReadingOutcome(ruleID: ruleID, kind: kind, direction: direction, memoPattern: memo))
        )
    }

    public static let all: [ReadingEntry] = [
        // 교통카드: 월렛 영문 알림(`₩1,550 for Metro` + `Your new balance is ₩10,000.`)
        ReadingEntry(
            id: "official.transit-fare", name: "교통카드 요금", rank: 10,
            conditions: [.frameContained(.body, "balance is ₩{잔액}"), .frame(.subtitle, "₩{금액} for {가맹점}")],
            action: .read(ReadingOutcome(
                ruleID: "transit-fare", kind: .purchase, direction: .outflow,
                instrument: .fixed(kind: .transitCard, nameFrom: .title, reportMissing: false),
                nonPositiveAmount: .skip, evidenceFromText: false
            ))
        ),
        // 요금이 없는 교통카드 알림(잔액만, 0원)은 거래가 아니다.
        ReadingEntry(
            id: "official.transit-balance-only", name: "교통카드 잔액 안내", rank: 11,
            conditions: [.frameContained(.body, "balance is ₩{잔액}")], action: .ignore(.balanceInquiry)
        ),
        // 월렛 카드 결제: 제목 `현대카드`, 부제 `<상호>, <지역>`, 본문 `₩1,200`
        ReadingEntry(
            id: "official.wallet-card-payment", name: "월렛 카드 결제", rank: 20,
            conditions: [.contains(.title, ["카드"]), .notEmpty(.subtitle), .frame(.body, "₩{금액}"), .frame(.subtitle, "{가맹점}" + region)],
            action: .read(ReadingOutcome(
                ruleID: walletCardPaymentRuleID, kind: .purchase, direction: .outflow,
                instrument: .fixed(kind: .unknown, nameFrom: .title, reportMissing: true), evidenceFromText: false
            ))
        ),

        ignore("promotion", "광고·혜택", 100, .promotion, ["광고", "혜택", "이벤트", "캐시백 안내"]),
        ignore("declined", "승인 거절", 101, .declined, ["승인거절", "승인 거절", "결제실패", "결제 실패", "한도초과", "처리실패"]),
        ignore("pending", "예정·대기", 102, .pending, [
            "예약이체", "예약 이체", "결제예정", "결제 예정", "입금예정", "환불 예정", "결제 대기", "결제대기", "승인 대기", "승인대기",
        ]),
        ignore("request", "송금·입금 요청", 103, .request, ["송금 요청", "송금요청", "송금을 받아주세요", "입금 요청"]),
        ignore("security", "사고예방·해외 확인", 104, .authentication, ["사고예방", "해외사용 확인"]),
        ignore("limit-change", "한도 변경", 105, .configurationChange, ["이체한도", "이체 한도", "한도 변경", "한도변경"]),

        read("card-bill", "카드대금", 200, ["카드대금", "결제대금"], "card-bill-payment", .cardBillPayment, .outflow),
        read("card-payment-withdrawal", "카드결제 출금", 201, ["카드결제 출금", "카드 결제 출금"], "card-payment-withdrawal", .cardBillPayment, .outflow),
        read("cancellation", "취소", 202, ["취소"], "adjustment", .cancellation, .inflow),
        read("refund", "환불", 203, ["환불"], "adjustment", .refund, .inflow),
        read("transfer-in", "입금 이체", 204, ["입금이체", "이체입금", "입금 이체", "이체 입금", "입금됐어요", "입금되었습니다"], "transfer-in", .transferIn, .inflow),
        read("transfer-out", "출금 이체·송금", 205, ["출금이체", "이체출금", "출금 이체", "이체 출금", "송금이 완료", "송금했", "송금"], "transfer-out", .transferOut, .outflow),
        read("wallet-top-up", "충전 완료", 206, ["충전이 완료", "충전 완료"], "wallet-top-up", .walletTopUp, .inflow),
        read("deposit", "입금", 207, ["입금"], "deposit", .deposit, .inflow),
        read("withdrawal", "출금", 208, ["출금"], "withdrawal", .withdrawal, .outflow, memo: tossName),
        read("purchase", "승인·사용·결제", 209, ["승인", "사용", "결제"], "purchase", .purchase, .outflow),

        ignore("login", "로그인·인증", 300, .authentication, ["로그인", "인증"]),
        ignore("declined-word", "거절", 301, .declined, ["거절"]),
        ignore("pending-word", "대기", 302, .pending, ["대기"]),
        ignore("balance-inquiry", "잔액 안내", 303, .balanceInquiry, ["잔액"]),
    ]
}
