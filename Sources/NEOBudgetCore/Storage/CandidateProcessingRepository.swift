public struct StoredTransactionCandidate: Codable, Equatable, Sendable {
    public let candidate: TransactionCandidate
    public let promotedEntryID: LedgerEntryID?

    public init(candidate: TransactionCandidate, promotedEntryID: LedgerEntryID? = nil) {
        self.candidate = candidate
        self.promotedEntryID = promotedEntryID
    }
}

public struct CandidateProcessingSnapshot: Codable, Equatable, Sendable {
    public let candidateRevision: UInt64
    public let candidates: [TransactionCandidateID: StoredTransactionCandidate]
    public let ledger: LedgerSnapshot

    public init(
        candidateRevision: UInt64,
        candidates: [TransactionCandidateID: StoredTransactionCandidate],
        ledger: LedgerSnapshot
    ) {
        self.candidateRevision = candidateRevision
        self.candidates = candidates
        self.ledger = ledger
    }
}

public enum CandidateProcessingResult: Equatable, Sendable {
    case stored(candidateRevision: UInt64)
    case promoted(candidateRevision: UInt64, ledgerRevision: UInt64)
    case alreadyStored(candidateRevision: UInt64)
    case alreadyPromoted(candidateRevision: UInt64, ledgerRevision: UInt64)
}

public enum CandidateProcessingError: Error, Equatable, Sendable {
    case staleCandidateRevision(expected: UInt64, actual: UInt64)
    case staleLedgerRevision(expected: UInt64, actual: UInt64)
    case conflictingCandidate(TransactionCandidateID)
    case evidenceAlreadyClaimed(id: String, candidateID: TransactionCandidateID)
    case revisionOverflow
    case ledger(LedgerStorageError)
}

/// Atomic boundary between candidate persistence and financial state.
///
/// For a `ready` candidate, saving the candidate, committing its proposed ledger entry,
/// and recording the promotion must succeed or fail as one transaction. Non-ready candidates
/// are persisted for later handling and never change the ledger. Repeating identical input is
/// idempotent even when the caller's revisions are now stale.
public protocol CandidateProcessingRepository {
    func processingSnapshot() throws -> CandidateProcessingSnapshot

    mutating func process(
        _ candidate: TransactionCandidate,
        expectedCandidateRevision: UInt64,
        expectedLedgerRevision: UInt64
    ) throws -> CandidateProcessingResult
}
