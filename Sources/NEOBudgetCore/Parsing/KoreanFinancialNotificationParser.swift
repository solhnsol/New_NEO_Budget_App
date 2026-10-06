import Foundation

/// Conservative baseline parser. Provider rules may extend it without acquiring account or ledger responsibilities.
public struct KoreanFinancialNotificationParser: TransactionCandidateParser, Sendable {
    public init() {}

    public func parse(_ notification: RawNotification, context: NotificationParsingContext) throws -> NotificationParseOutcome {
        guard !notification.id.isEmpty else { throw NotificationParserContractError.invalidRawNotificationID }
        let text = NotificationText.joined(notification)
        let lines = text.split(separator: "\n").map(String.init)
        guard let classification = classify(text) else { return .notTransaction(classifyNonTransaction(text)) }
        guard let amount = try parseAmount(in: lines) else { return .failed(.amountMissing) }

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

    private func classify(_ text: String) -> Classification? {
        if containsAny(text, ["카드대금", "결제대금"]) {
            return Classification(kind: .cardBillPayment, direction: .outflow, ruleID: "card-bill-payment")
        }
        if containsAny(text, ["취소", "환불"]) {
            return Classification(kind: text.contains("취소") ? .cancellation : .refund, direction: .inflow, ruleID: "adjustment")
        }
        if containsAny(text, ["출금이체", "이체출금", "송금"]) {
            return Classification(kind: .transferOut, direction: .outflow, ruleID: "transfer-out")
        }
        if containsAny(text, ["입금이체", "이체입금"]) {
            return Classification(kind: .transferIn, direction: .inflow, ruleID: "transfer-in")
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

    private func parseAmount(in lines: [String]) throws -> Int64? {
        for line in lines where line.contains("원") && !line.contains("잔액") {
            guard let wonIndex = line.firstIndex(of: "원") else { continue }
            let token = line[..<wonIndex].reversed().prefix {
                $0.isNumber || $0 == "," || $0 == " "
            }.reversed().filter(\.isNumber)
            guard !token.isEmpty else { continue }
            guard let value = Int64(String(token)) else { throw NotificationParserContractError.amountOverflow }
            return value
        }
        return nil
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

    private func reference(in lines: [String], labels: [String]) -> String? {
        for line in lines {
            for label in labels {
                guard let range = line.range(of: label, options: .caseInsensitive) else { continue }
                let suffix = line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " :#"))
                if !suffix.isEmpty { return suffix }
            }
        }
        return nil
    }
}
