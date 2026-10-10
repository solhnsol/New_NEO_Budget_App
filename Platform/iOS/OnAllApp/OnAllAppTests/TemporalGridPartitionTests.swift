import CoreGraphics
import Testing
@testable import OnAllApp

// The pure coordinate system of the temporal grid: coverage, equal cells, exact mapping both ways, zoom and interpolation.

/// 12 cells with very different lengths: 8 h, 1 h, 30 min, 30 min, 1 h, 1 h, 2 h, 2 h, 2 h, 2 h, 2 h, 2 h. Total height 600, so a cell is 50 pt.
private let sample = TemporalGridPartition(wholeMinutes: [0, 480, 540, 570, 600, 660, 720, 840, 960, 1080, 1200, 1320, 1440], totalHeight: 600)!
private let other = TemporalGridPartition(wholeMinutes: [0, 60, 120, 180, 240, 300, 360, 420, 480, 540, 600, 660, 1440], totalHeight: 600)!

@Test func aPartitionCoversTheWholeDayExactlyOnceWithEqualCells() {
    #expect(sample.slotCount == 12)
    #expect(sample.boundaries.count == 13)
    #expect(sample.boundaries.first == 0)
    #expect(sample.boundaries.last == 1440)
    #expect(zip(sample.boundaries, sample.boundaries.dropFirst()).allSatisfy { $0 < $1 })
    // The cells tile the day: their lengths add up to 24 hours, and neighbours share a boundary (no gap, no overlap).
    #expect((0..<12).map { sample.minutes(inSlot: $0) }.reduce(0, +) == 1440)
    for slot in 0..<12 {
        #expect(sample.end(ofSlot: slot) == sample.start(ofSlot: slot + 1) || slot == 11)
        #expect(sample.top(ofSlot: slot + 1) - sample.top(ofSlot: slot) == sample.slotHeight)
    }
    #expect(sample.slotHeight == 50)
    #expect(sample.timeToY(0) == 0)
    #expect(sample.timeToY(1440) == 600)
}

@Test func invalidBoundariesAreRefused() {
    #expect(TemporalGridPartition(wholeMinutes: [1, 720, 1440], totalHeight: 100) == nil)
    #expect(TemporalGridPartition(wholeMinutes: [0, 720, 1439], totalHeight: 100) == nil)
    #expect(TemporalGridPartition(wholeMinutes: [0, 720, 720, 1440], totalHeight: 100) == nil)
    #expect(TemporalGridPartition(wholeMinutes: [0, 900, 800, 1440], totalHeight: 100) == nil)
    #expect(TemporalGridPartition(wholeMinutes: [0, 1440], totalHeight: 0) == nil)
}

@Test func timeToYAndBackIsTheIdentityInBothDirections() {
    for partition in [sample, other, sample.zoomed(viewportHeight: 600, zoomScale: 2.5)] {
        var minute = 0.0
        while minute <= 1440 {
            #expect(abs(partition.yToTime(partition.timeToY(minute)) - minute) < 1e-9)
            minute += 0.37
        }
        var y: CGFloat = 0
        while y <= partition.totalHeight {
            #expect(abs(partition.timeToY(partition.yToTime(y)) - y) < 1e-9)
            y += 0.73
        }
        #expect(partition.yToTime(-5) == 0)
        #expect(partition.yToTime(partition.totalHeight + 5) == 1440)
    }
}

@Test func timeToYIsStrictlyIncreasingAndContinuousAcrossBoundaries() {
    var previous: CGFloat = -1
    for minute in stride(from: 0.0, through: 1440.0, by: 0.5) {
        let y = sample.timeToY(minute)
        #expect(y > previous)
        previous = y
    }
    for boundary in sample.boundaries.dropFirst().dropLast() {
        #expect(abs(sample.timeToY(boundary + 1e-9) - sample.timeToY(boundary - 1e-9)) < 1e-6)
    }
}

@Test func fiveAndSeventeenMinuteEventsHaveTheirExactHeight() {
    // 10:00-10:17 lies in the 60 minute cell 600...660 (50 pt): 17/60 of it.
    #expect(abs(sample.height(from: 600, to: 617) - 50 * 17 / 60) < 1e-9)
    // 9:30-9:35 in the 30 minute cell 570...600: 5/30 of 50 pt.
    #expect(abs(sample.height(from: 570, to: 575) - 50 * 5 / 30) < 1e-9)
    // The same 5 minutes in the 8 hour cell are a sixth of a point: thin, but exact, never rounded up to fit text.
    #expect(abs(sample.height(from: 100, to: 105) - 50 * 5 / 480) < 1e-9)
}

@Test func anEventAcrossSeveralCellsIsTheDifferenceOfItsTwoEnds() {
    // 07:00 (in the 8 h cell) to 10:30 (halfway through 10:00-11:00).
    let expected = (50 * 4 + 50 * 0.5) - 50 * 420 / 480
    #expect(abs(sample.height(from: 420, to: 630) - expected) < 1e-9)
    #expect(abs(sample.timeToY(630) - 225) < 1e-9)
}

@Test func timesAtTheSameMinuteAndEventsStartingTogetherShareAY() {
    #expect(sample.timeToY(615) == sample.timeToY(615))
    let a = sample.height(from: 615, to: 615)
    #expect(a == 0)
    // Two events from 09:00: the same top, whatever their length.
    #expect(sample.timeToY(540) == sample.timeToY(540))
    #expect(sample.height(from: 540, to: 570) < sample.height(from: 540, to: 600))
}

