import Foundation

/// 알림 글을 조각으로 나누고, 사용자가 고른 조각으로 항목을 만든다(design-v2/settings/shapes-v1.html).
/// 조각: 공백과 글자 종류(한글·영문·숫자·기호)가 바뀌는 곳에서 나누되, `150,000`, `11/05`, `18:22`는 한 조각이다.
/// 고르지 않은 글자는 고정 표현이 되고, 숫자·날짜는 자동으로 어떤 값이든 맞는다(`공용 표현`).
public struct ReadingEntryBuilder: Sendable {
    public enum TokenKind: String, Sendable { case digits, dateTime, korean, latin, symbol }

    public struct Token: Equatable, Sendable, Identifiable {
        public let id: Int
        public let text: String
        public let kind: TokenKind
        /// 앞 조각과 공백으로 떨어져 있었는가.
        public let spaceBefore: Bool
        public let newlineBefore: Bool
        /// 알림 글(`text`)에서 이 조각이 시작하는 글자 위치.
        public let offset: Int
    }

    /// 앱이 알아보는 종류 글자와 그 뜻. 방향 칸이 읽은 글자로 항목의 종류를 정한다.
    public static let directionWords: [String: DraftEventKind] = [
        "입금": .deposit, "출금": .withdrawal, "승인": .purchase, "결제": .purchase, "사용": .purchase,
        "취소": .cancellation, "환불": .refund, "충전": .walletTopUp,
    ]

    public let text: String
    public let tokens: [Token]
    /// 사용자가 직접 나눈 자리(글자 위치). 이 위치 앞에서 조각이 끊긴다.
    public let cuts: Set<Int>

