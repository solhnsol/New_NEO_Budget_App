import Foundation
import Testing
@testable import NEOBudgetCalendar

private let springDay = day(2026, 3, 8)       // America/New_York: 02:00 -> 03:00, a 23 hour day
private let fallDay = day(2026, 11, 1)        // America/New_York: 02:00 -> 01:00, a 25 hour day
private let seoulDay = day(2026, 10, 7)

@Test func anOrdinaryDayIsTheIdentityBetweenElapsedAndWall() {
    let clock = DayWallClock(day: seoulDay, zone: seoul)
    #expect(clock.kind == .regular && clock.totalMinutes == 1440 && clock.skippedWall == nil && clock.repeatedWall == nil)
    for minute in [0, 1, 59, 60, 719, 720, 1439] {
        #expect(clock.wallMinute(forElapsed: minute) == minute)
        #expect(clock.elapsedMinute(forWall: minute) == minute)
    }
    #expect(clock.wallMinute(forElapsed: 1440) == 1440 && clock.elapsedMinute(forWall: 1440) == 1440)
    #expect(clock.wallRange(startElapsed: 600, endElapsed: 660) == (600, 660))
}

@Test func springForwardSkipsAWallHourAndSpansAcrossItCoverIt() {
    let clock = DayWallClock(day: springDay, zone: newYork)
    #expect(clock.kind == .springForward && clock.totalMinutes == 23 * 60)
    #expect(clock.skippedWall == 120..<180 && clock.repeatedWall == nil)
    // Instant -> wall: before the gap the same, after it an hour later; the day still ends at 24:00.
    #expect(clock.wallMinute(forElapsed: 119) == 119)
    #expect(clock.wallMinute(forElapsed: 120) == 180)                    // 03:00 is two real hours after midnight (as in the timeline test)
    #expect(clock.wallMinute(forElapsed: 23 * 60 - 1) == 1439 && clock.wallMinute(forElapsed: 23 * 60) == 1440)
    // Wall -> instant: a time in the gap is the next real instant.
    for wall in [120, 150, 179] { #expect(clock.elapsedMinute(forWall: wall) == 120) }
    #expect(clock.elapsedMinute(forWall: 180) == 120 && clock.elapsedMinute(forWall: 60) == 60)
    // A span from 03:00 to 04:00 is wall 180...240; one across the gap (01:30 to 03:30) covers the gap.
    #expect(clock.wallRange(startElapsed: 120, endElapsed: 180) == (180, 240))
    #expect(clock.wallRange(startElapsed: 90, endElapsed: 150) == (90, 210))
}

@Test func fallBackRepeatsAWallHourAndTheFirstOccurrenceIsTheOneThatCanBeNamed() {
    let clock = DayWallClock(day: fallDay, zone: newYork)
    #expect(clock.kind == .fallBack && clock.totalMinutes == 25 * 60)
    #expect(clock.repeatedWall == 60..<120 && clock.skippedWall == nil)
    // Both occurrences of 01:30 have the same wall minute; the second elapsed minute is an hour later.
    #expect(clock.wallMinute(forElapsed: 90) == 90 && clock.wallMinute(forElapsed: 150) == 90)
    #expect(clock.wallMinute(forElapsed: 180) == 120)                    // 02:00 standard time, three real hours after midnight
    #expect(clock.wallMinute(forElapsed: 25 * 60) == 1440)
    // Wall -> instant: the repeated hour resolves to its first occurrence.
    for wall in [60, 90, 119] { #expect(clock.elapsedMinute(forWall: wall) == wall) }
    #expect(clock.elapsedMinute(forWall: 120) == 180)
    // A span wholly in the second occurrence lies over the same wall minutes as the first.
    #expect(clock.wallRange(startElapsed: 150, endElapsed: 170) == (90, 110))
    #expect(clock.wallRange(startElapsed: 90, endElapsed: 110) == (90, 110))
    // A span across the fold (01:30 first time to 01:10 second time) is drawn to the end of the first occurrence at the latest.
    #expect(clock.wallRange(startElapsed: 90, endElapsed: 130) == (90, 120))
    // A span from the second 01:50 to 02:10 is 01:50 ... 02:10.
    #expect(clock.wallRange(startElapsed: 170, endElapsed: 190) == (110, 130))
}

@Test func theMappingAgreesWithTheZonesOwnWallToInstantRuleOnEveryMinuteOfEveryKindOfDay() {
    for (date, zone) in [(seoulDay, seoul), (springDay, newYork), (fallDay, newYork)] {
        let clock = DayWallClock(day: date, zone: zone)
        let start = zone.dayBounds(date).start
        for wall in 0..<1440 {
            // `instant(of:minuteOfDay:)`: gap -> next valid instant, repeated -> first occurrence. The same instant, to the minute.
            let expected = zone.instant(of: date, minuteOfDay: wall)
            #expect(start + Int64(clock.elapsedMinute(forWall: wall)) * 60_000 == expected, "\(date) wall \(wall)")
        }
        for elapsed in 0..<clock.totalMinutes {
            // Instant -> wall is the clock reading, and back is never later than where it started (first occurrence).
            #expect(clock.wallMinute(forElapsed: elapsed) == zone.minuteOfDay(of: start + Int64(elapsed) * 60_000))
            #expect(clock.elapsedMinute(forWall: clock.wallMinute(forElapsed: elapsed)) <= elapsed)
        }
    }
}

@Test func wallToElapsedAndBackIsTheIdentityExceptInsideTheGapAndTheSecondRepeat() {
    for (date, zone) in [(springDay, newYork), (fallDay, newYork)] {
        let clock = DayWallClock(day: date, zone: zone)
        for wall in 0..<1440 {
            let back = clock.wallMinute(forElapsed: clock.elapsedMinute(forWall: wall))
            if let gap = clock.skippedWall, gap.contains(wall) { #expect(back == gap.upperBound) } else { #expect(back == wall) }
        }
    }
}

@Test func theMappingIsMonotoneOutsideTheFoldAndNeverLeavesTheDay() {
    for (date, zone) in [(seoulDay, seoul), (springDay, newYork), (fallDay, newYork)] {
        let clock = DayWallClock(day: date, zone: zone)
        var previous = -1
        for elapsed in -5...(clock.totalMinutes + 5) {
            let wall = clock.wallMinute(forElapsed: elapsed)
            #expect(wall >= 0 && wall <= 1440)
            let inFold = clock.repeatedWall != nil && elapsed == 120      // the single step back of a fall-back day
            if !inFold { #expect(wall >= previous) }
            previous = wall
        }
        // Spans clamp to the day: continuing past either end is drawn to the edge.
        let all = clock.wallRange(startElapsed: -50, endElapsed: clock.totalMinutes + 50)
        #expect(all == (0, 1440))
        let point = clock.wallRange(startElapsed: 300, endElapsed: 300)
        #expect(point.top == point.bottom)
    }
}

@Test func aSpanThatContinuesToTheNextDayOrFromThePreviousIsDrawnToTheEdge() {
    // `DayTimelineBuilder` clamps a multi-day event to the day's minutes; the clock then maps the clamped ends.
    let clock = DayWallClock(day: fallDay, zone: newYork)
    let continuesOn = clock.wallRange(startElapsed: 22 * 60, endElapsed: clock.totalMinutes)
    #expect(continuesOn.bottom == 1440 && continuesOn.top == clock.wallMinute(forElapsed: 22 * 60))
    let continuedFrom = clock.wallRange(startElapsed: 0, endElapsed: 3 * 60)
    #expect(continuedFrom.top == 0)
}
