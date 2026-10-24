import Foundation
import NEOBudgetCore
import NEOBudgetInMemoryStorage

/// The words the inbox and the account questions use for what the pipeline decided.
enum IntakeText {
    static func status(_ status: IntakeStatus) -> String {
        switch status {
        case .recorded: "가계부에 반영됨"
        case .sameActAs: "다른 알림과 같은 거래"
        case let .waiting(issues): "검토 대기: " + (issues.first.map(issue) ?? "확인 필요")
        case .notTransaction: "거래 아님"
        case .unreadable: "금액을 읽지 못함"
        case .failed: "처리하지 못함"
        }
    }

    /// Nothing for the user to do.
    static func isSettled(_ status: IntakeStatus) -> Bool {
        switch status {
        case .recorded, .sameActAs, .notTransaction: true
        case .waiting, .unreadable, .failed: false
        }
    }

    /// Waiting because the message never says which account it is about: tapping it asks the user (`RuleAnswerSheet`).
    static func asksForAccount(_ status: IntakeStatus) -> Bool {
        if case let .waiting(issues) = status { return issues.contains(.unboundSource) }
        return false
    }

    static func issue(_ issue: CandidateIssue) -> String {
        switch issue {
        case .unknownAccount: "처음 보는 계좌"
        case .unboundSource: "어느 계좌인지 모름"
        case .incompleteTransfer: "이체 상대 계좌를 모름"
        case .unsupportedEvent: "다른 알림으로 설명되지 않은 출금"
        case .missingOriginalEntry: "원래 결제를 찾지 못함"
        case .possibleReturnOfEarlierPurchase: "이전 결제의 환불일 수 있음"
        case .possibleSameMoneyRecorded: "이미 기록된 것과 같은 돈일 수 있음"
        case .parserUncertain: "알림 해석이 불확실"
        case .ambiguousWithoutStrongIdentity, .conflictingStrongIdentity: "같은 거래인지 불확실"
        case .missingAmount, .invalidAmount: "금액 확인 필요"
        case .missingTransactionTime: "시각 확인 필요"
        case .promotionRejected: "가계부에 넣지 못함"
        }
    }

    static func institution(_ id: InstitutionID?) -> String {
        guard let id else { return "알 수 없음" }
        return [
            "woori": "우리은행", "hyundaicard": "현대카드", "tossbank": "토스뱅크", "kakaopay": "카카오페이",
            "transit": "교통카드", "kakaobank": "카카오뱅크", "shinhan": "신한은행", "kb": "국민은행", "hana": "하나은행", "nh": "농협은행",
        ][id.rawValue] ?? id.rawValue
    }

    static func kind(_ kind: InstrumentKind) -> String {
        switch kind {
        case .bankAccount: "계좌"
        case .debitCard: "체크카드"
        case .creditCard: "신용카드"
        case .prepaidWallet: "선불 지갑"
        case .transitCard: "교통카드"
        case .unknown: "알 수 없음"
        }
    }

    static func identifier(_ identifier: AccountIdentifier) -> String {
        switch identifier {
        case let .accountNumber(number): number.pattern
        case let .accountTail(tail), let .cardTail(tail): "끝자리 \(tail)"
        case let .cardProduct(product): product
        }
    }

    static func suggestedName(institution: InstitutionID?, kind: InstrumentKind) -> String {
        "\(self.institution(institution)) \(self.kind(kind))"
    }

    /// What a new ledger target for this kind of instrument is: a card liability for a credit card, otherwise an
    /// account starting at zero (the app only counts what notifications moved).
    static func newTargetKind(for kind: InstrumentKind) -> NewTargetKind? {
        guard let zero = try? Money(minorUnits: 0, currency: "KRW") else { return nil }
        switch kind {
        case .creditCard: return .creditInstrument(currency: "KRW")
        case .prepaidWallet, .transitCard: return .account(.prepaid, openingBalance: zero)
        case .bankAccount, .debitCard, .unknown: return .account(.bank, openingBalance: zero)
        }
    }

    /// Whether a registered account can take messages about this kind of instrument.
    static func fits(_ profile: AccountProfile, _ kind: InstrumentKind) -> Bool {
        switch profile.binding {
        case .creditInstrument: kind.bindsToCreditInstrument
        case .account: !kind.bindsToCreditInstrument
        }
    }

    /// The notification's text on one or two lines.
    static func preview(_ notification: RawNotification) -> String {
        [notification.title, notification.subtitle, notification.body]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
