import Testing
import NEOBudgetCalendar

private let policy = TimelineEditPolicy.standard
private let zoomed = TimelineEditPolicy.zoomed
private let date = day(2026, 10, 7)

@Test func policyDefaultsMatchTheProductDecision() {
    #expect(policy.snapMinutes == 15 && policy.minimumDurationMinutes == 15 && policy.defaultNewEventDurationMinutes == 60)
    #expect(zoomed.snapMinutes == 5 && zoomed.minimumDurationMinutes == 15)
    #expect(throws: CalendarValidationError.self) { try TimelineEditPolicy(snapMinutes: 0, minimumDurationMinutes: 15, defaultNewEventDurationMinutes: 60) }
    #expect(throws: CalendarValidationError.self) { try TimelineEditPolicy(snapMinutes: 15, minimumDurationMinutes: 0, defaultNewEventDurationMinutes: 60) }
    #expect(throws: CalendarValidationError.self) { try TimelineEditPolicy(snapMinutes: 15, minimumDurationMinutes: 30, defaultNewEventDurationMinutes: 15) }
}

@Test func snapRoundsToTheNearestStepAndHalfwayGoesUp() {
    #expect(policy.snap(at(date, 10, 7), in: seoul) == at(date, 10, 0))
    #expect(policy.snap(at(date, 10, 8), in: seoul) == at(date, 10, 15))
    #expect(policy.snap(at(date, 10, 7) + 30_000, in: seoul) == at(date, 10, 15))   // exactly halfway
    #expect(policy.snap(at(date, 10, 0), in: seoul) == at(date, 10, 0))
    #expect(policy.snap(at(date, 23, 59), in: seoul) == seoul.dayBounds(date).end)  // may land on the next midnight
    #expect(zoomed.snap(at(date, 10, 2), in: seoul) == at(date, 10, 0))
    #expect(zoomed.snap(at(date, 10, 3), in: seoul) == at(date, 10, 5))
    #expect(zoomed.snap(at(date, 10, 2) + 30_000, in: seoul) == at(date, 10, 5))
}

@Test func snapIsAlignedToLocalMidnightInEveryZone() {
    let instant = at(day(2026, 3, 8), 3, 40, in: newYork)   // after the spring-forward gap
    let snapped = policy.snap(instant, in: newYork)
    #expect(newYork.minuteOfDay(of: snapped) % 15 == 0)
}

@Test func movingAnEventPreservesDurationAndSnapsTheStart() {
    let range = timed(at(date, 10, 0), at(date, 11, 30))
    let moved = policy.move(range, toProposedStart: at(date, 14, 7), in: seoul)
    #expect(moved.startUnixMilliseconds == at(date, 14, 0))
    #expect(moved.durationMilliseconds == range.durationMilliseconds)
    // An event whose length is off-grid keeps that exact length.
    let odd = timed(at(date, 9, 0), at(date, 9, 50))
    #expect(policy.move(odd, toProposedStart: at(date, 12, 0), in: seoul).durationMilliseconds == odd.durationMilliseconds)
}

@Test func movingAcrossMidnightIsAllowed() {
    let range = timed(at(date, 22, 0), at(date, 23, 0))
    let moved = policy.move(range, toProposedStart: at(date, 23, 30), in: seoul)
    #expect(seoul.localDate(of: moved.startUnixMilliseconds) == date)
    #expect(seoul.localDate(of: moved.endUnixMilliseconds - 1) == date.adding(days: 1))
}

@Test func movingToAnotherDayKeepsLocalTimeOfDayAndDuration() {
    let range = timed(at(date, 19, 0), at(date, 22, 0))
    let moved = policy.move(range, toDay: date.adding(days: 3), in: seoul)
    #expect(moved.startUnixMilliseconds == at(date.adding(days: 3), 19, 0))
    #expect(moved.durationMilliseconds == range.durationMilliseconds)
}

@Test func moveToDayKeepsWallClockAcrossDaylightSavingChange() {
    let before = day(2026, 3, 7)
    let range = timed(at(before, 9, 0, in: newYork), at(before, 10, 0, in: newYork))
    let moved = policy.move(range, toDay: day(2026, 3, 9), in: newYork)
    #expect(newYork.minuteOfDay(of: moved.startUnixMilliseconds) == 9 * 60)
    #expect(newYork.localDate(of: moved.startUnixMilliseconds) == day(2026, 3, 9))
}

@Test func resizingTheTopEdgeChangesOnlyTheStartAndNeverFlips() {
    let range = timed(at(date, 10, 0), at(date, 12, 0))
    let earlier = policy.resizeStart(range, toProposedStart: at(date, 9, 7), in: seoul)
    #expect(earlier.range.startUnixMilliseconds == at(date, 9, 0))
    #expect(earlier.range.endUnixMilliseconds == range.endUnixMilliseconds)
    #expect(!earlier.wasClamped)

    let past = policy.resizeStart(range, toProposedStart: at(date, 13, 0), in: seoul)
    #expect(past.range.endUnixMilliseconds == range.endUnixMilliseconds)
    #expect(past.range.startUnixMilliseconds == at(date, 11, 45))   // end - 15 min
    #expect(past.wasClamped)
}

