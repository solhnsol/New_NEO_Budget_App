import Foundation

/// Conservative baseline parser. Provider rules may extend it without acquiring account or ledger responsibilities.
public struct KoreanFinancialNotificationParser: TransactionCandidateParser, Sendable {
    public init() {}

    public func parse(_ notification: RawNotification, context: NotificationParsingContext) throws -> NotificationParseOutcome {
        guard !notification.id.isEmpty else { throw NotificationParserContractError.invalidRawNotificationID }
        let text = NotificationText.joined(notification)
        let lines = text.split(separator: "\n").map(String.init)
        if let transit = try transitFare(notification, context: context) { return transit }
        if let tap = try walletCardPayment(notification, context: context) { return tap }
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

    // MARK: Wallet transit card (English device format: fare in the subtitle, balance in the body)

    private static let transitFarePattern = try! NSRegularExpression(pattern: #"^₩([0-9]+(?:,[0-9]{3})*)\s+for\s+(.+)$"#)
    private static let transitBalancePattern = try! NSRegularExpression(pattern: #"balance is ₩[0-9]"#)

    /// A ride paid from a prepaid transit card: `₩1,550 for Metro` with `Your new balance is ₩10,000.` The fare is the amount;
    /// the balance is never read as one. Balance-only and no-charge notices of the same card are not transactions.
    /// Only the shape `AccountEvidenceExtractor` also reads as `transitFare` counts, so the parser and the account layer agree.
    private func transitFare(_ notification: RawNotification, context: NotificationParsingContext) throws -> NotificationParseOutcome? {
        let body = notification.body.map(NotificationText.normalize) ?? ""
        guard Self.matches(Self.transitBalancePattern, body) else { return nil }
        let subtitle = notification.subtitle.map(NotificationText.normalize) ?? ""
        guard let groups = Self.captures(Self.transitFarePattern, subtitle), groups.count == 2,
              let fare = Int64(groups[0].replacingOccurrences(of: ",", with: "")) else {
            return .notTransaction(.balanceInquiry)
        }
        guard fare > 0 else { return .notTransaction(.balanceInquiry) }
        var issues: [ParserIssue] = []
        let timestamp: ObservedTimestamp
        if let notificationTime = notification.notificationAtUnixMilliseconds {
            timestamp = ObservedTimestamp(unixMilliseconds: notificationTime, precision: .second, source: .notificationTime)
        } else {
            timestamp = ObservedTimestamp(unixMilliseconds: notification.capturedAtUnixMilliseconds, precision: .second, source: .captureTime)
            issues.append(.timeAbsentFallback)
        }
        let title = notification.title.map(NotificationText.normalize).flatMap { $0.isEmpty ? nil : $0 }
        return .candidate(try TransactionCandidateDraft(
            rawNotificationID: notification.id,
            parserID: context.parserID,
            parserVersion: context.parserVersion,
            ruleID: "transit-fare",
            kind: .purchase,
            direction: .outflow,
            amount: try Money(minorUnits: fare, currency: "KRW"),
            occurredAt: timestamp,
            instrument: InstrumentHint(kind: .transitCard, displayNameRaw: title),
            counterparty: DraftCounterparty(merchantRaw: groups[1].trimmingCharacters(in: .whitespaces)),
            evidence: evidence(notification: notification, lines: []),
            issues: issues,
            confidence: .high
        ))
    }

    // MARK: Wallet card payment (merchant and region in the subtitle, the won amount alone in the body)

    public static let walletCardPaymentRuleID = "wallet-card-payment"
    private static let walletAmountOnly = try! NSRegularExpression(pattern: #"^₩([0-9]+(?:,[0-9]{3})*)$"#)
    /// The region Wallet appends to the merchant (`<상호>, 서울특별시`). Only a trailing Korean province or city name is
    /// removed, so a comma inside a merchant name survives.
    private static let walletRegionSuffix = try! NSRegularExpression(
        pattern: #",\s*(?:서울|부산|대구|인천|광주|대전|울산)(?:특별시|광역시)$|,\s*세종특별자치시$|,\s*(?:경기|강원|충청[남북]|전라[남북]|경상[남북])도$|,\s*(?:강원|전북)특별자치도$|,\s*제주특별자치도$"#
    )

    /// A card payment shown by Wallet: title `현대카드`, subtitle `<상호>, <지역>`, body `₩1,200`. The card's kind (credit or
    /// check) is not in the message, so the hint carries only the name. Same shape `AccountEvidenceExtractor` reads as `walletCardTap`.
    private func walletCardPayment(_ notification: RawNotification, context: NotificationParsingContext) throws -> NotificationParseOutcome? {
        let title = notification.title.map(NotificationText.normalize) ?? ""
        let subtitle = notification.subtitle.map(NotificationText.normalize) ?? ""
        let body = notification.body.map(NotificationText.normalize) ?? ""
        guard title.contains("카드"), let groups = Self.captures(Self.walletAmountOnly, body), groups.count == 1 else { return nil }
        guard !subtitle.isEmpty else { return nil }
        guard let amount = Int64(groups[0].replacingOccurrences(of: ",", with: "")) else { return .failed(.amountUnparseable) }
        guard amount > 0 else { return .failed(.amountUnparseable) }
        let merchant = Self.walletRegionSuffix
            .stringByReplacingMatches(in: subtitle, range: NSRange(subtitle.startIndex..., in: subtitle), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        var issues: [ParserIssue] = [.instrumentHintMissing]
        let timestamp: ObservedTimestamp
        if let notificationTime = notification.notificationAtUnixMilliseconds {
            timestamp = ObservedTimestamp(unixMilliseconds: notificationTime, precision: .second, source: .notificationTime)
        } else {
            timestamp = ObservedTimestamp(unixMilliseconds: notification.capturedAtUnixMilliseconds, precision: .second, source: .captureTime)
            issues.append(.timeAbsentFallback)
        }
        return .candidate(try TransactionCandidateDraft(
            rawNotificationID: notification.id,
            parserID: context.parserID,
            parserVersion: context.parserVersion,
            ruleID: Self.walletCardPaymentRuleID,
            kind: .purchase,
            direction: .outflow,
            amount: try Money(minorUnits: amount, currency: "KRW"),
            occurredAt: timestamp,
            instrument: InstrumentHint(kind: .unknown, displayNameRaw: title),
            counterparty: DraftCounterparty(merchantRaw: merchant.isEmpty ? nil : merchant),
            evidence: evidence(notification: notification, lines: []),
            issues: merchant.isEmpty ? issues + [.merchantMissing] : issues,
            confidence: .high
        ))
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func captures(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
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
        if containsAny(text, ["사고예방", "해외사용 확인"]) { return .authentication }
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

    /// The first line of a Hyundai Card app alert (`<이름> 님, 현대 MM 승인`); the merchant is the line after the amount.
    private static let issuerApprovalHeader = try! NSRegularExpression(pattern: #"현대\s*[A-Za-z가-힣0-9]+\s*(?:해외)?(?:승인|취소)\s*$"#)

    private func parseCounterparty(_ lines: [String], direction: TransactionDirection) -> DraftCounterparty {
        let labels = ["승인번호", "거래번호", "거래ID", "원승인번호", "원거래번호", "잔액"]
        let markerLines = ["승인", "취소", "환불", "입금", "출금", "이체", "결제"]
        let candidate = lines.first {
            !$0.contains("원") && !labels.contains(where: $0.contains) && !markerLines.contains($0) && !Self.matches(Self.issuerApprovalHeader, $0)
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