    public init(text: String, cuts: Set<Int> = []) {
        self.text = text
        self.cuts = cuts
        let chars = Array(text)
        var tokens: [Token] = []
        var current = ""
        var currentKind: TokenKind?
        var start = 0
        var space = false
        var newline = false
        func flush() {
            guard let kind = currentKind, !current.isEmpty else { return }
            tokens.append(Token(id: tokens.count, text: current, kind: kind, spaceBefore: space, newlineBefore: newline, offset: start))
            current = ""
            currentKind = nil
            space = false
            newline = false
        }
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if cuts.contains(index) { flush() }
            if ch.isWhitespace {
                flush()
                space = true
                if ch.isNewline { newline = true }
                index += 1
                continue
            }
            if Self.isDigit(ch), currentKind == nil || currentKind == .digits || currentKind == .dateTime {
                // 숫자 덩어리: `150,000` `11/05` `18:22` `10.5`는 한 조각.
                if currentKind == nil { start = index; currentKind = .digits }
                current.append(ch)
                index += 1
                while index < chars.count, !cuts.contains(index) {
                    let c = chars[index]
                    if Self.isDigit(c) { current.append(c); index += 1; continue }
                    if ",/:.".contains(c), index + 1 < chars.count, Self.isDigit(chars[index + 1]), !cuts.contains(index + 1) {
                        if c != "," { currentKind = .dateTime }
                        current.append(c)
                        index += 1
                        continue
                    }
                    break
                }
                continue
            }
            let kind = Self.kind(of: ch)
            // 기호는 한 글자씩 따로 둔다(`[`, `]`).
            if kind != currentKind || kind == .symbol { flush(); currentKind = kind; start = index }
            current.append(ch)
            index += 1
        }
        flush()
        self.tokens = tokens
    }

    private static func isDigit(_ ch: Character) -> Bool { ch.isASCII && ch.isNumber }

    private static func kind(of ch: Character) -> TokenKind {
        if isDigit(ch) { return .digits }
        if ch.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }) { return .korean }
        if ch.isLetter { return .latin }
        return .symbol
    }

    /// 앱이 확실한 것만 미리 칠해 주는 제안: 종류 글자, 금액(바로 뒤가 `원`인 숫자), 날짜·시각. 사용자가 눌러 받아들인다.
    public func suggestions() -> [Int: ReadingSlot] {
        var result: [Int: ReadingSlot] = [:]
        var amountTaken = false
        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case .korean where Self.directionWords[token.text] != nil && !result.values.contains(.direction):
                result[token.id] = .direction
            case .digits where !amountTaken && index + 1 < tokens.count && tokens[index + 1].text == "원" && !tokens[index + 1].spaceBefore:
                result[token.id] = .amount
                amountTaken = true
            case .dateTime:
                result[token.id] = .time
            default: break
            }
        }
        return result
    }

    /// 이 조각에 붙일 수 있는 칸(글자 종류에 맞는 것만). 입금/출금 같은 종류 글자는 목록에 없다(미리 칠해 준다).
    public static func slots(for kind: TokenKind) -> [ReadingSlot] {
        switch kind {
        case .digits: [.amount, .balance, .accountNumber, .cardNumber, .approvalNumber, .custom, .free]
        case .dateTime: [.time, .custom, .free]
        case .korean, .latin: [.accountName, .cardName, .institution, .merchant, .payee, .memo, .custom, .free]
        case .symbol: []
        }
    }

    public enum BuildError: Error, Equatable, Sendable { case needsAmount, needsKind, needsName }

    /// 읽기 항목. `assignments`는 조각 id → 칸. 바로 이웃한 같은 칸은 한 값으로 합친다.
    /// 종류는 방향 칸이 있으면 그 글자가, 없으면 `kind`가 정한다. 금액 칸은 꼭 필요하다.
    public func readEntry(
        name: String, applicationIdentifier: String?, kind: DraftEventKind?, assignments: [Int: ReadingSlot], group: String? = nil,
        id: String = UUID().uuidString
    ) throws -> ReadingEntry {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard assignments.values.contains(.amount) else { throw BuildError.needsAmount }
        let sampleWord = tokens.first { assignments[$0.id] == .direction }.flatMap { Self.directionWords[$0.text] }
        guard let resolvedKind = sampleWord ?? kind else { throw BuildError.needsKind }
        guard !name.isEmpty else { throw BuildError.needsName }
        let hasDirection = assignments.values.contains(.direction)
        return ReadingEntry(
            id: "user.\(id)", name: name, origin: .user, applicationIdentifier: applicationIdentifier,
            conditions: [.frame(.all, frame(assignments: assignments))],
            action: .read(ReadingOutcome(
                ruleID: "user.\(id)", kind: resolvedKind, direction: Self.direction(of: resolvedKind),
                directionWords: hasDirection ? Self.directionWords : nil
            )),
            group: group
        )
    }

    /// 지금 칸 선택으로 만들 틀(공용 표현의 바탕).
    public func frame(assignments: [Int: ReadingSlot]) -> String {
        var frame = ""
        var previousSlot: ReadingSlot?
        for token in tokens {
            let slot = assignments[token.id]
            let separator = separator(before: token, firstInFrame: frame.isEmpty)
            if let slot {
                if previousSlot == slot, slot != .direction { continue }
                frame += separator + "{\(slot.rawValue)}"
                previousSlot = slot
                continue
            }
            previousSlot = nil
            frame += separator + Self.fixed(token)
        }
        return frame
    }

    /// 무시 항목: `fixedTokenIDs`로 고른 조각만 그대로 두고 나머지는 아무 글자나 된다.
    public func ignoreEntry(
        name: String, applicationIdentifier: String?, fixedTokenIDs: Set<Int>, group: String? = nil, id: String = UUID().uuidString
    ) throws -> ReadingEntry {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw BuildError.needsName }
        return ReadingEntry(
            id: "user.\(id)", name: name, origin: .user, applicationIdentifier: applicationIdentifier,
            conditions: [.frame(.all, ignoreFrame(fixedTokenIDs: fixedTokenIDs))], action: .ignore(.unrecognized), group: group
        )
    }

    public func ignoreFrame(fixedTokenIDs: Set<Int>) -> String {
        var frame = ""
        var gap = false
        for token in tokens {
            if fixedTokenIDs.contains(token.id) {
                if gap { frame += "{*}"; gap = false } else if !frame.isEmpty { frame += token.spaceBefore ? " " : "" }
                frame += Self.fixed(token, generalizeDigits: false)
            } else {
                gap = true
            }
        }
        if gap { frame += "{*}" }
        return frame.isEmpty ? "{*}" : frame
    }

    public enum Piece: Equatable, Sendable {
        case text(String)
        /// 칸 이름이나 자리 이름(`금액`, `아무 텍스트`). 화면에서 파랗게 보인다.
        case slot(String)
    }

    /// 공용 표현: 틀을 사람이 읽는 조각으로. 고정 글자는 그대로, 칸은 칸 이름, 숫자·날짜는 자동으로 일반화된 자리.
    public static func pieces(of frame: String) -> [Piece] {
        var result: [Piece] = []
        var literal = ""
        let chars = Array(frame)
        var index = 0
        func flush() { if !literal.isEmpty { result.append(.text(literal)); literal = "" } }
        while index < chars.count {
            guard chars[index] == "{" else { literal.append(chars[index]); index += 1; continue }
            var depth = 0
            var end = index
            while end < chars.count {
                if chars[end] == "{" { depth += 1 } else if chars[end] == "}" { depth -= 1; if depth == 0 { break } }
                end += 1
            }
            guard end < chars.count else { literal.append(contentsOf: chars[index...]); break }
            let inner = String(chars[(index + 1)..<end])
            flush()
            if inner == "*" { result.append(.slot("아무 텍스트")) }
            else if inner == #"re:[0-9]+"# { result.append(.slot("숫자")) }
            else if inner == Self.dateTimePattern { result.append(.slot("날짜 시각")) }
            else if inner.hasPrefix("re:") { result.append(.slot("…")) }
            else {
                let name = inner.split(separator: "=", maxSplits: 1).first.map(String.init) ?? inner
                result.append(.slot(ReadingSlot(rawValue: name)?.title ?? name))
            }
            index = end + 1
        }
        flush()
        return result
    }

    static let dateTimePattern = #"re:[0-9]+(?:[/:.][0-9]+)+"#

    public static func direction(of kind: DraftEventKind) -> TransactionDirection {
        switch kind {
        case .purchase, .withdrawal, .transferOut, .cardBillPayment, .cashWithdrawal, .feeCharge: .outflow
        case .cancellation, .refund, .deposit, .transferIn, .walletTopUp: .inflow
        case .purchaseSettlementNotice: .neutral
        }
    }

    private func separator(before token: Token, firstInFrame: Bool) -> String {
        guard !firstInFrame else { return "" }
        return token.newlineBefore || token.spaceBefore ? " " : ""
    }

    private static func fixed(_ token: Token, generalizeDigits: Bool = true) -> String {
        if generalizeDigits, token.kind == .digits { return #"{re:[0-9]+}"# }
        if generalizeDigits, token.kind == .dateTime { return "{\(dateTimePattern)}" }
        // 틀의 특수 글자(`{`, `}`)는 정규식으로 적는다.
        return token.text.map { $0 == "{" || $0 == "}" ? #"{re:\\\#($0)}"# : String($0) }.joined()
    }
}

extension ReadingSlot {
    /// 사용자에게 보이는 이름(`통장이름` → `통장 이름`).
    public var title: String {
        switch self {
        case .accountName: "통장 이름"
        case .cardName: "카드 이름"
        case .cardNumber: "카드 번호"
        case .accountNumber: "계좌번호"
        case .approvalNumber: "승인번호"
        case .custom: "직접 이름 붙이기"
        case .free: "무시"
        default: rawValue
        }
    }
}
