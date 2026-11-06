import CoreGraphics
import Testing
@testable import OnAllApp

private typealias F = TemporalGridFixtures
private typealias C = HorizontalDragClassifier

// MARK: The classifier

private func samples(_ points: [(Double, CGFloat, CGFloat)]) -> C {
    var classifier = C()
    classifier.begin(.init(time: points[0].0, x: points[0].1, y: points[0].2))
    for point in points.dropFirst() { classifier.move(.init(time: point.0, x: point.1, y: point.2)) }
    return classifier
}

@Test func aMostlySidewaysMovementBecomesASwipeAfterFourPointsAndAMostlyVerticalOneAScroll() {
    var c = C()
    c.begin(.init(time: 0, x: 100, y: 100))
    #expect(c.move(.init(time: 0.01, x: 102, y: 100)) == .undecided)           // not yet
    #expect(c.move(.init(time: 0.02, x: 104, y: 101)) == .horizontal)          // 4 points sideways, mostly sideways
    #expect(c.translation == 4)
    // The decision stays: coming back vertical later does not turn a swipe into a scroll.
    c.move(.init(time: 0.05, x: 104, y: 160)); #expect(c.decision == .horizontal)
    var v = C()
    v.begin(.init(time: 0, x: 100, y: 100))
    #expect(v.move(.init(time: 0.01, x: 101, y: 104)) == .undecided)
    #expect(v.move(.init(time: 0.02, x: 102, y: 107)) == .vertical)
    // A diagonal that is neither way stays undecided until one wins by the margin.
    var d = C()
    d.begin(.init(time: 0, x: 0, y: 0))
    #expect(d.move(.init(time: 0.01, x: 5, y: 5)) == .undecided)
    #expect(d.move(.init(time: 0.02, x: 12, y: 6)) == .horizontal)
}

@Test func theTranslationIsFromWhereTheFingerCameDownSoTheContentIsUnderItFromTheStart() {
    let c = samples([(0, 200, 300), (0.01, 197, 300), (0.02, 193, 301), (0.03, 188, 301)])
    #expect(c.decision == .horizontal && c.translation == -12)                    // the whole 12 points, not 12 minus a recognition threshold
}

@Test func theSpeedIsTheLastEightyMillisecondsAndZeroForAFingerThatStopped() {
    let moving = samples([(0, 0, 0), (0.02, 10, 0), (0.04, 20, 0), (0.06, 30, 0), (0.08, 40, 0), (0.10, 50, 0)])
    #expect(abs(moving.velocity(at: 0.10) - 500) < 1)                              // 10 points per 20 ms
    #expect(moving.velocity(at: 0.10 + C.velocityWindow + 0.01) == 0)                       // lifted longer ago than the window: stopped
    #expect(moving.velocity(at: 0.15) > 0)                                           // 50 ms after the last sample is still within it
    let stopped = samples([(0, 0, 0), (0.02, 40, 0), (0.04, 80, 0), (0.30, 80, 0)])
    #expect(stopped.velocity(at: 0.31) == 0)                                       // a fast move, then a pause: no flick
    let reversing = samples([(0, 0, 0), (0.02, 40, 0), (0.04, 80, 0), (0.06, 60, 0), (0.08, 20, 0), (0.10, -20, 0)])
    #expect(reversing.velocity(at: 0.10) < 0)                                      // the direction it is going now, not where it came from
    #expect(C().velocity(at: 0) == 0)
}

// MARK: A swipe through the explicit model

/// What the screen does with the events, without a screen: touch samples → classifier → `DayMoveModel`, stepped like the display link.
private struct Swipe {
    var model: DayMoveModel
    let dayWidth: CGFloat
    var classifier = C()
    var start = 0.0
    var now = 0.0
    var positions: [Double] = []
    var caught: Int?

    init(day: Int, dayWidth: CGFloat = 170) { model = DayMoveModel(day: day, bounds: 1...5); self.dayWidth = dayWidth; positions = [Double(day)] }

    mutating func step(_ seconds: Double) {
        var left = seconds
        while left > 1e-12 { let dt = min(left, 1.0 / 120); model.advance(by: dt); now += dt; left -= dt; positions.append(model.position) }
    }

