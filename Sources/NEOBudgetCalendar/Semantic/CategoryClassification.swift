/// Future-facing hook for the chain
/// `raw description → canonical payee/merchant → merchant type → canonical category → Activity / Tag / Area`.
///
/// Only the end of the chain that this module must not contradict is modeled here. Categories come from a
/// canonical taxonomy (`CanonicalCategoryID`), never from free text, and "unclassified" is an explicit,
/// normal state. Leaving a transaction unclassified is always better than forcing a wrong category.
public enum UnclassifiedReason: String, Codable, Hashable, Sendable {
    case notYetEvaluated
    case insufficientInformation
    case ambiguous
}

public enum CategoryClassification: Codable, Hashable, Sendable {
    case unclassified(UnclassifiedReason)
    case classified(CanonicalCategoryID, AssignmentProvenance)

    public static let initial = CategoryClassification.unclassified(.notYetEvaluated)

    public var categoryID: CanonicalCategoryID? {
        if case let .classified(id, _) = self { return id }
        return nil
    }
}

extension AssignmentPolicy {
    /// Applies a proposed category. A user choice is always kept. An automated proposal below the threshold
    /// does not become a category; the result stays `unclassified(.ambiguous)` instead of guessing.
    public func classification(
        proposing category: CanonicalCategoryID,
        provenance: AssignmentProvenance,
        replacing existing: CategoryClassification = .initial
    ) -> CategoryClassification {
        if case let .classified(_, existingProvenance) = existing, !provenance.mayReplace(existingProvenance) {
            return existing
        }
        guard accepts(provenance) else {
            if case .classified = existing { return existing }
            return .unclassified(.ambiguous)
        }
        return .classified(category, provenance)
    }
}
