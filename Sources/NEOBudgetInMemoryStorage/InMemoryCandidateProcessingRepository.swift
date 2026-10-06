import NEOBudgetCore

/// Reference implementation of the candidate-to-ledger transaction contract.
/// State is copied and validated first; assignments occur only after every operation succeeds.
public struct InMemoryCandidateProcessingRepository: CandidateProcessingRepository {
    private var candidateRevision: UInt64 = 0
    private var candidates: [TransactionCandidateID: StoredTransactionCandidate] = [:]
    private var ledger: InMemoryLedgerRepository

    public init(configuration: LedgerConfiguration) throws {
        ledger = try InMemoryLedgerRepository(configuration: configuration)
    }

    public func processingSnapshot() throws -> CandidateProcessingSnapshot {
        CandidateProcessingSnapshot(
            candidateRevision: candidateRevision,
            candidates: candidates,
            ledger: try ledger.snapshot()
        )
    }

    public mutating func process(
        _ candidate: TransactionCandidate,
        expectedCandidateRevision: UInt64,
        expectedLedgerRevision: UInt64
    ) throws -> CandidateProcessingResult {
        if let stored = candidates[candidate.id], stored.candidate == candidate {
            if stored.promotedEntryID != nil {
                return .alreadyPromoted(
                    candidateRevision: candidateRevision,
                    ledgerRevision: try ledger.snapshot().revision
                )
            }
            return .alreadyStored(candidateRevision: candidateRevision)
        }

        if let stored = candidates[candidate.id], stored.promotedEntryID != nil {
            throw CandidateProcessingError.conflictingCandidate(candidate.id)
        }
        guard expectedCandidateRevision == candidateRevision else {
            throw CandidateProcessingError.staleCandidateRevision(
                expected: expectedCandidateRevision,
                actual: candidateRevision
            )
        }
        guard candidateRevision < UInt64.max else {
            throw CandidateProcessingError.revisionOverflow
        }

        try validateEvidenceOwnership(of: candidate)
        var candidateState = candidates

        guard candidate.status == .ready else {
            candidateState[candidate.id] = StoredTransactionCandidate(candidate: candidate)
            candidates = candidateState
            candidateRevision += 1
            return .stored(candidateRevision: candidateRevision)
        }

        let currentLedgerRevision = try ledger.snapshot().revision
        guard expectedLedgerRevision == currentLedgerRevision else {
            throw CandidateProcessingError.staleLedgerRevision(
                expected: expectedLedgerRevision,
                actual: currentLedgerRevision
            )
        }

        // The candidate type guarantees this for ready state. Keep the guard defensive at
        // the storage boundary in case a future schema migration introduces invalid data.
        guard let entry = candidate.proposedEntry else {
            throw CandidateProcessingError.conflictingCandidate(candidate.id)
        }

        var ledgerState = ledger
        let ledgerResult: LedgerCommitResult
        do {
            ledgerResult = try ledgerState.commit(entry, expectedRevision: expectedLedgerRevision)
        } catch let error as LedgerStorageError {
            throw CandidateProcessingError.ledger(error)
        }

        let promotedLedgerRevision: UInt64
        switch ledgerResult {
        case let .committed(revision), let .alreadyCommitted(revision):
            promotedLedgerRevision = revision
        }
        candidateState[candidate.id] = StoredTransactionCandidate(
            candidate: candidate,
            promotedEntryID: entry.id
        )

        // This is the in-memory commit point. Nothing above mutates live state.
        ledger = ledgerState
        candidates = candidateState
        candidateRevision += 1
        return .promoted(
            candidateRevision: candidateRevision,
            ledgerRevision: promotedLedgerRevision
        )
    }

    private func validateEvidenceOwnership(of candidate: TransactionCandidate) throws {
        for (otherID, stored) in candidates where otherID != candidate.id {
            let claimed = Set(stored.candidate.evidenceIDs)
            if let duplicate = candidate.evidenceIDs.first(where: { claimed.contains($0) }) {
                throw CandidateProcessingError.evidenceAlreadyClaimed(
                    id: duplicate,
                    candidateID: otherID
                )
            }
        }
    }
}
