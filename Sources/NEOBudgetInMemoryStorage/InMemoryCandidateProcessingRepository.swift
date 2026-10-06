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
        if let stored = candidates[candidate.id] {
            if stored.promotedEntryID != nil,
               (stored.candidate == candidate || stored.candidate.proposedEntry == candidate.proposedEntry) {
                return .alreadyPromoted(
                    candidateRevision: candidateRevision,
                    ledgerRevision: try ledger.snapshot().revision
                )
            }
            if let rejection = stored.promotionRejection,
               stored.candidate.proposedEntry == candidate.proposedEntry {
                return .rejectedByLedger(
                    candidateRevision: candidateRevision,
                    ledgerRevision: try ledger.snapshot().revision,
                    reason: rejection
                )
            }
            if stored.candidate == candidate {
                return .alreadyStored(candidateRevision: candidateRevision)
            }
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

        var candidateState = candidates

        if candidate.status == .ready {
            switch try DefaultCandidateDeduplicationValidator().validate(
                candidate,
                against: candidates.values.map(\.candidate)
            ) {
            case .accepted:
                break
            case let .duplicate(existingCandidateID):
                return .duplicate(
                    existingCandidateID: existingCandidateID,
                    candidateRevision: candidateRevision,
                    ledgerRevision: try ledger.snapshot().revision
                )
            case let .needsReview(reviewCandidate):
                candidateState[reviewCandidate.id] = StoredTransactionCandidate(candidate: reviewCandidate)
                candidates = candidateState
                candidateRevision += 1
                return .stored(candidateRevision: candidateRevision)
            }
        }

        if let owner = evidenceOwner(of: candidate) {
            if owner.value.promotedEntryID != nil,
               owner.value.candidate.proposedEntry == candidate.proposedEntry {
                return .duplicate(
                    existingCandidateID: owner.key,
                    candidateRevision: candidateRevision,
                    ledgerRevision: try ledger.snapshot().revision
                )
            }
            throw duplicateEvidenceError(candidate, owner: owner)
        }

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
            let rejection = rejectionReason(error)
            let reviewCandidate = try TransactionCandidate(
                id: candidate.id,
                evidenceIDs: candidate.evidenceIDs,
                status: .needsReview,
                issues: [.promotionRejected],
                proposedEntry: candidate.proposedEntry,
                policyVersion: candidate.policyVersion,
                sourceDraft: candidate.sourceDraft
            )
            if let existing = candidateState[candidate.id], existing.promotedEntryID == nil {
                candidateState[candidate.id] = StoredTransactionCandidate(
                    candidate: existing.candidate,
                    promotionRejection: rejection
                )
            } else {
                candidateState[candidate.id] = StoredTransactionCandidate(
                    candidate: reviewCandidate,
                    promotionRejection: rejection
                )
            }
            candidates = candidateState
            candidateRevision += 1
            return .rejectedByLedger(
                candidateRevision: candidateRevision,
                ledgerRevision: currentLedgerRevision,
                reason: rejection
            )
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

    private func evidenceOwner(
        of candidate: TransactionCandidate
    ) -> Dictionary<TransactionCandidateID, StoredTransactionCandidate>.Element? {
        for element in candidates where element.key != candidate.id {
            let (otherID, stored) = element
            let claimed = Set(stored.candidate.evidenceIDs)
            if candidate.evidenceIDs.contains(where: { claimed.contains($0) }) { return (otherID, stored) }
        }
        return nil
    }

    private func duplicateEvidenceError(
        _ candidate: TransactionCandidate,
        owner: Dictionary<TransactionCandidateID, StoredTransactionCandidate>.Element
    ) -> CandidateProcessingError {
        let claimed = Set(owner.value.candidate.evidenceIDs)
        let duplicate = candidate.evidenceIDs.first(where: { claimed.contains($0) })!
        return .evidenceAlreadyClaimed(id: duplicate, candidateID: owner.key)
    }

    private func rejectionReason(_ error: LedgerStorageError) -> CandidatePromotionRejection {
        switch error {
        case .conflictingEntry: return .conflictingEntry
        case .staleRevision: return .invalidEntry
        case .revisionOverflow: return .revisionOverflow
        case .invalidConfiguration: return .invalidConfiguration
        case .invalidEntry: return .invalidEntry
        }
    }
}
