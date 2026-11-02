import Foundation

// What the user set for budgets, kept as one small file (docs: records/20261102-분석-예산-탭-설계.md §6, §12–13).
// Only the user's choices are saved; every number on screen is computed from the ledger when it is read.

public struct BudgetPeriodMonth: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }
    public static func < (lhs: BudgetPeriodMonth, rhs: BudgetPeriodMonth) -> Bool { (lhs.year, lhs.month) < (rhs.year, rhs.month) }
    public var key: String { "\(year)-\(month < 10 ? "0" : "")\(month)" }
}

public struct BudgetSettings: Equatable, Codable, Sendable {
    /// Day of the month the budget month starts (1–28; the salary day).
    public var startDay: Int
    /// A month that runs 11/25–12/24 is "11월" by default; on, it is named for the month it ends in.
    public var namedByEndMonth: Bool
    public var consumption: ConsumptionDateRule
    /// The only alert setting people see; the 4-day and 15% guards are fixed in `SpendPaceAlerts`.
    public var paceMultiplier: Double
    public var paceAlertsOn: Bool

    public init(
        startDay: Int = 1, namedByEndMonth: Bool = false, consumption: ConsumptionDateRule = ConsumptionDateRule(), paceMultiplier: Double = 1.3,
        paceAlertsOn: Bool = true
    ) {
        self.startDay = min(max(startDay, 1), 28)
        self.namedByEndMonth = namedByEndMonth
        self.consumption = consumption
        self.paceMultiplier = paceMultiplier
        self.paceAlertsOn = paceAlertsOn
    }

    // A file written by an older version still opens: every missing field takes its default.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            startDay: try values.decodeIfPresent(Int.self, forKey: .startDay) ?? 1, namedByEndMonth: try values.decodeIfPresent(Bool.self, forKey: .namedByEndMonth) ?? false,
            consumption: try values.decodeIfPresent(ConsumptionDateRule.self, forKey: .consumption) ?? ConsumptionDateRule(),
            paceMultiplier: try values.decodeIfPresent(Double.self, forKey: .paceMultiplier) ?? 1.3,
            paceAlertsOn: try values.decodeIfPresent(Bool.self, forKey: .paceAlertsOn) ?? true
        )
    }

    /// The days of the budget month named `month`.
    public func period(of month: BudgetPeriodMonth) throws -> AnalysisPeriod {
        if startDay > 1, namedByEndMonth {
            let previous = month.month == 1 ? BudgetPeriodMonth(year: month.year - 1, month: 12) : BudgetPeriodMonth(year: month.year, month: month.month - 1)
            return try AnalysisPeriod.month(year: previous.year, month: previous.month, startDay: startDay)
        }
        return try AnalysisPeriod.month(year: month.year, month: month.month, startDay: startDay)
    }

    /// The budget month a day belongs to.
    public func month(containing date: LocalDate) -> BudgetPeriodMonth {
        var index = date.year * 12 + (date.month - 1)
        if date.day < startDay { index -= 1 }          // before this month's start day: still in the one before
        if startDay > 1, namedByEndMonth { index += 1 }
        return BudgetPeriodMonth(year: index / 12, month: index % 12 + 1)
    }
}

public struct BudgetStore: Equatable, Codable, Sendable {
    /// A plan applies from its month until a later plan replaces it, so past months keep the budget they had.
    public private(set) var plans: [BudgetPeriodMonth: BudgetPlan]
    public var periodBudgets: [PeriodBudget]
    public var settings: BudgetSettings
    /// Alerts already sent, per budget (a month key, or a period budget id).
    public var alertStates: [String: SpendPaceAlertState]

    public init(
        plans: [BudgetPeriodMonth: BudgetPlan] = [:], periodBudgets: [PeriodBudget] = [], settings: BudgetSettings = BudgetSettings(),
        alertStates: [String: SpendPaceAlertState] = [:]
    ) {
        self.plans = plans
        self.periodBudgets = periodBudgets
        self.settings = settings
        self.alertStates = alertStates
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            plans: try values.decodeIfPresent([BudgetPeriodMonth: BudgetPlan].self, forKey: .plans) ?? [:],
            periodBudgets: try values.decodeIfPresent([PeriodBudget].self, forKey: .periodBudgets) ?? [],
            settings: try values.decodeIfPresent(BudgetSettings.self, forKey: .settings) ?? BudgetSettings(),
            alertStates: try values.decodeIfPresent([String: SpendPaceAlertState].self, forKey: .alertStates) ?? [:]
        )
    }

    /// The plan in force for `month`: the latest one starting on or before it. `nil` before any budget was set.
    public func plan(for month: BudgetPeriodMonth) -> BudgetPlan? {
        plans.filter { $0.key <= month }.max { $0.key < $1.key }?.value
    }

    /// Sets the plan from `month` on (a plan already set for that month is replaced; earlier months keep theirs).
    public mutating func setPlan(_ plan: BudgetPlan, from month: BudgetPeriodMonth) { plans[month] = plan }
}
