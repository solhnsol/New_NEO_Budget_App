import NEOBudgetCore

/// Where one received notification ended up, for the inbox the user reads.
public enum IntakeStatus: Equatable, Sendable {
    /// It is (part of) this ledger entry.
    case recorded(LedgerEntryID)
    /// Another notification of the same act was recorded; this one is its evidence.
    case sameActAs(TransactionCandidateID)
    /// Waiting for the user (an unknown account, a withdrawal nothing explains, a refund without its purchase...).
    case waiting([CandidateIssue])
    case notTransaction(NotTransactionReason)
    case unreadable(NotificationParseFailure)
    /// Processing threw. The notification is kept and is tried again on the next rebuild.
    case failed
}

/// "Messages like this one are about which account?" for a notification that never names its account.
public struct RuleQuestion: Equatable, Identifiable, Sendable {
    public let notificationID: String
    public let provider: SourceProviderID
    public let type: NotificationType
    public let institution: InstitutionID
    public let kind: InstrumentKind
    /// Registered accounts of the right class (a credit card for a credit card, an account for everything else).
    public let choices: [AccountProfile]

    public var id: String { notificationID }
}

/// The real ledger as a replay: every received notification, in arrival order, through `NotificationIntake` over the
/// user's account setup. Received notifications and the setup are the durable inputs; the processing repository is
/// derived and rebuilt from them whenever the setup changes, so an account confirmed today also binds the
/// notifications that arrived before it.
public struct IntakeLedger {
    public private(set) var notifications: [RawNotification]
    public private(set) var setup: IntakeSetup
    public private(set) var repository: InMemoryCandidateProcessingRepository
    private var outcomes: [String: NotificationIntakeOutcome]
    public let intake: NotificationIntake

    public init(notifications: [RawNotification], setup: IntakeSetup, intake: NotificationIntake) throws {
        self.notifications = []
        self.setup = setup
        self.repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        self.outcomes = [:]
        self.intake = intake
        try replay(notifications)
    }

    /// Adds the notifications not already received (by ID) and processes them. Returns the ones that were new.
    @discardableResult
    public mutating func receive(_ incoming: [RawNotification]) throws -> [RawNotification] {
        var known = Set(notifications.map(\.id))
        let fresh = incoming.filter { known.insert($0.id).inserted }
        for notification in fresh {
            notifications.append(notification)
            ingest(notification)
        }
        return fresh
    }

    public mutating func confirmAsNew(_ id: AccountCandidateID, displayName: String, kind: NewTargetKind, makeID: () -> String) throws {
        var setup = self.setup
        try setup.confirmAsNew(id, displayName: displayName, kind: kind, makeID: makeID)
        try rebuild(setup)
    }

    public mutating func link(_ id: AccountCandidateID, to binding: ResolvedLedgerBinding) throws {
        var setup = self.setup
        try setup.link(id, to: binding)
        try rebuild(setup)
    }

    public mutating func dismiss(_ id: AccountCandidateID) throws {
        var setup = self.setup
        try setup.dismiss(id)
        try rebuild(setup)
    }

    /// For a notification that waits only because its message never names the account (a pay app, a wallet, a
    /// transit card): which account messages like it belong to. Nil when a rule could not settle it.
    public func ruleQuestion(for notificationID: String) -> RuleQuestion? {
        guard let notification = notifications.first(where: { $0.id == notificationID }) else { return nil }
        let evidence = intake.extractor.evidence(from: notification)
        guard case let .needsConfirmation(reason, _) = setup.registry.resolve(evidence),
              reason == .noIdentifier || reason == .weakIdentifier,
              let provider = evidence.provider, let institution = evidence.instrument.institution else { return nil }
        let kind = evidence.instrument.kind
        let choices = setup.registry.profiles.filter { profile in
            guard profile.isActive else { return false }
            switch profile.binding {
            case .creditInstrument: return kind.bindsToCreditInstrument
            case .account: return !kind.bindsToCreditInstrument
            }
        }
        return RuleQuestion(notificationID: notificationID, provider: provider, type: evidence.type,
                            institution: institution, kind: kind, choices: choices)
    }

    /// Answers a `ruleQuestion`: messages like that one belong to `binding`, or to a new account named `newAccount`.
    public mutating func answer(
        _ question: RuleQuestion, binding: ResolvedLedgerBinding?, newAccount: (name: String, kind: NewTargetKind)?,
        at unixMilliseconds: Int64, makeID: () -> String
    ) throws {
        guard let notification = notifications.first(where: { $0.id == question.notificationID }) else { return }
        let evidence = intake.extractor.evidence(from: notification)
        var setup = self.setup
        let target: ResolvedLedgerBinding
        if let binding {
            target = binding
        } else if let newAccount {
            target = try setup.addAccount(displayName: newAccount.name, institution: question.institution, kind: newAccount.kind, makeID: makeID).binding
        } else {
            return
        }
        try setup.addSourceRule(for: evidence, binding: target, createdAtUnixMilliseconds: unixMilliseconds)
        try rebuild(setup)
    }

    public func status(of notificationID: String) -> IntakeStatus {
        guard let outcome = outcomes[notificationID] else { return .failed }
        switch outcome {
        case let .notTransaction(reason): return .notTransaction(reason)
        case let .unreadable(failure): return .unreadable(failure)
        case let .processed(candidateID, _):
            guard let snapshot = try? repository.processingSnapshot(), let stored = snapshot.candidates[candidateID] else { return .failed }
            if let entry = stored.promotedEntryID { return .recorded(entry) }
            if let act = stored.corroborates?.candidateID {
                if let entry = snapshot.candidates[act]?.promotedEntryID { return .recorded(entry) }
                return .sameActAs(act)
            }
            return .waiting(stored.candidate.issues)
        }
    }

    private mutating func rebuild(_ setup: IntakeSetup) throws {
        let all = notifications
        self.setup = setup
        repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        outcomes = [:]
        notifications = []
        try replay(all)
    }

    private mutating func replay(_ all: [RawNotification]) throws {
        try receive(all)
    }

    private mutating func ingest(_ notification: RawNotification) {
        if let outcome = try? intake.ingest(notification, setup: &setup, repository: &repository) {
            outcomes[notification.id] = outcome
        }
    }
}