@Test func resizingTheBottomEdgeChangesOnlyTheEndAndKeepsTheMinimum() {
    let range = timed(at(date, 10, 0), at(date, 12, 0))
    let later = policy.resizeEnd(range, toProposedEnd: at(date, 13, 8), in: seoul)
    #expect(later.range.endUnixMilliseconds == at(date, 13, 15))
    #expect(later.range.startUnixMilliseconds == range.startUnixMilliseconds)

    let tooSmall = policy.resizeEnd(range, toProposedEnd: at(date, 9, 0), in: seoul)
    #expect(tooSmall.range.endUnixMilliseconds == at(date, 10, 15))
    #expect(tooSmall.wasClamped)
}

@Test func bottomResizeCanBeKeptInsideTheSelectedDay() {
    let range = timed(at(date, 22, 0), at(date, 23, 0))
    let dayEnd = seoul.dayBounds(date).end
    let clamped = policy.resizeEnd(range, toProposedEnd: at(date.adding(days: 1), 2, 0), in: seoul, clampingToDayEnd: dayEnd)
    #expect(clamped.range.endUnixMilliseconds == dayEnd)
    #expect(clamped.wasClamped)
    let unclamped = policy.resizeEnd(range, toProposedEnd: at(date.adding(days: 1), 2, 0), in: seoul)
    #expect(unclamped.range.endUnixMilliseconds == at(date.adding(days: 1), 2, 0))
}

@Test func resizeNeverProducesAnInvalidRangeEvenForAnOffGridEnd() {
    let range = timed(at(date, 10, 0), at(date, 10, 20))
    let result = policy.resizeStart(range, toProposedStart: at(date, 10, 30), in: seoul)
    #expect(result.range.startUnixMilliseconds < result.range.endUnixMilliseconds)
    #expect(result.range.durationMilliseconds >= 15 * 60_000)
}

@Test func creatingByDragOrdersAndSnapsBothEnds() {
    let forward = policy.create(dragFrom: at(date, 9, 7), to: at(date, 10, 53), in: seoul)
    #expect(forward.range.startUnixMilliseconds == at(date, 9, 0))
    #expect(forward.range.endUnixMilliseconds == at(date, 11, 0))
    let backward = policy.create(dragFrom: at(date, 10, 53), to: at(date, 9, 7), in: seoul)
    #expect(backward.range == forward.range)
}

@Test func aShortDragBecomesTheMinimumDuration() {
    let result = policy.create(dragFrom: at(date, 9, 0), to: at(date, 9, 5), in: seoul)
    #expect(result.range.durationMilliseconds == 15 * 60_000)
    #expect(result.wasClamped)
    let fine = zoomed.create(dragFrom: at(date, 9, 0), to: at(date, 9, 20), in: seoul)
    #expect(fine.range.durationMilliseconds == 20 * 60_000)
}

@Test func creatingNearTheEndOfADayStaysInsideIt() {
    let dayEnd = seoul.dayBounds(date).end
    let result = policy.create(dragFrom: at(date, 23, 58), to: at(date, 23, 59), in: seoul, keepingInside: date)
    #expect(result.range.endUnixMilliseconds <= dayEnd)
    #expect(result.range.durationMilliseconds >= 15 * 60_000)
    #expect(result.range.startUnixMilliseconds >= seoul.dayBounds(date).start)
    #expect(result.wasClamped)
}

@Test func timedToAllDayUsesTheLocalDaysTheEventTouches() {
    let single = policy.timedToAllDay(timed(at(date, 10, 0), at(date, 11, 0)), in: seoul)
    #expect(single.firstDay == date && single.lastDay == date)
    let overnight = policy.timedToAllDay(timed(at(date, 22, 0), at(date.adding(days: 1), 2, 0)), in: seoul)
    #expect(overnight.firstDay == date && overnight.lastDay == date.adding(days: 1))
    // Ending exactly at midnight does not claim the next day.
    let untilMidnight = policy.timedToAllDay(timed(at(date, 20, 0), seoul.dayBounds(date).end), in: seoul)
    #expect(untilMidnight.lastDay == date)
}

@Test func allDayToTimedUsesTheDefaultDurationAtTheSnappedDrop() {
    let result = policy.allDayToTimed(atProposedStart: at(date, 14, 7), in: seoul)
    #expect(result.startUnixMilliseconds == at(date, 14, 0))
    #expect(result.durationMilliseconds == 60 * 60_000)
}

@Test func movingAnAllDayEventKeepsItsLengthInDays() {
    let range = allDayRange(date, date.adding(days: 2))
    let moved = policy.move(range, toFirstDay: date.adding(days: 10))
    #expect(moved.firstDay == date.adding(days: 10))
    #expect(moved.dayCount == 3)
}

@Test func editFunctionsAreDeterministic() {
    let range = timed(at(date, 10, 0), at(date, 11, 0))
    for _ in 0..<5 {
        #expect(policy.move(range, toProposedStart: at(date, 12, 4), in: seoul) == policy.move(range, toProposedStart: at(date, 12, 4), in: seoul))
        #expect(policy.resizeEnd(range, toProposedEnd: at(date, 12, 4), in: seoul) == policy.resizeEnd(range, toProposedEnd: at(date, 12, 4), in: seoul))
    }
}
