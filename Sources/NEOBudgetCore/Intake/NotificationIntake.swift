import Foundation

/// What the user has told the app about their accounts: the registry (keys, rules, open candidates) and the ledger
/// targets confirmed through it. Together with the received notifications it is everything the ledger is derived from.
public struct IntakeSetup: Codable, Equatable, Sendable {
    public private(set) var registry: AccountRegistry
    public private(set) var configuration: LedgerConfiguration
    /// Balance breaks the user confirmed as real money (see `ConfirmedGap`), and the ones they chose to leave alone.
    public private(set) var confirmedGaps: [ConfirmedGap]
    public private(set) var acknowledgedBreaks: Set<String>

    public init(registry: AccountRegistry = AccountRegistry(), configuration: LedgerConfiguration = LedgerConfiguration()) {
        self.registry = registry
        self.configuration = configuration
        self.confirmedGaps = []
        self.acknowledgedBreaks = []
    }

    private enum CodingKeys: String, CodingKey { case registry, configuration, confirmedGaps, acknowledgedBreaks }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        registry = try values.decode(AccountRegistry.self, forKey: .registry)
        configuration = try values.decode(LedgerConfiguration.self, forKey: .configuration)
        // A setup saved before balance breaks existed has neither.
        confirmedGaps = try values.decodeIfPresent([ConfirmedGap].self, forKey: .confirmedGaps) ?? []
        acknowledgedBreaks = try values.decodeIfPresent(Set<String>.self, forKey: .acknowledgedBreaks) ?? []
    }

    public mutating func confirm(_ gap: ConfirmedGap) {
        if !confirmedGaps.contains(where: { $0.key == gap.key }) { confirmedGaps.append(gap) }
        acknowledgedBreaks.remove(gap.key)
    }

    public mutating func acknowledgeBreak(_ key: String) {
        acknowledgedBreaks.insert(key)
        confirmedGaps.removeAll { $0.key == key }
    }

    /// Records a notification's account evidence (a new key becomes an open candidate). Idempotent per notification.
    @discardableResult
    public mutating func observe(_ evidence: AccountEvidence, notificationID: String, capturedAtUnixMilliseconds: Int64) -> AccountResolutionDecision {
        registry.observe(evidence, notificationID: notificationID, capturedAtUnixMilliseconds: capturedAtUnixMilliseconds)
    }

    /// The user says a candidate is a new account or card; the ledger gains it in the same step.
    @discardableResult
    public mutating func confirmAsNew(
        _ id: AccountCandidateID, displayName: String, kind: NewTargetKind, makeID: () -> String
    ) throws -> NewLedgerTarget {
        var registry = self.registry
        let target = try registry.confirmAsNew(id, displayName: displayName, kind: kind, makeID: makeID)
        self.registry = registry
        add(target)
        return target
    }

    /// The user says a candidate is an account already registered.
    public mutating func link(_ id: AccountCandidateID, to binding: ResolvedLedgerBinding) throws {
        try registry.link(id, to: binding)
    }

    public mutating func dismiss(_ id: AccountCandidateID) throws {
        try registry.dismiss(id)
    }

    /// The user adds an account or card by hand (one whose messages never carry a number: a wallet, a transit card).
    @discardableResult
    public mutating func addAccount(
        displayName: String, institution: InstitutionID?, kind: NewTargetKind, makeID: () -> String
    ) throws -> NewLedgerTarget {
        var registry = self.registry
        let target = try registry.addAccount(displayName: displayName, institution: institution, kind: kind, makeID: makeID)
        self.registry = registry
        add(target)
        return target
    }

    /// The user says messages like this one (same app, same message type, same institution and instrument kind) are
    /// about `binding`. Throws `siblingsExist` when another account could have sent the same message: then a rule
    /// would be a guess, and the notification stays for review.
    public mutating func addSourceRule(for evidence: AccountEvidence, binding: ResolvedLedgerBinding, createdAtUnixMilliseconds: Int64) throws {
        guard let provider = evidence.provider, let institution = evidence.instrument.institution else {
            throw AccountRegistryError.ruleScopeIncomplete
        }
        let kind = evidence.instrument.kind
        let id = SourceRuleID(rawValue: [provider.rawValue, evidence.type.rawValue, institution.rawValue, kind.rawValue].joined(separator: "|"))
        try registry.addSourceRule(id: id, provider: provider, types: [evidence.type], institution: institution, kind: kind,
                                   binding: binding, createdAtUnixMilliseconds: createdAtUnixMilliseconds)
    }

    /// The user says a word in bank messages stands for this account of theirs (the wallet a top-up goes to, a deposit
    /// from their own name): such a bank message is then a transfer, whichever alert arrives.
    public mutating func addCounterpartAlias(_ phrase: String, to binding: ResolvedLedgerBinding) throws {
        try registry.addCounterpartAlias(phrase, to: binding)
    }

    private mutating func add(_ target: NewLedgerTarget) {
        switch target {
        case let .account(account):
            configuration = LedgerConfiguration(accounts: configuration.accounts + [account], creditInstruments: configuration.creditInstruments)
        case let .creditInstrument(instrument):
            configuration = LedgerConfiguration(accounts: configuration.accounts, creditInstruments: configuration.creditInstruments + [instrument])
        }
    }
}

