import Foundation

// Monthly living budget over `AnalysisTransaction`s (docs: records/20261102-분석-예산-탭-설계.md §5, §11–13).
// Pure functions: nothing here reads or changes the ledger. Amounts are "my share" with what friends still owe taken out in advance.
// Rows should already carry the consumption date (`ConsumptionDate`).

/// What happens to money left in a category when the month closes.
public enum LeftoverPolicy: String, Codable, Sendable, CaseIterable {
    /// Default (Hans's RPi habit): the month starts fresh and the leftover piles up in the reserve.
    case sweepToReserve
    /// The leftover is added to next month's limit of the same category.
    case carrySameCategory
    /// The leftover is just gone.
    case none
}

public struct BudgetPlan: Equatable, Codable, Sendable {
    /// Whole-month limit for living spending (fixed costs included). Normally the sum of the category limits.
    public var monthlyLimitMinorUnits: Int64
    public var categoryLimits: [CanonicalCategoryID: Int64]
    public var leftover: LeftoverPolicy
    /// Irregular spending stays out of the monthly budget unless this is on.
    public var includeIrregular: Bool

    public init(
        monthlyLimitMinorUnits: Int64, categoryLimits: [CanonicalCategoryID: Int64] = [:], leftover: LeftoverPolicy = .sweepToReserve, includeIrregular: Bool = false
    ) {
        self.monthlyLimitMinorUnits = monthlyLimitMinorUnits
        self.categoryLimits = categoryLimits
        self.leftover = leftover
        self.includeIrregular = includeIrregular
    }

    /// Budget set per category; the total is their sum.
    public init(categoryLimits: [CanonicalCategoryID: Int64], leftover: LeftoverPolicy = .sweepToReserve, includeIrregular: Bool = false) {
        self.init(
            monthlyLimitMinorUnits: categoryLimits.values.reduce(0, +), categoryLimits: categoryLimits, leftover: leftover, includeIrregular: includeIrregular
        )
    }
}

public enum SpendPace: String, Sendable {
    /// Under 0.9 of the expected spending so far.
    case relaxed
    case onTrack
    /// Over 1.1.
    case fast
    /// The variable budget is already used up.
    case over
}

public struct CategoryBudgetStatus: Equatable, Sendable {
    public let category: CanonicalCategoryID
    public let limitMinorUnits: Int64
    public let spentMinorUnits: Int64
    public var remainingMinorUnits: Int64 { limitMinorUnits - spentMinorUnits }
    public var isOver: Bool { spentMinorUnits > limitMinorUnits }
}

public struct BudgetStatus: Equatable, Sendable {
    public let limitMinorUnits: Int64
    public let spentMinorUnits: Int64
    /// Already deducted friends' shares not yet paid back ("정산 대기 중").
    public let pendingMinorUnits: Int64
    /// Confirmed fixed-cycle costs of the month, and how much of them has already gone out.
    public let fixedBudgetMinorUnits: Int64
    public let fixedSpentMinorUnits: Int64
    public var upcomingFixedMinorUnits: Int64 { max(fixedBudgetMinorUnits - fixedSpentMinorUnits, 0) }
    public let variableBudgetMinorUnits: Int64
    public let variableSpentMinorUnits: Int64
    public var remainingVariableMinorUnits: Int64 { variableBudgetMinorUnits - variableSpentMinorUnits }
    public let daysLeft: Int
    /// Rounded toward zero; 0 once the variable budget is used up.
    public let perDayMinorUnits: Int64
    /// Spent share over the share of the month gone. `nil` before the first full day or without a variable budget.
    public let paceRatio: Double?
    public let pace: SpendPace?
    public let categories: [CategoryBudgetStatus]
    /// Month limit not given to any category.
    public let unassignedMinorUnits: Int64
}

public enum MonthlyBudget {
    /// `today`: the day being looked at (clamped into the period). Days before it are "gone", today and later are "left".
    /// `fixedMonthlyMinorUnits`: the monthly-equivalent total of confirmed recurring series.
    /// `excluding`: transactions another budget (a period budget) owns; they do not count here.
    public static func status(
        _ rows: [AnalysisTransaction], plan: BudgetPlan, period: AnalysisPeriod, today: LocalDate, fixedMonthlyMinorUnits: Int64 = 0,
        excluding: Set<String> = []
    ) -> BudgetStatus {
        let counted = SpendingAnalysis.inPeriod(rows, period).filter { !excluding.contains($0.id) && (plan.includeIrregular || !$0.isIrregular) }
        let spent = counted.reduce(Int64(0)) { $0 + $1.shareMinorUnits }
        let fixedSpent = counted.filter(\.isRecurring).reduce(Int64(0)) { $0 + $1.shareMinorUnits }
        let variableSpent = spent - fixedSpent
        let variableBudget = max(plan.monthlyLimitMinorUnits - fixedMonthlyMinorUnits, 0)
        let day = min(max(today, period.first), period.last)
        let elapsed = day.daysSinceUnixEpoch - period.first.daysSinceUnixEpoch
        let daysLeft = period.dayCount - elapsed
        let remaining = variableBudget - variableSpent

        var ratio: Double?
        var pace: SpendPace?
        if variableBudget > 0, elapsed > 0 {
            let expected = Double(variableBudget) * Double(elapsed) / Double(period.dayCount)
            ratio = Double(variableSpent) / expected
            pace = remaining < 0 ? .over : (ratio! < 0.9 ? .relaxed : (ratio! <= 1.1 ? .onTrack : .fast))
        }

        var perCategory: [CanonicalCategoryID: Int64] = [:]
        for row in counted { if let category = row.category { perCategory[category, default: 0] += row.shareMinorUnits } }
        let categories = plan.categoryLimits.map { CategoryBudgetStatus(category: $0.key, limitMinorUnits: $0.value, spentMinorUnits: perCategory[$0.key] ?? 0) }
            .sorted { $0.category < $1.category }

        return BudgetStatus(
            limitMinorUnits: plan.monthlyLimitMinorUnits, spentMinorUnits: spent, pendingMinorUnits: counted.reduce(0) { $0 + $1.pendingMinorUnits },
            fixedBudgetMinorUnits: fixedMonthlyMinorUnits, fixedSpentMinorUnits: fixedSpent,
            variableBudgetMinorUnits: variableBudget, variableSpentMinorUnits: variableSpent, daysLeft: daysLeft,
            perDayMinorUnits: daysLeft > 0 ? max(remaining, 0) / Int64(daysLeft) : 0, paceRatio: ratio, pace: pace, categories: categories,
            unassignedMinorUnits: plan.monthlyLimitMinorUnits - plan.categoryLimits.values.reduce(0, +)
        )
    }

    /// What closing a month does to the next month. Overspending (negative leftover) is never carried forward.
    public static func close(_ status: BudgetStatus, plan: BudgetPlan) -> (nextCategoryLimits: [CanonicalCategoryID: Int64], reserveAdded: Int64) {
        var next = plan.categoryLimits, reserve: Int64 = 0
        for category in status.categories where category.remainingMinorUnits > 0 {
            switch plan.leftover {
            case .sweepToReserve: reserve += category.remainingMinorUnits
            case .carrySameCategory: next[category.category, default: 0] += category.remainingMinorUnits
            case .none: break
            }
        }
        return (next, reserve)
    }
}
