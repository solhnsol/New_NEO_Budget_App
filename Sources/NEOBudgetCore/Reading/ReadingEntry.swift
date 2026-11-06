import Foundation

/// 읽기 사전의 항목 하나. 알림 한 건에서 값을 읽는 방법(또는 읽지 않고 무시하는 방법)을 데이터로만 담는다.
/// 공식 항목(앱이 기본 제공)과 사용자가 만든 항목이 같은 모양이고, 코드는 항목을 해석하는 엔진뿐이다.
public struct ReadingEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Origin: String, Codable, Sendable { case official, user }

    public var id: String
    public var name: String
    public var origin: Origin
    public var enabled: Bool
    /// 공식 항목끼리의 순서(작을수록 먼저). 사용자 항목은 구체성으로 가른다.
    public var rank: Int
    /// nil이면 모든 앱의 알림에 적용된다.
    public var applicationIdentifier: String?
    /// 모두 맞아야 이 항목이 알림과 맞는다.
    public var conditions: [ReadingCondition]
    public var action: ReadingAction

    public init(
        id: String, name: String, origin: Origin = .official, enabled: Bool = true, rank: Int = 0,
        applicationIdentifier: String? = nil, conditions: [ReadingCondition], action: ReadingAction
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.enabled = enabled
        self.rank = rank
        self.applicationIdentifier = applicationIdentifier
        self.conditions = conditions
        self.action = action
    }

    /// 고정 표현이 많을수록 구체적이다. 사용자 항목끼리의 우선순위에 쓴다.
    public var specificity: Int { conditions.reduce(0) { $0 + $1.specificity } }
}

public enum ReadingField: String, Codable, Sendable { case title, subtitle, body, all }

public enum ReadingCondition: Codable, Equatable, Sendable {
    /// 필드에 이 고정 표현 중 하나가 들어 있다.
    case contains(ReadingField, [String])
    /// 필드 전체가 이 틀과 같다. 틀: 고정 글자 + `{금액}` 같은 칸 + `{*}`(아무 글자).
    case frame(ReadingField, String)
    /// 필드 안에 이 틀이 들어 있다.
    case frameContained(ReadingField, String)
    case notEmpty(ReadingField)

    var specificity: Int {
        switch self {
        case let .contains(_, phrases): return phrases.map(\.count).min() ?? 0
        case let .frame(_, frame), let .frameContained(_, frame): return ReadingFrame.literalCount(frame) + 1
        case .notEmpty: return 0
        }
    }
}

public enum ReadingAction: Codable, Equatable, Sendable {
    /// 거래가 아니므로 기록하지 않는다(광고, 인증, 잔액 안내, 사용자가 무시하기로 한 알림).
    case ignore(NotTransactionReason)
    case read(ReadingOutcome)
}

/// 항목에서 읽은 결과를 후보로 만드는 방법.
public struct ReadingOutcome: Codable, Equatable, Sendable {
    public enum NonPositiveAmount: String, Codable, Sendable {
        /// 금액이 0 이하면 읽기 실패로 알린다.
        case fail
        /// 이 항목은 맞지 않는 것으로 보고 다음 항목으로 넘어간다.
        case skip
    }

    public enum Instrument: Codable, Equatable, Sendable {
        /// 알림 글자에서 카드/계좌를 짐작한다(공용 읽기 설정의 규칙).
        case byText
        /// 정해진 종류. 이름은 알림의 제목 등에서 가져온다.
        case fixed(kind: InstrumentHintKind, nameFrom: ReadingField?, reportMissing: Bool)
    }

    public var ruleID: String
    public var kind: DraftEventKind
    public var direction: TransactionDirection
    public var instrument: Instrument
    /// 틀에 `{금액}` 칸이 있어도 0 이하일 때의 처리.
    public var nonPositiveAmount: NonPositiveAmount
    /// 승인번호·거래번호 같은 증거를 알림 전체 글에서 읽을지.
    public var evidenceFromText: Bool
    /// 메모로 가져올 글(정규식). 예: 출금 알림의 `토스…` 받는 사람.
    public var memoPattern: String?

    public init(
        ruleID: String, kind: DraftEventKind, direction: TransactionDirection,
        instrument: Instrument = .byText, nonPositiveAmount: NonPositiveAmount = .fail,
        evidenceFromText: Bool = true, memoPattern: String? = nil
    ) {
        self.ruleID = ruleID
        self.kind = kind
        self.direction = direction
        self.instrument = instrument
        self.nonPositiveAmount = nonPositiveAmount
        self.evidenceFromText = evidenceFromText
        self.memoPattern = memoPattern
    }
}

/// 알림에서 읽을 수 있는 값의 종류(칸). 이름은 사용자에게 보이는 말과 같다.
public enum ReadingSlot: String, Codable, Sendable, CaseIterable {
    case amount = "금액", balance = "잔액", merchant = "가맹점", payee = "입금자명"
    case memo = "메모", accountName = "통장이름", accountNumber = "계좌번호"
    case cardName = "카드이름", cardNumber = "카드번호", approvalNumber = "승인번호"

    var pattern: String {
        switch self {
        case .amount, .balance: return #"[0-9]+(?:,[0-9]{3})*"#
        case .accountNumber, .cardNumber: return #"[0-9*\-]+"#
        case .approvalNumber: return #"[0-9A-Za-z]+"#
        default: return #".+?"#
        }
    }
}
