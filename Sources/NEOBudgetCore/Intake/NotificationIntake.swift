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
        let snapshot = try repository.processingSnapshot()
        // The second half of a Toss payment paid from a bank account is the expense: the account of the withdrawal, the shop of
        // the Toss alert. Neither alone can be booked, so what is assembled depends on the half already waiting.
        var recordedDraft = draft
        var recordedResolution = resolution
        var binding = observationWithoutID.binding
        let waiting = snapshot.candidates.values.compactMap(\.correlationRecord)
        let earlier = snapshot.candidates.values.first {
            $0.candidate.sourceDraft.map { $0.rawNotificationID == draft.rawNotificationID && $0.eventIndex == draft.eventIndex } == true
        }
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
        let candidate = try assembler.assemble(recordedDraft, resolution: recordedResolution, context: CandidateAssemblyContext(
            timeZoneIdentifier: timeZoneIdentifier,
            transferCounterpartAccountID: observationWithoutID.transferCounterpart,
            policyVersion: policyVersion
        ))
        let observation = CorrelationObservation(
            candidateID: candidate.id, draft: recordedDraft, binding: binding,
            transferCounterpart: observationWithoutID.transferCounterpart, source: observationWithoutID.source,
            notificationType: observationWithoutID.notificationType, institution: observationWithoutID.institution
        )
        let result = try repository.process(
            candidate, observation: observation, correlator: correlator,
            expectedCandidateRevision: snapshot.candidateRevision, expectedLedgerRevision: snapshot.ledger.revision
        )
        return .processed(candidateID: candidate.id, result: result)
    }
}
