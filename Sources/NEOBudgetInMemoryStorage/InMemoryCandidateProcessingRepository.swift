import NEOBudgetCore

/// Reference implementation of the candidate-to-ledger transaction contract.
/// Everything a call changes is validated before the first change, or undone if a later step of the same call fails, so
/// a call either applies completely or leaves the repository as it was. The cost of a call does not grow with the
/// number of stored candidates: what the dedup and the correlator compare against comes from indexes by time, evidence,
/// corroborated candidate and name.
public struct InMemoryCandidateProcessingRepository: CandidateProcessingRepository {
    private var candidateRevision: UInt64 = 0
    private var candidates: [TransactionCandidateID: StoredTransactionCandidate] = [:]
    private var ledger: InMemoryLedgerRepository
    private var index = CandidateIndex()
    /// Set while a group of changes that must apply together is under way.
    private var journal: Journal?
    private let deduplication = DefaultCandidateDeduplicationValidator()

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

    public func revisions() throws -> (candidate: UInt64, ledger: UInt64) {
        (candidateRevision, ledger.currentRevision)
    }

    /// One stored candidate by its ID, without taking a snapshot.
    public func storedCandidate(_ id: TransactionCandidateID) -> StoredTransactionCandidate? {
        candidates[id]
    }

    public func storedCandidate(ofNotification rawNotificationID: String, eventIndex: Int) throws -> StoredTransactionCandidate? {
        let ids = index.notificationEvents[CandidateIndex.EventKey(rawNotificationID: rawNotificationID, eventIndex: eventIndex)] ?? []
        return ids.min { $0.rawValue < $1.rawValue }.flatMap { candidates[$0] }
    }

