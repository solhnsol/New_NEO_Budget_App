import Testing
import NEOBudgetCalendar

private func d(_ month: Int, _ day: Int, year: Int = 2027) -> LocalDate {
    (try? LocalDate(year: year, month: month, day: day)) ?? { fatalError("date") }()
}
private func period(_ month: Int) -> AnalysisPeriod { (try? AnalysisPeriod.month(year: 2027, month: month)) ?? { fatalError("period") }() }
private func person(_ id: String) -> PersonID { PersonID(rawValue: id) }
private func dinner(_ id: String, head: Int = 3, people: [String] = ["min", "ji"], title: String = "저녁") -> AnalysisActivity {
    AnalysisActivity(id: ActivityID(rawValue: id), title: title, headcount: head, participants: people.map(person))
}
private func tx(
    _ id: String, _ date: LocalDate, _ share: Int64, pending: Int64 = 0, category: String? = nil, tags: Set<String> = [],
    activity: AnalysisActivity? = nil, recurring: Bool = false
) -> AnalysisTransaction {
    AnalysisTransaction(
        id: id, date: date, shareMinorUnits: share, pendingMinorUnits: pending, category: category.map { CanonicalCategoryID(rawValue: $0) },
        tags: tags, activity: activity, isRecurring: recurring
    )
}

@Test func summaryUsesMyShareAndKeepsThePendingPartApart() {
    // 60,000 dinner for three: 20,000 is mine, 20,000 already paid back, 20,000 still expected.
    let rows = [tx("din", d(10, 3), 20_000, pending: 20_000), tx("cafe", d(10, 5), 4_000), tx("rent", d(10, 25), 400_000, recurring: true)]
    let summary = SpendingAnalysis.summary(rows, in: period(10), through: d(10, 30))
    #expect(summary.totalMinorUnits == 424_000)
    #expect(summary.pendingMinorUnits == 20_000)
    #expect(summary.recurringMinorUnits == 400_000 && summary.oneOffMinorUnits == 24_000)
    #expect(summary.medianMinorUnits == 20_000 && summary.averageMinorUnits == 141_333)
    #expect(summary.dailyAverageMinorUnits == 14_133)     // over 30 days, days without spending included
}

@Test func dailyAverageOfAMonthInProgressStopsAtToday() {
    let summary = SpendingAnalysis.summary([tx("a", d(10, 1), 10_000)], in: period(10), through: d(10, 10))
    #expect(summary.dailyAverageMinorUnits == 1_000)
}

@Test func categoriesAreSortedAndUncategorizedIsItsOwnGroup() {
    let rows = [tx("a", d(10, 1), 5_000, category: "food"), tx("b", d(10, 2), 7_000, category: "food"), tx("c", d(10, 2), 3_000), tx("old", d(9, 30), 99_000, category: "food")]
    let groups = SpendingAnalysis.byCategory(rows, in: period(10))
    #expect(groups.map(\.key?.rawValue) == ["food", nil])
    #expect(groups[0].totalMinorUnits == 12_000 && groups[0].count == 2 && groups[0].averageMinorUnits == 6_000)
}

@Test func aTransactionWithTwoTagsCountsInBoth() {
    let rows = [tx("a", d(10, 1), 10_000, tags: ["데이트", "모임"]), tx("b", d(10, 2), 2_000, tags: ["모임"]), tx("c", d(10, 3), 500)]
    let groups = SpendingAnalysis.byTag(rows, in: period(10))
    #expect(groups.map(\.key) == ["모임", "데이트", nil])
    #expect(groups.map(\.totalMinorUnits) == [12_000, 10_000, 500])
}

@Test func repeatingActivitiesGroupByTitleAndPeopleAreNotDivided() {
    let rows = [
        tx("1", d(10, 4), 10_000, activity: dinner("s1", head: 3, title: "스터디")), tx("2", d(10, 4), 2_000, activity: dinner("s1", head: 3, title: "스터디")),
        tx("3", d(10, 11), 14_000, activity: dinner("s2", head: 2, people: ["min"], title: "스터디 ")), tx("4", d(10, 12), 9_000, activity: dinner("solo", head: 1, people: [], title: "독서")),
    ]
    let groups = SpendingAnalysis.byActivity(rows, in: period(10))
    #expect(groups.map(\.title) == ["스터디", "독서"])
    #expect(groups[0].occurrences == 2 && groups[0].totalMinorUnits == 26_000 && groups[0].perOccurrenceMinorUnits == 13_000)
    #expect(groups[1].isGathering == false)
    let people = SpendingAnalysis.byPerson(rows, in: period(10))
    #expect(people.map(\.personID.rawValue) == ["min", "ji"])
    #expect(people[0].totalMinorUnits == 26_000 && people[0].activityCount == 2 && people[1].totalMinorUnits == 12_000)
    let gatherings = SpendingAnalysis.gatherings(rows, in: period(10))
    #expect(gatherings.count == 2 && gatherings.totalMinorUnits == 26_000 && gatherings.perGatheringMinorUnits == 13_000 && gatherings.perPersonMinorUnits == 5_200)
}