/// What became of one received notification.
public enum NotificationIntakeOutcome: Equatable, Sendable {
    /// Not a financial act (an ad, a login code, a balance notice...). Kept as raw input only.
    case notTransaction(NotTransactionReason)
    /// It looked financial but the amount could not be read safely.
    case unreadable(NotificationParseFailure)
    case processed(candidateID: TransactionCandidateID, result: CandidateProcessingResult)
}

/// One received notification through the whole pipeline, in one place: parse (facts only) -> account evidence ->
/// registry (resolve, record new keys) -> assemble -> correlate against what is stored -> process (dedup, promotion).
/// It holds no state; the caller owns the setup and the repository and serializes calls.
public struct NotificationIntake: Sendable {
    public static let parserID = "korean-financial"
    public static let parserVersion = "2"

    public let timeZoneIdentifier: String
    public let policyVersion: String
    public let parser: KoreanFinancialNotificationParser
    public let extractor: AccountEvidenceExtractor
    public let assembler: DefaultTransactionCandidateAssembler
    public let correlator: NotificationCorrelator

    public init(
        timeZoneIdentifier: String,
        policyVersion: String = "intake-v1",
        extractor: AccountEvidenceExtractor = AccountEvidenceExtractor(),
        correlator: NotificationCorrelator = NotificationCorrelator()
    ) {
        self.timeZoneIdentifier = timeZoneIdentifier
        self.policyVersion = policyVersion
        self.parser = KoreanFinancialNotificationParser()
        self.extractor = extractor
        self.assembler = DefaultTransactionCandidateAssembler()
        self.correlator = correlator
    }

