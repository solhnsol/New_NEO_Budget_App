import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private func week(_ events: [CalendarEvent]) -> [WeekStripDay] {
    WeekStripBuilder.build(containing: day(2026, 10, 7), firstWeekday: 0, timeZone: seoul, events: events, life: .empty, transactions: [])
}

@Test func aMultiDayEventIsOneBarAndShortOnesStackUnderIt() {
    let layout = MonthWeekLayout(week: week([
        allDayEvent("trip", title: "학회", from: day(2026, 10, 5), to: day(2026, 10, 7)),
        event("a", title: "점심", from: at(day(2026, 10, 6), 12), to: at(day(2026, 10, 6), 13))
    ]))
    #expect(layout.bars.map(\.event.title) == ["학회", "점심"])
    #expect(layout.bars.map(\.lane) == [0, 1])
    #expect(layout.bars[0].firstColumn == 1 && layout.bars[0].lastColumn == 3)
    #expect(layout.bars[1].firstColumn == 2 && layout.bars[1].lastColumn == 2)
    #expect(layout.overflow.flatMap { $0 }.isEmpty)
}

@Test func whatDoesNotFitInTwoLanesBecomesOverflowOnItsDays() {
    let events = (1...3).map { event("e\($0)", title: "일정\($0)", from: at(day(2026, 10, 7), 8 + $0), to: at(day(2026, 10, 7), 9 + $0)) }
    let layout = MonthWeekLayout(week: week(events))
    #expect(layout.bars.count == 2)
    #expect(layout.overflow[3].map(\.title) == ["일정3"])
    #expect(layout.overflow[2].isEmpty)
}

@Test func aLaneIsReusedAfterItsEventEnds() {
    let layout = MonthWeekLayout(week: week([
        event("a", title: "월", from: at(day(2026, 10, 5), 9), to: at(day(2026, 10, 5), 10)),
        event("b", title: "수", from: at(day(2026, 10, 7), 9), to: at(day(2026, 10, 7), 10))
    ]))
    #expect(layout.bars.map(\.lane) == [0, 0])
}
