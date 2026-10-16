import CoreGraphics
import NEOBudgetCalendar
import Testing
@testable import OnAllApp

// Phase 2B-3, the frame for editing on the fixed grid (no editing yet): who owns a touch by where it begins and the mode, what a running gesture keeps off,
// edit sessions that freeze the time partition and the decisions (and end into the current plan without a jump), and the original a session is made against.

private let seoul = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private typealias G = FixedGridGestures

private let target = G.EditTarget(epoch: 10, blockID: BlockID(rawValue: "b"), frame: CGRect(x: 100, y: 200, width: 150, height: 120), canResizeStart: true, canResizeEnd: true)
private let editing = G.Mode.editing(target)

// MARK: Ownership

@Test func whoOwnsATouchByWhereItBeginsAndTheMode() {
    let event = G.Start.content(.event(BlockID(rawValue: "x")))
    let line = G.Start.content(.line("t"))
    func owners(_ start: G.Start, _ mode: G.Mode) -> Set<G.Recognizer> { Set(G.Recognizer.allCases.filter { G.receives($0, start: start, mode: mode) }) }
    // Browse: everything moves the days, scrolls and zooms; taps select what is under them; long presses create (empty), open details or the notice; no handles.
    #expect(owners(.empty, .browse) == [.dateSwipe, .scroll, .pinch, .longPress])
    #expect(owners(event, .browse) == [.dateSwipe, .scroll, .pinch, .tap, .longPress])
    #expect(owners(line, .browse) == [.dateSwipe, .scroll, .pinch, .tap, .longPress])
    #expect(owners(.gutter, .browse) == [.dateSwipe, .scroll, .pinch])
    #expect(owners(.handle(.resizeEnd), .browse).isEmpty)
    // Editing: a handle is the handle's only (its drag never scrolls, swipes or zooms); elsewhere scroll and pinch go on, the days do not move.
    #expect(owners(.handle(.resizeStart), editing) == [.handlePan, .tap])
    #expect(owners(.handle(.resizeEnd), editing) == [.handlePan, .tap])
    #expect(owners(.empty, editing) == [.scroll, .pinch, .tap])
    #expect(owners(event, editing) == [.scroll, .pinch, .tap])
    #expect(owners(.gutter, editing) == [.scroll, .pinch])
    for mode in [G.Mode.browse, editing] { for start in [G.Start.empty, event, line, .gutter] { #expect(!owners(start, mode).contains(.handlePan)) } }
}

@Test func aHandleIsFoundOnlyOnTheChosenCardAndOnlyWhileEditing() {
    let start = EditHit.startHandle(of: target.frame), end = EditHit.endHandle(of: target.frame)
    #expect(G.start(at: start, gutter: 60, mode: editing) { .nothing } == .handle(.resizeStart))
    #expect(G.start(at: CGPoint(x: end.x + 5, y: end.y - 8), gutter: 60, mode: editing) { .nothing } == .handle(.resizeEnd))
    #expect(G.start(at: start, gutter: 60, mode: .browse) { .event(target.blockID) } == .content(.event(target.blockID)))
    #expect(G.start(at: CGPoint(x: 175, y: 260), gutter: 60, mode: editing) { .event(target.blockID) } == .content(.event(target.blockID)))   // the body
    #expect(G.start(at: CGPoint(x: 30, y: 260), gutter: 60, mode: .browse) { .event(target.blockID) } == .gutter)
    #expect(G.start(at: CGPoint(x: 300, y: 600), gutter: 60, mode: editing) { .nothing } == .empty)
    // An end that continues from the day before (or into the next) has no handle on that side.
    let clipped = G.Mode.editing(G.EditTarget(epoch: 10, blockID: target.blockID, frame: target.frame, canResizeStart: false, canResizeEnd: true))
    #expect(G.start(at: start, gutter: 60, mode: clipped) { .event(target.blockID) } == .content(.event(target.blockID)))
}

@Test func whatARunningGestureKeepsOffUntilTheFingersLift() {
    // A pinch: no one-finger gesture, whatever finger stays (a long press under way is cancelled).
    #expect(G.suppressed(while: .pinch) == [.dateSwipe, .scroll, .tap, .longPress, .handlePan])
    // A long press keeps its finger: no scroll, no swipe, no tap; a second finger may still make it a pinch.
    #expect(G.suppressed(while: .longPress) == [.dateSwipe, .scroll, .tap])
    #expect(!G.suppressed(while: .longPress).contains(.pinch))
    // A handle drag is the only thing going on.
    #expect(G.suppressed(while: .handlePan) == [.dateSwipe, .scroll, .pinch, .tap, .longPress])
    // A day swipe: no scroll and no tap or long press of the finger moving the days; a pinch still takes over (direct manipulation, instant hand-over).
    #expect(G.suppressed(while: .dateSwipe) == [.scroll, .tap, .longPress, .handlePan])
    #expect(G.suppressed(while: .scroll).isEmpty)
}

@Test func whatATapAndALongPressMean() {
    let event = DayRenderPlan.Hit.event(BlockID(rawValue: "x"))
    #expect(G.tap(start: .content(event), mode: .browse, daysAtRest: true) == .select(event))
    #expect(G.tap(start: .content(event), mode: .browse, daysAtRest: false) == .none)          // a finger on moving days stops them
    #expect(G.tap(start: .empty, mode: .browse, daysAtRest: true) == .none)
    #expect(G.tap(start: .handle(.resizeEnd), mode: editing, daysAtRest: true) == .handle(.resizeEnd))
    #expect(G.tap(start: .content(event), mode: editing, daysAtRest: true) == .chooseOther(event))
    #expect(G.tap(start: .empty, mode: editing, daysAtRest: true) == .endEditing)
    #expect(G.longPress(start: .empty, mode: .browse) == .createDraft)
    #expect(G.longPress(start: .content(event), mode: .browse) == .details(BlockID(rawValue: "x")))
    #expect(G.longPress(start: .content(.line("t")), mode: .browse) == .notice)
    #expect(G.longPress(start: .empty, mode: editing) == .none)                                  // a tap outside ends the session first
    #expect(G.longPress(start: .content(event), mode: editing) == .none)
}

// MARK: Edit sessions

@MainActor
private final class Clock { var now: Double = 50 }

private struct Rig {
    var timelines: [Int: DayTimeline]
    let first: Int
    var environment: FixedGridEnvironment
    var revision = 1

    init(_ prefix: String) throws {
        let scenario = try #require(TemporalGridFixtures.all.first { $0.name.hasPrefix(prefix) })
        let days = try scenario.days.map { try fixtureTimeline($0) }
        first = days[0].day.daysSinceUnixEpoch
        timelines = Dictionary(uniqueKeysWithValues: days.map { ($0.day.daysSinceUnixEpoch, $0) })
        environment = FixedGridEnvironment(viewportHeight: 640, contentWidth: 165, textScale: scenario.textScale)
    }

    var inputs: FixedGridBrowseModel.Inputs {
        let kept = timelines
        return FixedGridBrowseModel.Inputs(zone: seoul, environment: environment, timelineFor: { kept[$0.daysSinceUnixEpoch] }, revision: revision)
    }

    func baseline(generation: Int = 0, window: Int) -> FixedGridEditBaseline {
        var days: [LocalDate: DayTimeline] = [:]
        for offset in -1...2 { let day = LocalDate(daysSinceUnixEpoch: window + offset); days[day] = timelines[window + offset] }
        let timeline = timelines[window]!
        return FixedGridEditBaseline(dataGeneration: generation, dataRevision: revision, days: days, target: (timeline.day, timeline.blocks[0]))
    }
}

private func largestStep(_ a: TemporalGridPartition, _ b: TemporalGridPartition) -> Double { zip(a.boundaries, b.boundaries).map { abs($0 - $1) }.max() ?? 0 }

@MainActor
@Test func aFrozenSessionKeepsThePartitionAndTheDecisionsWhileTheDataTheZoomAndThePlanningGoOn() async throws {
    var rig = try Rig("3 ")
    let model = FixedGridBrowseModel()
    let w = rig.first + 2
    let bounds = (w - 1)...(w + 2)
    let before = model.shared(position: Double(w), bounds: bounds, inputs: rig.inputs)
    let decided = model.decisionForDrawing(window: w, zoomKey: 4, isInteracting: false, inputs: rig.inputs)
    let session = model.freeze(position: Double(w), bounds: bounds, windows: [w], zoomKey: 4, inputs: rig.inputs, baseline: rig.baseline(window: w))
    #expect(model.freeze(position: Double(w), bounds: bounds, windows: [w], zoomKey: 4, inputs: rig.inputs, baseline: rig.baseline(window: w)) == session)  // one at a time
    // The data changes under the session (a read lands, a day is replaced) and the planning ahead plans the changed windows off the main thread.
    rig.timelines[w + 1] = try fixtureTimeline(TemporalGridFixtures.busy(w + 1 - rig.first))
    rig.revision = 2
    var ready = 0
    model.warm(windows: [w, w - 1, w + 1], inputs: rig.inputs) { ready += 1 }
    for _ in 0..<200 where ready < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(ready >= 2)                                                                 // planning went on
    let runs = model.continuousLayoutRuns
    #expect(model.shared(position: Double(w), bounds: bounds, inputs: rig.inputs) == before)
    for key in [4, 8, 12, 20, 32] {                                                    // the zoom changes during the session
        #expect(model.decisionForDrawing(window: w, zoomKey: key, isInteracting: false, inputs: rig.inputs).layout == decided.layout)
    }
    #expect(model.continuousLayoutRuns == runs)                                         // nothing decided while frozen
    // The room changes (a rotation): the same cells and times, the new height.
    var rotated = rig
    rotated.environment.viewportHeight = 360
    let tall = model.shared(position: Double(w), bounds: bounds, inputs: rotated.inputs)
    #expect(tall.boundaries == before.boundaries && tall.totalHeight == 360)
    // What changed outside the session is known against its original.
    let changes = try #require(model.frozen).baseline.changes(dataGeneration: 0, dataRevision: 2) { rig.timelines[$0.daysSinceUnixEpoch] }
    #expect(changes.changedDays == [LocalDate(daysSinceUnixEpoch: w + 1)] && changes.target == .unchanged && !changes.reloaded && !changes.isClean)
}

@MainActor
@Test func endingASessionEasesIntoTheCurrentPlanWithTheTimeAtTheMiddleKept() throws {
    var rig = try Rig("3 ")
    let model = FixedGridBrowseModel()
    let clock = Clock()
    model.clock = { clock.now }
    let w = rig.first + 2
    let bounds = (w - 1)...(w + 2)
    _ = model.shared(position: Double(w), bounds: bounds, inputs: rig.inputs)
    let session = model.freeze(position: Double(w), bounds: bounds, windows: [w], zoomKey: 12, inputs: rig.inputs, baseline: rig.baseline(window: w))
    let frozen = model.shared(position: Double(w), bounds: bounds, inputs: rig.inputs)
    let frozenDecision = model.decisionForDrawing(window: w, zoomKey: 12, isInteracting: false, inputs: rig.inputs)
    // During the session a day of the window changed: the plan now differs from what is frozen.
    rig.timelines[w + 1] = try fixtureTimeline(TemporalGridFixtures.busy(w + 1 - rig.first))
    rig.revision = 2
    let current = FixedGridBrowseModel().partition(window: w, inputs: rig.inputs)
    #expect(largestStep(frozen, current) > 1)
    // At zoom 3, the time at the middle of the screen as the session ends.
    let zoom: CGFloat = 3, viewport: CGFloat = 640, focal = viewport / 2
    var anchor = AnchorState(position: Double(w))
    var offset = ContinuousDayAxis.anchoredOffset(time: 13 * 60, partition: frozen, zoom: zoom, viewport: viewport, focal: focal).offset
    _ = anchor.offset(forPosition: Double(w), currentOffset: offset, userMoved: true, zoom: zoom, viewport: viewport, focal: focal) { _ in frozen }
    let middle = ContinuousDayAxis.time(atOffset: offset, partition: frozen, zoom: zoom, viewport: viewport, focal: focal)

    model.unfreeze(session)
    var previous = model.shared(position: Double(w), bounds: bounds, inputs: rig.inputs)
    #expect(largestStep(previous, frozen) < 1e-9)                                       // the first frame after is what was frozen
    #expect(model.thawing(window: w)?.weight == 0 && model.thawing(window: w)?.decision.layout == frozenDecision.layout)
    let total = largestStep(frozen, current)
    var frames = 0
    while model.isEasing {
        clock.now += 1.0 / 60
        frames += 1
        let next = model.shared(position: Double(w), bounds: bounds, inputs: rig.inputs)
        #expect(largestStep(previous, next) <= total / 5 + 1e-9, "frame \(frames)")
        // The scroll that keeps the middle time where it was, on the easing axis.
        offset = anchor.offset(forPosition: Double(w), currentOffset: offset, userMoved: false, zoom: zoom, viewport: viewport, focal: focal) { _ in next }.offset
        #expect(abs(ContinuousDayAxis.time(atOffset: offset, partition: next, zoom: zoom, viewport: viewport, focal: focal) - middle) < 1e-6, "frame \(frames)")
        previous = next
    }
    #expect(frames >= 15 && frames <= 20)
    #expect(previous == current && model.thawing(window: w) == nil)
    // And the decisions are the current ones again.
    let after = model.decisionForDrawing(window: w, zoomKey: 12, isInteracting: false, inputs: rig.inputs)
    #expect(model.frozen == nil && after.layout != nil)
}

@MainActor
@Test func theOriginalTellsAReloadAChangedDayAMovedOrGoneTargetAndADayNoLongerKept() throws {
    var rig = try Rig("16 ")
    let w = rig.first + 2
    let baseline = rig.baseline(generation: 3, window: w)
    func changes(generation: Int = 3, revision: Int) -> FixedGridEditBaseline.Changes {
        let kept = rig.timelines
        return baseline.changes(dataGeneration: generation, dataRevision: revision) { kept[$0.daysSinceUnixEpoch] }
    }
    #expect(changes(revision: rig.revision).isClean)                                    // nothing moved: nothing compared
    #expect(changes(revision: rig.revision + 5).isClean)                               // reads landed, the same days
    #expect(changes(generation: 4, revision: rig.revision + 1).reloaded)               // the calendar may have changed
    // The chosen event moved: the same calendar key, another time.
    let original = rig.timelines[w]!
    let source = TemporalGridFixtures.all.first { $0.name.hasPrefix("16 ") }!.days[w - rig.first]
    // Every event of the day half an hour later (so the chosen one certainly is).
    let moved = AllocationDay(
        day: source.day, totalMinutes: source.totalMinutes,
        events: source.events.map { AllocationEvent(id: $0.id, title: $0.title, startMinute: $0.startMinute + 30, endMinute: $0.endMinute + 30, linked: []) },
        transactions: [])
    rig.timelines[w] = try fixtureTimeline(moved)
    var found = changes(revision: rig.revision + 1)
    #expect(found.target == .changed && found.changedDays.contains(original.day))
    // Gone.
    rig.timelines[w] = try fixtureTimeline(AllocationDay(day: source.day, totalMinutes: source.totalMinutes, events: [], transactions: []))
    found = changes(revision: rig.revision + 2)
    #expect(found.target == .gone)
    // Not kept any more: not known to have changed.
    rig.timelines[w] = nil
    found = changes(revision: rig.revision + 3)
    #expect(found.target == .unknown && found.unknownDays.contains(original.day) && !found.changedDays.contains(original.day))
}

@MainActor
@Test func duringASessionReloadsAndPrefetchesStillChangeTheDaysAndTheOriginalSeesIt() async throws {
    let app = try AppModel.demo()
    await app.start()
    let policy = DayPrefetchPolicy.browse
    await app.loadMissing(extra: policy.readAhead, policy: policy.cachePolicy)
    let selected = app.selectedDay.daysSinceUnixEpoch
    let environment = FixedGridEnvironment(viewportHeight: 640, contentWidth: 165, textScale: 1)
    func inputs() -> FixedGridBrowseModel.Inputs { FixedGridBrowseModel.Inputs(zone: app.dayZone, environment: environment, timelineFor: { app.cachedTimeline(for: $0) }, revision: app.dataRevision) }
    let model = FixedGridBrowseModel()
    let bounds = (selected - 1)...(selected + 2)
    let drawn = model.shared(position: Double(selected), bounds: bounds, inputs: inputs())
    var days: [LocalDate: DayTimeline] = [:]
    for offset in -1...2 { let day = LocalDate(daysSinceUnixEpoch: selected + offset); days[day] = app.cachedTimeline(for: day) }
    let timeline = try #require(app.cachedTimeline(for: app.selectedDay))
    let baseline = FixedGridEditBaseline(dataGeneration: app.dataGeneration, dataRevision: app.dataRevision, days: days, target: timeline.blocks.first.map { (timeline.day, $0) })
    model.freeze(position: Double(selected), bounds: bounds, windows: [selected], zoomKey: 4, inputs: inputs(), baseline: baseline)
    let reads = app.dayReads
    await app.prefetch(forPosition: Double(selected) + 0.6, target: selected + 1)      // days are still read
    await app.reload()                                                                  // and the calendar is read again
    #expect(app.dayReads > reads)
    #expect(model.shared(position: Double(selected), bounds: bounds, inputs: inputs()) == drawn)
    let changes = baseline.changes(dataGeneration: app.dataGeneration, dataRevision: app.dataRevision) { app.cachedTimeline(for: $0) }
    #expect(changes.reloaded && !changes.isClean)
}

@Test func theSecondTapOnTheChosenEventsTitleRenamesIt() {
    // The chosen card is at (100, 200) 150 × 120: its title band is its top 30 points.
    let title = CGPoint(x: 140, y: 212)
    #expect(G.tap(start: .content(.event(target.blockID)), mode: editing, daysAtRest: true, point: title) == .title)
    // The draft moved the card away from where the plan has the event: its title still renames (the plan sees empty grid there).
    #expect(G.tap(start: .empty, mode: editing, daysAtRest: true, point: title) == .title)
    // Lower on the card is its body; a handle in the band is still the handle; browse has no title step.
    #expect(G.tap(start: .content(.event(target.blockID)), mode: editing, daysAtRest: true, point: CGPoint(x: 140, y: 260)) == .chooseOther(.event(target.blockID)))
    #expect(G.tap(start: .handle(.resizeStart), mode: editing, daysAtRest: true, point: CGPoint(x: 240, y: 202)) == .handle(.resizeStart))
    #expect(G.tap(start: .content(.event(target.blockID)), mode: .browse, daysAtRest: true, point: title) == .select(.event(target.blockID)))
    // A card shorter than the band is all title.
    #expect(G.titleBand(of: CGRect(x: 0, y: 0, width: 80, height: 12)).height == 12)
}
