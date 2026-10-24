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
                // Notifications kept only as evidence of another act are not acts of their own.
                against: candidates.values.filter { $0.corroborates == nil }.map(\.candidate)
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

    public mutating func process(
        _ candidate: TransactionCandidate,
        observation: CorrelationObservation,
        correlator: NotificationCorrelator,
        expectedCandidateRevision: UInt64,
        expectedLedgerRevision: UInt64
    ) throws -> CandidateProcessingResult {
        guard observation.candidateID == candidate.id else { throw CandidateProcessingError.invalidCorrelationTarget(observation.candidateID) }
        if let stored = candidates[candidate.id], let earlier = stored.observation {
            guard earlier == observation else { throw CandidateProcessingError.conflictingCandidate(candidate.id) }
            // A repeat: the earlier decision stands (judging again against later notifications could differ).
            if let match = stored.corroborates, stored.promotedEntryID == nil { return .corroborated(existingCandidateID: match.candidateID, candidateRevision: candidateRevision) }
            if stored.promotedEntryID != nil { return .alreadyPromoted(candidateRevision: candidateRevision, ledgerRevision: try ledger.snapshot().revision) }
            return .alreadyStored(candidateRevision: candidateRevision)
        }
        let records = candidates.values.compactMap(\.correlationRecord).sorted { $0.candidateID.rawValue < $1.candidateID.rawValue }
        var state = self
        let result = try state.apply(correlator.decide(observation, against: records), to: candidate,
                                     expectedCandidateRevision: expectedCandidateRevision, expectedLedgerRevision: expectedLedgerRevision)
        if let stored = state.candidates[candidate.id] {
            state.candidates[candidate.id] = StoredTransactionCandidate(
                candidate: stored.candidate, promotedEntryID: stored.promotedEntryID, promotionRejection: stored.promotionRejection,
                corroborates: stored.corroborates, reversalEntryID: stored.reversalEntryID, suggestions: stored.suggestions, observation: observation
            )
        }
        self = state
        return result
    }

    private mutating func apply(
        _ correlation: CorrelationDecision,
        to candidate: TransactionCandidate,
        expectedCandidateRevision: UInt64,
        expectedLedgerRevision: UInt64
    ) throws -> CandidateProcessingResult {
        switch correlation {
        case let .newAct(act):
            // Work on a copy: the candidate, the candidates it closes and a reversal commit together or not at all.
            var state = self
            let result = try state.process(candidate, expectedCandidateRevision: expectedCandidateRevision, expectedLedgerRevision: expectedLedgerRevision)
            guard case .promoted = result else {
                self = state
                return result
            }
            for closed in act.closes {
                guard let stored = state.candidates[closed.candidateID], stored.promotedEntryID == nil else {
                    throw CandidateProcessingError.invalidCorrelationTarget(closed.candidateID)
                }
                state.candidates[closed.candidateID] = stored.linked(to: CorrelationMatch(candidateID: candidate.id, rule: closed.rule))
            }
            var ledgerRevision = try state.ledger.snapshot().revision
            if let replaced = act.replacesIncome {
                guard let stored = state.candidates[replaced.candidateID], let entryID = stored.promotedEntryID, stored.reversalEntryID == nil,
                      let original = try state.ledger.snapshot().entries.first(where: { $0.id == entryID }), original.kind == .income else {
                    throw CandidateProcessingError.invalidCorrelationTarget(replaced.candidateID)
                }
                let reversal = LedgerEntry(
                    id: LedgerEntryID(rawValue: "reversal:" + entryID.rawValue),
                    kind: .reversal,
                    occurredAtUnixMilliseconds: candidate.proposedEntry?.occurredAtUnixMilliseconds ?? original.occurredAtUnixMilliseconds,
                    postings: try original.postings.map { Posting(accountID: $0.accountID, delta: try $0.delta.negated()) },
                    reverses: entryID
                )
                do {
                    switch try state.ledger.commit(reversal, expectedRevision: ledgerRevision) {
                    case let .committed(revision), let .alreadyCommitted(revision): ledgerRevision = revision
                    }
                } catch let error as LedgerStorageError {
                    throw CandidateProcessingError.ledger(error)
                }
                state.candidates[replaced.candidateID] = stored.linked(
                    to: CorrelationMatch(candidateID: candidate.id, rule: replaced.rule), reversal: reversal.id
                )
            }
            self = state
            return .promoted(candidateRevision: candidateRevision, ledgerRevision: ledgerRevision)

        case let .corroborates(match):
            if candidates[candidate.id] != nil { throw CandidateProcessingError.conflictingCandidate(candidate.id) }
            guard candidates[match.candidateID] != nil, match.candidateID != candidate.id else {
                throw CandidateProcessingError.invalidCorrelationTarget(match.candidateID)
            }
            try store(StoredTransactionCandidate(candidate: candidate, corroborates: match), expectedCandidateRevision: expectedCandidateRevision)
            return .corroborated(existingCandidateID: match.candidateID, candidateRevision: candidateRevision)

        case let .suggests(matches):
            let suggested: CandidateIssue = matches.contains { $0.rule == .refundSuggestion } ? .possibleReturnOfEarlierPurchase : .possibleSameMoneyRecorded
            let review = try TransactionCandidate(
                id: candidate.id,
                evidenceIDs: candidate.evidenceIDs,
                status: .needsReview,
                issues: candidate.status == .needsReview
                    ? Array(Set(candidate.issues + [suggested])).sorted { $0.rawValue < $1.rawValue }
                    : [suggested],
                proposedEntry: candidate.proposedEntry,
                policyVersion: candidate.policyVersion,
                sourceDraft: candidate.sourceDraft
            )
            if candidates[candidate.id] != nil { throw CandidateProcessingError.conflictingCandidate(candidate.id) }
            try store(StoredTransactionCandidate(candidate: review, suggestions: matches), expectedCandidateRevision: expectedCandidateRevision)
            return .stored(candidateRevision: candidateRevision)
        }
    }

    /// Stores a candidate that does not touch the ledger.
    private mutating func store(_ stored: StoredTransactionCandidate, expectedCandidateRevision: UInt64) throws {
        guard expectedCandidateRevision == candidateRevision else {
            throw CandidateProcessingError.staleCandidateRevision(expected: expectedCandidateRevision, actual: candidateRevision)
        }
        guard candidateRevision < UInt64.max else { throw CandidateProcessingError.revisionOverflow }
        if let owner = evidenceOwner(of: stored.candidate) { throw duplicateEvidenceError(stored.candidate, owner: owner) }
        candidates[stored.candidate.id] = stored
        candidateRevision += 1
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

private extension StoredTransactionCandidate {
    func linked(to match: CorrelationMatch, reversal: LedgerEntryID? = nil) -> StoredTransactionCandidate {
        StoredTransactionCandidate(
            candidate: candidate, promotedEntryID: promotedEntryID, promotionRejection: promotionRejection,
            corroborates: match, reversalEntryID: reversal ?? reversalEntryID, suggestions: suggestions, observation: observation
        )
    }
}