    mutating func down(_ x: CGFloat) {
        if model.phase == .settling { caught = model.target; model.beginDrag() }
        classifier.begin(.init(time: now, x: x, y: 300))
    }
}

/// Plays a finger along `xs` (one sample per 16 ms) and lets go: the screen's own mapping from translation to position.
private func swipe(_ xs: [CGFloat], from day: Int, dayWidth: CGFloat = 170, hold: Double = 0, existing: Swipe? = nil) -> Swipe {
    var run = existing ?? Swipe(day: day, dayWidth: dayWidth)
    run.down(xs[0])
    var began = false
    var origin = run.model.position
    for x in xs.dropFirst() {
        run.step(0.016)
        if run.classifier.move(.init(time: run.now, x: x, y: 300)) == .horizontal {
            if !began { began = true; if run.model.phase != .dragging { run.model.beginDrag() }; origin = run.model.position }
            run.model.drag(to: origin - Double(run.classifier.translation / dayWidth))
            run.positions.append(run.model.position)
        }
    }
    if hold > 0 { run.step(hold) }
    if began {
        let velocity = -Double(run.classifier.velocity(at: run.now) / dayWidth)
        run.model.release(velocity: velocity)
    } else if let caught = run.caught, run.model.phase == .dragging {
        run.model.retarget(to: caught)
    }
    return run
}

private func line(from: CGFloat, to: CGFloat, count: Int) -> [CGFloat] { (0...count).map { from + (to - from) * CGFloat($0) / CGFloat(count) } }

@Test func theDragMapsLinearlyToThePositionAndAShortSlowOneGoesBack() {
    var run = swipe(line(from: 300, to: 260, count: 10), from: 3)                    // 40 points left at 25 points per frame... then rest
    // Linear: 40 points of a 170 point day = 40/170 of a day, from the day it started on (the first 4 points are part of the distance too).
    #expect(abs(run.model.position - (3 + 40.0 / 170)) < 1e-9)
    #expect(run.model.phase == .settling)
    run.step(2)
    #expect(run.model.phase == .resting && run.model.position == 3)                  // short and slow (it stopped before letting go): back to the day it was on
}

@Test func aLongDragCarriesOnToTheNextDayEvenWhenItEndsSlowly() {
    var run = swipe(line(from: 320, to: 200, count: 20), from: 3, hold: 0.2)       // 120 points: more than half a day, then paused
    #expect(run.model.target == 4)
    run.step(2)
    #expect(run.model.position == 4)
}

@Test func aShortFastFlickCarriesOnAndAFasterOneCarriesFurtherButNeverPastTheHopLimit() {
    let slowFlick = swipe(line(from: 300, to: 270, count: 3), from: 3)               // 30 points in 48 ms: ~600 pt/s
    #expect(slowFlick.model.target == 4)
    let fast = swipe(line(from: 380, to: 120, count: 4), from: 2)                    // 260 points in 64 ms: ~4000 pt/s
    #expect(fast.model.target > 3 && fast.model.target - 2 <= DayMoveModel.maximumHop)
    let backwards = swipe(line(from: 100, to: 330, count: 4), from: 4)
    #expect(backwards.model.target < 4)
}

@Test func aSwipeCancelledByASecondFingerSettlesOnTheNearestDay() {
    var run = swipe(line(from: 300, to: 250, count: 5), from: 3, hold: 0.3)
    // The recogniser is cancelled: the screen releases with no speed.
    run.model.release(velocity: 0)
    run.step(2)
    #expect(run.model.position == 3)
}

@Test func aFingerDownInAFlightStopsItUnderTheFingerAndAPlainTouchLetsItCarryOn() {
    var run = Swipe(day: 1)
    run.model.retarget(to: 4); run.step(0.18)
    let flying = run.model.position, speed = run.model.velocity
    #expect(flying > 1 && flying < 4 && speed > 0)
    run.down(200)                                                                    // a finger lands on the moving days
    #expect(run.model.phase == .dragging && run.model.position == flying && run.model.velocity == 0)
    let before = run.positions.count
    run.step(0.2)
    #expect(run.positions[before...].allSatisfy { $0 == flying })                    // nothing moves under the finger
    run.model.retarget(to: run.caught!)                                              // it lifted without swiping
    run.step(2)
    #expect(run.model.position == 4)
}

