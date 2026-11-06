import Foundation
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

/// A balance a notification printed for an account ("잔액 1,234원", "Your new balance is ₩10,000"): what the bank or the
/// card itself said the account held at that moment.
public struct ReportedBalance: Equatable, Sendable {
    public let accountID: AccountID
    public let minorUnits: Int64
    public let atUnixMilliseconds: Int64
    public let notificationID: String
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
    private var outcomes: [String: IntakeLedgerSnapshot.Outcome]
    /// Where each received notification sits in `notifications`, which is also the set of IDs already received.
    private var positions: [String: Int]
    /// IDs of the notifications a partial replay left out (older than its cutoff); empty for a full one. They are not in
    /// `notifications`, `receive` does not take them again, and the ledger is complete only without them.
    public private(set) var deferredIDs: Set<String> = []
    public let intake: NotificationIntake
    public let history: ImportedHistory?
    /// What the history became (nil without one). The setup already holds its accounts.
    public let importPlan: ImportPlan?

    /// `replayingSince`: replay only the notifications at or after that time and leave the older ones out (`deferredIDs`), so
    /// the part of the history on screen is ready first and a full `IntakeLedger` over all of them can be built later.
    /// What is replayed gets the same answers as in the full replay, except what depends on an older notification: balances
    /// (they start from zero) and a refund whose purchase is left out (it waits, as if the purchase had never been seen).
    public init(
        notifications: [RawNotification], setup: IntakeSetup, intake: NotificationIntake,
        history: ImportedHistory? = nil, replayingSince cutoff: Int64? = nil
    ) throws {
        self.notifications = []
        self.history = history
        let plan = try history.map(ActualImportPlanner.plan)
        self.importPlan = plan
        var setup = setup
        if let plan { try setup.importAccounts(plan) }
        self.setup = setup
        self.repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        self.outcomes = [:]
        self.positions = [:]
        self.intake = intake
        try seedHistory()
        guard let cutoff else {
            try replay(notifications)
            return
        }
        let (recent, older) = notifications.reduce(into: ([RawNotification](), [RawNotification]())) { split, notification in
            if Self.time(of: notification) < cutoff { split.1.append(notification) } else { split.0.append(notification) }
        }
        deferredIDs = Set(older.map(\.id))
        try replay(recent)
    }

    public var isComplete: Bool { deferredIDs.isEmpty }

    /// Bump when anything that decides what a notification becomes changes (the parser's reading, the assembler, the
    /// correlator, deduplication): a saved ledger made under another value is not used, and the ledger is replayed once.
    public static let rulesRevision = 5

    /// The ledger as it stands, to save and restore later (`init(restoring:...)`). Nil for a partial replay.
    public func snapshot() -> IntakeLedgerSnapshot? {
        guard isComplete else { return nil }
        let state = repository.exportedState()
        return IntakeLedgerSnapshot(
            rules: Self.rulesKey(intake), history: Self.historyKey(history), setup: setup,
            notificationIDs: notifications.map(\.id), outcomes: outcomes,
            candidateRevision: state.candidateRevision, candidates: state.candidates, entries: state.entries
        )
    }

    /// Continues from a saved ledger instead of replaying: the notifications it covers are not parsed again, only the ones
    /// after them. Throws when the snapshot does not belong to these inputs (other rules, history or setup, or its
    /// notifications are not the start of `notifications`) or does not rebuild; the caller then replays everything.
    public init(
        restoring snapshot: IntakeLedgerSnapshot, notifications: [RawNotification], setup: IntakeSetup,
        intake: NotificationIntake, history: ImportedHistory? = nil
    ) throws {
        let plan = try history.map(ActualImportPlanner.plan)
        var setup = setup
        if let plan { try setup.importAccounts(plan) }
        let covered = snapshot.notificationIDs.count
        guard snapshot.format == IntakeLedgerSnapshot.currentFormat, snapshot.rules == Self.rulesKey(intake),
              snapshot.history == Self.historyKey(history), snapshot.setup == setup,
              notifications.count >= covered, zip(snapshot.notificationIDs, notifications).allSatisfy({ $0 == $1.id }),
              snapshot.outcomes.count <= covered
        else { throw IntakeLedgerSnapshotError.notApplicable }
        self.notifications = Array(notifications.prefix(covered))
        self.history = history
        self.importPlan = plan
        self.setup = snapshot.setup
        self.intake = intake
        self.outcomes = snapshot.outcomes
        self.positions = Dictionary(uniqueKeysWithValues: snapshot.notificationIDs.enumerated().map { ($1, $0) })
        guard positions.count == covered else { throw IntakeLedgerSnapshotError.notApplicable }
        self.repository = try InMemoryCandidateProcessingRepository(
            configuration: snapshot.setup.configuration, candidateRevision: snapshot.candidateRevision,
            candidates: snapshot.candidates, entries: snapshot.entries
        )
        try receive(Array(notifications.dropFirst(covered)))
    }

