import Testing
import NEOBudgetCalendar
import NEOBudgetCore

@Test func aSettledPurchaseShowsTheUsersShareInEveryPlace() throws {
    let date = event("date", title: "데이트", from: at(today, 19), to: at(today, 22))
    let life = try LifeState.empty.applying([
        .createActivity(Activity.materialized(from: date, id: ActivityID(rawValue: "a-date"), at: 1)),
        wholeAllocation("t-dinner", to: "a-date", total: 60_000)
    ])
    let transactions = [
        marker("t-dinner", at: at(today, 20), amount: 60_000, title: "저녁"),
        marker("t-taxi", at: at(today, 23), amount: 10_000, title: "택시")
    ]
    let built = DayTimelineBuilder.build(DayTimelineInput(
        day: today, timeZone: seoul, calendars: defaultCalendars, events: [date], life: life, transactions: transactions, policy: .standard
    ))
    let shown = built.reducingSpend(by: [txID("t-dinner"): 30_000, txID("t-taxi"): 4_000])

    let dinner = try #require(shown.blocks.first?.allocations.first)
    #expect(dinner.transactionAmount.minorUnits == 30_000)
    #expect(dinner.allocatedAmount.knownValue == 30_000)
    #expect(shown.blocks.first?.allocatedSpend.first?.exactMinorUnits == 30_000)
    #expect(shown.markers.first?.amount.minorUnits == 6_000)
    #expect(shown.summary.totals.first?.linkedNetMinorUnits == 30_000)
    #expect(shown.summary.totals.first?.unlinkedNetMinorUnits == 6_000)
    // the ledger side is untouched
    #expect(built.markers.first?.amount.minorUnits == 10_000)

    let week = WeekStripBuilder.build(
        containing: today, timeZone: seoul, events: [date], life: life, transactions: transactions,
        reductions: [txID("t-dinner"): 30_000, txID("t-taxi"): 4_000]
    )
    #expect(week.first { $0.day == today }?.netSpend.first?.minorUnits == 36_000)
}
