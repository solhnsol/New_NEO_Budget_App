import Foundation

/// Conservative baseline parser. Provider rules may extend it without acquiring account or ledger responsibilities.
public struct KoreanFinancialNotificationParser: TransactionCandidateParser, Sendable {
    public init() {}

    public func parse(_ notification: RawNotification, context: NotificationParsingContext) throws -> NotificationParseOutcome {
        guard !notification.id.isEmpty else { throw NotificationParserContractError.invalidRawNotificationID }
        let text = NotificationText.joined(notification)
        let lines = text.split(separator: "\n").map(String.init)
        if let reason = negativeSignal(in: text) { return .notTransaction(reason) }
        guard let classification = classify(text) else { return .notTransaction(classifyNonTransaction(text)) }
        let amount: Int64
        switch parseAmount(in: lines, classification: classification) {
        case let .value(value): amount = value
        case let .failure(failure): return .failed(failure)
        }

        var issues: [ParserIssue] = []
        let timestamp: ObservedTimestamp
        if let notificationTime = notification.notificationAtUnixMilliseconds {
            timestamp = ObservedTimestamp(unixMilliseconds: notificationTime, precision: .second, source: .notificationTime)
        } else {
            timestamp = ObservedTimestamp(
                unixMilliseconds: notification.capturedAtUnixMilliseconds,
                precision: .second,
                source: .captureTime
            )
            issues.append(.timeAbsentFallback)
        }
        let counterparty = parseCounterparty(lines, direction: classification.direction)
        if counterparty.merchantRaw == nil, counterparty.payeeRaw == nil { issues.append(.merchantMissing) }
        let instrument = parseInstrumentHint(text)
        if instrument.kind == .unknown { issues.append(.instrumentHintMissing) }

        return .candidate(try TransactionCandidateDraft(
            rawNotificationID: notification.id,
            parserID: context.parserID,
            parserVersion: context.parserVersion,
            ruleID: classification.ruleID,
            kind: classification.kind,
            direction: classification.direction,
            amount: try Money(minorUnits: amount, currency: "KRW"),
            occurredAt: timestamp,
            instrument: instrument,
            counterparty: counterparty,
            evidence: evidence(notification: notification, lines: lines),
            issues: issues,
            confidence: .high
        ))
    }

    private struct Classification {
        let kind: DraftEventKind
        let direction: TransactionDirection
        let ruleID: String
    }

    private enum AmountResult {
        case value(Int64)
        case failure(NotificationParseFailure)
    }

    private struct WonToken {
        let value: Int64?
        let hasFraction: Bool
    }

    private func negativeSignal(in text: String) -> NotTransactionReason? {
        if containsAny(text, ["광고", "혜택", "이벤트", "캐시백 안내"]) { return .promotion }
        if containsAny(text, ["승인거절", "승인 거절", "결제실패", "결제 실패", "한도초과", "처리실패"]) {
            return .declined
        }
        if containsAny(text, [
            "예약이체", "예약 이체", "결제예정", "결제 예정", "입금예정", "환불 예정",
            "결제 대기", "결제대기", "승인 대기", "승인대기"
        ]) {
            return .pending
        }
        if containsAny(text, ["송금 요청", "송금요청", "송금을 받아주세요", "입금 요청"]) { return .request }
        if containsAny(text, ["이체한도", "이체 한도", "한도 변경", "한도변경"]) { return .configurationChange }
        return nil
    }

