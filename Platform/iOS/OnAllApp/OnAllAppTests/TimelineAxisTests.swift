import CoreGraphics
import NEOBudgetCalendar
import Testing
@testable import OnAllApp

private let day = 1440
/// The numbers these tests reason with. `standard` is tuned for the screen and tested separately below.
private let parameters = TimelineAxis.Parameters(
    browseScale: 1.0, foldedScale: 0.12, minimumFoldedHeight: 30, padding: 45, minimumFoldMinutes: 90,
    editScale: 1.6, editMargin: 90, emptyDayFocus: (9 * 60)...(18 * 60)
)

private func browse(_ anchors: [Int]) -> TimelineAxis { TimelineAxis.browse(totalMinutes: day, anchors: anchors, parameters: parameters) }

@Test func aLinearAxisBehavesLikeTheOldUniformGeometry() {
    let axis = TimelineAxis.linear(totalMinutes: day, pointsPerMinute: 1.2)
    #expect(axis.height == 1728)
    #expect(axis.y(minute: 615) == 738)
    #expect(axis.minute(atY: 738) == 615)
    #expect(axis.minute(atY: -10) == 0 && axis.minute(atY: 99_999) == day)
    #expect(axis.foldedSegments.isEmpty)
}

@Test func anEmptyDayKeepsTheWorkingHoursAndFoldsTheRest() {
    let axis = browse([])
    let folded = axis.foldedSegments
    #expect(folded.map(\.startMinute) == [0, 18 * 60 + 45])
    #expect(folded.map(\.endMinute) == [9 * 60 - 45, day])
    #expect(axis.isFolded(minute: 3 * 60) && !axis.isFolded(minute: 12 * 60))
    #expect(axis.height < CGFloat(day) * parameters.browseScale * 0.6)      // well under a full uniform day
}

@Test func aSingleEventKeepsItsSurroundingsAtFullSizeAndFoldsTheEmptyDay() {
    let axis = browse([10 * 60, 11 * 60])
    // 09:15 ... 11:45 stays full size: 150 minutes at 1.0 point per minute.
    let unfolded = axis.segments.filter { !$0.isFolded }
    #expect(unfolded.count == 1 && unfolded[0].startMinute == 9 * 60 + 15 && unfolded[0].endMinute == 11 * 60 + 45)
    #expect(unfolded[0].height == 150)
    #expect(axis.foldedSegments.map(\.startMinute) == [0, 11 * 60 + 45])
    // Each fold is at least tall enough to carry a label.
    #expect(axis.foldedSegments.allSatisfy { $0.height >= parameters.minimumFoldedHeight })
}

@Test func stretchesTooShortToBeWorthFoldingStayAtFullSize() {
    // 10:00 ... 12:30 apart: after 45 minutes of padding on each side only 60 minutes remain, below the 90 minute minimum.
    let near = browse([10 * 60, 12 * 60 + 30])
    #expect(!near.isFolded(minute: 11 * 60))
    // 10:00 ... 13:00 leaves 90 minutes between the padded ends, which is folded.
    let far = browse([10 * 60, 13 * 60])
    #expect(far.isFolded(minute: 11 * 60 + 30) && !far.isFolded(minute: 10 * 60 + 30) && !far.isFolded(minute: 12 * 60 + 30))
}

@Test func theMiddleOfAVeryLongEventIsFoldedButItsEdgesAreNot() {
    let axis = browse([8 * 60, 18 * 60])        // a ten hour event
    #expect(axis.isFolded(minute: 13 * 60))
    #expect(!axis.isFolded(minute: 8 * 60 + 10) && !axis.isFolded(minute: 17 * 60 + 50))
    let linear = CGFloat(10 * 60) * parameters.browseScale
    #expect(axis.y(minute: 18 * 60) - axis.y(minute: 8 * 60) < linear / 2)
}

