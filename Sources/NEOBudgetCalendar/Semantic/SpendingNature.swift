import NEOBudgetCore

/// What a piece of spending means for the **budget**, independent of what was bought.
///
/// Category answers "what did the money go to?" (식비 > 외식). SpendingNature answers "what kind of spending is
/// it for budgeting?". The two are separate axes and are never merged: a restaurant meal on a Jeju trip is
/// still 외식, but it should not eat the monthly living budget. Keeping this apart is what stops one
/// irregular purchase from making the whole month look like a failure.
public enum SpendingNature: String, Codable, Hashable, Sendable, CaseIterable {
    /// Ordinary running costs of life (월세, 식비, 교통).
    case living
    /// Chosen spending that could be skipped without hurting daily life.
    case discretionary
    /// Large or one-off spending outside the regular rhythm (폰 구매, 여행 숙박).
    case irregular
}

/// A place where a nature can be stated. Stating one at a broad level (a category, an activity type, a tag)
/// is a default signal; stating one at a narrow level (an allocation) is the user's final word.
public enum NatureTarget: Codable, Hashable, Sendable {
    case allocation(AllocationID)
    case transaction(LedgerEntryID)
    case component(ExpenseComponentID)
    case activity(ActivityID)
    case tag(TagID)
    case activityType(ActivityTypeID)
    case category(CanonicalCategoryID)
}

/// Which level of the precedence chain decided the nature.
public enum NatureSource: String, Codable, Hashable, Sendable {
    case allocation, transaction, component, activity, tag, activityType, category
    /// Nothing stated a nature. Analysis reports it as unspecified instead of guessing `living`.
    case none
}

public struct ResolvedSpendingNature: Hashable, Sendable {
    public let nature: SpendingNature?
    public let source: NatureSource

    public init(nature: SpendingNature?, source: NatureSource) {
        self.nature = nature
        self.source = source
    }
}

/// Finds the nature that applies, most specific statement first:
///
/// `allocation / component` → `transaction` → `activity` → `tag` → `activityType` → `category` → none.
///
/// Tags are the one level that can disagree with itself (two tags that state different natures); a
/// disagreement counts as no statement at that level and the search goes on. Who made a statement does not
/// change the order; protection of user choices happens when statements are written.
public enum SpendingNatureResolver {
    public static func resolve(allocation: TransactionAllocation, in life: LifeState) -> ResolvedSpendingNature {
        resolve(
            specific: [(.allocation, .allocation(allocation.id)), (.transaction, .transaction(allocation.transactionID))],
            activityID: allocation.activityID,
            transactionTags: life.tags(forTransaction: allocation.transactionID).map(\.tagID),
            category: allocation.category,
            in: life
        )
    }

    public static func resolve(component: ExpenseComponent, in life: LifeState) -> ResolvedSpendingNature {
        let specific: [(NatureSource, NatureTarget)] = [(.component, .component(component.id))]
        return resolve(specific: specific, activityID: component.activityID, transactionTags: [], category: component.category, in: life)
    }

    private static func resolve(
        specific: [(NatureSource, NatureTarget)],
        activityID: ActivityID?,
        transactionTags: [TagID],
        category: CategoryAssignment,
        in life: LifeState
    ) -> ResolvedSpendingNature {
        for (source, target) in specific {
            if let nature = life.natureSignals[target]?.value { return ResolvedSpendingNature(nature: nature, source: source) }
        }
        let activity = activityID.flatMap { life.activities[$0] }
        if let activityID, let nature = life.natureSignals[.activity(activityID)]?.value {
            return ResolvedSpendingNature(nature: nature, source: .activity)
        }
        let tagIDs = Set(transactionTags + (activity?.tags.map(\.tagID) ?? []))
        let tagNatures = Set(tagIDs.compactMap { life.natureSignals[.tag($0)]?.value })
        if tagNatures.count == 1, let nature = tagNatures.first { return ResolvedSpendingNature(nature: nature, source: .tag) }
        if let typeID = activity?.activityType?.value, let nature = life.natureSignals[.activityType(typeID)]?.value {
            return ResolvedSpendingNature(nature: nature, source: .activityType)
        }
        if let categoryID = category.categoryID, let nature = life.natureSignals[.category(categoryID)]?.value {
            return ResolvedSpendingNature(nature: nature, source: .category)
        }
        return ResolvedSpendingNature(nature: nil, source: .none)
    }
}
