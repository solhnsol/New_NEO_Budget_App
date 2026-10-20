import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryStorage

/// The app's view of the ledger. A normal launch replays the notifications the Shortcut delivered (`IntakeLedger` over
/// `NotificationStore`); the demo and `-ledger-sample` seed a fixed synthetic repository instead. The timeline reads it
/// only through `transactionSource()`, which follows every change, so the command service is made once.
actor AppLedger {
    private enum Backing {
        case fixed(InMemoryCandidateProcessingRepository, LedgerConfiguration)
        case live(IntakeLedger, NotificationStore)
    }

    private var backing: Backing
    private let source: UpdatableTransactionSource
    private let decoder: ShortcutNotificationDecoder

    /// `promoting` seeds sample data through the existing atomic promotion.
    init(configuration: LedgerConfiguration = LedgerConfiguration(), promoting candidates: [TransactionCandidate] = []) throws {
        var repository = try InMemoryCandidateProcessingRepository(configuration: configuration)
        for candidate in candidates {
            let snapshot = try repository.processingSnapshot()
            _ = try repository.process(
                candidate, expectedCandidateRevision: snapshot.candidateRevision, expectedLedgerRevision: snapshot.ledger.revision
            )
        }
        backing = .fixed(repository, configuration)
        source = UpdatableTransactionSource(LedgerTransactionSource(processing: try repository.processingSnapshot()))
        decoder = ShortcutNotificationDecoder(timeZone: .current)
    }

    /// The real ledger: everything the Shortcut delivered so far, replayed over the saved account setup.
    init(store: NotificationStore, zone: DisplayTimeZone) throws {
        let setup = try store.setup()
        // A history that cannot be read is left out rather than keeping the whole ledger from opening.
        let history = try? store.history()
        let ledger = try IntakeLedger(
            notifications: try store.notifications(), setup: setup,
            intake: NotificationIntake(timeZoneIdentifier: zone.identifier), history: history
        )
        // Importing registers the history's accounts in the setup; keep them.
        if ledger.setup != setup { try store.save(setup: ledger.setup) }
        backing = .live(ledger, store)
        source = UpdatableTransactionSource(LedgerTransactionSource(processing: try ledger.repository.processingSnapshot()))
        decoder = ShortcutNotificationDecoder(timeZone: TimeZone(identifier: zone.identifier) ?? .current)
    }

    var isLive: Bool { if case .live = backing { true } else { false } }

    // MARK: Reading

    /// The ledger as the command service reads it: consumption only. The same object follows later changes.
    func transactionSource() throws -> any TransactionSource { source }

    /// Every account's and card's movements as the bank and the card company see them (the ledger tab's statement view).
    func statements() throws -> [LedgerStatements.Statement] {
        LedgerStatements.statements(try snapshot(), configuration: configuration)
    }

    /// Spending and refunds for the timeline. Money movement (transfers, card bill payments, income) is excluded
    /// by the projection, not here.
    func transactions() throws -> [TransactionMarker] {
        LedgerTimelineProjection.transactions(in: try snapshot())
    }

    /// Each refund or cancellation and the purchase it gives money back for, as the ledger links them.
    func refundLinks() throws -> [LedgerEntryID: LedgerEntryID] {
        Self.refundLinks(in: try snapshot().ledger)
    }

    /// Money that came in and nothing explains yet, newest first (`DepositMerge`).
    func unclassifiedDeposits(life: LifeState) throws -> [LedgerDeposit] {
        DepositMerge.unclassified(in: try snapshot(), life: life)
    }

    static func refundLinks(in ledger: LedgerSnapshot) -> [LedgerEntryID: LedgerEntryID] {
        Dictionary(ledger.entries.compactMap { entry in entry.adjustment.map { (entry.id, $0.originalEntryID) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Received notifications, newest first, with where each ended up. Empty outside the real ledger.
    func inbox() -> [InboxItem] {
        guard case let .live(ledger, _) = backing else { return [] }
        return ledger.notifications.reversed().map { notification in
            InboxItem(notification: notification, status: ledger.status(of: notification.id))
        }
    }

    /// Accounts and cards the notifications mention that the user has not said anything about yet.
    func accountQuestions() -> [AccountQuestion] {
        guard case let .live(ledger, _) = backing else { return [] }
        let byID = Dictionary(ledger.notifications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ledger.setup.registry.openCandidates.map { candidate in
            AccountQuestion(candidate: candidate, example: candidate.evidenceNotificationIDs.last.flatMap { byID[$0] })
        }
    }

    /// The accounts and cards already registered, for "이미 있는 계좌예요".
    func registeredAccounts() -> [AccountProfile] {
        guard case let .live(ledger, _) = backing else { return [] }
        return ledger.setup.registry.profiles.filter(\.isActive)
    }

    // MARK: Imported history

    /// Imported rows that still wait for the user (`IntakeLedger.pendingImports`), newest first. Empty without a history.
    func pendingImports() -> [PendingImport] {
        guard case let .live(ledger, _) = backing else { return [] }
        return ledger.pendingImports
    }

    /// The meaning the imported settlements add around the ledger (receivables and the deposits that paid them), to start the
    /// calendar side from. `nil` without a history or when it holds no settlement.
    func importedLife(now: Int64) -> LifeState? {
        guard case let .live(ledger, _) = backing, let plan = ledger.importPlan, !plan.settlements.isEmpty else { return nil }
        return try? ImportedSettlementSeed.life(from: plan, at: now)
    }

    /// Replaces the imported history with `data` (the file's bytes) and replays the ledger. Returns what was imported.
    func importHistory(_ data: Data) throws -> ImportSummary {
        guard case .live(let current, let store) = backing else { throw AppLedgerError.notLive }
        let history = try store.save(historyData: data)
        let ledger = try IntakeLedger(notifications: current.notifications, setup: current.setup, intake: current.intake, history: history)
        try store.save(setup: ledger.setup)
        backing = .live(ledger, store)
        try refreshSource()
        let reconciliation = ledger.importReconciliation()
        return ImportSummary(
            rows: history.transactions.count, accounts: history.accounts.count, pending: ledger.pendingImports.count,
            mismatchedAccounts: reconciliation.filter { !$0.matches }.map(\.accountName)
        )
    }

    // MARK: Receiving

    /// What the Shortcut sent, as text. Returns the notifications that were new, with where each ended up.
    func receive(_ text: String) throws -> [InboxItem] {
        guard case .live(var ledger, let store) = backing else { throw AppLedgerError.notLive }
        let decoded = try decoder.decode(text, receivedAtUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000))
        let fresh = try ledger.receive(decoded)
        if !fresh.isEmpty {
            try store.save(notifications: ledger.notifications)
            try store.save(setup: ledger.setup)
        }
        backing = .live(ledger, store)
        try refreshSource()
        return fresh.map { InboxItem(notification: $0, status: ledger.status(of: $0.id)) }
    }

    // MARK: Account answers

    func confirmAsNew(_ id: AccountCandidateID, displayName: String, kind: NewTargetKind) throws {
        try change { try $0.confirmAsNew(id, displayName: displayName, kind: kind, makeID: { "account-\(UUID().uuidString)" }) }
    }

    func link(_ id: AccountCandidateID, to binding: ResolvedLedgerBinding) throws {
        try change { try $0.link(id, to: binding) }
    }

    func dismiss(_ id: AccountCandidateID) throws {
        try change { try $0.dismiss(id) }
    }

    /// "Messages like this one are about which account?" for a notification that never names its account.
    func ruleQuestion(for notificationID: String) -> RuleQuestion? {
        guard case let .live(ledger, _) = backing else { return nil }
        return ledger.ruleQuestion(for: notificationID)
    }

    func answer(_ question: RuleQuestion, binding: ResolvedLedgerBinding?, newAccount: (name: String, kind: NewTargetKind)?) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try change { try $0.answer(question, binding: binding, newAccount: newAccount, at: now, makeID: { "account-\(UUID().uuidString)" }) }
    }

    private func change(_ apply: (inout IntakeLedger) throws -> Void) throws {
        guard case .live(var ledger, let store) = backing else { throw AppLedgerError.notLive }
        try apply(&ledger)
        try store.save(setup: ledger.setup)
        backing = .live(ledger, store)
        try refreshSource()
    }

    private func refreshSource() throws {
        source.replace(with: LedgerTransactionSource(processing: try snapshot()))
    }

    private func snapshot() throws -> CandidateProcessingSnapshot {
        switch backing {
        case let .fixed(repository, _): try repository.processingSnapshot()
        case let .live(ledger, _): try ledger.repository.processingSnapshot()
        }
    }

    private var configuration: LedgerConfiguration {
        switch backing {
        case let .fixed(_, configuration): configuration
        case let .live(ledger, _): ledger.setup.configuration
        }
    }
}

enum AppLedgerError: Error {
    /// Notifications go only to the real ledger, never to the demo or the sample.
    case notLive
}

/// What an import brought in, for the confirmation the user reads.
struct ImportSummary: Sendable {
    let rows: Int
    let accounts: Int
    /// Rows that wait for the user (`PendingImport`).
    let pending: Int
    /// Accounts whose balance after the import differs from the balance Actual had, beyond what waits in review.
    let mismatchedAccounts: [String]
}

struct InboxItem: Identifiable, Sendable {
    let notification: RawNotification
    let status: IntakeStatus
    var id: String { notification.id }
}

struct AccountQuestion: Identifiable, Sendable {
    let candidate: AccountCandidate
    /// The latest notification that mentioned it, to show the user what it looked like.
    let example: RawNotification?
    var id: AccountCandidateID { candidate.id }
}
