import Foundation

/// Strict baseline parser for explicit Korean financial-notification facts.
/// Provider-specific wording can be layered behind the same protocol once anonymized fixtures
/// are available. It intentionally refuses to infer missing identities, accounts, or originals.
public struct KoreanFinancialNotificationParser: TransactionCandidateParser, Sendable {
    public init() {}

    public func parse(
        _ notification: RawNotification,
        context: NotificationParsingContext
    ) throws -> TransactionCandidate {
        guard !notification.id.isEmpty else {
            throw TransactionCandidateParserError.invalidRawNotificationID
        }

        let text = NotificationText.joined(notification)
        let lines = text.split(separator: "\n").map(String.init)
        let event = classify(text)
        let providerReference = currentProviderReference(in: lines)
        let candidateID = TransactionCandidateID(rawValue: identity(
            prefix: "candidate",
            notification: notification,
            event: event,
            providerReference: providerReference
        ))
        let evidenceIDs = [notification.id]

        guard event != .unsupported else {
            return try TransactionCandidate(
                id: candidateID,
                evidenceIDs: evidenceIDs,
                status: .rejected,
                issues: [.unsupportedEvent],
                policyVersion: context.policyVersion
            )
        }
        guard let amount = try parseAmount(in: lines) else {
            return try reviewCandidate(
                id: candidateID,
                evidenceIDs: evidenceIDs,
                issues: [.missingAmount],
                context: context
            )
        }
        guard amount > 0 else {
            return try reviewCandidate(
                id: candidateID,
                evidenceIDs: evidenceIDs,
                issues: [.invalidAmount],
                context: context
            )
        }
        guard let occurredAt = notification.notificationAtUnixMilliseconds else {
            return try reviewCandidate(
                id: candidateID,
                evidenceIDs: evidenceIDs,
                issues: [.missingTransactionTime],
                context: context
            )
        }
        guard let binding = context.binding else {
            return try reviewCandidate(
                id: candidateID,
                evidenceIDs: evidenceIDs,
                issues: [.unboundSource],
                context: context
            )
        }

        let draftEntry: LedgerEntry
        switch event {
        case .expense:
            draftEntry = try expenseEntry(
                id: entryID(notification, event, providerReference),
                occurredAt: occurredAt,
                amount: amount,
                binding: binding,
                context: context,
                evidenceIDs: evidenceIDs
            )
        case .income:
            guard case let .account(accountID) = binding else {
                return try reviewCandidate(
                    id: candidateID,
                    evidenceIDs: evidenceIDs,
                    issues: [.unknownAccount],
                    context: context
                )
            }
            draftEntry = LedgerEntry(
                id: entryID(notification, event, providerReference),
                kind: .income,
                occurredAtUnixMilliseconds: occurredAt,
                postings: [Posting(
                    accountID: accountID,
                    delta: try Money(minorUnits: amount, currency: context.currency)
                )],
                evidenceIDs: evidenceIDs
            )
        case .transfer:
            guard case let .account(sourceAccountID) = binding,
                  let destinationAccountID = context.transferDestinationAccountID else {
                return try reviewCandidate(
                    id: candidateID,
                    evidenceIDs: evidenceIDs,
                    issues: [.incompleteTransfer],
                    context: context
                )
            }
            draftEntry = LedgerEntry(
                id: entryID(notification, event, providerReference),
                kind: .transfer,
                occurredAtUnixMilliseconds: occurredAt,
                postings: [
                    Posting(
                        accountID: sourceAccountID,
                        delta: try Money(minorUnits: -amount, currency: context.currency)
                    ),
                    Posting(
                        accountID: destinationAccountID,
                        delta: try Money(minorUnits: amount, currency: context.currency)
                    )
                ],
                evidenceIDs: evidenceIDs
            )
        case .cardPayment:
            guard case let .account(accountID) = binding,
                  let instrumentID = context.cardPaymentInstrumentID else {
                return try reviewCandidate(
                    id: candidateID,
                    evidenceIDs: evidenceIDs,
                    issues: [.parserUncertain],
                    context: context
                )
            }
            draftEntry = LedgerEntry(
                id: entryID(notification, event, providerReference),
                kind: .cardPayment,
                occurredAtUnixMilliseconds: occurredAt,
                postings: [Posting(
                    accountID: accountID,
                    delta: try Money(minorUnits: -amount, currency: context.currency)
                )],
                liabilityChanges: [LiabilityChange(
                    instrumentID: instrumentID,
                    delta: try Money(minorUnits: -amount, currency: context.currency)
                )],
                evidenceIDs: evidenceIDs
            )
        case .adjustment:
            guard let originalReference = originalProviderReference(in: lines),
                  let original = context.adjustmentOriginalsByProviderReference[originalReference] else {
                return try reviewCandidate(
                    id: candidateID,
                    evidenceIDs: evidenceIDs,
                    issues: [.missingOriginalEntry],
                    context: context
                )
            }
            draftEntry = try adjustmentEntry(
                id: entryID(notification, event, providerReference),
                occurredAt: occurredAt,
                amount: amount,
                binding: binding,
                original: original,
                context: context,
                evidenceIDs: evidenceIDs
            )
        case .unsupported:
            preconditionFailure("Unsupported events return before entry construction")
        }

        let issues: [CandidateIssue] = providerReference == nil
            ? [.ambiguousWithoutStrongIdentity]
            : []
        return try TransactionCandidate(
            id: candidateID,
            evidenceIDs: evidenceIDs,
            status: issues.isEmpty ? .ready : .needsReview,
            issues: issues,
            proposedEntry: draftEntry,
            policyVersion: context.policyVersion
        )
    }