    private static func rulesKey(_ intake: NotificationIntake) -> String {
        [NotificationIntake.parserID, NotificationIntake.parserVersion, intake.policyVersion, intake.timeZoneIdentifier, String(rulesRevision), intake.readingKey]
            .joined(separator: "/")
    }

    /// FNV-1a over the history's canonical JSON; a different import gives a different key.
    private static func historyKey(_ history: ImportedHistory?) -> String {
        guard let history else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (try? encoder.encode(history)) ?? Data() { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// Adds the notifications not already received (by ID) and processes them. Returns the ones that were new.
    @discardableResult
    public mutating func receive(_ incoming: [RawNotification]) throws -> [RawNotification] {
        let fresh = append(incoming)
        try settleConfirmedGaps()
        return fresh
    }

    private mutating func append(_ incoming: [RawNotification]) -> [RawNotification] {
        var fresh: [RawNotification] = []
        for notification in incoming where positions[notification.id] == nil && !deferredIDs.contains(notification.id) {
            positions[notification.id] = notifications.count + fresh.count
            fresh.append(notification)
        }
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

    /// The newest balance each account's notifications reported. A notice that moves no money (a transit "Trip in Progress"
    /// or "no charge", a bank balance line) counts too: it is the only record of money the ledger never saw leave. Notices
    /// whose account cannot be settled without asking the user are left out. The ledger starts from zero and holds only what
    /// notifications recorded, so this is what anchors a balance to the real one.
    public var reportedBalances: [AccountID: ReportedBalance] {
        var result: [AccountID: ReportedBalance] = [:]
        for (notification, accountID, balance) in resolvedBalances() {
            let at = Self.time(of: notification)
            if let known = result[accountID], known.atUnixMilliseconds > at { continue }
            result[accountID] = ReportedBalance(accountID: accountID, minorUnits: balance, atUnixMilliseconds: at, notificationID: notification.id)
        }
        return result
    }

    private func resolvedBalances() -> [(RawNotification, AccountID, Int64)] {
        notifications.compactMap { notification in
            var evidence = intake.extractor.evidence(from: notification)
            guard let balance = evidence.balanceMinorUnits else { return nil }
            // The no-charge and balance-only notices are the same Wallet transit card as a fare; a rule is scoped to the fare.
            if evidence.type == .transitBalanceOnly || evidence.type == .transitNoCharge {
                evidence = AccountEvidence(provider: evidence.provider, type: .transitFare, instrument: evidence.instrument, balanceMinorUnits: balance)
            }
            guard case let .resolved(.account(accountID), _) = setup.registry.resolve(evidence) else { return nil }
            return (notification, accountID, balance)
        }
    }

    // MARK: Balance breaks

    /// Where the balances notifications printed and the recorded movements disagree, and nothing explains it: not a user
    /// choice already made ("그냥 넘어가요", confirmed as an entry), not acts waiting for the user that add up to the
    /// difference. Each is a suggestion; nothing enters the ledger until `confirmBalanceGap`. A partial replay only sees the
    /// part it replayed.
    public var balanceBreaks: [BalanceBreak] {
        let snapshot = try? repository.processingSnapshot()
        let observations = balanceObservations()
        return BalanceChain.breaks(observations: observations).filter { gap in
            !setup.acknowledgedBreaks.contains(gap.id) && !setup.confirmedGaps.contains { $0.key == gap.id }
                && !isExplained(gap, snapshot: snapshot, chain: observations)
        }
    }

    /// The user says the break is real money of that kind: it becomes an expense or an income in the ledger, for as long as
    /// the break is still there. A notification that arrives later and covers it replaces the entry.
    public mutating func confirmBalanceGap(_ gap: BalanceBreak, label: String) throws {
        var setup = self.setup
        setup.confirm(ConfirmedGap(key: gap.id, accountID: gap.accountID, signedMinorUnits: gap.differenceMinorUnits,
                                   atUnixMilliseconds: gap.after.atUnixMilliseconds, label: label))
        try rebuild(setup)
    }

    /// "그냥 넘어가요": the break is not asked about again.
    public mutating func acknowledgeBalanceBreak(_ gap: BalanceBreak) throws {
        var setup = self.setup
        setup.acknowledgeBreak(gap.id)
        try rebuild(setup)
    }

    /// The balances of KRW accounts, each at the time of the act its notification reports and with the change it reports.
    private func balanceObservations() -> [BalanceObservation] {
        let currencies = Dictionary(uniqueKeysWithValues: setup.configuration.accounts.map { ($0.id, $0.openingBalance.currency) })
        return resolvedBalances().compactMap { notification, accountID, balance in
            guard currencies[accountID] == "KRW" else { return nil }
            let draft = (try? repository.storedCandidate(ofNotification: notification.id, eventIndex: 0))?.candidate.sourceDraft
            let delta: Int64 = switch draft?.direction {
            case .outflow: -(draft?.amount.minorUnits ?? 0)
            case .inflow: draft?.amount.minorUnits ?? 0
            default: 0
            }
            return BalanceObservation(accountID: accountID, atUnixMilliseconds: draft?.occurredAt.unixMilliseconds ?? Self.time(of: notification),
                                      minorUnits: balance, deltaMinorUnits: delta, notificationID: notification.id)
        }
    }

    /// Money moves in the gap that the chain itself does not hold: entries on this account, and acts still waiting for the user
    /// (their account is not known yet). The evidence of a link of the chain is the same money as that link, not another.
    private func isExplained(_ gap: BalanceBreak, snapshot: CandidateProcessingSnapshot?, chain: [BalanceObservation]) -> Bool {
        guard let snapshot else { return false }
        let links = Set(chain.map(\.notificationID))
        let linked = snapshot.candidates.values.filter { $0.candidate.sourceDraft.map { links.contains($0.rawNotificationID) } == true }
        let sameMoney = Set(linked.compactMap { $0.corroborates?.candidateID })
        let others = snapshot.candidates.values.compactMap { stored -> Int64? in
            guard let draft = stored.candidate.sourceDraft, !links.contains(draft.rawNotificationID), stored.corroborates == nil,
                  !sameMoney.contains(stored.candidate.id),
                  draft.occurredAt.unixMilliseconds > gap.before.atUnixMilliseconds, draft.occurredAt.unixMilliseconds <= gap.after.atUnixMilliseconds
            else { return nil }
            if let entryID = stored.promotedEntryID {
                let moved = snapshot.ledger.entries.first { $0.id == entryID }?.postings.filter { $0.accountID == gap.accountID }.reduce(Int64(0)) { $0 + $1.delta.minorUnits }
                return moved.flatMap { $0 == 0 ? nil : $0 }
            }
            switch draft.direction {
            case .outflow: return -draft.amount.minorUnits
            case .inflow: return draft.amount.minorUnits
            case .neutral: return nil
            }
        }
        return BalanceChain.isExplained(gap, by: others)
    }

    /// Books each confirmed gap whose break is still there, and starts over when a booked one is no longer a break (a late
    /// notification now covers it): replaying is how the entry goes away.
    private mutating func settleConfirmedGaps() throws {
        guard !setup.confirmedGaps.isEmpty else { return }
        let snapshot = try? repository.processingSnapshot()
        let observations = balanceObservations()
        let current = BalanceChain.breaks(observations: observations).filter { !isExplained($0, snapshot: snapshot, chain: observations) }
        let booked = Set((snapshot?.ledger.entries ?? []).map(\.id))
        var stale = false
        for gap in setup.confirmedGaps {
            let holds = current.contains { $0.id == gap.key && $0.differenceMinorUnits == gap.signedMinorUnits }
            let entryID = LedgerEntryID(rawValue: "entry:" + gap.key)
            if holds && !booked.contains(entryID) {
                try book(gap, as: entryID)
            } else if !holds && booked.contains(entryID) {
                stale = true
            }
        }
        if stale { try rebuild(setup) }
    }

    private mutating func book(_ gap: ConfirmedGap, as id: LedgerEntryID) throws {
        let amount = try Money(minorUnits: gap.signedMinorUnits, currency: "KRW")
        let spent = try amount.negated()
        let entry = gap.signedMinorUnits < 0
            ? LedgerEntry(id: id, kind: .expense, occurredAtUnixMilliseconds: gap.atUnixMilliseconds,
                          postings: [Posting(accountID: gap.accountID, delta: amount)],
                          budgetImpact: BudgetImpact(kind: .expense, amount: spent, attributedMonth: try month(of: gap.atUnixMilliseconds)),
                          evidenceIDs: [gap.key])
            : LedgerEntry(id: id, kind: .income, occurredAtUnixMilliseconds: gap.atUnixMilliseconds,
                          postings: [Posting(accountID: gap.accountID, delta: amount)], evidenceIDs: [gap.key])
        let candidate = try TransactionCandidate(id: TransactionCandidateID(rawValue: "candidate:" + gap.key), evidenceIDs: [gap.key],
                                                 status: .ready, proposedEntry: entry, policyVersion: intake.policyVersion)
        let revisions = try repository.revisions()
        _ = try repository.process(candidate, expectedCandidateRevision: revisions.candidate, expectedLedgerRevision: revisions.ledger)
    }

    private func month(of unixMilliseconds: Int64) throws -> BudgetMonth {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: intake.timeZoneIdentifier) ?? .current
        let parts = calendar.dateComponents([.year, .month], from: Date(timeIntervalSince1970: Double(unixMilliseconds) / 1_000))
        return try BudgetMonth(year: parts.year ?? 0, month: parts.month ?? 0)
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
        guard let notification = notification(withID: notificationID) else { return nil }
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
        guard let notification = notification(withID: question.notificationID) else { return }
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
        if let notification = notification(withID: notificationID), isCoveredByImport(notification) { return .coveredByImport }
        guard let outcome = outcomes[notificationID] else { return .failed }
        switch outcome {
        case let .notTransaction(reason): return .notTransaction(reason)
        case let .unreadable(failure): return .unreadable(failure)
        case let .processed(candidateID):
            guard let stored = repository.storedCandidate(candidateID) else { return .failed }
            if let entry = stored.promotedEntryID { return .recorded(entry) }
            if let act = stored.corroborates?.candidateID {
                if let entry = repository.storedCandidate(act)?.promotedEntryID { return .recorded(entry) }
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
        positions = [:]
        try seedHistory()
        _ = append(all)
        try settleConfirmedGaps()
    }

    /// The imported rows go in first, in date order, one by one through the same atomic promotion a notification uses. They are
    /// never run through the correlator: Actual's rows are what the user already settled.
    private mutating func seedHistory() throws {
        guard let importPlan else { return }
        for candidate in importPlan.candidates {
            let revisions = try repository.revisions()
            _ = try? repository.process(candidate, expectedCandidateRevision: revisions.candidate, expectedLedgerRevision: revisions.ledger)
        }
    }

    private func notification(withID id: String) -> RawNotification? {
        positions[id].map { notifications[$0] }
    }

    private func isCoveredByImport(_ notification: RawNotification) -> Bool {
        guard let cutover = importPlan?.cutoverUnixMilliseconds else { return false }
        return Self.time(of: notification) < cutover
    }

    private static func time(of notification: RawNotification) -> Int64 {
        notification.notificationAtUnixMilliseconds ?? notification.capturedAtUnixMilliseconds
    }

    private mutating func replay(_ all: [RawNotification]) throws {
        try receive(all)
    }

    private mutating func ingest(_ notification: RawNotification) {
        if let outcome = try? intake.ingest(notification, setup: &setup, repository: &repository) {
            outcomes[notification.id] = switch outcome {
            case let .notTransaction(reason): .notTransaction(reason)
            case let .unreadable(failure): .unreadable(failure)
            case let .processed(candidateID, _): .processed(candidateID)
            }
        }
    }
}


public enum IntakeLedgerSnapshotError: Error, Equatable, Sendable { case notApplicable }

/// A built ledger saved to disk (`IntakeLedger.snapshot()`), so a launch processes only the notifications that arrived
/// since. It is derived data: anything that does not match the current inputs is thrown away and replayed.
public struct IntakeLedgerSnapshot: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    /// What became of one notification (the part of `NotificationIntakeOutcome` the inbox reads).
    public enum Outcome: Codable, Equatable, Sendable {
        case notTransaction(NotTransactionReason)
        case unreadable(NotificationParseFailure)
        case processed(TransactionCandidateID)
    }

    public let format: Int
    public let rules: String
    public let history: String
    /// The setup as the replay left it (learned rules and candidate accounts included).
    public let setup: IntakeSetup
    /// The notifications already processed, in arrival order.
    public let notificationIDs: [String]
    public let outcomes: [String: Outcome]
    public let candidateRevision: UInt64
    public let candidates: [StoredTransactionCandidate]
    public let entries: [LedgerEntry]

    init(
        rules: String, history: String, setup: IntakeSetup, notificationIDs: [String], outcomes: [String: Outcome],
        candidateRevision: UInt64, candidates: [StoredTransactionCandidate], entries: [LedgerEntry]
    ) {
        self.format = Self.currentFormat
        self.rules = rules
        self.history = history
        self.setup = setup
        self.notificationIDs = notificationIDs
        self.outcomes = outcomes
        self.candidateRevision = candidateRevision
        self.candidates = candidates
        self.entries = entries
    }
}
