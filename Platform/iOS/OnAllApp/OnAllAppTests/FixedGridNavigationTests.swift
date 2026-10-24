import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

// The fixed grid's continuous day move and pinch zoom in Browse: what is planned and when, what a move may do to the selected day and the cache, and that the days and the time
// axis stay together. (The spring, the anchor and the geometry are the prototype's own and tested in `ContinuousGridTests`; here they are used on the product's data.)

private let seoul = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let newYork = (try? DisplayTimeZone(identifier: "America/New_York")) ?? { fatalError("tz") }()

private struct Rig {
    let scenario: AxisStabilityScenario
    let timelines: [Int: DayTimeline]
    let first: Int
    var environment: FixedGridEnvironment

    init(_ prefix: String, height: CGFloat = 640) throws {
        scenario = try #require(TemporalGridFixtures.all.first { $0.name.hasPrefix(prefix) })
        let days = try scenario.days.map { try fixtureTimeline($0) }
        first = days[0].day.daysSinceUnixEpoch
        timelines = Dictionary(uniqueKeysWithValues: days.map { ($0.day.daysSinceUnixEpoch, $0) })
        environment = FixedGridEnvironment(viewportHeight: height, contentWidth: 165, textScale: scenario.textScale)
    }

    func inputs(revision: Int = 0, overriding: [Int: DayTimeline] = [:]) -> FixedGridBrowseModel.Inputs {
        let merged = timelines.merging(overriding) { $1 }
        return FixedGridBrowseModel.Inputs(zone: seoul, environment: environment, timelineFor: { merged[$0.daysSinceUnixEpoch] }, revision: revision)
    }
    func strip(window: Int) -> [StripDay] { (-1...2).map { StripDay(day: LocalDate(daysSinceUnixEpoch: window + $0), timeline: timelines[window + $0]) } }
}

// MARK: Planning

@MainActor
@Test func aWindowPlannedForTheSwipeIsTheWindowTheFixedBrowseDrawsAtRest() throws {
    for prefix in ["14 ", "17 ", "18 ", "19 "] {
        let rig = try Rig(prefix)
        let window = rig.first + 2
        let model = FixedGridBrowseModel()
        let partition = model.partition(window: window, inputs: rig.inputs())
        let decision = model.decision(window: window, zoomKey: 4, inputs: rig.inputs())
        let rest = FixedGridBrowseModel()
        let drawn = try #require(rest.window(strip: rig.strip(window: window), zone: seoul, environment: rig.environment))
        #expect(partition == drawn.partition, "\(prefix) partition")
        #expect(decision.layout == drawn.layout, "\(prefix) layout")
    }
}

@MainActor
@Test func theWindowsAroundTheSelectedDayArePlannedOffTheMainThreadAndFramesOnlyFindThem() async throws {
    let rig = try Rig("18 ")
    let selected = rig.first + 2
    let model = FixedGridBrowseModel()
    var ready = 0
    model.warm(windows: [selected, selected + 1, selected - 1, selected + 2], inputs: rig.inputs()) { ready += 1 }
    #expect(model.framePlans == 0)                                                    // nothing was planned by asking
    for _ in 0..<200 where model.backgroundPlans < 4 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(model.backgroundPlans == 4 && ready == 4 && model.framePlans == 0)
    // Every position between the windows is a blend of planned ones: no plan runs, whatever the position.
    let bounds = (selected - 1)...(selected + 2)
    for step in 0...90 {
        let position = Double(selected - 1) + Double(step) / 30
        let shown = model.shared(position: position, bounds: bounds, inputs: rig.inputs())
        #expect(shown.boundaries.first == 0 && shown.boundaries.last == 1440 && zip(shown.boundaries, shown.boundaries.dropFirst()).allSatisfy { $0 < $1 })
    }
    #expect(model.framePlans == 0)
    // At a whole day the shared partition is the planned one; between two it is their blend at the fraction.
    let a = model.partition(window: selected, inputs: rig.inputs()), b = model.partition(window: selected + 1, inputs: rig.inputs())
    #expect(model.shared(position: Double(selected), bounds: bounds, inputs: rig.inputs()) == a)
    #expect(model.shared(position: Double(selected) + 0.25, bounds: bounds, inputs: rig.inputs()) == TemporalGridPartition.interpolated(from: a, to: b, progress: 0.25))
}

