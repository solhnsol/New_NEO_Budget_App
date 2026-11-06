import Foundation

/// 앱별 알림 모양(우리, 현대카드, 토스, 카카오페이, 월렛)에서 계좌·카드를 읽는 공식 항목.
public enum OfficialEvidenceEntries {
    private typealias E = ReadingEvidenceEntry
    private typealias I = EvidenceInstrument

    private static let account = #"{계좌번호=(?<![\d*-])(?=[\d-]*\*)\d{2,6}(?:-[\d*]{2,8}){1,3}(?![\d*-])}"#
    private static let balanceText = "잔액{re:\\s*}{잔액=[\\d,]+}{re:\\s*}원"
    private static let transitBalance = "balance is ₩{잔액=[\\d,]+}"

    private static func card(_ institution: String) -> I {
        I(institution: .fixed(institution), kind: .cardProduct, identifier: .cardProduct)
    }

    public static let all: [ReadingEvidenceEntry] = woori + hyundai + toss + kakao + wallet

    private static let woori: [E] = [
        E(id: "official.evidence.woori.account", name: "우리 입출금(계좌번호)", rank: 10, provider: "woori",
          conditions: [.frameContained(.all, account)], optionalReads: [.frameContained(.all, balanceText)],
          type: .bankTransaction, instrument: I(institution: .fixed("woori"), kind: .fixed(.bankAccount), identifier: .accountNumber), readsBalance: true),
        E(id: "official.evidence.woori.balance", name: "우리 입출금(잔액만)", rank: 11, provider: "woori",
          conditions: [.frameContained(.all, balanceText)],
          type: .bankTransaction, instrument: I(institution: .fixed("woori"), kind: .fixed(.bankAccount)), readsBalance: true),
    ]

    private static let hyundai: [E] = [
        E(id: "official.evidence.hyundai.approval", name: "현대카드 승인", rank: 10, provider: "hyundaicard",
          conditions: [.frameContained(.all, "현대{re:\\s*}{카드이름=[A-Za-z가-힣0-9]+}{re:\\s*}승인")],
          type: .cardApproval, instrument: card("hyundaicard")),
        E(id: "official.evidence.hyundai.cancel", name: "현대카드 취소", rank: 11, provider: "hyundaicard",
          conditions: [.frameContained(.all, "현대{re:\\s*}{카드이름=[A-Za-z가-힣0-9]+}{re:\\s*}취소")],
          type: .cardCancellation, instrument: card("hyundaicard")),
    ]

    private static let toss: [E] = {
        var list: [E] = [
            E(id: "official.evidence.toss.bank-transfer", name: "토스뱅크 이체", rank: 10, provider: "toss",
              conditions: [.contains(.all, ["→"]), .contains(.all, ["통장"]), .contains(.all, ["입금", "출금"])],
              type: .tossBankTransfer, instrument: I(institution: .fixed("tossbank"), kind: .fixed(.bankAccount))),
            E(id: "official.evidence.toss.interest", name: "토스뱅크 이자", rank: 11, provider: "toss",
              conditions: [.contains(.all, ["이자"]), .contains(.all, ["통장"])],
              type: .tossBankInterest, instrument: I(institution: .fixed("tossbank"), kind: .fixed(.bankAccount))),
            E(id: "official.evidence.toss.person-deposit", name: "토스 사람 입금", rank: 12, provider: "toss",
              conditions: [.frameContained(.all, "{기관=[가-힣]+}{re:\\s*}계좌{re:(?:로|에)\\s*}입금")],
              type: .tossPersonDeposit, instrument: I(institution: .named, kind: .fixed(.bankAccount))),
        ]
        // 결제 알림: 제목이나 본문에 `결제`가 있을 때, 어떤 수단인지에 따라.
        for (gate, field) in [("title", ReadingField.title), ("body", ReadingField.body)] {
            let gateCondition = ReadingCondition.contains(field, ["결제"])
            list += [
                E(id: "official.evidence.toss.pay.card.\(gate)", name: "토스 결제(현대카드)", rank: 20, provider: "toss",
                  conditions: [gateCondition, .frameContained(.all, "현대카드{re:\\s*}{카드이름=[A-Za-z0-9]+|체크}")],
                  type: .tossPayment, instrument: card("hyundaicard")),
                E(id: "official.evidence.toss.pay.money.\(gate)", name: "토스 결제(토스페이머니)", rank: 21, provider: "toss",
                  conditions: [gateCondition, .frameContained(.body, "{re:^\\s*}토스페이머니{re:\\s*[・·]}")],
                  type: .tossPayment, instrument: I(institution: .fixed("tosspay"), kind: .fixed(.prepaidWallet))),
                E(id: "official.evidence.toss.pay.bank.\(gate)", name: "토스 결제(은행 계좌)", rank: 22, provider: "toss",
                  conditions: [gateCondition, .frameContained(.body, "{re:^\\s*}{기관=[가-힣]+}{re:\\s*[・·]}")],
                  type: .tossPayment, instrument: I(institution: .named, kind: .fixed(.bankAccount), unresolved: .skipEntry)),
                E(id: "official.evidence.toss.pay.unknown.\(gate)", name: "토스 결제(수단 미상)", rank: 23, provider: "toss",
                  conditions: [gateCondition], type: .tossPayment, instrument: I(institution: .none, kind: .fixed(.unknown))),
            ]
        }
        return list
    }()

