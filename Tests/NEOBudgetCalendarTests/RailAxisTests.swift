import Testing
@testable import NEOBudgetCalendar

@Test func railAxisGivesEveryTransactionItsRoomAndShrinksEmptyHours() {
    let axis = RailAxis(events: [], transactions: [600, 610, 900], now: nil, firstMinute: 540, lastMinute: 960)
    #expect(axis.y(610) - axis.y(600) >= 46)
    // 540→600 has no transaction at its start, so it is the lazy 0.35 pt/min up to the 46 pt a transaction needs.
    #expect(axis.y(600) == max(46, 60 * 0.35))
    #expect(axis.y(0) == 0 && axis.y(5000) == axis.height)
}

@Test func railAxisPastEventsAndCardsReserveTheirOwnRoom() {
    let axis = RailAxis(events: [.init(start: 600, end: 720, isCard: false), .init(start: 900, end: 905, isCard: true)], transactions: [], now: 780, firstMinute: 540, lastMinute: 1000)
    #expect(axis.y(600) - axis.y(540) >= 28)
    #expect(axis.y(905) - axis.y(900) >= 56)
    #expect(axis.y(720) < axis.y(780) && axis.y(780) < axis.y(900))
}

@Test func railAxisHourMarksSkipCrowdedHoursAndHourRangePadsTheContent() {
    let axis = RailAxis(events: [], transactions: [], now: nil, firstMinute: 0, lastMinute: 24 * 60)
    let marks = axis.hourMarks()
    #expect(marks.first?.hour == 0 && marks.count == 24)
    let crowded = RailAxis(events: [], transactions: [], now: nil, firstMinute: 0, lastMinute: 60, needs: { var n = RailAxis.Needs(); n.emptyPointsPerMinute = 0.1; return n }())
    #expect(crowded.hourMarks().map(\.hour) == [0])
    let empty = RailAxis.hourRange(covering: []), padded = RailAxis.hourRange(covering: [610, 700])
    #expect(empty.first == 540 && empty.last == 1080)
    #expect(padded.first == 540 && padded.last == 780)
}

@Test func railAxisStretchesForRowsSharingAMinuteAndForAPastEventsName() {
    // Three rows at 17:43 stack 38 apart: the next thing after them (a name under an event begun at 19:00) is still below the last row.
    let axis = RailAxis(
        events: [.init(start: 19 * 60, end: 20 * 60, isCard: false)], transactions: [17 * 60 + 43, 17 * 60 + 43, 17 * 60 + 43],
        now: nil, firstMinute: 17 * 60, lastMinute: 21 * 60
    )
    let lastRow = axis.y(17 * 60 + 43) + 2 * 38
    #expect(axis.y(19 * 60) >= lastRow + 18)
    #expect(axis.y(19 * 60 + 1) - axis.y(19 * 60) >= 22)
}

@Test func aRowAtTheMinuteAPastEventBeganStandsUnderItsName() {
    let axis = RailAxis(
        events: [.init(start: 10 * 60, end: 11 * 60, isCard: false)], transactions: [10 * 60],
        now: nil, firstMinute: 9 * 60, lastMinute: 12 * 60
    )
    // The name is 22 high under the start, then the row (38): the next minute is at least that far on.
    #expect(axis.y(10 * 60 + 1) - axis.y(10 * 60) >= 22 + 38)
}

@Test func theEventGoingOnNowIsDrawnInItsTrueProportion() {
    // 09:00-11:00 at 10:05: about 54% of it is behind. With a name room under the start it used to look 75% done.
    let axis = RailAxis(
        events: [.init(start: 9 * 60, end: 11 * 60, isCard: false)], transactions: [],
        now: 10 * 60 + 5, firstMinute: 8 * 60, lastMinute: 12 * 60
    )
    let share = (axis.y(10 * 60 + 5) - axis.y(9 * 60)) / (axis.y(11 * 60) - axis.y(9 * 60))
    #expect(abs(share - 65.0 / 120.0) < 0.02)
}
