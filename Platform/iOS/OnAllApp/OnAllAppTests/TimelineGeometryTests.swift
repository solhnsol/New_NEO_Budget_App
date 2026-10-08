import CoreGraphics
import NEOBudgetCalendar
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()

/// Blocks as the real builder produces them, so layout columns come from the domain, not from the test.
private func blocks(_ spans: [(start: Int, end: Int)]) -> [EventBlock] {
    let calendar = CalendarID(rawValue: "c")
    let events = spans.enumerated().compactMap { index, span -> CalendarEvent? in
        guard let range = try? TimedRange(
            startUnixMilliseconds: zone.instant(of: day, minuteOfDay: span.start),
            endUnixMilliseconds: zone.instant(of: day, minuteOfDay: span.end)
        ) else { return nil }
        return CalendarEvent(id: CalendarEventID(rawValue: "e\(index)"), calendarID: calendar, title: "t\(index)", time: .timed(range))
    }
    let timeline = DayTimelineBuilder.build(DayTimelineInput(day: day, timeZone: zone, events: events, life: .empty, transactions: []))
    return timeline.blocks.sorted { $0.title < $1.title }
}

@Test func contentHeightFollowsTheDayLengthIncludingDaylightSavingDays() {
    #expect(TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 1).contentHeight == 1440)
    #expect(TimelineGeometry(totalMinutes: 1380, pointsPerMinute: 1).contentHeight == 1380)
    #expect(TimelineGeometry(totalMinutes: 1500, pointsPerMinute: 1).contentHeight == 1500)
}

@Test func minutesAndPointsRoundTripAndClamp() {
    let geometry = TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 1.2)
    #expect(geometry.minute(atY: geometry.y(minute: 615)) == 615)
    #expect(geometry.minute(atY: -50) == 0)
    #expect(geometry.minute(atY: 100_000) == 1440)
}

@Test func overlappingBlocksShareTheWidthWithoutGaps() {
    var geometry = TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 1)
    geometry.gutterWidth = 50
    geometry.markerRailWidth = 70
    geometry.columnSpacing = 2
    let built = blocks([(600, 660), (630, 690)])
    #expect(built.map(\.layout.columnCount) == [2, 2])
    #expect(Set(built.map(\.layout.column)) == [0, 1])
    let ordered = built.sorted { $0.layout.column < $1.layout.column }
    let first = geometry.blockFrame(ordered[0], totalWidth: 420)
    let second = geometry.blockFrame(ordered[1], totalWidth: 420)
    // 420 - 50 - 70 = 300 available, two columns of 150 each minus spacing.
    #expect(first.minX == 50 && first.width == 148)
    #expect(second.minX == 200 && second.width == 148)
    #expect(first.maxX <= second.minX)
    #expect(first.height == 59 && second.height == 59)
    #expect(first.minY == CGFloat(ordered[0].displayStartMinute))
}

@Test func aSingleBlockUsesTheWholeAvailableWidth() {
    let geometry = TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 1)
    let frame = geometry.blockFrame(blocks([(540, 555)])[0], totalWidth: 400)
    #expect(frame.width == 400 - geometry.gutterWidth - geometry.markerRailWidth - geometry.columnSpacing)
}

@Test func markersThatWouldOverlapArePushedDownInOrder() {
    let geometry = TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 1)
    let positions = geometry.markerYPositions(minutes: [740, 720, 721, 900], minimumSpacing: 22)
    #expect(positions == [764, 720, 742, 900])
    #expect(geometry.markerYPositions(minutes: []).isEmpty)
}

@Test func hourMarksLabelWallClockHoursEvenOnATransitionDay() throws {
    let zone = try DisplayTimeZone(identifier: "America/New_York")
    // 2027-03-14 is the US spring-forward day: 23 hours, and 02:00 does not exist.
    let day = try LocalDate(year: 2027, month: 3, day: 14)
    let bounds = zone.dayBounds(day)
    let minutes = Int((bounds.end - bounds.start) / 60_000)
    #expect(minutes == 1380)
    let marks = TimelineGeometry(totalMinutes: minutes).hourMarks(dayStartUnixMilliseconds: bounds.start, zone: zone)
    #expect(marks.count == 23)
    #expect(marks.map(\.wallHour).prefix(3) == [0, 1, 3])
    #expect(marks.last?.wallHour == 23)
}
