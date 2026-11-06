public enum CandidateDeduplicationResult: Equatable, Sendable {
    case accepted(TransactionCandidate)
    case duplicate(existingCandidateID: TransactionCandidateID)
    case needsReview(TransactionCandidate)
}

public protocol CandidateDeduplicationValidator {
    func validate(
        _ candidate: TransactionCandidate,
        against existing: [TransactionCandidate]
    ) throws -> CandidateDeduplicationResult
}

/// Lack of strong identity is normal until another materially similar candidate collides with it.
/// Approval numbers remain scoped evidence, not global identity.
public struct DefaultCandidateDeduplicationValidator: CandidateDeduplicationValidator, Sendable {
    public let similarityWindowMilliseconds: Int64

    public init(similarityWindowMilliseconds: Int64 = 300_000) {
        self.similarityWindowMilliseconds = similarityWindowMilliseconds
    }

    public func validate(
        _ candidate: TransactionCandidate,
        against existing: [TransactionCandidate]
    ) throws -> CandidateDeduplicationResult {
        guard candidate.status == .ready, let draft = candidate.sourceDraft else { return .accepted(candidate) }
        let collisions = existing.filter { materiallySimilar(candidate, $0) }
        guard !collisions.isEmpty else { return .accepted(candidate) }

        let candidateStrong = strongEvidence(in: draft)
        if let duplicate = collisions.first(where: {
            !candidateStrong.isDisjoint(with: strongEvidence(in: $0.sourceDraft))
        }) {
            return .duplicate(existingCandidateID: duplicate.id)
        }
        let conflictingStrong = collisions.contains { other in
            let otherStrong = strongEvidence(in: other.sourceDraft)
            return !candidateStrong.isEmpty && !otherStrong.isEmpty && candidateStrong.isDisjoint(with: otherStrong)
        }
        let issue: CandidateIssue = conflictingStrong ? .conflictingStrongIdentity : .ambiguousWithoutStrongIdentity
        return .needsReview(try TransactionCandidate(
            id: candidate.id,
            evidenceIDs: candidate.evidenceIDs,
            status: .needsReview,
            issues: [issue],
            policyVersion: candidate.policyVersion,
            sourceDraft: draft
        ))
    }

    private func materiallySimilar(_ lhs: TransactionCandidate, _ rhs: TransactionCandidate) -> Bool {
        guard let lhsDraft = lhs.sourceDraft,
              let rhsDraft = rhs.sourceDraft,
              lhsDraft.kind == rhsDraft.kind,
              lhsDraft.direction == rhsDraft.direction,
              lhsDraft.amount == rhsDraft.amount,
              boundIdentities(in: lhs) == boundIdentities(in: rhs) else { return false }
        let (difference, overflow) = lhsDraft.occurredAt.unixMilliseconds
            .subtractingReportingOverflow(rhsDraft.occurredAt.unixMilliseconds)
        guard !overflow, difference != Int64.min else { return false }
        return abs(difference) <= similarityWindowMilliseconds
    }

    private func boundIdentities(in candidate: TransactionCandidate) -> Set<String> {
        guard let entry = candidate.proposedEntry else { return [] }
        let accounts = entry.postings.map { "account:\($0.accountID.rawValue)" }
        let instruments = entry.liabilityChanges.map { "instrument:\($0.instrumentID.rawValue)" }
        return Set(accounts + instruments)
    }

    private func strongEvidence(in draft: TransactionCandidateDraft?) -> Set<String> {
        guard let draft else { return [] }
        return Set(draft.evidence.compactMap { evidence in
            guard evidence.strength == .strong else { return nil }
            return "\(evidence.scope ?? "")\u{1f}\(evidence.kind.rawValue)\u{1f}\(evidence.value)"
        })
    }
}
