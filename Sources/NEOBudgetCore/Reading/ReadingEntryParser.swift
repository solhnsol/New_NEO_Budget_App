import Foundation

/// 읽기 사전을 해석하는 엔진. 알림 한 건에 대해 우선순위가 가장 높은 맞는 항목을 찾아 무시하거나 읽는다.
/// 어떤 알림을 어떻게 읽을지는 전부 `ReadingDictionary` 데이터가 정하고, 이 파일에는 앱·가게별 규칙이 없다.
public struct ReadingEntryParser: TransactionCandidateParser, Sendable {
    public static let walletCardPaymentRuleID = OfficialReadingEntries.walletCardPaymentRuleID

    public let dictionary: ReadingDictionary
    /// 틀을 해석하지 못해 건너뛴 항목 id(사용자가 만든 항목이 잘못 저장된 경우 등).
    public let invalidEntryIDs: [String]
    private let entries: [CompiledEntry]
    private let readers: CompiledReaders

    public init(dictionary: ReadingDictionary = .official) {
        self.dictionary = dictionary
        var invalid: [String] = []
        self.entries = dictionary.effectiveEntries.compactMap { entry in
            if let compiled = CompiledEntry(entry) { return compiled }
            invalid.append(entry.id)
            return nil
        }
        self.invalidEntryIDs = invalid
        self.readers = CompiledReaders(dictionary.settings)
    }

    public func parse(_ notification: RawNotification, context: NotificationParsingContext) throws -> NotificationParseOutcome {
        try decide(notification, context: context).outcome
    }

    /// 어느 항목이 이 알림을 읽었는지. 아무 항목도 맞지 않으면 nil. 항목 목록의 "지난 알림 N건"에 쓴다.
    public func entryID(for notification: RawNotification) -> String? {
        guard !notification.id.isEmpty, let context = try? NotificationParsingContext(
            timeZoneIdentifier: "UTC", referenceTimeUnixMilliseconds: 0, parserID: "probe", parserVersion: "1"
        ) else { return nil }
        return (try? decide(notification, context: context))?.entryID
    }

    private func decide(_ notification: RawNotification, context: NotificationParsingContext) throws -> (outcome: NotificationParseOutcome, entryID: String?) {
        guard !notification.id.isEmpty else { throw NotificationParserContractError.invalidRawNotificationID }
        let view = NotificationView(notification)
        let app = notification.source.applicationIdentifier
        for entry in entries where entry.entry.applicationIdentifier == nil || entry.entry.applicationIdentifier == app {
            guard let values = entry.match(view) else { continue }
            switch entry.entry.action {
            case let .ignore(reason): return (.notTransaction(reason), entry.entry.id)
            case let .read(outcome):
                if let result = try read(outcome, values: values, notification: notification, view: view, context: context) {
                    return (result, entry.entry.id)
                }
            }
        }
        return (.notTransaction(.unrecognized), nil)
    }

    // MARK: Reading

