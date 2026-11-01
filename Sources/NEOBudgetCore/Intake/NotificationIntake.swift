/// What the user has told the app about their accounts: the registry (keys, rules, open candidates) and the ledger
/// targets confirmed through it. Together with the received notifications it is everything the ledger is derived from.
public struct IntakeSetup: Codable, Equatable, Sendable {
    public private(set) var registry: AccountRegistry
    public private(set) var configuration: LedgerConfiguration

    public init(registry: AccountRegistry = AccountRegistry(), configuration: LedgerConfiguration = LedgerConfiguration()) {
        self.registry = registry
        self.configuration = configuration
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
        let waiting = try repository.correlationRecords(near: draft.occurredAt.unixMilliseconds, within: correlator.searchRadiusMilliseconds)
        let earlier = try repository.storedCandidate(ofNotification: draft.rawNotificationID, eventIndex: draft.eventIndex)
        if let recorded = earlier?.observation, recorded.draft.ruleID == NotificationCorrelator.tossQuickPayRuleID || recorded.notificationType == .tossPayment {
            // The same notification again: it is recorded as it was the first time, whatever has been paired since.
            recordedDraft = recorded.draft
            if let paired = recorded.binding { recordedResolution = .resolved(paired) }
            binding = recorded.binding
        } else if let recording = correlator.quickPayRecording(for: observationWithoutID, against: waiting) {
            recordedDraft = recording.draft
            recordedResolution = .resolved(recording.binding)
            binding = recording.binding
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
            transferCounterpartAccountID: observationWithoutID.transferCounterpart,
            cancelledPurchase: cancelled,
            policyVersion: policyVersion
        ))
        let observation = CorrelationObservation(
            candidateID: candidate.id, draft: recordedDraft, binding: binding,
            transferCounterpart: observationWithoutID.transferCounterpart, source: observationWithoutID.source,
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
