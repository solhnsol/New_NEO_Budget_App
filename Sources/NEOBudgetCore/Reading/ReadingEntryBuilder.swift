import Foundation

/// 알림 글을 조각(공백·글자 종류가 바뀌는 곳에서 나눈 것)으로 나누고, 사용자가 고른 조각으로 항목을 만든다.
/// 고르지 않은 글자는 고정 표현이 되고, 숫자·날짜는 자동으로 어떤 숫자든 맞는다(`공용 표현`).
public struct ReadingEntryBuilder: Sendable {
    public enum TokenKind: String, Sendable { case digits, korean, latin, symbol }

    public struct Token: Equatable, Sendable, Identifiable {
        public let id: Int
        public let text: String
        public let kind: TokenKind
        /// 앞 조각과 공백으로 떨어져 있었는가.
        public let spaceBefore: Bool
        /// 줄바꿈 뒤에서 시작하는가.
        public let newlineBefore: Bool
    }

    public let text: String
    public let tokens: [Token]

    public init(text: String) {
        self.text = text
        var tokens: [Token] = []
        var current = ""
        var currentKind: TokenKind?
        var space = false
        var newline = false
        func flush() {
            guard let kind = currentKind, !current.isEmpty else { return }
            tokens.append(Token(id: tokens.count, text: current, kind: kind, spaceBefore: space, newlineBefore: newline))
            current = ""
            currentKind = nil
            space = false
            newline = false
        }
        for ch in text {
            if ch.isWhitespace {
                flush()
                space = true
                if ch.isNewline { newline = true }
                continue
            }
            let kind = Self.kind(of: ch)
            // 기호는 한 글자씩 따로 둔다(`[`, `]`, `/`, `,`).
            if kind != currentKind || kind == .symbol { flush(); currentKind = kind }
            current.append(ch)
        }
        flush()
        self.tokens = tokens
    }

    private static func kind(of ch: Character) -> TokenKind {
        if ch.isASCII, ch.isNumber { return .digits }
        if ch.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }) { return .korean }
        if ch.isLetter { return .latin }
        return .symbol
    }

    /// 쉼표로 이어진 숫자(`150,000`)는 한 조각처럼 다루는 편이 쓰기 쉽다: 금액 후보 묶음.
    public func mergedAmountTokenIDs(startingAt id: Int) -> [Int] {
        guard tokens.indices.contains(id), tokens[id].kind == .digits else { return [id] }
        var ids = [id]
        var next = id + 1
        while next + 1 < tokens.count, tokens[next].text == ",", !tokens[next].spaceBefore,
              tokens[next + 1].kind == .digits, !tokens[next + 1].spaceBefore, tokens[next + 1].text.count == 3 {
            ids += [next, next + 1]
            next += 2
        }
        return ids
    }

    /// 화면에 보이는 단위: 쉼표로 이어진 숫자(`150,000`)는 한 덩어리, 나머지는 조각 하나씩. 각 덩어리는 조각 id 목록이다.
    public var groups: [[Int]] {
        var result: [[Int]] = []
        var index = 0
        while index < tokens.count {
            let ids = mergedAmountTokenIDs(startingAt: index)
            result.append(ids)
            index = (ids.last ?? index) + 1
        }
        return result
    }

    /// 이 조각 묶음에 붙일 수 있는 칸(글자 종류에 맞는 것만). 입금/출금 같은 방향은 칸이 아니다.
    public static func slots(for kind: TokenKind) -> [ReadingSlot] {
        switch kind {
        case .digits: [.amount, .balance, .accountNumber, .cardNumber, .approvalNumber]
        case .korean, .latin: [.accountName, .cardName, .institution, .merchant, .payee, .memo]
        case .symbol: []
        }
    }

    public enum BuildError: Error, Equatable, Sendable { case needsAmount, needsName }

    /// 읽기 항목: `assignments`는 조각 id → 칸. 같은 칸이 붙은 이웃 조각은 하나로 합친다. 금액 칸은 꼭 필요하다.
    public func readEntry(
        name: String, applicationIdentifier: String?, kind: DraftEventKind, assignments: [Int: ReadingSlot], id: String = UUID().uuidString
    ) throws -> ReadingEntry {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw BuildError.needsName }
        guard assignments.values.contains(.amount) else { throw BuildError.needsAmount }
        var frame = ""
        var previousSlot: ReadingSlot?
        for token in tokens {
            let slot = assignments[token.id]
            if let slot {
                if previousSlot == slot { continue }
                frame += separator(before: token, firstInFrame: frame.isEmpty) + "{\(slot.rawValue)}"
                previousSlot = slot
                continue
            }
            previousSlot = nil
            frame += separator(before: token, firstInFrame: frame.isEmpty) + Self.fixed(token)
        }
        return ReadingEntry(
            id: "user.\(id)", name: name, origin: .user, applicationIdentifier: applicationIdentifier,
            conditions: [.frame(.all, frame)],
            action: .read(ReadingOutcome(ruleID: "user.\(id)", kind: kind, direction: Self.direction(of: kind)))
        )
    }

    /// 무시 항목: `fixedTokenIDs`로 고른 조각만 그대로 두고 나머지는 아무 글자나 된다.
    public func ignoreEntry(name: String, applicationIdentifier: String?, fixedTokenIDs: Set<Int>, id: String = UUID().uuidString) throws -> ReadingEntry {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw BuildError.needsName }
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
        if frame.isEmpty { frame = "{*}" }
        return ReadingEntry(
            id: "user.\(id)", name: name, origin: .user, applicationIdentifier: applicationIdentifier,
            conditions: [.frame(.all, frame)], action: .ignore(.unrecognized)
        )
    }

    /// 공용 표현: 만든 틀을 사람이 읽는 말로 보여 준다(`[광고] 아무 텍스트`).
    public static func commonExpression(of frame: String) -> String {
        frame.replacingOccurrences(of: "{*}", with: " 아무 텍스트 ")
            .replacingOccurrences(of: #"\{re:\[0-9\]\+[^}]*\}"#, with: "숫자", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

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
        if token.kind == .digits, generalizeDigits { return #"{re:[0-9]+}"# }
        // 틀의 특수 글자(`{`, `}`)는 정규식으로 적는다.
        return token.text.map { $0 == "{" || $0 == "}" ? #"{re:\\\#($0)}"# : String($0) }.joined()
    }
}
