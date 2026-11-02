import Testing
import NEOBudgetCalendar

private func d(_ month: Int, _ day: Int, year: Int = 2027) -> LocalDate {
    (try? LocalDate(year: year, month: month, day: day)) ?? { fatalError("date") }()
}
private func november() -> AnalysisPeriod { (try? AnalysisPeriod.month(year: 2027, month: 11)) ?? { fatalError("period") }() }
private func cat(_ id: String) -> CanonicalCategoryID { CanonicalCategoryID(rawValue: id) }
private func tx(
    _ id: String, _ date: LocalDate, _ share: Int64, pending: Int64 = 0, category: String? = nil, tags: Set<String> = [], activity: AnalysisActivity? = nil,
    recurring: Bool = false, irregular: Bool = false
) -> AnalysisTransaction {
    AnalysisTransaction(
        id: id, date: date, shareMinorUnits: share, pendingMinorUnits: pending, category: category.map(cat), tags: tags, activity: activity,
        isRecurring: recurring, isIrregular: irregular
    )
}

// MARK: Monthly budget (records/20261102-분석-예산-탭-설계.md example 1)

@Test func perDayBudgetTakesUpcomingFixedCostsOutFirst() {
    // 700,000 budget, 210,000 fixed a month, of which 100,000 already went out. 150,000 variable spent by the 10th; looked at on the 11th.
    let rows = [tx("rent", d(11, 1), 100_000, recurring: true), tx("a", d(11, 4), 130_000), tx("b", d(11, 9), 20_000, pending: 20_000)]
    let status = MonthlyBudget.status(rows, plan: BudgetPlan(monthlyLimitMinorUnits: 700_000), period: november(), today: d(11, 11), fixedMonthlyMinorUnits: 210_000)
    #expect(status.spentMinorUnits == 250_000 && status.pendingMinorUnits == 20_000)
    #expect(status.variableBudgetMinorUnits == 490_000 && status.variableSpentMinorUnits == 150_000)
    #expect(status.remainingVariableMinorUnits == 340_000 && status.upcomingFixedMinorUnits == 110_000)
    #expect(status.daysLeft == 20 && status.perDayMinorUnits == 17_000)
    #expect(status.pace == .onTrack)                      // expected 163,333 so far, spent 150,000 → 0.92
}

@Test func paceBandsAndOverspending() {
    let plan = BudgetPlan(monthlyLimitMinorUnits: 300_000)
    func pace(_ spent: Int64, day: Int = 11) -> SpendPace? {
        MonthlyBudget.status([tx("x", d(11, 2), spent)], plan: plan, period: november(), today: d(11, day)).pace
    }
    #expect(pace(80_000) == .relaxed)        // expected 100,000 → 0.8
    #expect(pace(100_000) == .onTrack)
    #expect(pace(130_000) == .fast)
    #expect(pace(310_000, day: 20) == .over)
    #expect(MonthlyBudget.status([], plan: plan, period: november(), today: d(11, 1)).pace == nil)   // nothing gone yet
}

@Test func irregularAndPeriodBudgetSpendingStayOutOfTheMonth() {
    let trip = PeriodBudget(
        id: "trip", name: "여행", amountMinorUnits: 1_200_000, first: d(1, 1), last: d(12, 31), scope: PeriodBudgetScope(tags: ["여행"])
    )
    let rows = [tx("phone", d(11, 3), 900_000, irregular: true), tx("jeju", d(11, 5), 400_000, tags: ["여행"]), tx("lunch", d(11, 6), 12_000)]
    let owned = PeriodBudget.ownedIDs([trip], rows: rows)
    #expect(owned == ["jeju"])
    let status = MonthlyBudget.status(rows, plan: BudgetPlan(monthlyLimitMinorUnits: 700_000), period: november(), today: d(11, 7), excluding: owned)
    #expect(status.spentMinorUnits == 12_000)
    // the month counts it too when the user asks for it
    var both = trip
    both.alsoCountInMonthly = true
    #expect(PeriodBudget.ownedIDs([both], rows: rows).isEmpty)
}

