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
    /// It arrived before the imported history's cutover: the act is already one of the imported rows.
    case coveredByImport
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

/// The real ledger as a replay: first an imported history (`ImportedHistory`, if the user has one), then every received
/// notification, in arrival order, through `NotificationIntake` over the user's account setup. Notifications from before
/// the history's cutover are kept but not replayed: their acts are the imported rows. Received notifications, the
/// imported history and the setup are the durable inputs; the processing repository is derived and rebuilt from them
/// whenever the setup changes, so an account confirmed today also binds the notifications that arrived before it.
public struct IntakeLedger {
    public private(set) var notifications: [RawNotification]
    public private(set) var setup: IntakeSetup
    public private(set) var repository: InMemoryCandidateProcessingRepository
    private var outcomes: [String: NotificationIntakeOutcome]
    public let intake: NotificationIntake
    public let history: ImportedHistory?
    /// What the history became (nil without one). The setup already holds its accounts.
    public let importPlan: ImportPlan?

    public init(notifications: [RawNotification], setup: IntakeSetup, intake: NotificationIntake, history: ImportedHistory? = nil) throws {
        self.notifications = []
        self.history = history
        let plan = try history.map(ActualImportPlanner.plan)
        self.importPlan = plan
        var setup = setup
        if let plan { try setup.importAccounts(plan) }
        self.setup = setup
        self.repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        self.outcomes = [:]
        self.intake = intake
        try seedHistory()
        try replay(notifications)
    }

    /// Adds the notifications not already received (by ID) and processes them. Returns the ones that were new.
    @discardableResult
    public mutating func receive(_ incoming: [RawNotification]) throws -> [RawNotification] {
        var known = Set(notifications.map(\.id))
        let fresh = incoming.filter { known.insert($0.id).inserted }
        for notification in fresh {
            notifications.append(notification)
            if !isCoveredByImport(notification) { ingest(notification) }
        }
        return fresh
    }

    /// The imported rows that still wait for the user, newest first: money in with no explanation, purchases with no
    /// category or name, transfers and withdrawals nothing explains. Each is in the state its notification would have been
    /// in had it just arrived and nobody handled it.
    public var pendingImports: [PendingImport] {
        guard let importPlan else { return [] }
        let snapshot = try? repository.processingSnapshot()
        var result = importPlan.pending
        for candidate in importPlan.candidates where candidate.status == .ready {
            guard snapshot?.candidates[candidate.id]?.promotedEntryID == nil else { continue }
            if let index = result.firstIndex(where: { $0.candidateID == candidate.id }) {
                result[index] = result[index].settingInLedger(false)
            } else if let draft = candidate.sourceDraft {
                result.append(PendingImport(
                    candidateID: candidate.id, accountName: "", title: draft.counterparty.merchantRaw, amount: draft.amount,
                    signedMinorUnits: 0, occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds, reasons: [.notRecorded], inLedger: false
                ))
            }
        }
        return result.sorted { ($0.occurredAtUnixMilliseconds, $0.id) > ($1.occurredAtUnixMilliseconds, $1.id) }
    }

    /// Imported balances against the balances Actual had, account by account (empty without a history).
    public func importReconciliation() -> [AccountReconciliation] {
        guard let importPlan, let snapshot = try? repository.processingSnapshot() else { return [] }
        return importPlan.reconcile(with: snapshot.ledger, pending: pendingImports)
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
        if let notification = notifications.first(where: { $0.id == notificationID }), isCoveredByImport(notification) { return .coveredByImport }
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
        try seedHistory()
        try replay(all)
    }

    /// The imported rows go in first, in date order, one by one through the same atomic promotion a notification uses. They are
    /// never run through the correlator: Actual's rows are what the user already settled.
    private mutating func seedHistory() throws {
        guard let importPlan else { return }
        for candidate in importPlan.candidates {
            let snapshot = try repository.processingSnapshot()
            _ = try? repository.process(candidate, expectedCandidateRevision: snapshot.candidateRevision, expectedLedgerRevision: snapshot.ledger.revision)
        }
    }

    private func isCoveredByImport(_ notification: RawNotification) -> Bool {
        guard let cutover = importPlan?.cutoverUnixMilliseconds else { return false }
        return (notification.notificationAtUnixMilliseconds ?? notification.capturedAtUnixMilliseconds) < cutover
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