    private enum Event: String {
        case expense
        case income
        case transfer
        case cardPayment
        case adjustment
        case unsupported
    }

    private func classify(_ text: String) -> Event {
        if containsAny(text, ["취소", "환불"]) { return .adjustment }
        if containsAny(text, ["카드대금", "결제대금"]) { return .cardPayment }
        if containsAny(text, ["이체", "송금"]) { return .transfer }
        if text.contains("입금") { return .income }
        if containsAny(text, ["승인", "사용", "결제"]) { return .expense }
        return .unsupported
    }

    private func containsAny(_ value: String, _ terms: [String]) -> Bool {
        terms.contains(where: value.contains)
    }

    private func parseAmount(in lines: [String]) throws -> Int64? {
        for line in lines where line.contains("원") && !line.contains("잔액") {
            guard let wonIndex = line.firstIndex(of: "원") else { continue }
            let beforeWon = line[..<wonIndex]
            let token = beforeWon.reversed().prefix { character in
                character.isNumber || character == "," || character == " "
            }.reversed().filter { $0.isNumber }
            guard !token.isEmpty else { continue }
            guard let value = Int64(String(token)) else {
                throw TransactionCandidateParserError.amountOverflow
            }
            return value
        }
        return nil
    }

    private func currentProviderReference(in lines: [String]) -> String? {
        reference(
            in: lines.filter { !$0.contains("원거래") && !$0.contains("원승인") },
            labels: ["거래번호", "승인번호", "거래ID", "거래 ID", "Transaction ID"]
        )
    }

    private func originalProviderReference(in lines: [String]) -> String? {
        reference(in: lines, labels: ["원거래번호", "원승인번호", "Original ID"])
    }

    private func reference(in lines: [String], labels: [String]) -> String? {
        for line in lines {
            for label in labels {
                guard let range = line.range(of: label, options: .caseInsensitive) else { continue }
                let suffix = line[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " :#"))
                if !suffix.isEmpty { return suffix }
            }
        }
        return nil
    }

    private func identity(
        prefix: String,
        notification: RawNotification,
        event: Event,
        providerReference: String?
    ) -> String {
        if let providerReference {
            return [
                prefix,
                lengthPrefixed(notification.source.applicationIdentifier),
                event.rawValue,
                lengthPrefixed(providerReference)
            ].joined(separator: "/")
        }
        return [prefix, "raw", lengthPrefixed(notification.id)].joined(separator: "/")
    }

    private func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    private func entryID(
        _ notification: RawNotification,
        _ event: Event,
        _ providerReference: String?
    ) -> LedgerEntryID {
        LedgerEntryID(rawValue: identity(
            prefix: "entry",
            notification: notification,
            event: event,
            providerReference: providerReference
        ))
    }

    private func reviewCandidate(
        id: TransactionCandidateID,
        evidenceIDs: [String],
        issues: [CandidateIssue],
        context: NotificationParsingContext
    ) throws -> TransactionCandidate {
        try TransactionCandidate(
            id: id,
            evidenceIDs: evidenceIDs,
            status: .needsReview,
            issues: issues,
            policyVersion: context.policyVersion
        )
    }

    private func expenseEntry(
        id: LedgerEntryID,
        occurredAt: Int64,
        amount: Int64,
        binding: NotificationLedgerBinding,
        context: NotificationParsingContext,
        evidenceIDs: [String]
    ) throws -> LedgerEntry {
        let money = try Money(minorUnits: amount, currency: context.currency)
        let postings: [Posting]
        let liabilities: [LiabilityChange]
        switch binding {
        case let .account(accountID):
            postings = [Posting(accountID: accountID, delta: try money.negated())]
            liabilities = []
        case let .creditInstrument(instrumentID):
            postings = []
            liabilities = [LiabilityChange(instrumentID: instrumentID, delta: money)]
        }
        return LedgerEntry(
            id: id,
            kind: .expense,
            occurredAtUnixMilliseconds: occurredAt,
            postings: postings,
            liabilityChanges: liabilities,
            budgetImpact: BudgetImpact(
                kind: .expense,
                amount: money,
                attributedMonth: context.currentBudgetMonth
            ),
            evidenceIDs: evidenceIDs
        )
    }

    private func adjustmentEntry(
        id: LedgerEntryID,
        occurredAt: Int64,
        amount: Int64,
        binding: NotificationLedgerBinding,
        original: AdjustmentOriginal,
        context: NotificationParsingContext,
        evidenceIDs: [String]
    ) throws -> LedgerEntry {
        let money = try Money(minorUnits: amount, currency: context.currency)
        let postings: [Posting]
        let liabilities: [LiabilityChange]
        switch binding {
        case let .account(accountID):
            postings = [Posting(accountID: accountID, delta: money)]
            liabilities = []
        case let .creditInstrument(instrumentID):
            postings = []
            liabilities = [LiabilityChange(instrumentID: instrumentID, delta: try money.negated())]
        }
        return LedgerEntry(
            id: id,
            kind: .adjustment,
            occurredAtUnixMilliseconds: occurredAt,
            postings: postings,
            liabilityChanges: liabilities,
            budgetImpact: BudgetImpact(
                kind: .return,
                amount: money,
                attributedMonth: original.budgetMonth
            ),
            adjustment: AdjustmentLink(originalEntryID: original.entryID, reason: .refund),
            evidenceIDs: evidenceIDs
        )
    }
}