@Test func comparesWithTheSameNumberOfDaysLastMonth() throws {
    let rows = [tx("s1", d(9, 5), 10_000), tx("s2", d(9, 20), 90_000), tx("o1", d(10, 4), 12_000)]
    let result = try SpendingAnalysis.versusEarlier(rows, period: period(10), through: d(10, 10))
    #expect(result.current == 12_000 && result.earlier == 10_000)     // 9/1–9/10, not the 90,000 on 9/20
}

@Test func aSalaryDayMonthRunsFromThatDayToTheDayBeforeTheNext() throws {
    let p = try AnalysisPeriod.month(year: 2027, month: 12, startDay: 25)
    #expect(p.first == d(12, 25) && p.last == d(1, 24, year: 2028) && p.dayCount == 31)
}

// MARK: recurring

private func input(_ id: String, _ name: String, _ date: LocalDate, _ won: Int64) -> RecurringInput { .init(id: id, name: name, date: date, amountMinorUnits: won) }

@Test func monthlySameAmountIsSuggestedAndNextDueIsNextMonth() {
    let rows = (1...4).map { input("n\($0)", "넷플릭스 \($0)", d($0 + 6, 15), 17_000) }   // 7/15 … 10/15
    let found = RecurringDetector.suggestions(rows)
    #expect(found.count == 1)
    #expect(found[0].cycle == .monthly && found[0].expectedMinorUnits == 17_000 && !found[0].isVariableAmount)
    #expect(found[0].nextDue == d(11, 15))
}

@Test func aVariableBillIsRecurringButFlaggedVariable() {
    let rows = [input("a", "관리비", d(7, 10), 80_000), input("b", "관리비", d(8, 9), 120_000), input("c", "관리비", d(9, 11), 100_000)]
    let found = RecurringDetector.suggestions(rows)
    #expect(found.count == 1 && found[0].isVariableAmount && found[0].expectedMinorUnits == 100_000)
}

@Test func aHabitOnVaryingDaysIsNotRecurring() {
    let days = [1, 2, 4, 9, 10, 17, 18, 25, 28]
    let rows = days.map { input("c\($0)", "카페", d(10, $0), 4_500) }
    #expect(RecurringDetector.suggestions(rows).isEmpty)
}

@Test func twoOccurrencesNeedAHintOrAYearlyCycle() {
    #expect(RecurringDetector.suggestions([input("a", "헬스장", d(9, 1), 50_000), input("b", "헬스장", d(10, 1), 50_000)]).isEmpty)
    #expect(RecurringDetector.suggestions([input("a", "통신비", d(9, 1), 50_000), input("b", "통신비", d(10, 1), 50_000)]).count == 1)
    #expect(RecurringDetector.suggestions([input("a", "보험료", d(10, 1, year: 2026), 300_000), input("b", "보험료", d(10, 3), 300_000)]).first?.cycle == .yearly)
}

@Test func theSameShopWithVeryDifferentAmountsIsSplitIntoSeries() {
    var rows = (7...10).map { input("a\($0)", "편의점", d($0, 5), 9_900) }
    rows += [input("big1", "편의점", d(8, 20), 150_000)]
    let found = RecurringDetector.suggestions(rows)
    #expect(found.count == 1 && found[0].expectedMinorUnits == 9_900)
}

@Test func decisionsHideDismissedAndApplyConfirmedByNameAndAmount() {
    let rows = (7...10).map { input("n\($0)", "넷플릭스", d($0, 15), 17_000) }
    var decisions = RecurringDecisions()
    let series = RecurringDetector.suggestions(rows)[0]
    decisions.confirm(series)
    #expect(RecurringDetector.suggestions(rows, decisions: decisions).isEmpty)
    #expect(decisions.isRecurring(id: "x", name: "넷플릭스 1234", amountMinorUnits: 17_000))
    #expect(!decisions.isRecurring(id: "x", name: "넷플릭스", amountMinorUnits: 60_000))     // far from the usual amount
    decisions.overrides["x"] = false
    #expect(!decisions.isRecurring(id: "x", name: "넷플릭스", amountMinorUnits: 17_000))
    #expect(decisions.perMonthMinorUnits == 17_000)
    decisions.dismiss(series)
    #expect(decisions.confirmed.isEmpty && RecurringDetector.suggestions(rows, decisions: decisions).isEmpty)
}