    public func ingest<Repository: CandidateProcessingRepository>(
        _ notification: RawNotification,
        setup: inout IntakeSetup,
        repository: inout Repository
    ) throws -> NotificationIntakeOutcome {
        let context = try NotificationParsingContext(
            timeZoneIdentifier: timeZoneIdentifier,
            referenceTimeUnixMilliseconds: notification.capturedAtUnixMilliseconds,
            parserID: Self.parserID,
            parserVersion: Self.parserVersion
        )
        let draft: TransactionCandidateDraft
        switch try parser.parse(notification, context: context) {
        case let .notTransaction(reason): return .notTransaction(reason)
        case let .failed(failure): return .unreadable(failure)
        case let .candidate(parsed): draft = parsed
        }

        let evidence = extractor.evidence(from: notification)
        let decision = setup.observe(evidence, notificationID: notification.id, capturedAtUnixMilliseconds: notification.capturedAtUnixMilliseconds)
        let resolution: AccountResolution = switch decision {
        case let .resolved(binding, _): .resolved(binding)
        case .newCandidate: .unresolved(.unknownAccount)
        case .needsConfirmation: .unresolved(.unboundSource)
        }
        // The observation carries the counterpart only when it is one of the user's registered accounts.
        let observationWithoutID = CorrelationObservation(
            candidateID: TransactionCandidateID(rawValue: "-"), draft: draft, evidence: evidence,
            registry: setup.registry, fallbackSource: notification.source.applicationIdentifier
        )
        let revisions = try repository.revisions()
        // The second half of a Toss payment paid from a bank account is the expense: the account of the withdrawal, the shop of
        // the Toss alert. Neither alone can be booked, so what is assembled depends on the half already waiting.
        var recordedDraft = draft
        var recordedResolution = resolution
        var binding = observationWithoutID.binding
        var transferCounterpart = observationWithoutID.transferCounterpart
        var cardInstrument: CreditInstrumentID?
        let waiting = try repository.correlationRecords(near: draft.occurredAt.unixMilliseconds, within: correlator.searchRadiusMilliseconds)
        let earlier = try repository.storedCandidate(ofNotification: draft.rawNotificationID, eventIndex: draft.eventIndex)
        if let recorded = earlier?.observation, Self.rewrittenRuleIDs.contains(recorded.draft.ruleID) {
            recordedDraft = recorded.draft
            transferCounterpart = recorded.transferCounterpart
            if recorded.draft.ruleID == Self.cardBillRuleID { cardInstrument = Self.cardInstrument(for: recorded.draft, in: setup.configuration.creditInstruments) }
        } else if earlier == nil, transferCounterpart == nil, case let .account(own)? = binding,
                  let wallet = setup.registry.counterpartAlias(in: NotificationText.joined(notification)), wallet != own,
                  let transfer = Self.asTransfer(draft) {
            // A bank message that names one of the user's own accounts by a word they confirmed is a transfer to or from it
            // (a Toss Pay Money top-up, the money coming back). It beats the Toss pairing: the shop is paid from the wallet.
            recordedDraft = transfer
            transferCounterpart = wallet
        } else if let recorded = earlier?.observation, recorded.draft.ruleID == NotificationCorrelator.tossQuickPayRuleID || recorded.notificationType == .tossPayment {
            // The same notification again: it is recorded as it was the first time, whatever has been paired since.
            recordedDraft = recorded.draft
            if let paired = recorded.binding { recordedResolution = .resolved(paired) }
            binding = recorded.binding
        } else if let recording = correlator.quickPayRecording(for: observationWithoutID, against: waiting) {
            recordedDraft = recording.draft
            recordedResolution = .resolved(recording.binding)
            binding = recording.binding
        } else if earlier == nil, transferCounterpart == nil, let own = correlator.ownTransferCounterpart(of: draft, binding: binding, among: waiting),
                  let transfer = Self.asTransfer(draft) {
            // A withdrawal and a deposit of one amount on two of the user's accounts at the same moment are one transfer, whatever name
            // the bank prints (`토스 <이름>`, a bare `출금`).
            recordedDraft = transfer
            transferCounterpart = own
        } else if earlier == nil, case .account? = binding, let person = Self.asTossPersonTransfer(draft, text: NotificationText.joined(notification)) {
            // A bank withdrawal `토스 <이름>` with no Toss alert to pair with (Toss sends none while its app is open) is the user's own
            // transfer to that person. The Toss payment pairing above wins when its alert is already here.
            recordedDraft = person
        } else if earlier == nil, case let .account(own)? = binding, let bill = Self.asCardBillPayment(draft, text: NotificationText.joined(notification), cards: setup.configuration.creditInstruments),
                  !waiting.contains(where: { $0.draft.kind == .purchase && $0.binding == .account(own) && $0.draft.amount == draft.amount }) {
            // `[출금] 현대카드 1,069,690원` with no card approval of that money: the monthly bill, paid from this account.
            recordedDraft = bill.draft
            cardInstrument = bill.card
        } else if earlier == nil, case .account? = binding, let premium = Self.asHealthInsurance(draft, text: NotificationText.joined(notification)) {
            recordedDraft = premium
        } else if earlier == nil, case .account? = binding, let charge = Self.asPrepaidChargeSpending(draft, text: NotificationText.joined(notification)) {
            // The user has not registered that prepaid wallet (a registered one is the alias transfer above): the top-up stays spending.
            recordedDraft = charge
        }
        // A cancellation is booked against the purchase it undoes, found among what is stored (not by an approval number
        // only: bank cancellations carry none). A repeat keeps what it was linked to the first time.
        var cancels = earlier?.observation?.cancels
        var cancelled: CancelledPurchase?
        if earlier == nil, recordedDraft.kind == .cancellation {
            let probe = CorrelationObservation(
                candidateID: TransactionCandidateID(rawValue: "-"), draft: recordedDraft, binding: binding,
                transferCounterpart: nil, source: observationWithoutID.source
            )
            let records = try repository.correlationRecords(
                near: recordedDraft.occurredAt.unixMilliseconds, within: NotificationCorrelator.cancellationWindowMilliseconds
            )
            if let purchase = correlator.cancelledPurchase(by: probe, among: records), let entryID = purchase.entryID {
                cancels = purchase.candidateID
                cancelled = CancelledPurchase(entryID: entryID, occurredAtUnixMilliseconds: purchase.draft.occurredAt.unixMilliseconds)
            }
        }
        let candidate = try assembler.assemble(recordedDraft, resolution: recordedResolution, context: CandidateAssemblyContext(
            timeZoneIdentifier: timeZoneIdentifier,
            transferCounterpartAccountID: transferCounterpart,
            cardPaymentInstrumentID: cardInstrument,
            cancelledPurchase: cancelled,
            policyVersion: policyVersion
        ))
        let observation = CorrelationObservation(
            candidateID: candidate.id, draft: recordedDraft, binding: binding,
            transferCounterpart: transferCounterpart, source: observationWithoutID.source,
            notificationType: observationWithoutID.notificationType, institution: observationWithoutID.institution,
            cancels: cancels
        )
        let result = try repository.process(
            candidate, observation: observation, correlator: correlator,
            expectedCandidateRevision: revisions.candidate, expectedLedgerRevision: revisions.ledger
        )
        if case .promoted = result, recordedDraft.kind == .purchase {
            try settleWaitingCancellations(near: recordedDraft.occurredAt.unixMilliseconds, repository: &repository)
        }
        return .processed(candidateID: candidate.id, result: result)
    }

