/// Where a thing's category stands. Four different situations that must never be merged:
///
/// - `classified`: it is known what it was, and the canonical taxonomy has a category for it.
/// - `other` (기타): it is known what it was, but the taxonomy has no fitting category. **A limit of the taxonomy.**
/// - `unknown` (모름): what it was is not known; there is not enough information. **A limit of the information.**
/// - `unclassified` (미분류): the information is enough, but the system has not decided yet. **A pending job.**
///
/// Categories come from a canonical taxonomy (`CanonicalCategoryID`), never from free text, and leaving
/// something undecided is always better than forcing a wrong category. Amount uncertainty is a separate axis:
/// an exact amount can have an unknown category, and an unknown amount can have a classified category.
public enum UnclassifiedReason: String, Codable, Hashable, Sendable {
    case notYetEvaluated
    /// The classifier saw candidates but none was good enough, or they conflicted.
    case ambiguous
}

public enum CategoryAssignmentKind: String, Codable, Hashable, Sendable {
    case classified, other, unknown, unclassified
}

public enum CategoryAssignment: Codable, Hashable, Sendable {
    case classified(CanonicalCategoryID, AssignmentProvenance)
    case other(AssignmentProvenance)
    case unknown(AssignmentProvenance)
    case unclassified(UnclassifiedReason)

    public static let initial = CategoryAssignment.unclassified(.notYetEvaluated)

    public var kind: CategoryAssignmentKind {
        switch self {
        case .classified: return .classified
        case .other: return .other
        case .unknown: return .unknown
        case .unclassified: return .unclassified
        }
    }

    public var categoryID: CanonicalCategoryID? {
        if case let .classified(id, _) = self { return id }
        return nil
    }

    /// Who decided this, when anyone did. A pending `unclassified` has no decider.
    public var provenance: AssignmentProvenance? {
        switch self {
        case let .classified(_, provenance), let .other(provenance), let .unknown(provenance): return provenance
        case .unclassified: return nil
        }
    }

    /// An automated decision never replaces a user's; a user may replace anything.
    public func mayBeReplaced(by newProvenance: AssignmentProvenance) -> Bool {
        guard let existing = provenance else { return true }
        return newProvenance.mayReplace(existing)
    }

    /// Whether this assignment may take the place of `existing`. A pending `unclassified` has no decider, so
    /// it counts as the system's and never replaces a decision a user made.
    public func canReplace(_ existing: CategoryAssignment) -> Bool {
        guard let existingProvenance = existing.provenance else { return true }
        guard let own = provenance else { return existingProvenance.source != .user }
        return own.mayReplace(existingProvenance)
    }

    /// How urgently a person should look at this: `unknown` needs the user's information, a conflicting
    /// classifier result comes next, a not-yet-evaluated one can simply be retried, and `other` or a classified
    /// category needs no review (a crowded `other` bucket is a signal for the taxonomy, not for each item).
    public var reviewPriority: Int {
        switch self {
        case .unknown: return 3
        case .unclassified(.ambiguous): return 2
        case .unclassified(.notYetEvaluated): return 1
        case .classified, .other: return 0
        }
    }
}

extension AssignmentPolicy {
    /// Applies a proposed category.
    ///
    /// - A user choice (a category, `other`, or `unknown`) is always kept against automation.
    /// - An automated proposal below the confidence threshold does not become a category; the result stays
    ///   `unclassified(.ambiguous)` instead of guessing.
    /// - An `unknown` is a lack of information. A classifier does not turn it into a category merely by being
    ///   confident: it needs `newEvidence` (information that was not there when it became unknown).
    public func classification(
        proposing category: CanonicalCategoryID,
        provenance: AssignmentProvenance,
        replacing existing: CategoryAssignment = .initial,
        newEvidence: Bool = false
    ) -> CategoryAssignment {
        guard existing.mayBeReplaced(by: provenance) else { return existing }
        if provenance.source == .automated, case .unknown = existing, !newEvidence { return existing }
        guard accepts(provenance) else {
            switch existing {
            case .classified, .other, .unknown: return existing
            case .unclassified: return .unclassified(.ambiguous)
            }
        }
        return .classified(category, provenance)
    }
}