    private func classify(_ text: String) -> Classification? {
        if containsAny(text, ["카드대금", "결제대금"]) {
            return Classification(kind: .cardBillPayment, direction: .outflow, ruleID: "card-bill-payment")
        }
        if containsAny(text, ["카드결제 출금", "카드 결제 출금"]) {
            return Classification(kind: .cardBillPayment, direction: .outflow, ruleID: "card-payment-withdrawal")
        }
        if containsAny(text, ["취소", "환불"]) {
            return Classification(kind: text.contains("취소") ? .cancellation : .refund, direction: .inflow, ruleID: "adjustment")
        }
        if containsAny(text, ["입금이체", "이체입금", "입금 이체", "이체 입금", "입금됐어요", "입금되었습니다"]) {
            return Classification(kind: .transferIn, direction: .inflow, ruleID: "transfer-in")
        }
        if containsAny(text, ["출금이체", "이체출금", "출금 이체", "이체 출금", "송금이 완료", "송금했", "송금"]) {
            return Classification(kind: .transferOut, direction: .outflow, ruleID: "transfer-out")
        }
        if containsAny(text, ["충전이 완료", "충전 완료"]) {
            return Classification(kind: .walletTopUp, direction: .inflow, ruleID: "wallet-top-up")
        }
        if text.contains("입금") { return Classification(kind: .deposit, direction: .inflow, ruleID: "deposit") }
        if text.contains("출금") { return Classification(kind: .withdrawal, direction: .outflow, ruleID: "withdrawal") }
        if containsAny(text, ["승인", "사용", "결제"]) {
            return Classification(kind: .purchase, direction: .outflow, ruleID: "purchase")
        }
        return nil
    }

    private func classifyNonTransaction(_ text: String) -> NotTransactionReason {
        if containsAny(text, ["광고", "혜택", "이벤트"]) { return .promotion }
        if containsAny(text, ["로그인", "인증"]) { return .authentication }
        if text.contains("거절") { return .declined }
        if text.contains("대기") { return .pending }
        if text.contains("잔액") { return .balanceInquiry }
        return .unrecognized
    }

    private func containsAny(_ value: String, _ terms: [String]) -> Bool { terms.contains(where: value.contains) }

    private func parseAmount(in lines: [String], classification: Classification) -> AmountResult {
        if lines.contains(where: { line in
            containsAny(line.uppercased(), ["USD", "EUR", "JPY", "CNY", "GBP", "$"]) ||
                (containsAny(line, ["약 ", "예상"]) && line.contains("원"))
        }) {
            return .failure(.unsupportedCurrency)
        }

        var preferred: [Int64] = []
        var fallback: [Int64] = []
        for originalLine in lines {
            // Cumulative usage, limits and balances describe the account, never this transaction.
            if containsAny(originalLine, ["누적", "한도", "사용액"]) { continue }
            let balanceMarkers = ["잔액", "잔고", "잔여"]
            let line = balanceMarkers
                .compactMap { originalLine.range(of: $0)?.lowerBound }
                .min()
                .map { String(originalLine[..<$0]) } ?? originalLine
            let tokens = wonTokens(in: line)
            if tokens.contains(where: \.hasFraction) { return .failure(.amountUnparseable) }
            if tokens.contains(where: { $0.value == nil }) { return .failure(.amountUnparseable) }
            let values = tokens.compactMap(\.value)
            guard !values.isEmpty else { continue }

            if [.cancellation, .refund].contains(classification.kind),
               containsAny(line, ["취소", "환불"]) {
                if line.contains(" 중 "), let last = values.last { preferred.append(last) }
                else { preferred.append(contentsOf: values) }
            } else if isTransactionAmountLine(line, kind: classification.kind) {
                preferred.append(contentsOf: values)
            } else {
                fallback.append(contentsOf: values)
            }
        }
        let candidates = preferred.isEmpty ? fallback : preferred
        guard !candidates.isEmpty else { return .failure(.amountMissing) }
        let unique = Set(candidates)
        guard unique.count == 1, let amount = unique.first else { return .failure(.amountAmbiguous) }
        guard amount > 0 else { return .failure(.amountUnparseable) }
        return .value(amount)
    }