@Test func eventsAtMidnightAreOnTheEdgesOfTheGrid() {
    #expect(sample.timeToY(0) == 0)
    #expect(abs(sample.height(from: 0, to: 120) - 50 * 120 / 480) < 1e-9)
    #expect(abs(sample.height(from: 1320, to: 1440) - 50) < 1e-9)
    #expect(sample.slot(containingMinute: 1440) == 11)
    #expect(sample.slot(containingMinute: 480) == 1)   // a boundary belongs to the later cell
    #expect(sample.slot(containingMinute: 479.999) == 0)
}

// MARK: Zoom

@Test func zoomOneFitsTheDayInTheViewportAndLargerZoomScalesEveryCellTheSame() {
    let one = sample.zoomed(viewportHeight: 600, zoomScale: 1)
    #expect(one.totalHeight == 600)
    for zoom in [1.0, 1.5, 2.0, 3.0] as [CGFloat] {
        let zoomed = sample.zoomed(viewportHeight: 600, zoomScale: zoom)
        #expect(zoomed.boundaries == sample.boundaries)                    // zooming never changes what a cell stands for
        #expect(zoomed.totalHeight == 600 * zoom)
        #expect(zoomed.slotHeight == sample.slotHeight * zoom)
        for slot in 0..<12 { #expect(zoomed.top(ofSlot: slot) == sample.top(ofSlot: slot) * zoom) }
        for minute in stride(from: 0.0, through: 1440.0, by: 7.3) { #expect(abs(zoomed.timeToY(minute) - sample.timeToY(minute) * zoom) < 1e-9) }
    }
    // A zoom under 1 is not allowed: the whole day always fits.
    #expect(sample.zoomed(viewportHeight: 600, zoomScale: 0.4).totalHeight == 600)
}

@Test func zoomKeepsTheOrderOfTimes() {
    let zoomed = sample.zoomed(viewportHeight: 600, zoomScale: 3)
    var previous: CGFloat = -1
    for minute in stride(from: 0.0, through: 1440.0, by: 3) {
        #expect(zoomed.timeToY(minute) > previous)
        previous = zoomed.timeToY(minute)
    }
}

// MARK: Interpolation

@Test func interpolationStartsAtAEndsAtBAndMeetsInTheMiddle() throws {
    let at0 = try #require(TemporalGridPartition.interpolated(from: sample, to: other, progress: 0))
    let at1 = try #require(TemporalGridPartition.interpolated(from: sample, to: other, progress: 1))
    let half = try #require(TemporalGridPartition.interpolated(from: sample, to: other, progress: 0.5))
    #expect(at0 == sample)
    #expect(at1 == other)
    for index in 0..<13 { #expect(half.boundaries[index] == (sample.boundaries[index] + other.boundaries[index]) / 2) }
    // A fractional boundary stays fractional: nothing is rounded to a whole minute.
    let quarter = try #require(TemporalGridPartition.interpolated(from: sample, to: other, progress: 0.25))
    #expect(quarter.boundaries.contains { $0 != $0.rounded() })
}

@Test func everyBlendIsAValidPartitionWithTheLinesWhereTheyWere() throws {
    for p in stride(from: 0.0, through: 1.0, by: 0.02) {
        let blend = try #require(TemporalGridPartition.interpolated(from: sample, to: other, progress: p))
        #expect(blend.boundaries.first == 0 && blend.boundaries.last == 1440)
        #expect(zip(blend.boundaries, blend.boundaries.dropFirst()).allSatisfy { $0 < $1 })
        #expect(blend.totalHeight == sample.totalHeight)
        #expect(blend.slotCount == sample.slotCount)
        for slot in 0..<12 { #expect(blend.top(ofSlot: slot) == sample.top(ofSlot: slot)) }       // the horizontal lines do not move
        // No cell is shorter than the shorter of its two ends (so the minimum cell length survives a blend).
        for slot in 0..<12 { #expect(blend.minutes(inSlot: slot) >= min(sample.minutes(inSlot: slot), other.minutes(inSlot: slot)) - 1e-9) }
    }
    #expect(TemporalGridPartition.interpolated(from: sample, to: TemporalGridPartition.uniform(slotCount: 10, totalHeight: 600), progress: 0.5) == nil)
}

@Test func anEventMovesContinuouslyAsTheProgressChanges() throws {
    // A 17 minute event at 10:00, followed along the whole blend in 1% steps: its top and its bottom move a bounded amount per step.
    var previous: (CGFloat, CGFloat)?
    var worst: CGFloat = 0
    for step in 0...100 {
        let blend = try #require(TemporalGridPartition.interpolated(from: sample, to: other, progress: Double(step) / 100))
        let now = (blend.timeToY(600), blend.timeToY(617))
        if let previous { worst = max(worst, abs(now.0 - previous.0), abs(now.1 - previous.1)) }
        previous = now
        #expect(now.1 > now.0)
    }
    #expect(worst < 6)       // 600 pt grid; a jump of a whole-minute rounding would still be small, so this guards against whole-cell jumps
}

// MARK: The existing axis

@Test func aPlannedPartitionIsAnExactTimelineAxisAndABlendIsOnlyApproximate() throws {
    let adapted = sample.timelineAxis()
    #expect(adapted.isExact)
    #expect(adapted.maximumError == 0)
    #expect(abs(adapted.axis.height - 600) < 1e-9)
    #expect(adapted.axis.segments.count == 12)
    for minute in [0, 17, 100, 479, 480, 600, 617, 1000, 1440] {
        #expect(abs(adapted.axis.y(minute: minute) - sample.timeToY(Double(minute))) < 1e-9)
    }
    let blend = try #require(TemporalGridPartition.interpolated(from: sample, to: other, progress: 0.31))
    let rough = blend.timelineAxis()
    #expect(!rough.isExact)
    #expect(rough.maximumError > 0)                      // the old contract rounds a boundary to a whole minute
    #expect(rough.axis.segments.count == 12)              // but a blend never loses a cell: boundaries stay at least 10 minutes apart
}
