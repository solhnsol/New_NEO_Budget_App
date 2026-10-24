import Foundation
import Testing
import NEOBudgetCalendar

@Test func localDateRejectsImpossibleDates() {
    #expect(throws: CalendarValidationError.self) { try LocalDate(year: 2026, month: 2, day: 29) }
    #expect(throws: CalendarValidationError.self) { try LocalDate(year: 2026, month: 13, day: 1) }
    #expect(throws: CalendarValidationError.self) { try LocalDate(year: 2026, month: 4, day: 31) }
    #expect(throws: CalendarValidationError.self) { try LocalDate(year: 2026, month: 1, day: 0) }
    #expect((try? LocalDate(year: 2028, month: 2, day: 29)) != nil)
    #expect((try? LocalDate(year: 2100, month: 2, day: 29)) == nil)
    #expect((try? LocalDate(year: 2000, month: 2, day: 29)) != nil)
}

@Test func localDateEpochArithmeticRoundTrips() throws {
    #expect(day(1970, 1, 1).daysSinceUnixEpoch == 0)
    #expect(day(1969, 12, 31).daysSinceUnixEpoch == -1)
    #expect(day(2026, 10, 7).adding(days: 25) == day(2026, 11, 1))
    #expect(day(2026, 12, 31).adding(days: 1) == day(2027, 1, 1))
    #expect(day(2028, 2, 28).adding(days: 1) == day(2028, 2, 29))
    #expect(day(2026, 3, 1).adding(days: -1) == day(2026, 2, 28))
    for offset in stride(from: -40_000, through: 40_000, by: 997) {
        let date = LocalDate(daysSinceUnixEpoch: offset)
        #expect(date.daysSinceUnixEpoch == offset)
        #expect((try? LocalDate(year: date.year, month: date.month, day: date.day)) == date)
    }
}

@Test func localDateWeekdayUsesSundayAsZero() {
    #expect(day(1970, 1, 1).weekday == 4)   // Thursday
    #expect(day(2026, 10, 7).weekday == 3)  // Wednesday
    #expect(day(2026, 10, 4).weekday == 0)  // Sunday
    #expect(day(2026, 10, 10).weekday == 6) // Saturday
    #expect(day(1969, 12, 28).weekday == 0) // Sunday, before the epoch
}

@Test func localDateOrdersChronologicallyAndDecodesWithValidation() throws {
    #expect(day(2026, 1, 31) < day(2026, 2, 1))
    #expect(day(2025, 12, 31) < day(2026, 1, 1))
    let data = try JSONEncoder().encode(day(2026, 10, 7))
    #expect(try JSONDecoder().decode(LocalDate.self, from: data) == day(2026, 10, 7))
    let bad = Data(#"{"year":2026,"month":2,"day":30}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(LocalDate.self, from: bad) }
}

@Test func displayTimeZoneRejectsUnknownIdentifiers() {
    #expect(throws: CalendarValidationError.self) { try DisplayTimeZone(identifier: "Not/AZone") }
    #expect(throws: CalendarValidationError.self) { try DisplayTimeZone(identifier: "") }
}

@Test func seoulDayBoundsAreExactlyTwentyFourHours() {
    let bounds = seoul.dayBounds(day(2026, 10, 5))
    // 2026-10-05T00:00+09:00 == 2026-10-04T15:00Z
    #expect(bounds.start == 1_791_126_000_000)
    #expect(bounds.end - bounds.start == 86_400_000)
    #expect(seoul.localDate(of: bounds.start) == day(2026, 10, 5))
    #expect(seoul.localDate(of: bounds.end - 1) == day(2026, 10, 5))
    #expect(seoul.localDate(of: bounds.end) == day(2026, 10, 6))
}

@Test func daylightSavingDaysAreTwentyThreeAndTwentyFiveHours() {
    let springForward = newYork.dayBounds(day(2026, 3, 8))
    #expect(springForward.end - springForward.start == 23 * 3_600_000)
    let fallBack = newYork.dayBounds(day(2026, 11, 1))
    #expect(fallBack.end - fallBack.start == 25 * 3_600_000)
}

@Test func wallClockMinutesRoundTripAndGapsMoveForward() {
    let instant = at(day(2026, 10, 7), 14, 35)
    #expect(seoul.minuteOfDay(of: instant) == 14 * 60 + 35)
    #expect(seoul.instant(of: day(2026, 10, 7), minuteOfDay: 14 * 60 + 35) == instant)
    // 02:30 does not exist in New York on 2026-03-08; it resolves to the next valid instant.
    let resolved = newYork.instant(of: day(2026, 3, 8), minuteOfDay: 2 * 60 + 30)
    let minute = newYork.minuteOfDay(of: resolved)
    #expect(minute >= 3 * 60 && minute < 4 * 60)
    #expect(newYork.localDate(of: resolved) == day(2026, 3, 8))
}

@Test func timedAndDayRangesCannotBeInvalid() throws {
    #expect(throws: CalendarValidationError.self) { try TimedRange(startUnixMilliseconds: 10, endUnixMilliseconds: 10) }
    #expect(throws: CalendarValidationError.self) { try TimedRange(startUnixMilliseconds: 11, endUnixMilliseconds: 10) }
    #expect(throws: CalendarValidationError.self) { try DayRange(firstDay: day(2026, 10, 8), lastDay: day(2026, 10, 7)) }
    let range = allDayRange(day(2026, 10, 7), day(2026, 10, 9))
    #expect(range.dayCount == 3)
    #expect(range.contains(day(2026, 10, 8)))
    #expect(!range.contains(day(2026, 10, 10)))
    let bad = Data(#"{"startUnixMilliseconds":5,"endUnixMilliseconds":1}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(TimedRange.self, from: bad) }
}

@Test func eventUpdateDistinguishesKeepSetAndClear() {
    let base = CalendarEvent(
        id: eventID("e"), calendarID: calendarID("life"), title: "원래", time: .timed(timed(1_000, 2_000)),
        location: "강남", notes: "메모"
    )
    #expect(CalendarEventUpdate().isEmpty)
    #expect(!CalendarEventUpdate(title: "새").isEmpty)
    let titleOnly = CalendarEventUpdate(title: "새").applied(to: base)
    #expect(titleOnly.title == "새" && titleOnly.location == "강남" && titleOnly.notes == "메모")
    let cleared = CalendarEventUpdate(location: .clear, notes: .set("새 메모")).applied(to: base)
    #expect(cleared.location == nil && cleared.notes == "새 메모" && cleared.title == "원래")
}

@Test func allDayAndTimedRangesOverlapWindowsInTheGivenZone() {
    let bounds = seoul.dayBounds(day(2026, 10, 7))
    #expect(EventTimeRange.allDay(allDayRange(day(2026, 10, 7), day(2026, 10, 7))).overlaps(from: bounds.start, to: bounds.end, in: seoul))
    #expect(!EventTimeRange.allDay(allDayRange(day(2026, 10, 8), day(2026, 10, 8))).overlaps(from: bounds.start, to: bounds.end, in: seoul))
    #expect(EventTimeRange.timed(timed(bounds.start - 1_000, bounds.start + 1_000)).overlaps(from: bounds.start, to: bounds.end, in: seoul))
    #expect(!EventTimeRange.timed(timed(bounds.end, bounds.end + 1_000)).overlaps(from: bounds.start, to: bounds.end, in: seoul))
}