    static let aliasTransferRuleID = "alias-transfer"
    public static let tossPersonTransferRuleID = "toss-person-transfer"
    static let prepaidChargeSpendingRuleID = "prepaid-charge-spending"
    private static let rewrittenRuleIDs: Set<String> = [aliasTransferRuleID, tossPersonTransferRuleID, prepaidChargeSpendingRuleID, cardBillRuleID, healthInsuranceRuleID]
    static let healthInsuranceRuleID = "health-insurance-withdrawal"
    private static let healthInsurancePattern = try! NSRegularExpression(pattern: #"\[출금\]\s*건강[가-힣]{2,4}\s+[0-9]"#)
    static let cardBillRuleID = "card-bill-withdrawal"
    private static let cardBillPattern = try! NSRegularExpression(pattern: #"\[출금\]\s*([가-힣]*카드)\s+[0-9][0-9,]*\s*원"#)

    /// Woori's `[출금] 토스    김의근 10,000원`: the person's name sits between `토스` and the amount.
    private static let tossPersonPatterns = [
        #"\[출금\]\s*토스\s+([가-힣]{2,4})\s+[0-9][0-9,]*\s*원"#,
        // The SMS layout: the name follows the masked account number.
        #"\*\S*\s+토스\s+([가-힣]{2,4})\s+(?:잔액|잔고|[0-9]{1,2}/)"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let kakaoPayWord = try! NSRegularExpression(pattern: #"(?<![가-힣A-Za-z0-9_])카카오페이(?![가-힣A-Za-z0-9_])"#)
    /// Words that follow `토스` for a service, not a person.
    private static let tossServiceWords: Set<String> = ["페이", "머니", "뱅크", "증권", "쇼핑", "페이먼츠", "프라임", "보험", "카드", "퀵", "인슈어런스"]

    /// A bank withdrawal to `토스 <사람 이름>` read as the purchase-shaped spending on that person (my transfer is my spending).
    static func asTossPersonTransfer(_ draft: TransactionCandidateDraft, text: String) -> TransactionCandidateDraft? {
        guard draft.kind == .withdrawal, draft.direction == .outflow,
              let match = tossPersonPatterns.lazy.compactMap({ $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) }).first,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let name = String(text[range])
        guard !tossServiceWords.contains(name) else { return nil }
        return rewritten(draft, ruleID: tossPersonTransferRuleID, counterparty: DraftCounterparty(payeeRaw: name, memoRaw: "토스"))
    }

    /// A bank-side Kakao Pay top-up reads `[출금] (주)카카오페이 …`. shortcut: Kakao Pay only; add 티머니/캐시비 words when
    /// their real bank messages are known (checklist §8 of the prepaid top-up record).

    static func asPrepaidChargeSpending(_ draft: TransactionCandidateDraft, text: String) -> TransactionCandidateDraft? {
        guard draft.kind == .withdrawal, draft.direction == .outflow,
              kakaoPayWord.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return nil }
        return rewritten(draft, ruleID: prepaidChargeSpendingRuleID, counterparty: DraftCounterparty(merchantRaw: "카카오페이", memoRaw: "충전"))
    }

    /// A bank withdrawal named after a registered card (`[출금] 현대카드 …`) is that card's bill. shortcut: a bill arriving before
    /// the approval of a same-money check-card purchase would be booked as a bill; none seen, since approvals precede the bank alert.
    static func asCardBillPayment(_ draft: TransactionCandidateDraft, text: String, cards: [CreditInstrument]) -> (draft: TransactionCandidateDraft, card: CreditInstrumentID)? {
        guard draft.kind == .withdrawal, draft.direction == .outflow,
              let match = cardBillPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let card = cards.first(where: { $0.name.contains(String(text[range])) }),
              let bill = rewritten(draft, ruleID: cardBillRuleID, counterparty: DraftCounterparty(merchantRaw: card.name, memoRaw: "카드 대금"), kind: .cardBillPayment)
        else { return nil }
        return (bill, card.id)
    }

    /// The bank prints the health insurance auto-debit as `[출금] 건강<이름> …`: spending, not a transfer.
    static func asHealthInsurance(_ draft: TransactionCandidateDraft, text: String) -> TransactionCandidateDraft? {
        guard draft.kind == .withdrawal, draft.direction == .outflow,
              healthInsurancePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return nil }
        return rewritten(draft, ruleID: healthInsuranceRuleID, counterparty: DraftCounterparty(merchantRaw: "건강보험료"))
    }