    private func isTransactionAmountLine(_ line: String, kind: DraftEventKind) -> Bool {
        switch kind {
        case .purchase: return containsAny(line, ["승인", "결제", "사용"])
        case .cancellation, .refund: return containsAny(line, ["취소", "환불"])
        case .deposit, .transferIn: return containsAny(line, ["입금", "받았", "보낸"])
        case .withdrawal, .transferOut, .cashWithdrawal: return containsAny(line, ["출금", "이체", "송금"])
        case .cardBillPayment: return containsAny(line, ["카드대금", "결제대금", "카드결제"])
        case .walletTopUp: return line.contains("충전")
        case .purchaseSettlementNotice, .feeCharge: return false
        }
    }

    private func wonTokens(in line: String) -> [WonToken] {
        let pattern = #"(?<![0-9.,])([0-9]+(?:,[0-9]{3})*)(?:\.([0-9]+))?\s*원"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, range: range).map { match in
            let integerText = Range(match.range(at: 1), in: line).map { String(line[$0]).replacingOccurrences(of: ",", with: "") }
            return WonToken(
                value: integerText.flatMap(Int64.init),
                hasFraction: match.range(at: 2).location != NSNotFound
            )
        }
    }

    private func parseInstrumentHint(_ text: String) -> InstrumentHint {
        if text.contains("카드") { return InstrumentHint(kind: .creditCard, displayNameRaw: "카드") }
        if containsAny(text, ["계좌", "입금", "출금", "이체"]) { return InstrumentHint(kind: .bankAccount) }
        return InstrumentHint(kind: .unknown)
    }

    private func parseCounterparty(_ lines: [String], direction: TransactionDirection) -> DraftCounterparty {
        let labels = ["승인번호", "거래번호", "거래ID", "원승인번호", "원거래번호", "잔액"]
        let markerLines = ["승인", "취소", "환불", "입금", "출금", "이체", "결제"]
        let candidate = lines.first {
            !$0.contains("원") && !labels.contains(where: $0.contains) && !markerLines.contains($0)
        }
        return direction == .outflow ? DraftCounterparty(merchantRaw: candidate) : DraftCounterparty(payeeRaw: candidate)
    }

    private func evidence(notification: RawNotification, lines: [String]) -> [DraftEvidence] {
        var result: [DraftEvidence] = []
        let scope = notification.source.applicationIdentifier
        if let value = notification.sourceDeliveryID {
            result.append(DraftEvidence(kind: .deliveryID, strength: .strong, value: value, scope: scope))
        }
        let currentLines = lines.filter { !$0.contains("원거래") && !$0.contains("원승인") }
        if let value = reference(in: currentLines, labels: ["거래번호", "거래ID", "거래 ID", "Transaction ID"]) {
            result.append(DraftEvidence(kind: .providerTransactionID, strength: .strong, value: value, scope: scope))
        }
        if let value = reference(in: lines, labels: ["승인번호"]) {
            result.append(DraftEvidence(kind: .approvalNumber, strength: .scoped, value: value, scope: scope))
        }
        if let value = reference(in: lines, labels: ["원거래번호", "원승인번호", "Original ID"]) {
            result.append(DraftEvidence(kind: .originalApprovalReference, strength: .relation, value: value, scope: scope))
        }
        return result
    }

    /// A label such as `승인번호` must not match inside `원승인번호`; the preceding `원` marks the
    /// original-transaction label, so only a label that starts its own token counts as current.
    private func reference(in lines: [String], labels: [String]) -> String? {
        for line in lines {
            for label in labels {
                var searchRange = line.startIndex..<line.endIndex
                while let range = line.range(of: label, options: .caseInsensitive, range: searchRange) {
                    let precededByOriginalMarker = !label.hasPrefix("원")
                        && range.lowerBound > line.startIndex
                        && line[line.index(before: range.lowerBound)] == "원"
                    if !precededByOriginalMarker {
                        let suffix = line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " :#"))
                        if !suffix.isEmpty { return suffix }
                    }
                    searchRange = range.upperBound..<line.endIndex
                }
            }
        }
        return nil
    }
}