@Test func categoryLimitsAndUnassignedMoney() {
    let plan = BudgetPlan(monthlyLimitMinorUnits: 700_000, categoryLimits: [cat("food"): 250_000, cat("cafe"): 60_000, cat("transit"): 80_000])
    let rows = [tx("a", d(11, 2), 180_000, category: "food"), tx("b", d(11, 3), 62_000, category: "cafe"), tx("c", d(11, 4), 5_000)]
    let status = MonthlyBudget.status(rows, plan: plan, period: november(), today: d(11, 5))
    #expect(status.unassignedMinorUnits == 310_000)
    #expect(status.categories.first { $0.category == cat("cafe") }?.isOver == true)
    #expect(status.categories.first { $0.category == cat("cafe") }?.remainingMinorUnits == -2_000)
    #expect(status.spentMinorUnits == 247_000)             // uncategorized spending still counts toward the whole
}

@Test func closingTheMonthFollowsTheLeftoverPolicy() {
    func close(_ policy: LeftoverPolicy) -> (next: Int64, reserve: Int64) {
        let plan = BudgetPlan(categoryLimits: [cat("food"): 250_000, cat("cafe"): 60_000], leftover: policy)
        let status = MonthlyBudget.status([tx("a", d(11, 2), 180_000, category: "food"), tx("b", d(11, 3), 70_000, category: "cafe")], plan: plan, period: november(), today: d(11, 30))
        let result = MonthlyBudget.close(status, plan: plan)
        return (result.nextCategoryLimits[cat("food")] ?? 0, result.reserveAdded)
    }
    #expect(close(.sweepToReserve) == (250_000, 70_000))    // cafe overspent: nothing carried
    #expect(close(.carrySameCategory) == (320_000, 0))
    #expect(close(.none) == (250_000, 0))
}

@Test func aMonthCanStartOnSalaryDay() throws {
    let period = try AnalysisPeriod.month(year: 2027, month: 11, startDay: 25)
    #expect(period.first == d(11, 25) && period.last == d(12, 24))
}

// MARK: Period budgets (examples 1–2 of §12.2)

@Test func trackingBudgetShowsSpentAgainstTheWholeAmount() {
    let trip = PeriodBudget(id: "t", name: "여행", amountMinorUnits: 1_200_000, first: d(1, 1), last: d(12, 31), scope: PeriodBudgetScope(tags: ["여행"]))
    let rows = [tx("jeju", d(3, 10), 400_000, tags: ["여행"]), tx("japan", d(7, 20), 700_000, tags: ["여행"]), tx("food", d(7, 21), 9_000)]
    let progress = trip.progress(rows, today: d(8, 5))
    #expect(progress.spentMinorUnits == 1_100_000 && progress.remainingMinorUnits == 100_000)
    #expect((progress.paceRatio ?? 0) > 1.4)                // 92% used, about 60% of the year gone
}

@Test func accruingBudgetBuildsUpMonthByMonth() {
    let reserve = PeriodBudget(
        id: "r", name: "비정기", amountMinorUnits: 2_400_000, first: d(1, 1), last: d(12, 31), scope: PeriodBudgetScope(categories: [cat("gadget")]), mode: .accrue
    )
    let rows = [tx("phone", d(3, 3), 900_000, category: "gadget")]
    #expect(reserve.progress(rows, today: d(3, 31)).remainingMinorUnits == -300_000)
    #expect(reserve.progress(rows, today: d(12, 31)).remainingMinorUnits == 1_500_000)
}

@Test func activityScopeFollowsTheCalendar() {
    let event = AnalysisActivity(id: ActivityID(rawValue: "jeju-1"), title: "제주", headcount: 2, participants: [])
    let budget = PeriodBudget(id: "j", name: "제주", amountMinorUnits: 500_000, first: d(1, 1), last: d(12, 31), scope: PeriodBudgetScope(activities: [event.id]))
    #expect(budget.progress([tx("a", d(5, 1), 80_000, activity: event), tx("b", d(5, 1), 9_000)], today: d(5, 2)).spentMinorUnits == 80_000)
}

// MARK: Consumption date (§12.4)

