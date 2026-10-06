public struct TransactionCandidateID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum CandidateStatus: String, Codable, Sendable {
    case ready
    case needsReview
    case waitingForEvidence
    case rejected
}

/// Stable, machine-readable reasons that the application can explain in a review UI.
public enum CandidateIssue: String, Codable, Hashable, Sendable {
    case ambiguousWithoutStrongIdentity
    case conflictingStrongIdentity
    case unknownAccount
    case unboundSource
    case missingAmount
    case invalidAmount
    case missingTransactionTime
    case missingOriginalEntry
    case incompleteTransfer
    case parserUncertain
    case unsupportedEvent
}

public enum CandidateValidationError: Error, Equatable, Sendable {
    case emptyIdentifier
    case emptyPolicyVersion
    case missingEvidence
    case duplicateEvidence(String)
    case invalidState(CandidateStatus)
    case proposedEntryEvidenceMismatch
    case draftEvidenceMismatch
}

/// An assembled/deduplicated result is not a financial fact until it reaches `ready` and is
/// explicitly committed. `needsReview` therefore cannot silently mutate the ledger.
public struct TransactionCandidate: Codable, Equatable, Sendable {
    public let id: TransactionCandidateID
    public let evidenceIDs: [String]
    public let status: CandidateStatus
    public let issues: [CandidateIssue]
    public let proposedEntry: LedgerEntry?
    public let policyVersion: String
    public let sourceDraft: TransactionCandidateDraft?

    public init(
        id: TransactionCandidateID,
        evidenceIDs: [String],
        status: CandidateStatus,
        issues: [CandidateIssue] = [],
        proposedEntry: LedgerEntry? = nil,
        policyVersion: String,
        sourceDraft: TransactionCandidateDraft? = nil
    ) throws {
        guard !id.rawValue.isEmpty else { throw CandidateValidationError.emptyIdentifier }
        guard !policyVersion.isEmpty else { throw CandidateValidationError.emptyPolicyVersion }
        guard !evidenceIDs.isEmpty, evidenceIDs.allSatisfy({ !$0.isEmpty }) else {
            throw CandidateValidationError.missingEvidence
        }
        var uniqueEvidence = Set<String>()
        for evidenceID in evidenceIDs where !uniqueEvidence.insert(evidenceID).inserted {
            throw CandidateValidationError.duplicateEvidence(evidenceID)
        }
        guard Set(issues).count == issues.count else {
            throw CandidateValidationError.invalidState(status)
        }

        switch status {
        case .ready:
            guard issues.isEmpty, proposedEntry != nil else {
                throw CandidateValidationError.invalidState(status)
            }
        case .needsReview:
            guard !issues.isEmpty else { throw CandidateValidationError.invalidState(status) }
        case .waitingForEvidence, .rejected:
            guard !issues.isEmpty, proposedEntry == nil else {
                throw CandidateValidationError.invalidState(status)
            }
        }

        if let proposedEntry, Set(proposedEntry.evidenceIDs) != uniqueEvidence {
            throw CandidateValidationError.proposedEntryEvidenceMismatch
        }
        if let sourceDraft, !uniqueEvidence.contains(sourceDraft.rawNotificationID) {
            throw CandidateValidationError.draftEvidenceMismatch
        }

        self.id = id
        self.evidenceIDs = evidenceIDs
        self.status = status
        self.issues = issues
        self.proposedEntry = proposedEntry
        self.policyVersion = policyVersion
        self.sourceDraft = sourceDraft
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case evidenceIDs
        case status
        case issues
        case proposedEntry
        case policyVersion
        case sourceDraft
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(TransactionCandidateID.self, forKey: .id),
            evidenceIDs: values.decode([String].self, forKey: .evidenceIDs),
            status: values.decode(CandidateStatus.self, forKey: .status),
            issues: values.decode([CandidateIssue].self, forKey: .issues),
            proposedEntry: values.decodeIfPresent(LedgerEntry.self, forKey: .proposedEntry),
            policyVersion: values.decode(String.self, forKey: .policyVersion),
            sourceDraft: values.decodeIfPresent(TransactionCandidateDraft.self, forKey: .sourceDraft)
        )
    }
}