@MainActor
@Test func aFrameThatOutrunsThePlanningPlansItselfOnceAndCountsIt() throws {
    let rig = try Rig("14 ")
    let model = FixedGridBrowseModel()
    let window = rig.first + 3
    _ = model.shared(position: Double(window) + 0.5, bounds: (window - 1)...(window + 2), inputs: rig.inputs())
    #expect(model.framePlans == 2)                                                   // the two windows around the position, each once
    _ = model.shared(position: Double(window) + 0.6, bounds: (window - 1)...(window + 2), inputs: rig.inputs())
    #expect(model.framePlans == 2)
}

@MainActor
@Test func aChangedDayReplansTheWindowsThatReadItAndOnlyThose() throws {
    let rig = try Rig("14 ")
    let model = FixedGridBrowseModel()
    let w = rig.first + 2
    _ = model.partition(window: w, inputs: rig.inputs(revision: 1))
    _ = model.partition(window: w + 4, inputs: rig.inputs(revision: 1))
    #expect(model.framePlans == 2)
    // The same days read again (a new revision, equal content): nothing is planned again.
    _ = model.partition(window: w, inputs: rig.inputs(revision: 2))
    _ = model.partition(window: w + 4, inputs: rig.inputs(revision: 2))
    #expect(model.framePlans == 2)
    // One day changes: the window that reads it is planned again, the other keeps its plan.
    let changed = try fixtureTimeline(TemporalGridFixtures.day(w - rig.first - 1, events: [(8 * 60, 9 * 60), (8 * 60 + 5, 9 * 60), (8 * 60 + 10, 9 * 60)], transactions: [500, 501]))
    _ = model.partition(window: w, inputs: rig.inputs(revision: 3, overriding: [w - 1: changed]))
    _ = model.partition(window: w + 4, inputs: rig.inputs(revision: 3, overriding: [w - 1: changed]))
    #expect(model.framePlans == 3)
}

@MainActor
@Test func aPinchNeverRunsTheEngineAndTheZoomItEndsAtDecidesOnce() throws {
    let rig = try Rig("17 ")
    let model = FixedGridBrowseModel()
    let w = rig.first + 2
    let rested = model.decision(window: w, zoomKey: 4, inputs: rig.inputs())
    let runs = model.continuousLayoutRuns
    for key in 5...32 {
        let drawn = model.decisionForDrawing(window: w, zoomKey: key, isInteracting: true, inputs: rig.inputs())
        #expect(drawn.layout == rested.layout)
    }
    #expect(model.continuousLayoutRuns == runs)                                       // 28 pinch frames, no run
    _ = model.decisionForDrawing(window: w, zoomKey: FixedGridBrowseModel.zoomKey(3.1), isInteracting: false, inputs: rig.inputs())
    #expect(model.continuousLayoutRuns == runs + 1)
    _ = model.decisionForDrawing(window: w, zoomKey: FixedGridBrowseModel.zoomKey(3.12), isInteracting: false, inputs: rig.inputs())
    #expect(model.continuousLayoutRuns == runs + 1)                                   // a quarter of a unit is one decision
    #expect(FixedGridBrowseModel.zoomKey(1) == 4 && FixedGridBrowseModel.zoomKey(8) == 32)
}

@MainActor
@Test func aWindowWithADaylightSavingDayIsPlannedOnTheWallClockAndDrawnWithoutTheEngine() throws {
    let day = try LocalDate(year: 2026, month: 3, day: 8)
    func make(_ date: LocalDate) throws -> DayTimeline {
        let begin = newYork.dayBounds(date).start
        let range = try TimedRange(startUnixMilliseconds: begin + 125 * 60_000, endUnixMilliseconds: begin + 185 * 60_000)
        return DayTimelineBuilder.build(DayTimelineInput(
            day: date, timeZone: newYork, calendars: [CalendarDescriptor(id: CalendarID(rawValue: "c"), title: "약속")],
            events: [CalendarEvent(id: CalendarEventID(rawValue: "e"), calendarID: CalendarID(rawValue: "c"), title: "일정", time: .timed(range), revisionToken: "r")], life: .empty, transactions: []))
    }
    let days = try (-1...2).map { try make(day.adding(days: $0)) }
    let byEpoch = Dictionary(uniqueKeysWithValues: days.map { ($0.day.daysSinceUnixEpoch, $0) })
    let inputs = FixedGridBrowseModel.Inputs(zone: newYork, environment: FixedGridEnvironment(viewportHeight: 640, contentWidth: 165, textScale: 1), timelineFor: { byEpoch[$0.daysSinceUnixEpoch] }, revision: 0)
    let model = FixedGridBrowseModel()
    let window = day.daysSinceUnixEpoch - 1 + 1                                       // D-1 ... D+2 with the DST day second
    let decision = model.decision(window: day.daysSinceUnixEpoch, zoomKey: 4, inputs: inputs)
    #expect(decision.layout == nil)
    let partition = model.partition(window: window, inputs: inputs)
    #expect(partition.boundaries.first == 0 && partition.boundaries.last == 1440)
}

