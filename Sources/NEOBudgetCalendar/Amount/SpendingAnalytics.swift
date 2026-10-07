import NEOBudgetCore

// Pure aggregation helpers for the budget questions this domain has to be able to answer later:
// "how much of the month was living cost, how much irregular, how much discretionary?" and
// "how much of what I spent has an unknown category?". They never guess: an amount that is not settled stays
// a range, a nature nobody stated stays `unspecified`, and settlement residuals are kept out entirely.

/// One piece of spending, with the three independent axes side by side.
public struct SpendingItem: Hashable, Sendable {
    public let id: String
    public let amount: AmountEntry
    public let flow: TransactionFlow
    public let category: CategoryAssignment
    public let nature: ResolvedSpendingNature
    public let activityID: ActivityID?
}

public struct NatureBreakdown: Hashable, Sendable {
    public let currency: String
    public let living: AmountAggregate?
    public let discretionary: AmountAggregate?
    public let irregular: AmountAggregate?
    /// Spending nobody has given a nature. Never silently counted as `living`.
    public let unspecified: AmountAggregate?
    public let total: AmountAggregate

    public func aggregate(for nature: SpendingNature) -> AmountAggregate? {
        switch nature {
        case .living: return living
        case .discretionary: return discretionary
        case .irregular: return irregular
        }
    }
}

public struct CategoryStateBreakdown: Hashable, Sendable {
    public let currency: String
    public let classified: AmountAggregate?
    /// Known what it was, no category in the taxonomy fits (기타).
    public let other: AmountAggregate?
    /// Not enough information to say what it was (모름).
    public let unknown: AmountAggregate?
    /// The system has not decided yet (미분류).
    public let unclassified: AmountAggregate?
    public let total: AmountAggregate
}

public enum SpendingAnalytics {
    /// Spending items from allocations (the ledger-backed side). `.spend` is what leaves; refunds are a
    /// separate flow and are never mixed into the spend totals.
    public static func items(in life: LifeState, flow: TransactionFlow = .spend) -> [SpendingItem] {
        life.allocationSets.values
            .filter { $0.flow == flow }
            .flatMap(\.allocations)
            .sorted { $0.id < $1.id }
            .map { allocation in
                SpendingItem(
                    id: allocation.id.rawValue, amount: allocation.amount, flow: flow, category: allocation.category,
                    nature: SpendingNatureResolver.resolve(allocation: allocation, in: life), activityID: allocation.activityID
                )
            }
    }

    /// Spending items from shared-expense components. Use this *or* `items(in:)` for one analysis: a
    /// component that mirrors an allocated transaction would otherwise be counted twice.
    public static func items(fromComponentsIn life: LifeState) -> [SpendingItem] {
        life.components.values.sorted { $0.id < $1.id }.map { component in
            SpendingItem(
                id: component.id.rawValue, amount: component.amount, flow: .spend, category: component.category,
                nature: SpendingNatureResolver.resolve(component: component, in: life), activityID: component.activityID
            )
        }
    }

    public static func byNature(_ items: [SpendingItem]) -> [NatureBreakdown] {
        let currencies = Set(items.map(\.amount.currency)).sorted()
        return currencies.map { currency in
            let mine = items.filter { $0.amount.currency == currency }
            func pick(_ nature: SpendingNature?) -> AmountAggregate? {
                let subset = mine.filter { $0.nature.nature == nature }
                return subset.isEmpty ? nil : summarize(subset)
            }
            return NatureBreakdown(
                currency: currency, living: pick(.living), discretionary: pick(.discretionary), irregular: pick(.irregular),
                unspecified: pick(nil), total: summarize(mine)
            )
        }
    }

    public static func byCategoryState(_ items: [SpendingItem]) -> [CategoryStateBreakdown] {
        let currencies = Set(items.map(\.amount.currency)).sorted()
        return currencies.map { currency in
            let mine = items.filter { $0.amount.currency == currency }
            func pick(_ kind: CategoryAssignmentKind) -> AmountAggregate? {
                let subset = mine.filter { $0.category.kind == kind }
                return subset.isEmpty ? nil : summarize(subset)
            }
            return CategoryStateBreakdown(
                currency: currency, classified: pick(.classified), other: pick(.other), unknown: pick(.unknown),
                unclassified: pick(.unclassified), total: summarize(mine)
            )
        }
    }

    /// Items to look at first, most urgent first (see `CategoryAssignment.reviewPriority`). Items that need no
    /// review are left out.
    public static func reviewQueue(_ items: [SpendingItem]) -> [SpendingItem] {
        items
            .filter { $0.category.reviewPriority > 0 }
            .sorted { lhs, rhs in
                if lhs.category.reviewPriority != rhs.category.reviewPriority { return lhs.category.reviewPriority > rhs.category.reviewPriority }
                return lhs.id < rhs.id
            }
    }

    private static func summarize(_ items: [SpendingItem]) -> AmountAggregate {
        AmountAggregate.summarize(items.map { (currency: $0.amount.currency, knowledge: $0.amount.knowledge) })[0]
    }
}

/// What rounding did to a set of obligations: the real cost versus what was asked.
public struct RoundingSummary: Hashable, Sendable {
    public let currency: String
    public let rawShareMinorUnits: Int64
    public let requestedMinorUnits: Int64
    /// Requested minus raw. Negative means people were asked for less than their real share.
    public var adjustmentMinorUnits: Int64 { requestedMinorUnits - rawShareMinorUnits }

    /// Only obligations that remember a raw share and have a settled amount are counted.
    public static func summarize(_ obligations: [Obligation], direction: ObligationDirection? = nil) -> [RoundingSummary] {
        var raw: [String: Int64] = [:]
        var requested: [String: Int64] = [:]
        for obligation in obligations where obligation.status != .cancelled && (direction == nil || obligation.direction == direction) {
            guard let share = obligation.share, let value = obligation.amount.knowledge.knownValue else { continue }
            raw[obligation.currency, default: 0] += share.rawShareMinorUnits
            requested[obligation.currency, default: 0] += value
        }
        return raw.keys.sorted().map { RoundingSummary(currency: $0, rawShareMinorUnits: raw[$0] ?? 0, requestedMinorUnits: requested[$0] ?? 0) }
    }
}

extension LifeState {
    /// Nature and category breakdowns over the allocation-backed spend.
    public func spendingByNature(flow: TransactionFlow = .spend) -> [NatureBreakdown] {
        SpendingAnalytics.byNature(SpendingAnalytics.items(in: self, flow: flow))
    }

    public func residualSummary() -> [ResidualSummary] {
        ResidualSummary.summarize(Array(residuals.values))
    }
}