    private static let kakao: [E] = [
        E(id: "official.evidence.kakao.charge", name: "카카오페이 충전", rank: 10, provider: "kakaopay",
          conditions: [.contains(.all, ["충전"]), .frameContained(.all, "충전계좌{re:\\s*:\\s*}{기관=\\S+}{re:\\s+}{계좌번호=\\d{4}}")],
          type: .kakaoCharge, instrument: I(institution: .fixed("kakaopay"), kind: .fixed(.prepaidWallet)),
          counterpart: I(institution: .named, kind: .fixed(.bankAccount), identifier: .accountTail, unresolved: .unknownHint)),
        E(id: "official.evidence.kakao.send", name: "카카오페이 송금", rank: 11, provider: "kakaopay",
          conditions: [.contains(.all, ["송금했"]), .frameContained(.all, "{기관=\\S+}{re:\\s+}{계좌번호=\\d{4}}{re:\\s*\\(}")],
          type: .kakaoSend, instrument: I(institution: .fixed("kakaopay"), kind: .fixed(.prepaidWallet)),
          counterpart: I(institution: .named, kind: .fixed(.bankAccount), identifier: .accountTail, unresolved: .unknownHint)),
        E(id: "official.evidence.kakao.receive", name: "카카오페이 받음", rank: 12, provider: "kakaopay",
          conditions: [.contains(.all, ["보냈"])],
          type: .kakaoReceive, instrument: I(institution: .fixed("kakaopay"), kind: .fixed(.prepaidWallet))),
    ]

    private static let transit = I(institution: .fixed("transit"), kind: .fixed(.transitCard))

    private static let wallet: [E] = [
        E(id: "official.evidence.wallet.fare", name: "교통카드 요금", rank: 10, provider: "wallet",
          conditions: [.frameContained(.subtitle, "{re:^\\s*}₩{금액=[\\d,]+}{re:\\s+}for{re:\\s}"), .frameContained(.body, transitBalance)],
          type: .transitFare, instrument: transit, readsBalance: true, readsTextAmount: true),
        E(id: "official.evidence.wallet.no-charge", name: "교통카드 무료", rank: 11, provider: "wallet",
          conditions: [.frameContained(.body, transitBalance), .frameContained(.body, "{re:(?i)no charge}")],
          type: .transitNoCharge, instrument: transit, readsBalance: true),
        E(id: "official.evidence.wallet.balance", name: "교통카드 잔액", rank: 12, provider: "wallet",
          conditions: [.frameContained(.body, transitBalance)], type: .transitBalanceOnly, instrument: transit, readsBalance: true),
        E(id: "official.evidence.wallet.tap.hyundai", name: "월렛 카드(현대카드)", rank: 13, provider: "wallet",
          conditions: [.frame(.body, "₩{금액=[\\d,]+}"), .contains(.title, ["카드"]), .contains(.title, ["현대카드"])],
          type: .walletCardTap, instrument: I(institution: .fixed("hyundaicard"), kind: .fixed(.unknown))),
        E(id: "official.evidence.wallet.tap", name: "월렛 카드", rank: 14, provider: "wallet",
          conditions: [.frame(.body, "₩{금액=[\\d,]+}"), .contains(.title, ["카드"])],
          type: .walletCardTap, instrument: I(institution: .none, kind: .fixed(.unknown))),
    ]
}