// MARK: The move

@Test func aReleaseCarriesTheDaysOneDayFromTheSelectedDayAndNeverFurther() {
    #expect(FixedGridMove.held(target: 105, selected: 100) == 101)
    #expect(FixedGridMove.held(target: 95, selected: 100) == 99)
    #expect(FixedGridMove.held(target: 100, selected: 100) == 100)
    #expect(FixedGridMove.pending(position: 100.4, selected: 100) == 0 && FixedGridMove.pending(position: 100.6, selected: 100) == 1)
    #expect(FixedGridMove.pending(position: 101.9, selected: 100) == 1 && FixedGridMove.pending(position: 98.2, selected: 100) == -1)
    #expect(FixedGridMove.takeOver(position: 100.7, selected: 100) == 1 && FixedGridMove.takeOver(position: 100.2, selected: 100) == 0)
    #expect(FixedGridMove.bounds(around: 100) == 99...102)
}

/// What the view does with `DayMoveModel`, without the view: the selected day, the model's bounds and the rules above, and the model's own spring.
private struct Run {
    var selected: Int
    var move: DayMoveModel
    private(set) var commits: [Int] = []
    private(set) var worstDistance = 0.0                                              // how far the position ever was from the selected day

    init(day: Int) {
        selected = day
        move = DayMoveModel(day: day, bounds: FixedGridMove.bounds(around: day), maximumHop: 1)
    }
    private mutating func note() { worstDistance = max(worstDistance, abs(move.position - Double(selected))) }
    private mutating func rebase(keeping position: Double?) {
        var next = DayMoveModel(day: selected, bounds: FixedGridMove.bounds(around: selected), maximumHop: 1)
        if let position { next.beginDrag(); next.drag(to: position) }
        move = next
    }
    mutating func takeOver() {
        let delta = FixedGridMove.takeOver(position: move.position, selected: selected)
        guard delta != 0 else { return }
        selected += delta; commits.append(selected)
        rebase(keeping: move.position)
    }
    mutating func drag(by days: Double, from start: Double) {
        if move.phase != .dragging { move.beginDrag() }
        move.drag(to: DayPrefetchPolicy.browse.clampedPosition(start + days, selected: selected)); note()
    }
    mutating func release(velocity: Double) {
        move.release(velocity: velocity)
        let held = FixedGridMove.held(target: move.target, selected: selected)
        if held != move.target { move.retarget(to: held) }
    }
    mutating func advance(_ seconds: Double) { let steps = Int(seconds / 0.008); for _ in 0..<steps { move.advance(by: 0.008); note() } }
    mutating func rest() {
        advance(3)
        let day = Int(move.position.rounded())
        if day != selected { selected = day; commits.append(day) }
        rebase(keeping: nil)
    }
}

