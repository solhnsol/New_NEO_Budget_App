import CoreGraphics
import NEOBudgetCalendar
import Testing
@testable import OnAllApp

private let day = 1440
/// The numbers these tests reason with. `standard` is tuned for the screen and tested separately below.
private let parameters = TimelineAxis.Parameters(
    browseScale: 1.0, foldedScale: 0.12, minimumFoldedHeight: 30, padding: 45, minimumFoldMinutes: 90,
    editScale: 1.6, emptyDayFocus: (9 * 60)...(18 * 60), handleRadius: 45, handleRamp: 15, rampScale: 1.3, zoneMergeGap: 20
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

@Test func enlargingAroundTheHandlesMakesEveryFifteenMinuteStepTallEnoughToDrag() {
    let axis = browse([10 * 60, 11 * 60])
    let zones = axis.handleZones(around: [10 * 60, 11 * 60], parameters: parameters)
    #expect(zones == [(9 * 60 + 15)...(11 * 60 + 45)])                     // the two handles' windows overlap, so they are one
    let editing = axis.expandedLocally(around: [10 * 60, 11 * 60], parameters: parameters)
    #expect(editing.y(minute: 10 * 60 + 15) - editing.y(minute: 10 * 60) == 24)
    #expect(editing.y(minute: 11 * 60) - editing.y(minute: 10 * 60) == 96)
    #expect(abs(editing.y(minute: 6 * 60) - axis.y(minute: 6 * 60)) < 0.001)                 // above the zone nothing moves
    #expect(editing.height > axis.height)
    // Dragging one step in the enlarged region moves exactly one snap step.
    let start = editing.y(minute: 10 * 60)
    #expect(editing.minute(atY: start + 24) == 10 * 60 + 15)
}

@Test func theEnlargedZoneIsOpenedButEverythingElseKeepsItsBrowseShape() {
    let axis = browse([9 * 60, 22 * 60])
    let editing = axis.expandedLocally(around: [22 * 60, 23 * 60 + 50], parameters: parameters)
    #expect(editing.isFolded(minute: 14 * 60))                // the long quiet stretch in the middle stays folded
    #expect(!editing.isFolded(minute: 23 * 60))
    #expect(editing.segments.first?.startMinute == 0 && editing.segments.last?.endMinute == day)
    for pair in zip(editing.segments, editing.segments.dropFirst()) { #expect(pair.0.endMinute == pair.1.startMinute) }
    #expect(abs(editing.y(minute: 6 * 60) - axis.y(minute: 6 * 60)) < 0.001)
}

@Test func collapsingBackIsTheSameAxisAsBefore() {
    let axis = browse([9 * 60, 12 * 60])
    _ = axis.expandedLocally(around: [9 * 60, 10 * 60], parameters: parameters)
    #expect(axis == browse([9 * 60, 12 * 60]))      // the browse axis is a value; enlarging never mutates it
}

@Test func theSizeChangesGraduallyTowardsAnEnlargedZone() {
    let axis = browse([10 * 60, 18 * 60])             // an eight hour event: its middle is folded
    let editing = axis.expandedLocally(around: [10 * 60, 18 * 60], parameters: parameters)
    // Scales seen walking down from the fold into the start handle's zone: folded -> ramp -> edit.
    let scales = editing.segments.filter { $0.endMinute > 9 * 60 && $0.startMinute < 11 * 60 + 30 }.map(\.pointsPerMinute)
    #expect(scales.contains(parameters.rampScale) && scales.contains(parameters.editScale))
    let ramp = editing.segments.first { $0.pointsPerMinute == parameters.rampScale }
    let core = editing.segments.first { $0.pointsPerMinute == parameters.editScale }
    #expect(ramp != nil && core != nil && (ramp?.startMinute ?? 0) < (core?.startMinute ?? 0))
}

// MARK: Events of every length, under the screen settings

/// What the screen would draw while editing an event from `start` to `end` minutes, with nothing else on the day.
private func editing(_ start: Int, _ end: Int) -> (browse: TimelineAxis, editing: TimelineAxis, handles: [Int]) {
    let standard = TimelineAxis.Parameters.standard
    let browse = TimelineAxis.browse(totalMinutes: day, anchors: [start, end], parameters: standard)
    return (browse, browse.expandedLocally(around: [start, end], parameters: standard), [start, end])
}

struct EventLength: Sendable, CustomTestStringConvertible {
    let name: String
    let start: Int
    let end: Int
    var testDescription: String { name }
}

private let lengths = [
    EventLength(name: "30 minutes", start: 10 * 60, end: 10 * 60 + 30),
    EventLength(name: "2 hours", start: 10 * 60, end: 12 * 60),
    EventLength(name: "8 hours", start: 9 * 60, end: 17 * 60),
    EventLength(name: "24 hours", start: 0, end: day),
]

@Test(arguments: lengths) func everyHandleHasComfortableStepsAndAWholeEventFitsOneScreen(length: EventLength) {
    let standard = TimelineAxis.Parameters.standard
    let shapes = editing(length.start, length.end)
    for handle in shapes.handles {
        // A step towards the inside of the day, whichever side of the handle has room (the edge of the day has one side only).
        let neighbour = handle + 15 <= day ? handle + 15 : handle - 15
        let step = abs(shapes.editing.y(minute: neighbour) - shapes.editing.y(minute: handle))
        #expect(step >= 15 * standard.editScale - 0.001, "\(length.name) at \(handle): \(step)")
        let other = handle - 15 >= 0 ? handle - 15 : handle + 15
        #expect(abs(shapes.editing.y(minute: handle) - shapes.editing.y(minute: other)) >= 15 * standard.editScale - 0.001, "\(length.name) other side of \(handle)")
        // A round trip through the enlarged region is exact.
        #expect(shapes.editing.minute(atY: shapes.editing.y(minute: handle)) == handle)
    }
    // Both handles are within one phone screen of each other, however long the event is.
    let span = shapes.editing.y(minute: length.end) - shapes.editing.y(minute: length.start)
    #expect(span < 640, "\(length.name): \(span)")
    // Enlarging adds a bounded amount, not the length of the event.
    #expect(shapes.editing.height - shapes.browse.height < 2 * (CGFloat(2 * standard.handleRadius + 2 * standard.handleRamp) * standard.editScale))
}

@Test func theMiddleOfALongEventStaysFoldedWhileEditing() {
    for length in lengths where length.end - length.start >= 8 * 60 {
        let shapes = editing(length.start, length.end)
        let middle = (length.start + length.end) / 2
        #expect(shapes.browse.isFolded(minute: middle) && shapes.editing.isFolded(minute: middle), Comment(rawValue: length.name))
        // The folded middle keeps its scale; the zones only take a few minutes off its ends.
        let before = shapes.browse.segments.first { $0.isFolded && $0.startMinute <= middle && middle <= $0.endMinute }
        let after = shapes.editing.segments.first { $0.isFolded && $0.startMinute <= middle && middle <= $0.endMinute }
        #expect(before != nil && after != nil && before?.pointsPerMinute == after?.pointsPerMinute, Comment(rawValue: length.name))
        #expect((after?.height ?? .infinity) <= (before?.height ?? 0), Comment(rawValue: length.name))
    }
}

@Test func zonesMergeWhenTheHandlesAreCloseAndStaySeparateWhenTheyAreFar() {
    let standard = TimelineAxis.Parameters.standard
    let axis = TimelineAxis.browse(totalMinutes: day, anchors: [10 * 60, 18 * 60], parameters: standard)
    let radius = standard.handleRadius, gap = standard.zoneMergeGap
    #expect(axis.handleZones(around: [10 * 60, 10 * 60 + 30], parameters: standard).count == 1)                  // 30 minutes: one zone
    #expect(axis.handleZones(around: [10 * 60, 10 * 60 + 2 * radius + gap], parameters: standard).count == 1)    // windows exactly a gap apart: merged
    #expect(axis.handleZones(around: [10 * 60, 10 * 60 + 2 * radius + gap + 1], parameters: standard).count == 2)   // one minute more: separate
    #expect(axis.handleZones(around: [0, day], parameters: standard) == [0...radius, (day - radius)...day])      // clamped to the day
    #expect(axis.handleZones(around: [], parameters: standard).isEmpty)
}

@Test func enlargedMappingStaysMonotonicAndContiguousForEveryLength() {
    for length in lengths {
        let axis = editing(length.start, length.end).editing
        var previous: CGFloat = -1
        for minute in stride(from: 0, through: day, by: 5) {
            let y = axis.y(minute: minute)
            #expect(y >= previous, "\(length.name) \(minute)")
            previous = y
        }
        for pair in zip(axis.segments, axis.segments.dropFirst()) { #expect(pair.0.endMinute == pair.1.startMinute) }
        #expect(axis.segments.first?.startMinute == 0 && axis.segments.last?.endMinute == day)
    }
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
    let editing = axis.expandedLocally(around: [9 * 60, 10 * 60 + 30], parameters: standard)
    #expect(editing.y(minute: 9 * 60 + 15) - editing.y(minute: 9 * 60) >= 15 * standard.editScale)
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

// MARK: One frame of an axis changing shape

/// The shapes before and after a zone opens at `minute` on an eight hour event's folded middle.
private func zoomShapes(at minute: Int = 13 * 60) -> (from: TimelineAxis, to: TimelineAxis, delta: CGFloat) {
    let standard = TimelineAxis.Parameters.standard
    let from = TimelineAxis.browse(totalMinutes: day, anchors: [9 * 60, 17 * 60], parameters: standard)
    let to = from.expandedLocally(around: [minute], parameters: standard)
    return (from, to, to.y(minute: minute) - from.y(minute: minute))
}

@Test func aBlendIsTheOldShapeAtTheStartAndTheNewShapeAtTheEnd() {
    let shapes = zoomShapes()
    let start = TimelineGeometry(from: shapes.from, to: shapes.to, progress: 0)
    let end = TimelineGeometry(from: shapes.from, to: shapes.to, progress: 1)
    for minute in stride(from: 0, through: day, by: 20) {
        #expect(abs(start.y(minute: minute) - shapes.from.y(minute: minute)) < 0.0001)
        #expect(abs(end.y(minute: minute) - shapes.to.y(minute: minute)) < 0.0001)
    }
    // The content never gets shorter during a change: it is as tall as the taller of the two shapes, in every frame.
    let tallest = max(shapes.from.height, shapes.to.height)
    #expect(abs(start.contentHeight - tallest) < 0.0001 && abs(end.contentHeight - tallest) < 0.0001)
    for step in 0...10 {
        let frame = TimelineGeometry(from: shapes.to, to: shapes.from, progress: CGFloat(step) / 10)      // a fold-away, the other way
        #expect(frame.contentHeight >= shapes.to.height - 0.0001)
    }
}

@Test func theAnchorMinuteStaysAtTheSameScreenPositionInEveryFrameOfAChange() {
    let shapes = zoomShapes()
    let anchor = 13 * 60
    let before = shapes.from.y(minute: anchor)                                   // where it is on screen at the start (scroll offset 0)
    for step in 0...20 {
        let progress = CGFloat(step) / 20
        let frame = TimelineGeometry(from: shapes.from, to: shapes.to, progress: progress)
        // The content is moved up by delta * progress while the scroll view stays put.
        let onScreen = frame.y(minute: anchor) - shapes.delta * progress
        #expect(abs(onScreen - before) < 0.0001, "progress \(progress)")
    }
    // The change ends with the scroll view moving by the whole delta and the shift dropped: the same position again.
    let committed = shapes.to.y(minute: anchor) - shapes.delta
    #expect(abs(committed - before) < 0.0001)
}

@Test func everyMinuteMovesSmoothlyBetweenItsTwoPositionsAndNeverOutOfOrder() {
    let shapes = zoomShapes()
    var previousFrame: [CGFloat] = (0...day).map { shapes.from.y(minute: $0) }
    for step in 1...20 {
        let frame = TimelineGeometry(from: shapes.from, to: shapes.to, progress: CGFloat(step) / 20)
        var last: CGFloat = -1
        for minute in stride(from: 0, through: day, by: 10) {
            let y = frame.y(minute: minute)
            #expect(y >= last)                                                    // time never runs backwards on screen
            last = y
            let low = min(shapes.from.y(minute: minute), shapes.to.y(minute: minute))
            let high = max(shapes.from.y(minute: minute), shapes.to.y(minute: minute))
            #expect(y >= low - 0.0001 && y <= high + 0.0001)                      // and never overshoots
            // The step between two frames is a twentieth of the whole move: no frame jumps.
            let travel = abs(shapes.to.y(minute: minute) - shapes.from.y(minute: minute))
            #expect(abs(y - previousFrame[minute]) <= travel / 20 + 0.0001)
        }
        previousFrame = (0...day).map { frame.y(minute: $0) }
    }
}

@Test func aBlocksBodyAndItsHandlesShareOneCoordinateSystemInEveryFrame() {
    let shapes = zoomShapes()
    for step in 0...10 {
        let frame = TimelineGeometry(from: shapes.from, to: shapes.to, progress: CGFloat(step) / 10)
        // A block 09:00-17:00: its top and bottom edges are the start and end minute as drawn in this frame, and the handles
        // sit at those edges, so they cannot move differently from the body.
        let top = frame.y(minute: 9 * 60)
        let bottom = frame.y(minute: 17 * 60)
        let rect = CGRect(x: frame.gutterWidth, y: top, width: 200, height: bottom - top - 1)
        #expect(EditHit.startHandle(of: rect).y == top)
        #expect(EditHit.endHandle(of: rect).y == rect.maxY)
        #expect(abs(rect.maxY - (bottom - 1)) < 0.0001)
    }
}

@Test func hourMarksAndFoldsFadeWhenOnlyOneShapeHasThem() {
    let shapes = zoomShapes()
    let utc = try! DisplayTimeZone(identifier: "UTC")
    let start = TimelineGeometry(from: shapes.from, to: shapes.to, progress: 0)
    let middle = TimelineGeometry(from: shapes.from, to: shapes.to, progress: 0.5)
    let end = TimelineGeometry(from: shapes.from, to: shapes.to, progress: 1)
    // A mark that only the new shape has: invisible at first, full at the end. One that only the old shape has: the reverse.
    let arriving = Set(TimelineGeometry(axis: shapes.to).hourMarks(dayStartUnixMilliseconds: 0, zone: utc).map(\.elapsedMinute))
    let leaving = Set(TimelineGeometry(axis: shapes.from).hourMarks(dayStartUnixMilliseconds: 0, zone: utc).map(\.elapsedMinute))
    let onlyNew = arriving.subtracting(leaving), onlyOld = leaving.subtracting(arriving), both = arriving.intersection(leaving)
    #expect(!onlyNew.isEmpty || !onlyOld.isEmpty)
    func opacity(_ geometry: TimelineGeometry, _ minute: Int) -> CGFloat? {
        geometry.hourMarks(dayStartUnixMilliseconds: 0, zone: utc).first { $0.elapsedMinute == minute }?.opacity
    }
    for minute in onlyNew { #expect(opacity(start, minute) == 0 && opacity(middle, minute) == 0.5 && opacity(end, minute) == 1) }
    for minute in onlyOld { #expect(opacity(start, minute) == 1 && opacity(middle, minute) == 0.5 && opacity(end, minute) == 0) }
    for minute in both { #expect(opacity(start, minute) == 1 && opacity(middle, minute) == 1 && opacity(end, minute) == 1) }
    // A fold that only the old shape has fades out as the zone opens through it.
    let oldFolds = shapes.from.foldedSegments.map { $0.startMinute...$0.endMinute }
    let newFolds = shapes.to.foldedSegments.map { $0.startMinute...$0.endMinute }
    for fold in start.foldMarks {
        let range = fold.startMinute...fold.endMinute
        #expect(fold.opacity == (oldFolds.contains(range) ? 1 : 0))                  // at the start only the old shape's folds show
    }
    for fold in end.foldMarks {
        let range = fold.startMinute...fold.endMinute
        #expect(fold.opacity == (newFolds.contains(range) ? 1 : 0))
    }
    #expect(middle.foldMarks.contains { $0.opacity == 0.5 })
}
