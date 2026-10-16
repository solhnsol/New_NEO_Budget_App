import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryStorage

/// The app's view of the ledger. Today it holds an in-memory processing repository that nothing feeds in a normal
/// launch, because durable storage and notification ingestion are not part of the app yet. The timeline reads it
/// only through `LedgerTimelineProjection`, so whichever repository later backs it needs no UI change.
actor AppLedger {
    private var repository: InMemoryCandidateProcessingRepository
    private let configuration: LedgerConfiguration

    /// `promoting` seeds sample data through the existing atomic promotion. A normal launch passes nothing.
    init(configuration: LedgerConfiguration = LedgerConfiguration(), promoting candidates: [TransactionCandidate] = []) throws {
        var repository = try InMemoryCandidateProcessingRepository(configuration: configuration)
        for candidate in candidates {
            let snapshot = try repository.processingSnapshot()
            _ = try repository.process(
                candidate, expectedCandidateRevision: snapshot.candidateRevision, expectedLedgerRevision: snapshot.ledger.revision
            )
        }
        self.repository = repository
        self.configuration = configuration
    }

    /// The ledger as the command service reads it: consumption only, with per-entry time precision and titles.
    func transactionSource() throws -> LedgerTransactionSource {
        LedgerTransactionSource(processing: try repository.processingSnapshot())
    }

    /// Every account's and card's movements as the bank and the card company see them (the ledger tab's statement view).
    func statements() throws -> [LedgerStatements.Statement] {
        LedgerStatements.statements(try repository.processingSnapshot(), configuration: configuration)
    }

    /// Spending and refunds for the timeline. Money movement (transfers, card bill payments, income) is excluded
    /// by the projection, not here.
    func transactions() throws -> [TransactionMarker] {
        LedgerTimelineProjection.transactions(in: try repository.processingSnapshot())
    }
}