@Test func aNewSwipeTakesOverAFlightWithoutAJumpAndWithoutWaiting() {
    var first = swipe(line(from: 380, to: 140, count: 6), from: 1)                   // a flick towards later days
    #expect(first.model.phase == .settling)
    first.step(0.15)
    let flying = first.model.position
    first.positions = [flying]
    let second = swipe(line(from: 150, to: 330, count: 12), from: 1, existing: first)   // grabbed and dragged back before the flight ended
    #expect(abs(second.positions[0] - flying) < 1e-9)
    // Every step of the position, from the grab on, is a small step: no jump when the finger takes over.
    var worst = 0.0
    for (a, b) in zip(second.positions, second.positions.dropFirst()) { worst = max(worst, abs(b - a)) }
    #expect(worst < 0.12, "largest step \(worst)")
    #expect(second.model.target < Int(flying.rounded(.up)))                           // and it turned round
}

@Test func swipesInQuickSuccessionAddUpWithNoIgnoredInputAndStayInsideTheDays() {
    var run = Swipe(day: 1)
    for _ in 0..<4 {
        run = swipe(line(from: 330, to: 130, count: 8), from: 1, existing: run)     // each lands on a moving window
        run.step(0.09)
    }
    #expect(run.model.position <= 5 && run.model.position >= 1)
    #expect(run.model.target >= 4)                                                   // four flicks carried it well on, none was dropped
    var worst = 0.0
    for (a, b) in zip(run.positions, run.positions.dropFirst()) { worst = max(worst, abs(b - a)) }
    #expect(worst < 0.2, "largest step \(worst)")
    run.step(3)
    #expect(run.model.phase == .resting && run.model.position == Double(run.model.target))
}

// MARK: The anchor through every kind of interruption

private struct AnchorRig {
    let scenario = F.demoTransRun()
    let store = TemporalGridStore()
    func windowPartition(_ window: Int) -> TemporalGridPartition {
        var p = TemporalGridParameters.hourly(slotCount: 12)
        p.viewportHeight = 640; p.allocation = scenario.parameters
        return store.plan(window: TemporalWindow(days: Array(scenario.days[(window - 1)...(window + 2)]), mainIndex: 1), parameters: p).partition
    }
    func partition(_ position: Double) -> TemporalGridPartition { ContinuousDayAxis.partition(at: position, bounds: 1...5) { windowPartition($0) } }
}

@Test func theAnchorIsTakenOnTheFirstStepAndHeldWhileTheDaysMove() {
    let rig = AnchorRig()
    var anchor = AnchorState(position: 2)
    var offset: CGFloat = 900                                                         // 3x: somewhere in the middle of the day
    let time = ContinuousDayAxis.time(atOffset: offset, partition: rig.partition(2), zoom: 3, viewport: 640, focal: 320)
    for position in stride(from: 2.0, through: 4.0, by: 0.05) {
        let result = anchor.offset(forPosition: position, currentOffset: offset, userMoved: false, zoom: 3, viewport: 640, focal: 320, partitionAt: rig.partition)
        offset = result.offset
        #expect(abs(ContinuousDayAxis.time(atOffset: offset, partition: rig.partition(position), zoom: 3, viewport: 640, focal: 320) - time) < 1e-6)
    }
    #expect(abs((anchor.time ?? -1) - time) < 1e-9)
}