@Test func slowDragsFastFlicksAndChainedFlicksMoveOneDayAtATimeAndTheSelectedDayFollows() {
    // A slow drag that lets go short of half a day returns; past half it goes on to the next day.
    var run = Run(day: 100)
    run.move.beginDrag(); run.drag(by: 0.3, from: 100); run.release(velocity: 0); run.rest()
    #expect(run.selected == 100 && run.move.position == 100)
    run.move.beginDrag(); run.drag(by: 0.7, from: 100); run.release(velocity: 0); run.rest()
    #expect(run.selected == 101 && run.move.position == 101)

    // A hard flick from rest carries one day, not two.
    run.move.beginDrag(); run.drag(by: 0.9, from: 101); run.release(velocity: 12); run.rest()
    #expect(run.selected == 102 && run.move.position == 102)

    // Chained flicks: the next begins while the last is still settling, takes over from where the days are, and each is one day from the then-selected day.
    var chain = Run(day: 200)
    for _ in 0..<5 {
        let start = chain.move.position
        chain.move.beginDrag()
        chain.takeOver()
        chain.drag(by: 0.4, from: start)
        chain.release(velocity: 9)
        chain.advance(0.18)                                                           // not yet at rest when the finger comes down again
    }
    chain.rest()
    #expect(chain.selected >= 203 && chain.selected <= 205)                           // five flicks in a second carried the days at least three days on
    #expect(chain.worstDistance <= 1.0 + 1e-9)                                        // and the position never got more than a day from the selected day
    #expect(chain.commits == Array(chain.commits.sorted()) && Set(chain.commits).count == chain.commits.count)    // one day at a time, forwards

    // A reversal in flight: towards later days, then a flick back before it lands.
    var reverse = Run(day: 300)
    reverse.move.beginDrag(); reverse.drag(by: 0.6, from: 300); reverse.release(velocity: 6); reverse.advance(0.1)
    let before = reverse.move.position
    reverse.move.beginDrag(); reverse.takeOver()
    reverse.drag(by: -0.5, from: before); reverse.release(velocity: -8); reverse.rest()
    #expect(reverse.worstDistance <= 1.0 + 1e-9)
    #expect(abs(reverse.move.position - reverse.move.position.rounded()) < 1e-9 && reverse.selected == Int(reverse.move.position))
}

@Test func theDaysCannotBeDraggedPastTheEdgesTheCacheAndThePlanningCover() {
    var run = Run(day: 50)
    run.move.beginDrag(); run.drag(by: 5, from: 50)
    #expect(run.move.position == 51)                                                  // one day from the selected day
    run.drag(by: -9, from: 50)
    #expect(run.move.position == 49)
    #expect(FixedGridMove.bounds(around: 50).contains(Int(run.move.position)))
}

// MARK: The time axis and the anchor

@MainActor
@Test func theTimeAtTheMiddleOfTheScreenStaysWhereItIsWhileTheDaysMoveAtEveryZoom() throws {
    let rig = try Rig("14 ")
    let model = FixedGridBrowseModel()
    let w = rig.first + 2
    let bounds = (w - 1)...(w + 2)
    let viewport: CGFloat = 640
    for zoom in [3.0, 8.0] as [CGFloat] {
        let inputs = rig.inputs()
        let partitionAt: (Double) -> TemporalGridPartition = { model.shared(position: $0, bounds: bounds, inputs: inputs) }
        let noon = 13.0 * 60
        var state = AnchorState(position: Double(w))
        let start = ContinuousDayAxis.anchoredOffset(time: noon, partition: partitionAt(Double(w)), zoom: zoom, viewport: viewport, focal: viewport / 2)
        var offset = start.offset
        var worst = 0.0
        for step in 0...40 {
            let position = Double(w) + Double(step) / 40
            let result = state.offset(forPosition: position, currentOffset: offset, userMoved: false, zoom: zoom, viewport: viewport, focal: viewport / 2, partitionAt: partitionAt)
            offset = result.offset
            let at = ContinuousDayAxis.time(atOffset: offset, partition: partitionAt(position), zoom: zoom, viewport: viewport, focal: viewport / 2)
            worst = max(worst, abs(at - noon))
            #expect(!result.clamped, "zoom \(zoom) position \(position)")
        }
        #expect(worst < 1e-6, "zoom \(zoom): the time at the middle moved by \(worst) minutes")
    }
    // At 1x there is nothing to scroll: the whole day is shown, whatever the position.
    let one = ContinuousDayAxis.anchoredOffset(time: 780, partition: model.shared(position: Double(w) + 0.5, bounds: bounds, inputs: rig.inputs()), zoom: 1, viewport: viewport, focal: viewport / 2)
    #expect(one.offset == 0)
}