@Test func mappingIsMonotonicAndRoundTripsWhereNothingIsFolded() {
    let axis = browse([9 * 60, 10 * 60 + 30, 15 * 60, 20 * 60])
    var previous: CGFloat = -1
    for minute in 0...day {
        let y = axis.y(minute: minute)
        #expect(y >= previous)
        previous = y
        if !axis.isFolded(minute: minute) { #expect(axis.minute(atY: y) == minute, "minute \(minute)") }
    }
    #expect(axis.y(minute: day) == axis.height)
}

@Test func insideAFoldOnePointIsManyMinutesAndNeverLeavesTheStretch() {
    let axis = browse([12 * 60])
    let fold = axis.foldedSegments[0]
    let top = axis.top(of: fold)
    for offset in stride(from: 0, through: fold.height, by: 5) {
        let minute = axis.minute(atY: top + offset)
        #expect(minute >= fold.startMinute && minute <= fold.endMinute)
    }
    #expect(axis.minute(atY: top + fold.height / 2) > fold.startMinute + 100)
}

@Test func expandingMakesEveryFifteenMinuteStepTallEnoughToDrag() {
    let axis = browse([10 * 60, 11 * 60])
    let window = axis.editWindow(around: (10 * 60)...(11 * 60), parameters: parameters)
    #expect(window == (8 * 60 + 30)...(12 * 60 + 30))
    let editing = axis.expanded(over: window, scale: parameters.editScale)
    #expect(editing.y(minute: 10 * 60 + 15) - editing.y(minute: 10 * 60) == 24)
    #expect(editing.y(minute: 11 * 60) - editing.y(minute: 10 * 60) == 96)
    #expect(!editing.isFolded(minute: 9 * 60) && !editing.isFolded(minute: 12 * 60))      // folds inside the window are opened
    #expect(abs(editing.y(minute: 6 * 60) - axis.y(minute: 6 * 60)) < 0.001)                  // above the window nothing moves
    #expect(editing.height > axis.height)
    // Dragging one step in the enlarged region moves exactly one snap step.
    let start = editing.y(minute: 10 * 60)
    #expect(editing.minute(atY: start + 24) == 10 * 60 + 15)
    #expect(editing.minute(atY: start + 12) == 10 * 60 + 8 || editing.minute(atY: start + 12) == 10 * 60 + 7)
}

@Test func expandingKeepsOtherFoldsFoldedAndTheWindowInsideTheDay() {
    let axis = browse([9 * 60, 22 * 60])
    let window = axis.editWindow(around: (22 * 60)...(23 * 60 + 50), parameters: parameters)
    #expect(window.upperBound == day)
    let editing = axis.expanded(over: window, scale: parameters.editScale)
    #expect(editing.isFolded(minute: 14 * 60))                // the long quiet stretch in the middle stays folded
    #expect(!editing.isFolded(minute: 23 * 60))
    #expect(editing.segments.first?.startMinute == 0 && editing.segments.last?.endMinute == day)
    // Segments stay contiguous.
    for pair in zip(editing.segments, editing.segments.dropFirst()) { #expect(pair.0.endMinute == pair.1.startMinute) }
}

@Test func collapsingBackIsTheSameAxisAsBefore() {
    let axis = browse([9 * 60, 12 * 60])
    let window = axis.editWindow(around: (9 * 60)...(10 * 60), parameters: parameters)
    _ = axis.expanded(over: window, scale: parameters.editScale)
    #expect(axis == browse([9 * 60, 12 * 60]))      // the browse axis is a value; expanding never mutates it
}

// MARK: The numbers the screen actually uses

@Test func aBusyDayFitsRoughlyOnOneScreenWhileAnEditedEventGetsComfortableSteps() {
    let standard = TimelineAxis.Parameters.standard
    // A realistic busy day: classes, lunch, study, a long gap, an evening event, a late transaction.
    let anchors = [9 * 60, 10 * 60 + 30, 12 * 60, 13 * 60, 12 * 60 + 30, 14 * 60 + 30, 16 * 60, 17 * 60, 19 * 60, 20 * 60 + 30, 21 * 60 + 30]
    let axis = TimelineAxis.browse(totalMinutes: day, anchors: anchors, parameters: standard)
    let uniform = CGFloat(day) * 1.2
    #expect(axis.height < uniform / 2.4)                                        // about a screen instead of a day and a half
    #expect(axis.height < 640)
    // Editing: a 15 minute step is big enough to hit.
    let window = axis.editWindow(around: (9 * 60)...(10 * 60 + 30), parameters: standard)
    let editing = axis.expanded(over: window, scale: standard.editScale)
    #expect(editing.y(minute: 9 * 60 + 15) - editing.y(minute: 9 * 60) >= 24)
}

@Test func aVeryLongEventAndALongQuietStretchBothFoldUnderTheScreenSettings() {
    let standard = TimelineAxis.Parameters.standard
    let axis = TimelineAxis.browse(totalMinutes: day, anchors: [8 * 60, 18 * 60, 21 * 60], parameters: standard)
    #expect(axis.isFolded(minute: 13 * 60))                                     // inside the ten hour event
    #expect(!axis.isFolded(minute: 8 * 60 + 10))
    #expect(axis.height < 400)
}

@Test func hourLabelsThatWouldCollideWithAFoldLabelAreNotDrawn() {
    // A 09:00 ... 11:30 event: its middle (09:30 ... 11:00) is folded under the screen settings.
    let standard = TimelineAxis.Parameters.standard
    let axis = TimelineAxis.browse(totalMinutes: day, anchors: [9 * 60, 11 * 60 + 30], parameters: standard)
    let fold = axis.foldedSegments.first { $0.startMinute > 9 * 60 }
    #expect(fold?.startMinute == 9 * 60 + 30 && fold?.endMinute == 11 * 60)
    #expect(axis.isFoldedOrBordering(minute: 10 * 60))        // inside
    #expect(axis.isFoldedOrBordering(minute: 11 * 60))        // exactly on the fold's edge
    #expect(!axis.isFoldedOrBordering(minute: 9 * 60))        // the event's own start keeps its label
    let utc = try! DisplayTimeZone(identifier: "UTC")
    let marks = TimelineGeometry(axis: axis).hourMarks(dayStartUnixMilliseconds: 0, zone: utc)
    #expect(!marks.contains { $0.elapsedMinute == 10 * 60 || $0.elapsedMinute == 11 * 60 })
    #expect(marks.contains { $0.elapsedMinute == 9 * 60 })
}