@Test func earlyMorningPaymentCountsForTheDayBefore() {
    #expect(ConsumptionDate.resolve(date: d(11, 2), minuteOfDay: 90) == d(11, 1))      // 01:30
    #expect(ConsumptionDate.resolve(date: d(11, 2), minuteOfDay: 120) == d(11, 2))     // 02:00 is the new day
    #expect(ConsumptionDate.resolve(date: d(11, 2), minuteOfDay: nil) == d(11, 2))
    #expect(ConsumptionDate.resolve(date: d(11, 2), minuteOfDay: 90, rule: ConsumptionDateRule(cutoffMinutes: 0)) == d(11, 2))
    #expect(ConsumptionDate.resolve(date: d(12, 1), minuteOfDay: 30) == d(11, 30))     // month end
}

@Test func paymentsInAnOvernightEventCountOnItsStartDay() {
    let party = OvernightEvent(startDate: d(11, 1), endDate: d(11, 2), durationMinutes: 8 * 60, isAllDay: false)
    #expect(ConsumptionDate.resolve(date: d(11, 2), minuteOfDay: 3 * 60 + 10, event: party) == d(11, 1))   // taxi at 03:10
    #expect(ConsumptionDate.resolve(date: d(11, 2), minuteOfDay: 5 * 60, event: party) == d(11, 1))        // after the cutoff, still the party
    let trip = OvernightEvent(startDate: d(11, 1), endDate: d(11, 3), durationMinutes: 40 * 60, isAllDay: false)
    #expect(ConsumptionDate.resolve(date: d(11, 2), minuteOfDay: 14 * 60, event: trip) == d(11, 2))        // long event: own day
    let allDay = OvernightEvent(startDate: d(11, 1), endDate: d(11, 2), durationMinutes: 24 * 60, isAllDay: true)
    #expect(ConsumptionDate.resolve(date: d(11, 2), minuteOfDay: 10 * 60, event: allDay) == d(11, 2))
}

// MARK: Pace alert (§12.3)

@Test func paceAlertWaitsForEnoughDaysAndRealSpending() {
    let state = SpendPaceAlertState()
    func run(spent: Int64, elapsed: Int, minute: Int = 12 * 60) -> SpendPaceAlert? {
        SpendPaceAlerts.evaluate(budgetMinorUnits: 490_000, spentMinorUnits: spent, elapsedDays: elapsed, periodDays: 30, state: state, today: d(11, 13), minuteOfDay: minute).alert
    }
    let alert = run(spent: 280_000, elapsed: 12)
    #expect(alert?.projectedMinorUnits == 700_000 && alert?.overMinorUnits == 210_000)
    #expect(run(spent: 90_000, elapsed: 3) == nil)                    // fewer than 4 days
    #expect(run(spent: 60_000, elapsed: 5) == nil)                    // under 15% of the budget
    #expect(run(spent: 220_000, elapsed: 12) == nil)                  // 1.12× — not fast enough
    #expect(run(spent: 280_000, elapsed: 12, minute: 22 * 60) == nil) // quiet hours
}

@Test func paceAlertsEscalateAndAreCapped() {
    var state = SpendPaceAlertState()
    func run(spent: Int64, elapsed: Int, day: Int) -> SpendPaceAlert? {
        let result = SpendPaceAlerts.evaluate(budgetMinorUnits: 490_000, spentMinorUnits: spent, elapsedDays: elapsed, periodDays: 30, state: state, today: d(11, day), minuteOfDay: 12 * 60)
        state = result.state
        return result.alert
    }
    #expect(run(spent: 280_000, elapsed: 12, day: 13) != nil)
    #expect(run(spent: 290_000, elapsed: 12, day: 13) == nil)         // once a day
    #expect(run(spent: 300_000, elapsed: 13, day: 14) == nil)         // not worse enough than 1.43
    #expect(run(spent: 380_000, elapsed: 13, day: 14) != nil)         // 1.79× is 0.3 worse than 1.43×
    #expect(run(spent: 560_000, elapsed: 15, day: 16) != nil)         // 2.29× is 0.4 worse than 1.79×
    #expect(run(spent: 490_000, elapsed: 20, day: 21) == nil)         // already three alerts this period
}
