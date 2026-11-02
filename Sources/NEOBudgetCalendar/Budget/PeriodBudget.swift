import Foundation

// A budget over a long span that is not tied to the month (a year of trips, gifts). Tracking only: no money moves.
// By default what it counts is kept out of the monthly living budget (docs: records/20261102-분석-예산-탭-설계.md §12.2, §13).

public enum PeriodBudgetMode: String, Codable, Sendable {
    /// Just the span's total against what was spent.
    case track
    /// The total builds up evenly month by month and the balance is accrued minus spent (the old "비정기 봉투").
    case accrue
}

public struct PeriodBudgetScope: Equatable, Codable, Sendable {
    public var categories: Set<CanonicalCategoryID>
    public var tags: Set<String>
    /// Spending tied to these calendar activities (a trip's events).
    public var activities: Set<ActivityID>

    public init(categories: Set<CanonicalCategoryID> = [], tags: Set<String> = [], activities: Set<ActivityID> = []) {
        self.categories = categories
        self.tags = tags
        self.activities = activities
    }
}

public struct PeriodBudgetProgress: Equatable, Sendable {
    public let spentMinorUnits: Int64
    /// `track`: the whole amount. `accrue`: what has built up so far.
    public let availableMinorUnits: Int64
    public var remainingMinorUnits: Int64 { availableMinorUnits - spentMinorUnits }
    /// Spent share of the whole amount over the share of the span gone. `nil` before the first full day.
    public let paceRatio: Double?
}

public struct PeriodBudget: Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var amountMinorUnits: Int64
    public var first: LocalDate
    public var last: LocalDate
    public var scope: PeriodBudgetScope
    public var mode: PeriodBudgetMode
    /// Off by default: what this budget counts is not counted again in the monthly budget.
    public var alsoCountInMonthly: Bool

    public init(
        id: String, name: String, amountMinorUnits: Int64, first: LocalDate, last: LocalDate, scope: PeriodBudgetScope,
        mode: PeriodBudgetMode = .track, alsoCountInMonthly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.amountMinorUnits = amountMinorUnits
        self.first = first
        self.last = last
        self.scope = scope
        self.mode = mode
        self.alsoCountInMonthly = alsoCountInMonthly
    }

    public func matches(_ row: AnalysisTransaction) -> Bool {
        guard row.date >= first, row.date <= last else { return false }
        if let category = row.category, scope.categories.contains(category) { return true }
        if !scope.tags.isDisjoint(with: row.tags) { return true }
        if let activity = row.activity, scope.activities.contains(activity.id) { return true }
        return false
    }

    public func progress(_ rows: [AnalysisTransaction], today: LocalDate) -> PeriodBudgetProgress {
        let spent = rows.filter(matches).reduce(Int64(0)) { $0 + $1.shareMinorUnits }
        let day = min(max(today, first), last)
        let totalDays = last.daysSinceUnixEpoch - first.daysSinceUnixEpoch + 1
        let elapsed = day.daysSinceUnixEpoch - first.daysSinceUnixEpoch
        let available: Int64
        switch mode {
        case .track: available = amountMinorUnits
        case .accrue:
            func index(_ date: LocalDate) -> Int { date.year * 12 + date.month }
            let months = index(last) - index(first) + 1, reached = index(day) - index(first) + 1
            available = reached >= months ? amountMinorUnits : amountMinorUnits * Int64(reached) / Int64(months)
        }
        let ratio: Double? = elapsed > 0 && amountMinorUnits > 0
            ? (Double(spent) / Double(amountMinorUnits)) / (Double(elapsed) / Double(totalDays)) : nil
        return PeriodBudgetProgress(spentMinorUnits: spent, availableMinorUnits: available, paceRatio: ratio)
    }

    /// Transactions that belong only to period budgets, to hand to `MonthlyBudget.status(excluding:)`.
    public static func ownedIDs(_ budgets: [PeriodBudget], rows: [AnalysisTransaction]) -> Set<String> {
        let separate = budgets.filter { !$0.alsoCountInMonthly }
        return Set(rows.filter { row in separate.contains { $0.matches(row) } }.map(\.id))
    }
}
