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

@Test func railAxisStretchesASharedMinuteSoEveryRowKeepsItsRealMinute() {
    let axis = RailAxis(events: [], transactions: [1063, 1063, 1063, 1100], now: 1067, firstMinute: 1000, lastMinute: 1200)
    #expect(axis.y(1064) - axis.y(1063) >= 2 * 28 + 46)
    #expect(axis.y(1067) > axis.y(1064))
}
