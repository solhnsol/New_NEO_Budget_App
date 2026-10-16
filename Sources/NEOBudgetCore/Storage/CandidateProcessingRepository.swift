public struct StoredTransactionCandidate: Codable, Equatable, Sendable {
    public let candidate: TransactionCandidate
    public let promotedEntryID: LedgerEntryID?
    public let promotionRejection: CandidatePromotionRejection?
    /// This notification is evidence of the act of another candidate (see `NotificationCorrelator`); it never becomes
    /// an entry of its own. A candidate that was promoted and later turned out to be a transfer leg keeps its entry and
    /// gains this link together with `reversalEntryID`.
    public let corroborates: CorrelationMatch?
    /// The entry that reversed this candidate's own entry when it was corrected into another act.
    public let reversalEntryID: LedgerEntryID?
    /// Earlier candidates the user may confirm this one belongs to (amount and name only).
    public let suggestions: [CorrelationMatch]
    /// What the correlator knew of this notification when it arrived, so later notifications can be judged against it.
    public let observation: CorrelationObservation?

    public init(
        candidate: TransactionCandidate,
        promotedEntryID: LedgerEntryID? = nil,
        promotionRejection: CandidatePromotionRejection? = nil,
        corroborates: CorrelationMatch? = nil,
        reversalEntryID: LedgerEntryID? = nil,
        suggestions: [CorrelationMatch] = [],
        observation: CorrelationObservation? = nil
    ) {
        self.candidate = candidate
        self.promotedEntryID = promotedEntryID
        self.promotionRejection = promotionRejection
        self.corroborates = corroborates
        self.reversalEntryID = reversalEntryID
        self.suggestions = suggestions
        self.observation = observation
    }

    /// The correlator's view of this candidate, when it was processed with an observation.
    public var correlationRecord: CorrelationRecord? {
        observation.map {
            CorrelationRecord(observation: $0, entryID: promotedEntryID, recordedAsIncome: candidate.proposedEntry?.kind == .income && promotedEntryID != nil,
                              corroborates: corroborates)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case candidate, promotedEntryID, promotionRejection, corroborates, reversalEntryID, suggestions, observation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            candidate: try values.decode(TransactionCandidate.self, forKey: .candidate),
            promotedEntryID: try values.decodeIfPresent(LedgerEntryID.self, forKey: .promotedEntryID),
            promotionRejection: try values.decodeIfPresent(CandidatePromotionRejection.self, forKey: .promotionRejection),
            corroborates: try values.decodeIfPresent(CorrelationMatch.self, forKey: .corroborates),
            reversalEntryID: try values.decodeIfPresent(LedgerEntryID.self, forKey: .reversalEntryID),
            suggestions: try values.decodeIfPresent([CorrelationMatch].self, forKey: .suggestions) ?? [],
            observation: try values.decodeIfPresent(CorrelationObservation.self, forKey: .observation)
        )
    }
}

public enum CandidatePromotionRejection: String, Codable, Equatable, Sendable {
    case conflictingEntry
    case revisionOverflow
    case invalidConfiguration
    case invalidEntry
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
    /// Stored as evidence of an existing candidate's act; the ledger did not change.
    case corroborated(existingCandidateID: TransactionCandidateID, candidateRevision: UInt64)
    case alreadyPromoted(candidateRevision: UInt64, ledgerRevision: UInt64)
    case duplicate(existingCandidateID: TransactionCandidateID, candidateRevision: UInt64, ledgerRevision: UInt64)
    case rejectedByLedger(
        candidateRevision: UInt64,
        ledgerRevision: UInt64,
        reason: CandidatePromotionRejection
    )
}

public enum CandidateProcessingError: Error, Equatable, Sendable {
    case staleCandidateRevision(expected: UInt64, actual: UInt64)
    case staleLedgerRevision(expected: UInt64, actual: UInt64)
    case conflictingCandidate(TransactionCandidateID)
    case evidenceAlreadyClaimed(id: String, candidateID: TransactionCandidateID)
    case revisionOverflow
    case ledger(LedgerStorageError)
    /// A correlation named a candidate that is not stored, or one that cannot take this role.
    case invalidCorrelationTarget(TransactionCandidateID)
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

    /// Judges the candidate with `correlator` against the stored candidates and applies the decision in the same atomic step:
    /// - `corroborates`: stored as evidence of the existing act; the ledger does not change.
    /// - `newAct`: processed as usual; when it is promoted, the candidates it `closes` become its evidence, and an income
    ///   it `replacesIncome` is reversed (a `reversal` entry) and becomes its evidence. Nothing is applied if it is not promoted.
    /// - `suggests`: stored for review with the suggested partners; the ledger does not change.
    /// The candidate must be assembled with `observation.transferCounterpart` as its transfer counterpart.
    mutating func process(
        _ candidate: TransactionCandidate,
        observation: CorrelationObservation,
        correlator: NotificationCorrelator,
        expectedCandidateRevision: UInt64,
        expectedLedgerRevision: UInt64
    ) throws -> CandidateProcessingResult
}
