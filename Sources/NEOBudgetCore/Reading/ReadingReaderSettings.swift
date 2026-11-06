import Foundation

/// 공용 읽기 설정: 항목에 칸이 따로 적혀 있지 않을 때 엔진이 쓰는 한국 금융 알림의 일반적인 글 규칙.
/// 코드가 아니라 데이터라서 공식 사전과 함께 갱신되고, 특정 사람·앱에 맞춘 규칙은 여기에 두지 않는다.
public struct ReadingReaderSettings: Codable, Equatable, Sendable {
    public struct InstrumentRule: Codable, Equatable, Sendable {
        public var terms: [String]
        public var kind: InstrumentHintKind
        public var name: String?
    }

    /// 글에서 카드/계좌를 짐작하는 규칙. 위에서부터 첫 번째가 이긴다.
    public var instrumentRules: [InstrumentRule]
    /// 이 말이 든 줄은 계좌의 누적·한도 이야기라 이번 거래 금액이 아니다.
    public var cumulativeTerms: [String]
    /// 이 말부터 뒤는 잔액 이야기다.
    public var balanceTerms: [String]
    public var foreignCurrencyTerms: [String]
    /// 원화 금액이 있는 줄에 이 말이 있으면 대략값이라 읽지 않는다.
    public var estimateTerms: [String]
    /// 외화 금액 옆에 원화가 괄호로 적힌 모양(원화를 금액으로 읽는다). 첫 칸이 원화 숫자.
    public var foreignWithWonPattern: String
    /// 금액에서 빼는 모양(포인트 사용·적립).
    public var pointsPattern: String
    public var cancelOrRefundTerms: [String]
    /// 종류별로, 이 말이 든 줄의 금액을 우선한다. 키는 `DraftEventKind` 원문.
    public var amountLineTerms: [String: [String]]
    /// 증거(승인번호 등)를 읽는 이름표.
    public var providerTransactionLabels: [String]
    public var approvalLabels: [String]
    public var originalReferenceLabels: [String]
    public var originalMarkerTerms: [String]
    /// 이름이 될 수 없는 줄: 번호 이름표가 든 줄, 상태만 적힌 줄, 금액이 든 줄.
    public var nonNameLabels: [String]
    public var statusLines: [String]
    public var nonNameLinePrefixes: [String]
    /// 앱 머리글처럼 이름이 될 수 없는 줄(정규식).
    public var nonNameLinePatterns: [String]
    /// 입금 알림에서 보낸 사람 이름을 읽는 틀(정규식, 첫 칸이 이름). 위에서부터 먼저 맞는 것.
    public var inflowNamePatterns: [String]
    /// 지출 알림에 이름 줄이 없을 때 금액 앞에서 가게 이름을 읽는 틀(정규식, 첫 칸이 이름).
    public var shopBeforeAmountPattern: String

    public static let official = ReadingReaderSettings(
        instrumentRules: [
            .init(terms: ["카드"], kind: .creditCard, name: "카드"),
            .init(terms: ["계좌", "입금", "출금", "이체"], kind: .bankAccount, name: nil),
        ],
        cumulativeTerms: ["누적", "한도", "사용액"],
        balanceTerms: ["잔액", "잔고", "잔여"],
        foreignCurrencyTerms: ["USD", "EUR", "JPY", "CNY", "GBP", "$"],
        estimateTerms: ["약 ", "예상"],
        foreignWithWonPattern: #"[0-9][0-9,.]*\s*(?:USD|EUR|JPY|CNY|GBP)\s*\(([0-9]+(?:,[0-9]{3})*)원\)"#,
        pointsPattern: #"포인트\s*[0-9][0-9,]*\s*원\s*(?:사용|적립)"#,
        cancelOrRefundTerms: ["취소", "환불"],
        amountLineTerms: [
            "purchase": ["승인", "결제", "사용"],
            "cancellation": ["취소", "환불"], "refund": ["취소", "환불"],
            "deposit": ["입금", "받았", "보낸"], "transferIn": ["입금", "받았", "보낸"],
            "withdrawal": ["출금", "이체", "송금"], "transferOut": ["출금", "이체", "송금"], "cashWithdrawal": ["출금", "이체", "송금"],
            "cardBillPayment": ["카드대금", "결제대금", "카드결제"],
            "walletTopUp": ["충전"],
        ],
        providerTransactionLabels: ["거래번호", "거래ID", "거래 ID", "Transaction ID"],
        approvalLabels: ["승인번호"],
        originalReferenceLabels: ["원거래번호", "원승인번호", "Original ID"],
        originalMarkerTerms: ["원거래", "원승인"],
        nonNameLabels: ["승인번호", "거래번호", "거래ID", "원승인번호", "원거래번호", "잔액"],
        statusLines: ["승인", "취소", "환불", "입금", "출금", "이체", "결제", "결제 완료", "결제완료", "승인 완료", "승인완료", "이체 완료", "이체완료", "송금 완료", "송금완료", "출금 완료", "입금 완료", "충전 완료"],
        nonNameLinePrefixes: ["[Web발신]"],
        // 현대카드 앱의 첫 줄(`<이름> 님, 현대 MM 승인`)
        nonNameLinePatterns: [#"현대\s*[A-Za-z가-힣0-9]+\s*(?:해외)?(?:승인취소|승인|취소)\s*$"#],
        inflowNamePatterns: [
            // 우리은행: `[입금] 차유진        67,035원 …`
            #"\[(?:입금|이체입금)\]\s*(.+?)\s+[0-9][0-9,]*\s*원"#,
        ],
        shopBeforeAmountPattern: #"^(?:\[[^\]]*\]\s*)?(.+?)\s*(?:에서|에)?\s*[0-9][0-9,]*\s*원"#
    )

    /// 마스킹된 계좌번호 뒤에서 이름을 읽는 틀(`…계좌 잔액` 한 줄짜리 은행 알림). 입금 알림 전용이라 따로 둔다.
    public var afterMaskedAccountPattern: String = #"\S*\*{2,}\S*\s+(.+?)\s*(?:잔액|잔고|[0-9]{1,2}/[0-9]{1,2}\b|$)"#
}