    private func read(
        _ outcome: ReadingOutcome, values: [ReadingSlot: String], notification: RawNotification, view: NotificationView,
        context: NotificationParsingContext
    ) throws -> NotificationParseOutcome? {
        let amount: Int64
        if let text = values[.amount] {
            guard let parsed = Int64(text.replacingOccurrences(of: ",", with: "")), parsed > 0 else {
                return outcome.nonPositiveAmount == .skip ? nil : .failed(.amountUnparseable)
            }
            amount = parsed
        } else {
            switch parseAmount(in: view.lines, kind: outcome.kind) {
            case let .value(value): amount = value
            case let .failure(failure): return .failed(failure)
            }
        }

        var issues: [ParserIssue] = []
        let instrument: InstrumentHint
        var instrumentUnknown = false
        switch outcome.instrument {
        case .byText:
            instrument = instrumentHint(view.text)
            instrumentUnknown = instrument.kind == .unknown
        case let .fixed(kind, nameFrom, reportMissing):
            let name = nameFrom.map { view.field($0) }.flatMap { $0.isEmpty ? nil : $0 }
            instrument = InstrumentHint(kind: kind, displayNameRaw: name)
            if reportMissing { issues.append(.instrumentHintMissing) }
        }

        let timestamp: ObservedTimestamp
        if let notificationTime = notification.notificationAtUnixMilliseconds {
            timestamp = ObservedTimestamp(unixMilliseconds: notificationTime, precision: .second, source: .notificationTime)
        } else {
            timestamp = ObservedTimestamp(unixMilliseconds: notification.capturedAtUnixMilliseconds, precision: .second, source: .captureTime)
            issues.append(.timeAbsentFallback)
        }

        let counterparty: DraftCounterparty
        if let name = outcome.fixedName {
            counterparty = outcome.direction == .inflow ? DraftCounterparty(payeeRaw: name) : DraftCounterparty(merchantRaw: name)
        } else if values[.merchant] != nil || values[.payee] != nil || values[.memo] != nil {
            counterparty = DraftCounterparty(
                merchantRaw: values[.merchant].flatMap { $0.isEmpty ? nil : $0 },
                payeeRaw: values[.payee].flatMap { $0.isEmpty ? nil : $0 },
                memoRaw: values[.memo].flatMap { $0.isEmpty ? nil : $0 }
            )
        } else {
            counterparty = parseCounterparty(view.lines, direction: outcome.direction, text: view.text, kind: outcome.kind,
                                             title: view.title.isEmpty ? nil : view.title, memoPattern: outcome.memoPattern)
        }
        if counterparty.merchantRaw == nil, counterparty.payeeRaw == nil { issues.append(.merchantMissing) }
        if instrumentUnknown { issues.append(.instrumentHintMissing) }

        let balance = values[.balance].flatMap { Int64($0.replacingOccurrences(of: ",", with: "")) }.flatMap { try? Money(minorUnits: $0, currency: "KRW") }
        return .candidate(try TransactionCandidateDraft(
            rawNotificationID: notification.id,
            parserID: context.parserID,
            parserVersion: context.parserVersion,
            ruleID: outcome.ruleID,
            kind: outcome.kind,
            direction: outcome.direction,
            amount: try Money(minorUnits: amount, currency: "KRW"),
            balanceAfter: balance,
            occurredAt: timestamp,
            instrument: instrument,
            counterparty: counterparty,
            evidence: evidence(notification: notification, lines: outcome.evidenceFromText ? view.lines : []),
            issues: issues,
            confidence: .high
        ))
    }

    // MARK: Default readers (항목에 칸이 적혀 있지 않을 때)

    private enum AmountResult {
        case value(Int64)
        case failure(NotificationParseFailure)
    }

    private struct WonToken {
        let value: Int64?
        let hasFraction: Bool
    }

    private var settings: ReadingReaderSettings { dictionary.settings }

    private func containsAny(_ value: String, _ terms: [String]) -> Bool { terms.contains(where: value.contains) }

    private func instrumentHint(_ text: String) -> InstrumentHint {
        for rule in settings.instrumentRules where containsAny(text, rule.terms) {
            return InstrumentHint(kind: rule.kind, displayNameRaw: rule.name)
        }
        return InstrumentHint(kind: .unknown)
    }