    public func correlationRecords(near unixMilliseconds: Int64, within radius: Int64) throws -> [CorrelationRecord] {
        let window = Set(index.ids(in: \.byRecordTime, near: unixMilliseconds, within: radius))
        var ids = window
        for id in window { ids.formUnion(index.corroborators[id] ?? []) }
        return ids.compactMap { candidates[$0]?.correlationRecord }
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
                    ledgerRevision: ledger.currentRevision
                )
            }
            if let rejection = stored.promotionRejection,
               stored.candidate.proposedEntry == candidate.proposedEntry {
                return .rejectedByLedger(
                    candidateRevision: candidateRevision,
                    ledgerRevision: ledger.currentRevision,
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

        // Nothing is changed before the commit point below: the checks above and these only read.
        if candidate.status == .ready {
            switch try deduplication.validate(candidate, against: dedupNeighbours(of: candidate)) {
            case .accepted:
                break
            case let .duplicate(existingCandidateID):
                return .duplicate(
                    existingCandidateID: existingCandidateID,
                    candidateRevision: candidateRevision,
                    ledgerRevision: ledger.currentRevision
                )
            case let .needsReview(reviewCandidate):
                put(StoredTransactionCandidate(candidate: reviewCandidate), id: reviewCandidate.id)
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
                    ledgerRevision: ledger.currentRevision
                )
            }
            throw duplicateEvidenceError(candidate, owner: owner)
        }

        guard candidate.status == .ready else {
            put(StoredTransactionCandidate(candidate: candidate), id: candidate.id)
            candidateRevision += 1
            return .stored(candidateRevision: candidateRevision)
        }

        let currentLedgerRevision = ledger.currentRevision
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

        // A commit that throws leaves the ledger as it was, so this is the commit point.
        let ledgerResult: LedgerCommitResult
        do {
            ledgerResult = try ledger.commit(entry, expectedRevision: expectedLedgerRevision)
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
            if let existing = candidates[candidate.id], existing.promotedEntryID == nil {
                put(StoredTransactionCandidate(
                    candidate: existing.candidate,
                    promotionRejection: rejection
                ), id: candidate.id)
            } else {
                put(StoredTransactionCandidate(
                    candidate: reviewCandidate,
                    promotionRejection: rejection
                ), id: candidate.id)
            }
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
        put(StoredTransactionCandidate(
            candidate: candidate,
            promotedEntryID: entry.id
        ), id: candidate.id)
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
            if stored.promotedEntryID != nil { return .alreadyPromoted(candidateRevision: candidateRevision, ledgerRevision: ledger.currentRevision) }
            return .alreadyStored(candidateRevision: candidateRevision)
        }
        let nearby = try correlationRecords(near: observation.draft.occurredAt.unixMilliseconds, within: correlator.searchRadiusMilliseconds)
        var sameNamePurchases: [CorrelationRecord] = []
        if let name = NotificationCorrelator.refundSearchKey(for: observation.draft) {
            sameNamePurchases = (index.purchasesByName[name] ?? []).compactMap { candidates[$0]?.correlationRecord }
        }
        let decision = correlator.decide(observation, nearby: nearby, sameNamePurchases: sameNamePurchases)

        // The candidate, the candidates it closes and a reversal apply together or not at all.
        journal = Journal(candidateRevision: candidateRevision, ledger: ledger.checkpoint())
        do {
            let result = try apply(decision, to: candidate,
                                   expectedCandidateRevision: expectedCandidateRevision, expectedLedgerRevision: expectedLedgerRevision)
            if let stored = candidates[candidate.id] {
                put(StoredTransactionCandidate(
                    candidate: stored.candidate, promotedEntryID: stored.promotedEntryID, promotionRejection: stored.promotionRejection,
                    corroborates: stored.corroborates, reversalEntryID: stored.reversalEntryID, suggestions: stored.suggestions, observation: observation
                ), id: candidate.id)
            }
            journal = nil
            return result
        } catch {
            rollback()
            throw error
        }
    }

    private mutating func apply(
        _ correlation: CorrelationDecision,
        to candidate: TransactionCandidate,
        expectedCandidateRevision: UInt64,
        expectedLedgerRevision: UInt64
    ) throws -> CandidateProcessingResult {
        switch correlation {
        case let .newAct(act):
            let revisionBefore = candidateRevision
            let result = try process(candidate, expectedCandidateRevision: expectedCandidateRevision, expectedLedgerRevision: expectedLedgerRevision)
            guard case .promoted = result else { return result }
            for closed in act.closes {
                guard let stored = candidates[closed.candidateID], stored.promotedEntryID == nil else {
                    throw CandidateProcessingError.invalidCorrelationTarget(closed.candidateID)
                }
                put(stored.linked(to: CorrelationMatch(candidateID: candidate.id, rule: closed.rule)), id: closed.candidateID)
            }
            var ledgerRevision = ledger.currentRevision
            if let replaced = act.replacesIncome {
                guard let stored = candidates[replaced.candidateID], let entryID = stored.promotedEntryID, stored.reversalEntryID == nil,
                      let original = ledger.entry(withID: entryID), original.kind == .income else {
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
                    switch try ledger.commit(reversal, expectedRevision: ledgerRevision) {
                    case let .committed(revision), let .alreadyCommitted(revision): ledgerRevision = revision
                    }
                } catch let error as LedgerStorageError {
                    throw CandidateProcessingError.ledger(error)
                }
                put(stored.linked(
                    to: CorrelationMatch(candidateID: candidate.id, rule: replaced.rule), reversal: reversal.id
                ), id: replaced.candidateID)
            }
            return .promoted(candidateRevision: revisionBefore, ledgerRevision: ledgerRevision)

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
        put(stored, id: stored.candidate.id)
        candidateRevision += 1
    }

    // MARK: Changes and the way back

    private struct Journal {
        let candidateRevision: UInt64
        let ledger: InMemoryLedgerRepository.Checkpoint
        var previous: [(id: TransactionCandidateID, stored: StoredTransactionCandidate?)] = []

        init(candidateRevision: UInt64, ledger: InMemoryLedgerRepository.Checkpoint) {
            self.candidateRevision = candidateRevision
            self.ledger = ledger
        }
    }

    /// The only place a stored candidate is written, so the indexes always match what is stored.
    private mutating func put(_ stored: StoredTransactionCandidate, id: TransactionCandidateID) {
        let old = candidates[id]
        journal?.previous.append((id, old))
        index.replace(old, with: stored, id: id)
        candidates[id] = stored
    }

    private mutating func rollback() {
        guard let journal else { return }
        for (id, previous) in journal.previous.reversed() {
            index.replace(candidates[id], with: previous, id: id)
            candidates[id] = previous
        }
        candidateRevision = journal.candidateRevision
        ledger.rollback(to: journal.ledger)
        self.journal = nil
    }

    // MARK: Lookups

    /// The stored candidates a ready candidate could collide with: those whose first reading is within the dedup window of its
    /// own, leaving out notifications kept only as evidence of another act (they are not acts of their own).
    private func dedupNeighbours(of candidate: TransactionCandidate) -> [TransactionCandidate] {
        guard let time = candidate.sourceDraft?.occurredAt.unixMilliseconds else { return [] }
        return index.ids(in: \.byDraftTime, near: time, within: deduplication.similarityWindowMilliseconds)
            .sorted { $0.rawValue < $1.rawValue }
            .compactMap { id in candidates[id].flatMap { $0.corroborates == nil ? $0.candidate : nil } }
    }

    private func evidenceOwner(
        of candidate: TransactionCandidate
    ) -> Dictionary<TransactionCandidateID, StoredTransactionCandidate>.Element? {
        var owner: TransactionCandidateID?
        for evidenceID in candidate.evidenceIDs {
            for id in index.evidence[evidenceID] ?? [] where id != candidate.id {
                if owner == nil || id.rawValue < owner!.rawValue { owner = id }
            }
        }
        guard let owner, let stored = candidates[owner] else { return nil }
        return (key: owner, value: stored)
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

/// What stored candidates are looked up by, so a lookup reads the few that matter and not all of them.
private struct CandidateIndex {
    struct EventKey: Hashable {
        let rawNotificationID: String
        let eventIndex: Int
    }

    /// Time buckets as wide as the longest time any rule compares, so a window reads a handful of buckets.
    private static let bucketMilliseconds: Int64 = 900_000

    /// By the time the correlator knows the notification at (`observation.draft`).
    var byRecordTime: [Int64: Set<TransactionCandidateID>] = [:]
    /// By the time of the notification as first read (`candidate.sourceDraft`), which the dedup compares.
    var byDraftTime: [Int64: Set<TransactionCandidateID>] = [:]
    /// The candidates that are evidence of the key candidate.
    var corroborators: [TransactionCandidateID: Set<TransactionCandidateID>] = [:]
    var evidence: [String: Set<TransactionCandidateID>] = [:]
    var notificationEvents: [EventKey: Set<TransactionCandidateID>] = [:]
    /// Purchases under their `purchaseNameKey`.
    var purchasesByName: [String: Set<TransactionCandidateID>] = [:]

    private struct Keys: Equatable {
        var recordTime: Int64?
        var draftTime: Int64?
        var corroborates: TransactionCandidateID?
        var evidence: [String] = []
        var event: EventKey?
        var name: String?

        init(_ stored: StoredTransactionCandidate?) {
            guard let stored else { return }
            if let draft = stored.observation?.draft {
                recordTime = draft.occurredAt.unixMilliseconds
                if draft.kind == .purchase { name = NotificationCorrelator.purchaseNameKey(draft) }
            }
            if let draft = stored.candidate.sourceDraft {
                draftTime = draft.occurredAt.unixMilliseconds
                event = EventKey(rawNotificationID: draft.rawNotificationID, eventIndex: draft.eventIndex)
            }
            corroborates = stored.corroborates?.candidateID
            evidence = stored.candidate.evidenceIDs
        }
    }

    mutating func replace(_ old: StoredTransactionCandidate?, with new: StoredTransactionCandidate?, id: TransactionCandidateID) {
        let before = Keys(old), after = Keys(new)
        guard before != after else { return }
        if let time = before.recordTime { Self.remove(id, at: Self.bucket(time), from: &byRecordTime) }
        if let time = before.draftTime { Self.remove(id, at: Self.bucket(time), from: &byDraftTime) }
        if let target = before.corroborates { Self.remove(id, at: target, from: &corroborators) }
        for key in before.evidence { Self.remove(id, at: key, from: &evidence) }
        if let event = before.event { Self.remove(id, at: event, from: &notificationEvents) }
        if let name = before.name { Self.remove(id, at: name, from: &purchasesByName) }
        if let time = after.recordTime { byRecordTime[Self.bucket(time), default: []].insert(id) }
        if let time = after.draftTime { byDraftTime[Self.bucket(time), default: []].insert(id) }
        if let target = after.corroborates { corroborators[target, default: []].insert(id) }
        for key in after.evidence { evidence[key, default: []].insert(id) }
        if let event = after.event { notificationEvents[event, default: []].insert(id) }
        if let name = after.name { purchasesByName[name, default: []].insert(id) }
    }

    /// The IDs in the buckets that cover `time - radius ... time + radius` (more than that range, never less).
    func ids(in buckets: KeyPath<CandidateIndex, [Int64: Set<TransactionCandidateID>]>, near time: Int64, within radius: Int64) -> [TransactionCandidateID] {
        let table = self[keyPath: buckets]
        let low = Self.bucket(time.subtractingReportingOverflow(radius).overflow ? .min : time - radius)
        let high = Self.bucket(time.addingReportingOverflow(radius).overflow ? .max : time + radius)
        var result: [TransactionCandidateID] = []
        if high - low > Int64(table.count) {
            for (bucket, ids) in table where bucket >= low && bucket <= high { result.append(contentsOf: ids) }
        } else {
            for bucket in low...high { if let ids = table[bucket] { result.append(contentsOf: ids) } }
        }
        return result
    }

    private static func bucket(_ time: Int64) -> Int64 {
        let (quotient, remainder) = time.quotientAndRemainder(dividingBy: bucketMilliseconds)
        return remainder < 0 ? quotient - 1 : quotient
    }

    private static func remove<Key: Hashable>(_ id: TransactionCandidateID, at key: Key, from table: inout [Key: Set<TransactionCandidateID>]) {
        guard var ids = table[key] else { return }
        table[key] = nil
        ids.remove(id)
        if !ids.isEmpty { table[key] = ids }
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