    private static func cardInstrument(for draft: TransactionCandidateDraft, in cards: [CreditInstrument]) -> CreditInstrumentID? {
        cards.first(where: { $0.name == draft.counterparty.merchantRaw })?.id
    }

    private static func rewritten(_ draft: TransactionCandidateDraft, ruleID: String, counterparty: DraftCounterparty, kind: DraftEventKind = .purchase) -> TransactionCandidateDraft? {
        try? TransactionCandidateDraft(
            rawNotificationID: draft.rawNotificationID, eventIndex: draft.eventIndex, parserID: draft.parserID,
            parserVersion: draft.parserVersion, ruleID: ruleID, kind: kind, direction: .outflow,
            amount: draft.amount, balanceAfter: draft.balanceAfter, occurredAt: draft.occurredAt, instrument: draft.instrument,
            counterparty: counterparty, evidence: draft.evidence, issues: draft.issues.filter { $0 != .merchantMissing },
            confidence: draft.confidence
        )
    }

    /// A bank withdrawal or deposit read as the transfer it is; anything else stays as it was.
    private static func asTransfer(_ draft: TransactionCandidateDraft) -> TransactionCandidateDraft? {
        let kind: DraftEventKind
        switch (draft.kind, draft.direction) {
        case (.withdrawal, .outflow): kind = .transferOut
        case (.deposit, .inflow): kind = .transferIn
        default: return nil
        }
        return try? TransactionCandidateDraft(
            rawNotificationID: draft.rawNotificationID, eventIndex: draft.eventIndex, parserID: draft.parserID,
            parserVersion: draft.parserVersion, ruleID: aliasTransferRuleID, kind: kind, direction: draft.direction,
            amount: draft.amount, balanceAfter: draft.balanceAfter, occurredAt: draft.occurredAt, instrument: draft.instrument,
            counterparty: draft.counterparty, evidence: draft.evidence, issues: draft.issues, confidence: draft.confidence
        )
    }

    /// A purchase was just recorded: cancellations that arrived before it (the bank sends a cancellation within the same
    /// second as the payment, and the order of delivery is not the order of the payments) can now be booked against it, and
    /// the alert of a cancellation that has just been booked is evidence of it. Oldest first, so the result is the same
    /// whichever order they arrived in.
    private func settleWaitingCancellations<Repository: CandidateProcessingRepository>(
        near time: Int64, repository: inout Repository
    ) throws {
        let window = NotificationCorrelator.cancellationWindowMilliseconds
        let waiting = try repository.correlationRecords(near: time, within: window).filter {
            $0.entryID == nil && $0.corroborates == nil && $0.cancels == nil && $0.draft.kind == .cancellation
        }.sorted { ($0.draft.occurredAt.unixMilliseconds, $0.candidateID.rawValue) < ($1.draft.occurredAt.unixMilliseconds, $1.candidateID.rawValue) }
        for record in waiting {
            // Records are read again each time: the cancellation before this one may have taken the purchase.
            let records = try repository.correlationRecords(near: record.draft.occurredAt.unixMilliseconds, within: window)
            let purchase = correlator.cancelledPurchase(by: record.observation(cancels: nil), among: records)
            let observation = record.observation(cancels: purchase?.candidateID)
            switch correlator.decide(observation, against: records) {
            case .corroborates: break
            case .newAct where purchase != nil: break
            default: continue
            }
            guard let binding = record.binding else { continue }
            let candidate = try assembler.assemble(record.draft, resolution: .resolved(binding), context: CandidateAssemblyContext(
                timeZoneIdentifier: timeZoneIdentifier,
                transferCounterpartAccountID: record.transferCounterpart,
                cancelledPurchase: purchase.flatMap { found in
                    found.entryID.map { CancelledPurchase(entryID: $0, occurredAtUnixMilliseconds: found.draft.occurredAt.unixMilliseconds) }
                },
                policyVersion: policyVersion
            ))
            let revisions = try repository.revisions()
            _ = try repository.process(
                candidate, observation: observation, correlator: correlator,
                expectedCandidateRevision: revisions.candidate, expectedLedgerRevision: revisions.ledger
            )
        }
    }
}