@MainActor
@Test func everyEventAndTransactionIsDrawnOnceAtEachZoomOnEveryHardFixtureAndTheDaysShareTheAxisWhileTheyMove() throws {
    for prefix in ["7 ", "14 ", "17 ", "18 ", "19 ", "8 "] {
        let rig = try Rig(prefix)
        let model = FixedGridBrowseModel()
        let w = rig.first + 2
        let bounds = (w - 1)...(w + 2)
        for zoom in [1.0, 3.0, 8.0] as [CGFloat] {
            for position in [Double(w), Double(w) + 0.37, Double(w) + 1] {
                let inputs = rig.inputs()
                let shown = model.shared(position: position, bounds: bounds, inputs: inputs).zoomed(viewportHeight: rig.environment.viewportHeight, zoomScale: zoom)
                let layoutWindow = Int(position.rounded())
                let decision = model.decision(window: layoutWindow, zoomKey: FixedGridBrowseModel.zoomKey(zoom), inputs: inputs)
                var tops: [Int: [CGFloat]] = [:]
                for epoch in Int(position.rounded(.down))...(Int(position.rounded(.down)) + 2) {
                    guard let timeline = rig.timelines[epoch] else { continue }
                    let role: DayRole? = epoch == layoutWindow ? .main : (epoch == layoutWindow + 1 ? .secondary : nil)
                    let plan = DayRenderPlan(
                        prepared: DayRenderPlan.Prepared(timeline: timeline, role: role, layout: decision.layout), geometry: model.axis(for: timeline.day, partition: shown, zone: seoul),
                        layoutWidth: 231, textScale: rig.scenario.textScale, titleWidth: { decision.titleWidths[$0] ?? 40 })
                    let ids = plan.lines.map(\.id) + plan.overflows.flatMap { $0.members.map(\.transactionID) } + plan.events.flatMap { $0.insideRows.map { $0.transactionID.rawValue } }
                    let expected = timeline.markers.map(\.transactionID.rawValue) + timeline.blocks.flatMap { $0.allocations.map(\.transactionID.rawValue) }
                    #expect(Set(ids) == Set(expected) && Set(ids).count == ids.count, "\(prefix) zoom \(zoom) position \(position) day \(epoch)")
                    #expect(plan.events.map(\.block.id).count == timeline.blocks.count)
                    // The same minute is at the same height in every column: the shared axis.
                    tops[epoch] = plan.events.map { $0.frame.minY } + [model.axis(for: timeline.day, partition: shown, zone: seoul).y(minute: 600)]
                    for item in plan.events { #expect(item.touchFrame.height >= 44 - 1e-6) }
                }
                let tens = tops.values.compactMap(\.last)
                #expect(tens.allSatisfy { abs($0 - (tens.first ?? 0)) < 1e-9 })
            }
        }
    }
}

// MARK: The model and the cache

@MainActor
@Test func theSelectedDayTheCacheAndTheStripAgreeAfterARunOfMovesThatBeganBeforeTheLastLanded() async throws {
    let model = try AppModel.demo()
    await model.start()
    let policy = DayPrefetchPolicy.browse
    await model.loadMissing(extra: policy.readAhead, policy: policy.cachePolicy)
    let start = model.selectedDay
    var revisions = [model.dataRevision]
    var run = Run(day: start.daysSinceUnixEpoch)
    for step in 0..<6 {
        let from = run.move.position
        run.move.beginDrag()
        let before = run.selected
        run.takeOver()
        if run.selected != before { #expect(model.moveTo(LocalDate(daysSinceUnixEpoch: run.selected))) }
        run.drag(by: 0.5, from: from)
        run.release(velocity: 8)
        await model.prefetch(forPosition: run.move.position, target: run.move.target)
        run.advance(0.2)
        await model.prefetch(forPosition: run.move.position, target: run.move.target)
        let needed = DayPrefetchPolicy.neededDays(position: run.move.position, target: run.move.target).map { LocalDate(daysSinceUnixEpoch: $0) }
        #expect(model.cachedDays.isSuperset(of: needed), "step \(step)")
        #expect(model.visibleTimelines.count == 2)
        revisions.append(model.dataRevision)
    }
    run.rest()
    #expect(model.moveTo(LocalDate(daysSinceUnixEpoch: run.selected)) || model.selectedDay.daysSinceUnixEpoch == run.selected)
    await model.loadMissing(extra: policy.readAhead, policy: policy.cachePolicy)
    #expect(model.selectedDay.daysSinceUnixEpoch == run.selected && run.selected - start.daysSinceUnixEpoch >= 3)
    #expect(model.visibleTimelines.map(\.day.daysSinceUnixEpoch) == [run.selected, run.selected + 1])
    #expect(model.cachedDays.isSuperset(of: DayCachePolicy.standard.required(around: model.selectedDay)))
    #expect(model.cachedDays.count <= policy.cachePolicy.capacity)
    #expect(model.cachedTimeline(for: model.selectedDay) != nil && model.cachedTimeline(for: start.adding(days: -40)) == nil)
    #expect(revisions.last! > revisions.first!)                                       // the revision moved as days were read
}
