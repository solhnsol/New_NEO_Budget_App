/// Where a thing's category stands. Five different situations that must never be merged:
///
/// - `classified`: it is known what it was, and the canonical taxonomy has a category for it.
/// - `other` (기타): it is known what it was, but the taxonomy has no fitting category. **A limit of the taxonomy.**
/// - `unresolved` (모름, 아직): not enough information yet, and the user has **not been asked**. Worth asking.
/// - `confirmedUnknown` (모른다고 확인함): the user was asked and said "I do not know". **A user decision.**
///   The same evidence never produces the same question again; only newer evidence reopens it.
/// - `unclassified` (미분류): the information is enough, but the system has not decided yet. **A pending job**
///   for the classifier or merchant resolution, not a question for the user.
///
/// Categories come from a canonical taxonomy (`CanonicalCategoryID`), never from free text, and leaving
/// something undecided is always better than forcing a wrong category. Amount uncertainty is a separate axis:
/// an exact amount can have an unresolved category, and an unknown amount can have a classified category.
public enum UnclassifiedReason: String, Codable, Hashable, Sendable {
    case notYetEvaluated
    /// The classifier saw candidates but none was good enough, or they conflicted.
    case ambiguous
}

public enum CategoryAssignmentKind: String, Codable, Hashable, Sendable {
    case classified, other, unresolved, confirmedUnknown, unclassified
}

public enum CategoryAssignment: Codable, Hashable, Sendable {
    case classified(CanonicalCategoryID, AssignmentProvenance)
    case other(AssignmentProvenance)
    /// Not enough information, and nobody has been asked yet.
    case unresolved
    /// The user said they do not know. The provenance is always the user's; its `evidenceVersion` is the newest
    /// evidence the user had seen (the assignment time stands in when none was stated).
    case confirmedUnknown(AssignmentProvenance)
    case unclassified(UnclassifiedReason)

    public static let initial = CategoryAssignment.unclassified(.notYetEvaluated)

    public var kind: CategoryAssignmentKind {
        switch self {
        case .classified: return .classified
        case .other: return .other
        case .unresolved: return .unresolved
        case .confirmedUnknown: return .confirmedUnknown
        case .unclassified: return .unclassified
        }
    }

    public var categoryID: CanonicalCategoryID? {
        if case let .classified(id, _) = self { return id }
        return nil
    }

    /// Who decided this, when anyone did. `unresolved` and `unclassified` are pending states with no decider.
    public var provenance: AssignmentProvenance? {
        switch self {
        case let .classified(_, provenance), let .other(provenance), let .confirmedUnknown(provenance): return provenance
        case .unresolved, .unclassified: return nil
        }
    }

    /// The evidence a `confirmedUnknown` was confirmed against.
    public var confirmedEvidenceVersion: Int64? {
        guard case let .confirmedUnknown(provenance) = self else { return nil }
        return provenance.evidenceVersion ?? provenance.assignedAtUnixMilliseconds
    }

    /// An automated decision never replaces a user's, with one exception that is not really an override: a
    /// user's "I do not know" is reopened by evidence newer than what they saw.
    public func mayBeReplaced(by newProvenance: AssignmentProvenance) -> Bool {
        if let confirmed = confirmedEvidenceVersion, newProvenance.source == .automated {
            guard let evidence = newProvenance.evidenceVersion else { return false }
            return evidence > confirmed
        }
        guard let existing = provenance else { return true }
        return newProvenance.mayReplace(existing)
    }

    /// Whether this assignment may take the place of `existing`. A pending state has no decider, so it counts
    /// as the system's and never replaces a decision a user made. A `confirmedUnknown` is the one user
    /// decision that automation may replace, and only with evidence newer than what the user saw.
    public func canReplace(_ existing: CategoryAssignment) -> Bool {
        if let confirmed = existing.confirmedEvidenceVersion {
            guard let own = provenance else { return false }
            if own.source == .user { return true }
            guard let evidence = own.evidenceVersion else { return false }
            return evidence > confirmed
        }
        guard let existingProvenance = existing.provenance else { return true }
        guard let own = provenance else { return existingProvenance.source != .user }
        return own.mayReplace(existingProvenance)
    }

    /// How urgently a person should look at this. Only `unresolved` is a question for the user. A conflicting
    /// classifier result and a not-yet-evaluated one are the system's own work (they are listed after, so a
    /// retry is visible, but they are not asked). `confirmedUnknown`, `other` and `classified` need no review:
    /// a crowded `other` bucket is a signal for the taxonomy, not for each item.
    public var reviewPriority: Int {
        switch self {
        case .unresolved: return 3
        case .unclassified(.ambiguous): return 2
        case .unclassified(.notYetEvaluated): return 1
        case .confirmedUnknown, .classified, .other: return 0
        }
    }

    /// The user may be asked what this was.
    public var needsUserQuestion: Bool { kind == .unresolved }

    /// The classifier or merchant resolution should look again; the user is not involved.
    public var needsAutomatedRetry: Bool { kind == .unclassified }

    /// Whether to put this in front of the user given the newest evidence seen for the thing. A
    /// `confirmedUnknown` returns only when evidence is newer than what the user confirmed against.
    public func isWorthAskingAbout(latestEvidenceVersion: Int64?) -> Bool {
        if let confirmed = confirmedEvidenceVersion {
            guard let latest = latestEvidenceVersion else { return false }
            return latest > confirmed
        }
        return needsUserQuestion
    }
}

extension AssignmentPolicy {
    /// Applies a proposed category.
    ///
    /// - A user choice (a category or `other`) is always kept against automation.
    /// - An automated proposal below the confidence threshold does not become a category; the result stays
    ///   `unclassified(.ambiguous)` (or `unresolved`) instead of guessing.
    /// - A `confirmedUnknown` is not overwritten by a classifier that merely feels confident: the proposal's
    ///   provenance must carry an `evidenceVersion` newer than the one the user confirmed against.
    public func classification(
        proposing category: CanonicalCategoryID,
        provenance: AssignmentProvenance,
        replacing existing: CategoryAssignment = .initial
    ) -> CategoryAssignment {
        guard existing.mayBeReplaced(by: provenance) else { return existing }
        guard accepts(provenance) else {
            switch existing {
            case .classified, .other, .confirmedUnknown, .unresolved: return existing
            case .unclassified: return .unclassified(.ambiguous)
            }
        }
        return .classified(category, provenance)
    }
}
