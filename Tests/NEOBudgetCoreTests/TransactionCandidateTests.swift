import Foundation
import Testing
import NEOBudgetCore

@Test func ambiguousInputIsRepresentedAsReviewWorkNotAReadyEntry() throws {
    let candidate = try TransactionCandidate(
        id: TransactionCandidateID(rawValue: "candidate-1"),
        evidenceIDs: ["raw-1"],
        status: .needsReview,
        issues: [.ambiguousWithoutStrongIdentity],
        policyVersion: "dedup-v1"
    )

    #expect(candidate.status == .needsReview)
    #expect(candidate.proposedEntry == nil)
}

@Test func readyCandidateMustCarryAnEntryBackedByTheSameEvidence() throws {
    let entry = LedgerEntry(
        id: LedgerEntryID(rawValue: "entry-1"),
        kind: .income,
        occurredAtUnixMilliseconds: 1,
        postings: [Posting(
            accountID: AccountID(rawValue: "bank"),
            delta: try Money(minorUnits: 1_000, currency: "KRW")
        )],
        evidenceIDs: ["raw-1"]
    )
    let ready = try TransactionCandidate(
        id: TransactionCandidateID(rawValue: "candidate-1"),
        evidenceIDs: ["raw-1"],
        status: .ready,
        proposedEntry: entry,
        policyVersion: "candidate-v1"
    )
    #expect(ready.proposedEntry == entry)

    #expect(throws: CandidateValidationError.proposedEntryEvidenceMismatch) {
        try TransactionCandidate(
            id: TransactionCandidateID(rawValue: "candidate-2"),
            evidenceIDs: ["raw-2"],
            status: .ready,
            proposedEntry: entry,
            policyVersion: "candidate-v1"
        )
    }
}

@Test func invalidCandidateStateCannotEnterThroughDecoding() throws {
    let invalid = Data(#"""
    {
      "id":"candidate-1",
      "evidenceIDs":["raw-1"],
      "status":"needsReview",
      "issues":[],
      "policyVersion":"candidate-v1"
    }
    """#.utf8)

    #expect(throws: CandidateValidationError.invalidState(.needsReview)) {
        try JSONDecoder().decode(TransactionCandidate.self, from: invalid)
    }
}