@Test func whenThePersonScrollsOrPinchesInAFlightTheAnchorIsTakenAgainFromWhereTheyLeft() {
    let rig = AnchorRig()
    var anchor = AnchorState(position: 2)
    var offset: CGFloat = 900
    let first = anchor.offset(forPosition: 2.2, currentOffset: offset, userMoved: false, zoom: 3, viewport: 640, focal: 320, partitionAt: rig.partition)
    offset = first.offset
    // They scroll by 150 points while the days are still moving; the offset on screen is theirs.
    offset += 150
    let theirTime = ContinuousDayAxis.time(atOffset: offset, partition: rig.partition(2.2), zoom: 3, viewport: 640, focal: 320)
    let second = anchor.offset(forPosition: 2.4, currentOffset: offset, userMoved: true, zoom: 3, viewport: 640, focal: 320, partitionAt: rig.partition)
    #expect(abs((anchor.time ?? -1) - theirTime) < 1e-9)                              // the new anchor is what they are looking at
    #expect(abs(ContinuousDayAxis.time(atOffset: second.offset, partition: rig.partition(2.4), zoom: 3, viewport: 640, focal: 320) - theirTime) < 1e-6)
    // A pinch changes the zoom as well: the anchor is again what is at the middle at the new zoom.
    offset = 1500
    let pinchedTime = ContinuousDayAxis.time(atOffset: offset, partition: rig.partition(2.4), zoom: 6, viewport: 640, focal: 320)
    _ = anchor.offset(forPosition: 2.6, currentOffset: offset, userMoved: true, zoom: 6, viewport: 640, focal: 320, partitionAt: rig.partition)
    #expect(abs((anchor.time ?? -1) - pinchedTime) < 1e-9)
    // While they hold the scroll the move does not touch it, and forgets the anchor; the first step after they let go takes a new one.
    anchor.release(at: 3.0)
    #expect(anchor.time == nil && anchor.position == 3.0)
    _ = anchor.offset(forPosition: 3.1, currentOffset: 1200, userMoved: false, zoom: 6, viewport: 640, focal: 320, partitionAt: rig.partition)
    #expect(anchor.time != nil)
}

@Test func theDaysOnScreenAndTheTimeAxisUseOnePositionWhateverTheSwipeDoes() {
    let rig = AnchorRig()
    let geometry = DayAxisGeometry(dayWidth: 170)
    let run = swipe(line(from: 330, to: 150, count: 12), from: 2)
    var settled = run
    settled.step(1.5)
    var worstStep: CGFloat = 0
    var previous: [CGFloat]?
    for position in settled.positions {
        let shared = rig.partition(position)
        let rendered = geometry.renderedDays(at: position)
        // The columns' x and the axis' y both come from this one number.
        let xs = rendered.map { geometry.x(ofDay: Double($0), at: position) }
        #expect(xs == xs.sorted() && zip(xs, xs.dropFirst()).allSatisfy { abs($1 - $0 - 170) < 1e-9 })
        let ys = (0...24).map { shared.timeToY(Double($0 * 60)) }
        if let previous { for (a, b) in zip(previous, ys) { worstStep = max(worstStep, abs(a - b)) } }
        previous = ys
    }
    #expect(worstStep < 6, "largest hour movement between two frames \(worstStep)")
}

@Test func theDayCountAcrossTheScreenIsOneNumberAndTheStructureFollowsIt() {
    for columns in [2, 3, 4] {
        let geometry = DayAxisGeometry(dayWidth: 120, visibleColumns: columns)
        #expect(geometry.visibleDays(at: 3).count == columns)
        #expect(geometry.visibleDays(at: 3.4).count == columns + 1)
        #expect(geometry.renderedDays(at: 3.4) == geometry.visibleDays(at: 3.4))
        #expect(geometry.x(ofDay: 4, at: 3) == 120)
    }
}

@Test func aFrameOfASwipeCostsLittleAndPlansNothing() {
    let rig = AnchorRig()
    for window in 1...5 { _ = rig.windowPartition(window) }
    rig.store.resetCounters()
    var anchor = AnchorState(position: 1)
    let clock = ContinuousClock()
    var run = Swipe(day: 1)
    run.model.retarget(to: 5)
    var frames = 0
    var offset: CGFloat = 800
    let elapsed = clock.measure {
        while run.model.isMoving {
            run.model.advance(by: 1.0 / 120); frames += 1
            offset = anchor.offset(forPosition: run.model.position, currentOffset: offset, userMoved: false, zoom: 4, viewport: 640, focal: 320, partitionAt: rig.partition).offset
        }
    }
    let ms = (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) / Double(max(1, frames))
    print("SWIPE  model + anchor step: \(String(format: "%.4f", ms)) ms over \(frames) frames; plans \(rig.store.planRuns)")
    #expect(rig.store.planRuns == 0 && rig.store.profileBuilds == 0)
    #expect(ms < 1)
}
