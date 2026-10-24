import CoreGraphics
import Testing
@testable import OnAllApp

private typealias F = TemporalGridFixtures

/// A fixture run whose windows are 1...5 (nine days, a window reads the day before and two after), planned through a store.
private struct Rig {
    let scenario = F.demoTransRun()
    let store = TemporalGridStore()
    let bounds = 1...5
    var parameters: TemporalGridParameters {
        var p = TemporalGridParameters.hourly(slotCount: 12)
        p.viewportHeight = 640; p.allocation = scenario.parameters
        return p
    }
    func windowPartition(_ window: Int) -> TemporalGridPartition {
        store.plan(window: TemporalWindow(days: Array(scenario.days[(window - 1)...(window + 2)]), mainIndex: 1), parameters: parameters).partition
    }
    func partition(at position: Double) -> TemporalGridPartition {
        ContinuousDayAxis.partition(at: position, bounds: bounds) { windowPartition($0) }
    }
}

// MARK: Coordinates

@Test func daysAreSideBySideWithAFixedWidthAndTheWindowShowsTheOnesThatReachIt() {
    let geometry = DayAxisGeometry(dayWidth: 170)
    #expect(geometry.x(ofDay: 3, at: 3) == 0 && geometry.x(ofDay: 4, at: 3) == 170 && geometry.x(ofDay: 3, at: 3.25) == -42.5)
    #expect(geometry.position(startingAt: 3, translation: -85) == 3.5 && geometry.position(startingAt: 3, translation: 170) == 2)
    #expect(geometry.visibleDays(at: 3) == 3...4)                       // on a whole day: exactly two columns
    #expect(geometry.visibleDays(at: 3.25) == 3...5)                    // between: the third day's edge comes in
    #expect(geometry.visibleDays(at: 3.999) == 3...5)
    #expect(geometry.visibleDays(at: -1.5) == -2...0)                   // negative days are days too: the line is infinite
    for position in stride(from: -3.0, through: 40.0, by: 0.173) {
        let days = geometry.visibleDays(at: position)
        #expect(days.count <= 3)
        // Every visible day really reaches into the window, and no day outside does.
        for day in days { #expect(geometry.x(ofDay: Double(day) + 1, at: position) > 0 && geometry.x(ofDay: Double(day), at: position) < 2 * 170) }
        #expect(geometry.x(ofDay: Double(days.lowerBound - 1) + 1, at: position) <= 0)
        #expect(geometry.x(ofDay: Double(days.upperBound + 1), at: position) >= 2 * 170)
    }
}

@Test func theWindowsAndDaysPlannedForAreFewAndFollowThePosition() {
    let geometry = DayAxisGeometry(dayWidth: 170)
    let bounds = 1...5
    #expect(geometry.windows(at: 3, bounds: bounds) == [3])
    #expect(geometry.windows(at: 3.4, bounds: bounds) == [3, 4])
    #expect(geometry.windows(at: 5, bounds: bounds) == [5] && geometry.windows(at: 9, bounds: bounds) == [5] && geometry.windows(at: -4, bounds: bounds) == [1])
    #expect(geometry.planningDays(at: 3, bounds: bounds) == 2...5)
    #expect(geometry.planningDays(at: 3.4, bounds: bounds) == 2...6)
    for position in stride(from: 1.0, through: 5.0, by: 0.05) { #expect(geometry.planningDays(at: position, bounds: bounds).count <= 5) }
}

// MARK: The shared time

@Test func theSharedPartitionIsTheWindowsOwnOnWholeDaysAndTheStraightBlendBetween() {
    let rig = Rig()
    for window in 1...5 { #expect(rig.partition(at: Double(window)) == rig.windowPartition(window)) }
    let a = rig.windowPartition(2), b = rig.windowPartition(3)
    for fraction in [0.1, 0.25, 0.5, 0.9] {
        let blend = rig.partition(at: 2 + fraction)
        for index in 0..<blend.boundaries.count { #expect(abs(blend.boundaries[index] - ((1 - fraction) * a.boundaries[index] + fraction * b.boundaries[index])) < 1e-9) }
        #expect(blend.totalHeight == a.totalHeight && blend.slotCount == a.slotCount)       // the lines are where they were
    }
    #expect(rig.partition(at: -5) == rig.windowPartition(1) && rig.partition(at: 99) == rig.windowPartition(5))
}

@Test func theHorizontalProgressAndTheTimeBlendAreTheSameNumber() {
    let rig = Rig()
    var model = DayMoveModel(day: 2, bounds: rig.bounds)
    model.retarget(to: 4)
    for _ in 0..<40 {
        model.advance(by: 1.0 / 60)
        let fraction = model.progress
        let a = rig.windowPartition(model.day), b = rig.windowPartition(min(model.day + 1, 5))
        let blend = rig.partition(at: model.position)
        if model.day < 5 { for index in 0..<blend.boundaries.count { #expect(abs(blend.boundaries[index] - ((1 - fraction) * a.boundaries[index] + fraction * b.boundaries[index])) < 1e-9) } }
    }
}

@Test func oneSharedTimeToYForEveryDayOnScreenAndNoJumpWhileMoving() {
    let rig = Rig()
    let geometry = DayAxisGeometry(dayWidth: 170)
    var previous: [CGFloat]?
    var worst: CGFloat = 0
    for step in 0...800 {
        let position = 1 + 4 * Double(step) / 800
        let shared = rig.partition(at: position)
        // Every rendered day takes y from this one partition: the same minute is at the same y in every column.
        for day in geometry.renderedDays(at: position) {
            let entities = GridDayEntities.make(rig.scenario.days[day])
            let placed = GridPlacement.place(entities, partition: shared, metrics: .standard(), transactionPitch: 26)
            for event in placed.events { #expect(event.top == shared.timeToY(Double(event.startMinute)) && event.bottom == shared.timeToY(Double(event.endMinute))) }
        }
        let ys = (0...24).map { shared.timeToY(Double($0 * 60)) }
        if let previous { for (a, b) in zip(previous, ys) { worst = max(worst, abs(a - b)) } }
        previous = ys
    }
    #expect(worst < 8, "largest move of an hour between two steps of 1/200 day: \(worst)")           // a bounded move: no jump
}

// MARK: Virtualization and cache

@Test func onlyTheVisibleDaysAreBuiltAndAWholeSweepPlansEachWindowOnce() {
    let rig = Rig()
    let geometry = DayAxisGeometry(dayWidth: 170)
    var builtDays = Set<Int>()
    var entityBuilds = 0
    var maximumRendered = 0
    var cache: [Int: GridDayEntities] = [:]
    func sweep(_ positions: [Double]) {
        for position in positions {
            _ = rig.partition(at: position)
            let rendered = geometry.renderedDays(at: position)
            maximumRendered = max(maximumRendered, rendered.count)
            for day in rendered where cache[day] == nil { cache[day] = GridDayEntities.make(rig.scenario.days[day]); entityBuilds += 1; builtDays.insert(day) }
        }
    }
    let forward = stride(from: 1.0, through: 5.0, by: 0.01).map { $0 }
    sweep(forward)
    let plansAfterForward = rig.store.planRuns, profilesAfterForward = rig.store.profileBuilds
    #expect(plansAfterForward == 5)                              // windows 1 ... 5, once each, however many frames
    #expect(profilesAfterForward <= 9)                           // days 0 ... 8 at most, once each
    #expect(maximumRendered <= 3)
    #expect(builtDays == Set(1...6) && entityBuilds == 6)         // entities only for days that were ever on screen (day 6 is the edge of the window at 5)
    // Back again, and again forwards: nothing new is planned or built.
    sweep(forward.reversed())
    sweep(forward)
    #expect(rig.store.planRuns == plansAfterForward && rig.store.profileBuilds == profilesAfterForward && entityBuilds == 6)
    #expect(rig.store.hitRate > 0.9)
}

@Test func theCacheIsBoundedAndANewDayFindsNothingStale() {
    let rig = Rig()
    let small = TemporalGridStore(limit: 3)
    var p = rig.parameters
    for window in [1, 2, 3, 4, 5, 1, 2] { _ = small.plan(window: TemporalWindow(days: Array(rig.scenario.days[(window - 1)...(window + 2)]), mainIndex: 1), parameters: p) }
    #expect(small.entryCount <= 6)
    // A changed setting is a different key: nothing planned for the old one is reused.
    let before = rig.store.planRuns
    _ = rig.windowPartition(2)
    p.viewportHeight = 700
    _ = rig.store.plan(window: TemporalWindow(days: Array(rig.scenario.days[1...4]), mainIndex: 1), parameters: p)
    #expect(rig.store.planRuns == before + 2)
}

@Test func everyEventAndTransactionKeepsItsIdentityWhereverTheWindowIs() {
    let rig = Rig()
    let geometry = DayAxisGeometry(dayWidth: 170)
    var firstSeen: [Int: [String]] = [:]
    for position in stride(from: 1.0, through: 5.0, by: 0.07) {
        let shared = rig.partition(at: position)
        for day in geometry.renderedDays(at: position) {
            let source = rig.scenario.days[day]
            let entities = GridDayEntities.make(source)
            let placed = GridPlacement.place(entities, partition: shared, metrics: .standard(), transactionPitch: 26)
            let ids = placed.events.map(\.id).sorted() + placed.transactions.map(\.id).sorted()
            #expect(placed.events.map(\.id).sorted() == source.events.map(\.id).sorted())
            #expect(placed.transactions.map(\.id).sorted() == (source.transactions.map(\.id) + source.events.flatMap { $0.linked.map(\.id) }).sorted())
            if let known = firstSeen[day] { #expect(known == ids, "day \(day) at \(position)") } else { firstSeen[day] = ids }
            for event in placed.events { #expect(event.startMinute == source.events.first { $0.id == event.id }?.startMinute) }
        }
    }
}

// MARK: The move model

@Test func aDragSetsThePositionWithinTheBoundsAndAFlickLandsAhead() {
    var model = DayMoveModel(day: 3, bounds: 1...5)
    #expect(model.phase == .resting && model.position == 3 && model.day == 3 && model.progress == 0)
    model.drag(to: 3.4)
    #expect(model.phase == .dragging && model.position == 3.4 && model.day == 3 && abs(model.progress - 0.4) < 1e-12)
    model.drag(to: 9); #expect(model.position == 5)
    model.drag(to: -9); #expect(model.position == 1)
    model.drag(to: 3.3)
    model.release(velocity: 0)
    #expect(model.phase == .settling && model.target == 3)                        // slowly: back to the nearer day
    model.beginDrag(); model.drag(to: 3.3)
    model.release(velocity: 4)                                                    // a flick towards later days
    #expect(model.target == 4 || model.target == 5)
    model.beginDrag(); model.drag(to: 3.0)
    model.release(velocity: 40)
    #expect(model.target - 3 <= DayMoveModel.maximumHop)                          // never more than the hop limit
}

@Test func theSpringIsExactSoTheFrameRateDoesNotMatterAndItSettlesOnTheDay() {
    var coarse = DayMoveModel(day: 1, bounds: 1...5), fine = coarse
    coarse.retarget(to: 4); fine.retarget(to: 4)
    coarse.advance(by: 0.2)
    for _ in 0..<12 { fine.advance(by: 0.2 / 12) }
    #expect(abs(coarse.position - fine.position) < 1e-9 && abs(coarse.velocity - fine.velocity) < 1e-9)
    var settled = DayMoveModel(day: 1, bounds: 1...5)
    settled.retarget(to: 4)
    var frames = 0
    while settled.isMoving && frames < 600 { settled.advance(by: 1.0 / 60); frames += 1 }
    #expect(settled.phase == .resting && settled.position == 4 && settled.velocity == 0)
    #expect(frames < 90)                                                           // about a second at most
}

@Test func aReversalHasNoJumpAndRapidTapsAddUpWithinTheBounds() {
    var model = DayMoveModel(day: 2, bounds: 1...5)
    model.retarget(by: 1); model.retarget(by: 1); model.retarget(by: 1)
    #expect(model.target == 5)                                                     // 2 + 3, from the day being headed for each time
    model.retarget(by: 1)
    #expect(model.target == 5)                                                     // the bound
    for _ in 0..<12 { model.advance(by: 1.0 / 60) }
    let flying = model.position, speed = model.velocity
    #expect(flying > 2 && flying < 5 && speed > 0)
    // The finger comes down in mid-flight: the position is where it was, and the motion stops under it.
    model.beginDrag()
    #expect(model.position == flying && model.velocity == 0 && model.phase == .dragging)
    // Letting go the other way turns round without a jump.
    model.release(velocity: -3)
    #expect(model.target < Int(flying.rounded(.up)) && model.position == flying)
    var previous = model.position
    var worstStep = 0.0
    while model.isMoving { model.advance(by: 1.0 / 60); worstStep = max(worstStep, abs(model.position - previous)); previous = model.position }
    #expect(worstStep < 0.2)
    // A tap in mid-settle keeps the speed it has: no jump in the velocity.
    var tapped = DayMoveModel(day: 1, bounds: 1...5)
    tapped.retarget(to: 4); for _ in 0..<6 { tapped.advance(by: 1.0 / 60) }
    let before = (tapped.position, tapped.velocity)
    tapped.retarget(to: 2)
    #expect(tapped.position == before.0 && tapped.velocity == before.1)
}

@Test func theSameEventsGiveTheSameWindowPositionsAndNeverLeaveTheBounds() {
    func run() -> [Double] {
        var model = DayMoveModel(day: 3, bounds: 1...5)
        var trace: [Double] = []
        let script: [(Int, () -> Void)] = [(0, { model.retarget(by: 1) }), (10, { model.retarget(by: 1) }), (14, { model.beginDrag(); model.drag(to: model.position - 0.4) }),
                                           (20, { model.drag(to: model.position + 1.2) }), (24, { model.release(velocity: 20) }), (60, { model.retarget(by: -2) }), (75, { model.retarget(by: -9) })]
        for frame in 0..<220 {
            for (at, action) in script where at == frame { action() }
            model.advance(by: 1.0 / 60)
            trace.append(model.position)
            #expect(model.position >= 1 && model.position <= 5)
        }
        return trace
    }
    #expect(run() == run())
}

// MARK: The anchor

@Test func theTimeAtTheMiddleOfTheScreenStaysPutWhileTheDaysMoveAtEveryZoom() {
    let rig = Rig()
    let viewport: CGFloat = 640, focal = viewport / 2
    for zoom in [1, 1.5, 2, 3.7, 5, 8] as [CGFloat] {
        // Anchor a time in the middle part of the day (never clamped by the ends of the day) and move across all the windows and back.
        for anchor in [10.5 * 60, 13.25 * 60, 15.0 * 60] {
            var worst = 0.0, clampedSteps = 0, steps = 0
            var first: CGFloat?
            for position in (stride(from: 1.0, through: 5.0, by: 0.05).map { $0 } + stride(from: 5.0, through: 1.0, by: -0.05).map { $0 }) {
                let result = ContinuousDayAxis.anchoredOffset(time: anchor, partition: rig.partition(at: position), zoom: zoom, viewport: viewport, focal: focal)
                steps += 1
                #expect(result.offset >= 0 && result.offset <= max(0, viewport * zoom - viewport) + 1e-9)
                if zoom == 1 { #expect(result.offset == 0) }
                if result.clamped { clampedSteps += 1 } else { worst = max(worst, result.residualMinutes) }
                if position == 1.0 { first = first ?? result.offset }
            }
            #expect(worst < 1e-6, "zoom \(zoom) anchor \(anchor)")
            if zoom >= 2 { #expect(clampedSteps == 0, "zoom \(zoom): the middle of the day has room at every position") }
            if zoom == 1 { #expect(clampedSteps > steps / 2) }                    // nothing to scroll at 1x: the time cannot stay put (only where it happens to be the middle already)
            // Out and back: the offset returns to what it was.
            let back = ContinuousDayAxis.anchoredOffset(time: anchor, partition: rig.partition(at: 1), zoom: zoom, viewport: viewport, focal: focal)
            #expect(back.offset == first)
        }
    }
}

@Test func atTheEndsOfTheDayTheAnchorStopsAtTheEdgeOfTheGrid() {
    let rig = Rig()
    let viewport: CGFloat = 640
    for zoom in [2, 8] as [CGFloat] {
        let top = ContinuousDayAxis.anchoredOffset(time: 20, partition: rig.partition(at: 2.5), zoom: zoom, viewport: viewport, focal: viewport / 2)
        #expect(top.clamped && top.offset == 0 && top.residualMinutes > 0)
        let bottom = ContinuousDayAxis.anchoredOffset(time: 1430, partition: rig.partition(at: 2.5), zoom: zoom, viewport: viewport, focal: viewport / 2)
        #expect(bottom.clamped && bottom.offset == viewport * zoom - viewport && bottom.residualMinutes > 0)
    }
    // The time under the middle of the screen at a rest state is a valid anchor for the next move (round trip through the offset).
    let partition = rig.partition(at: 3)
    let offset: CGFloat = 1234
    let time = ContinuousDayAxis.time(atOffset: offset, partition: partition, zoom: 5, viewport: viewport, focal: viewport / 2)
    let again = ContinuousDayAxis.anchoredOffset(time: time, partition: partition, zoom: 5, viewport: viewport, focal: viewport / 2)
    #expect(!again.clamped && abs(again.offset - offset) < 1e-6)
}

@Test func aFrameOfTheContinuousSpaceDoesNoPlanning() {
    let rig = Rig()
    // Warm: the windows are planned.
    for window in 1...5 { _ = rig.windowPartition(window) }
    rig.store.resetCounters()
    let geometry = DayAxisGeometry(dayWidth: 170)
    let entities = (0...8).map { GridDayEntities.make(rig.scenario.days[$0]) }
    let clock = ContinuousClock()
    var model = DayMoveModel(day: 1, bounds: 1...5)
    model.retarget(to: 5)
    var frames = 0
    let elapsed = clock.measure {
        while model.isMoving {
            model.advance(by: 1.0 / 120)
            frames += 1
            let shared = rig.partition(at: model.position).zoomed(viewportHeight: 640, zoomScale: 3)
            for day in geometry.renderedDays(at: model.position) { _ = GridPlacement.place(entities[day], partition: shared, metrics: .standard(), transactionPitch: 26) }
            _ = HourAxis.layout(partition: shared, metrics: HourAxis.Metrics())
        }
    }
    let ms = (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) / Double(max(1, frames))
    print("CONT  frame of the continuous space (partition blend + 3 columns + axis): \(String(format: "%.3f", ms)) ms over \(frames) frames; plans \(rig.store.planRuns), profiles \(rig.store.profileBuilds)")
    #expect(rig.store.planRuns == 0 && rig.store.profileBuilds == 0)
    #expect(ms < 4)
}