    private func parseAmount(in originalLines: [String], kind: DraftEventKind) -> AmountResult {
        let lines = originalLines.map { line -> String in
            var line = line
            if let match = readers.foreignWithWon.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let whole = Range(match.range, in: line), let won = Range(match.range(at: 1), in: line) {
                line.replaceSubrange(whole, with: line[won] + "원")
            }
            return readers.points.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        }
        if lines.contains(where: { line in
            containsAny(line.uppercased(), settings.foreignCurrencyTerms) || (containsAny(line, settings.estimateTerms) && line.contains("원"))
        }) {
            return .failure(.unsupportedCurrency)
        }

        var preferred: [Int64] = []
        var fallback: [Int64] = []
        for originalLine in lines {
            // 누적·한도·잔액은 계좌 이야기이지 이번 거래 금액이 아니다.
            if containsAny(originalLine, settings.cumulativeTerms) { continue }
            let line = settings.balanceTerms
                .compactMap { originalLine.range(of: $0)?.lowerBound }
                .min()
                .map { String(originalLine[..<$0]) } ?? originalLine
            let tokens = wonTokens(in: line)
            if tokens.contains(where: \.hasFraction) { return .failure(.amountUnparseable) }
            if tokens.contains(where: { $0.value == nil }) { return .failure(.amountUnparseable) }
            let values = tokens.compactMap(\.value)
            guard !values.isEmpty else { continue }

            if [.cancellation, .refund].contains(kind), containsAny(line, settings.cancelOrRefundTerms) {
                if line.contains(" 중 "), let last = values.last { preferred.append(last) } else { preferred.append(contentsOf: values) }
            } else if containsAny(line, settings.amountLineTerms[kind.rawValue] ?? []) {
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

    private func wonTokens(in line: String) -> [WonToken] {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return readers.wonToken.matches(in: line, range: range).map { match in
            let integerText = Range(match.range(at: 1), in: line).map { String(line[$0]).replacingOccurrences(of: ",", with: "") }
            return WonToken(value: integerText.flatMap(Int64.init), hasFraction: match.range(at: 2).location != NSNotFound)
        }
    }

    /// 금액이 든 줄(`2,800원`). 가게 이름에 글자 `원`이 들어 있어도(`…공학원점`) 이름은 이름이다.
    private static func hasWonAmount(_ line: String) -> Bool {
        line.range(of: #"[0-9][0-9,]*\s*원"#, options: .regularExpression) != nil
    }

    private func parseCounterparty(
        _ lines: [String], direction: TransactionDirection, text: String, kind: DraftEventKind, title: String?, memoPattern: String?
    ) -> DraftCounterparty {
        let labels = settings.nonNameLabels
        let markerLines = settings.statusLines
        let candidates = lines.filter { line in
            !Self.hasWonAmount(line) && !labels.contains(where: line.contains) && !markerLines.contains(line)
                && !readers.nonNameLines.contains(where: { Self.matches($0, line) })
                && !settings.nonNameLinePrefixes.contains(where: line.hasPrefix)
        }
        // 앱의 제목 줄은 아무의 이름도 아니다. 다른 줄이 없을 때만 쓴다.
        var candidate = direction == .inflow ? (candidates.first { $0 != title } ?? candidates.first) : candidates.first
        if candidate == nil, direction == .outflow, kind == .purchase {
            candidate = lines.lazy.compactMap { Self.captures(readers.shopBeforeAmount, $0)?.first?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && $0.rangeOfCharacter(from: .letters) != nil && !markerLines.contains($0) }
        }
        if direction == .inflow,
           let name = readers.inflowNames.lazy.compactMap({ regex in
               lines.lazy.compactMap { Self.captures(regex, $0)?.first?.trimmingCharacters(in: .whitespaces) }.first
           }).first,
           !name.isEmpty, name.rangeOfCharacter(from: .letters) != nil {
            candidate = name
        } else if direction == .inflow, kind != .refund, kind != .cancellation,
                  let line = lines.first(where: { $0.contains("원") && $0.contains("*") }),
                  let name = Self.captures(readers.afterMaskedAccount, line)?.first.map({ $0.trimmingCharacters(in: .whitespaces) }),
                  !name.isEmpty, name.rangeOfCharacter(from: .letters) != nil, !name.contains("원") {
            candidate = name
        }
        let memo: String? = (direction == .outflow ? memoPattern : nil)
            .flatMap { try? NSRegularExpression(pattern: $0) }
            .flatMap { regex in regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { Range($0.range, in: text) } }
            .map { String(text[$0]) }
        return direction == .outflow ? DraftCounterparty(merchantRaw: candidate, memoRaw: memo) : DraftCounterparty(payeeRaw: candidate)
    }

    private func evidence(notification: RawNotification, lines: [String]) -> [DraftEvidence] {
        var result: [DraftEvidence] = []
        let scope = notification.source.applicationIdentifier
        if let value = notification.sourceDeliveryID {
            result.append(DraftEvidence(kind: .deliveryID, strength: .strong, value: value, scope: scope))
        }
        let currentLines = lines.filter { line in !settings.originalMarkerTerms.contains(where: line.contains) }
        if let value = reference(in: currentLines, labels: settings.providerTransactionLabels) {
            result.append(DraftEvidence(kind: .providerTransactionID, strength: .strong, value: value, scope: scope))
        }
        if let value = reference(in: lines, labels: settings.approvalLabels) {
            result.append(DraftEvidence(kind: .approvalNumber, strength: .scoped, value: value, scope: scope))
        }
        if let value = reference(in: lines, labels: settings.originalReferenceLabels) {
            result.append(DraftEvidence(kind: .originalApprovalReference, strength: .relation, value: value, scope: scope))
        }
        return result
    }

    /// `승인번호` 이름표가 `원승인번호` 안에서 맞지 않게, 앞 글자가 `원`이면 원거래 이름표로 본다.
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

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func captures(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}

// MARK: Compiled forms

struct NotificationView {
    let title: String
    let subtitle: String
    let body: String
    let text: String
    let lines: [String]

    init(_ notification: RawNotification) {
        title = NotificationText.normalize(notification.title ?? "")
        subtitle = NotificationText.normalize(notification.subtitle ?? "")
        body = NotificationText.normalize(notification.body ?? "")
        text = NotificationText.joined(notification)
        lines = text.split(separator: "\n").map(String.init)
    }

    func field(_ field: ReadingField) -> String {
        switch field {
        case .title: return title
        case .subtitle: return subtitle
        case .body: return body
        case .all: return text
        }
    }
}

private struct CompiledEntry: Sendable {
    enum Condition: Sendable {
        case contains(ReadingField, [String])
        case frame(ReadingField, ReadingFrame)
        case notEmpty(ReadingField)
    }

    let entry: ReadingEntry
    let conditions: [Condition]

    init?(_ entry: ReadingEntry) {
        var compiled: [Condition] = []
        for condition in entry.conditions {
            switch condition {
            case let .contains(field, terms): compiled.append(.contains(field, terms))
            case let .notEmpty(field): compiled.append(.notEmpty(field))
            case let .frame(field, text):
                guard let frame = ReadingFrame(text, anchored: true) else { return nil }
                compiled.append(.frame(field, frame))
            case let .frameContained(field, text):
                guard let frame = ReadingFrame(text, anchored: false) else { return nil }
                compiled.append(.frame(field, frame))
            }
        }
        self.entry = entry
        self.conditions = compiled
    }

    func match(_ view: NotificationView) -> [ReadingSlot: String]? {
        var values: [ReadingSlot: String] = [:]
        for condition in conditions {
            switch condition {
            case let .contains(field, terms):
                let text = view.field(field)
                guard terms.contains(where: text.contains) else { return nil }
            case let .notEmpty(field):
                guard !view.field(field).isEmpty else { return nil }
            case let .frame(field, frame):
                guard let found = frame.match(in: view.field(field)) else { return nil }
                values.merge(found) { $1 }
            }
        }
        return values
    }
}

private struct CompiledReaders: Sendable {
    let foreignWithWon: NSRegularExpression
    let points: NSRegularExpression
    let wonToken = try! NSRegularExpression(pattern: #"(?<![0-9.,])([0-9]+(?:,[0-9]{3})*)(?:\.([0-9]+))?\s*원"#)
    let nonNameLines: [NSRegularExpression]
    let inflowNames: [NSRegularExpression]
    let shopBeforeAmount: NSRegularExpression
    let afterMaskedAccount: NSRegularExpression

    init(_ settings: ReadingReaderSettings) {
        func compile(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern, options: options)
        }
        let never = try! NSRegularExpression(pattern: "(?!)")
        foreignWithWon = compile(settings.foreignWithWonPattern, [.caseInsensitive]) ?? never
        points = compile(settings.pointsPattern) ?? never
        nonNameLines = settings.nonNameLinePatterns.compactMap { compile($0) }
        inflowNames = settings.inflowNamePatterns.compactMap { compile($0) }
        shopBeforeAmount = compile(settings.shopBeforeAmountPattern) ?? never
        afterMaskedAccount = compile(settings.afterMaskedAccountPattern) ?? never
    }
}
