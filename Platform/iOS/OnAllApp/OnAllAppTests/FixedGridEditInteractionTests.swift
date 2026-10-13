import CoreGraphics
import NEOBudgetCalendar
import Testing
@testable import OnAllApp

// Phase 3A, the edit interaction on the fixed grid (no time is changed, nothing is saved): entering, the handles, confirm and cancel, the exit policies for a tap
// outside and a change of the selected day, the grid's freeze kept through it all, and the anchor the grid unfreezes at after a save.

private let zoneSeoul = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private typealias I = FixedGridEditInteraction

private func key(_ id: String) -> CalendarEventKey { CalendarEventKey(calendarID: CalendarID(rawValue: "c"), eventID: CalendarEventID(rawValue: id)) }
private let day = LocalDate(daysSinceUnixEpoch: 20_000)
private let lunch = I.Target(day: day, blockID: BlockID(rawValue: "lunch"), eventKey: key("lunch"), startMinute: 720, endMinute: 780)
private let meeting = I.Target(day: day, blockID: BlockID(rawValue: "meeting"), eventKey: key("meeting"), startMinute: 900, endMinute: 960)

/// Enters on `lunch` (session 1) and returns the machine.
private func entered(_ policy: I.ExitPolicy = .init()) -> I {
    var machine = I(policy: policy)
    _ = machine.handle(.enter(lunch))
    return machine
}

/// Entered, a handle dragged and the draft said to be changed.
private func dirty(_ policy: I.ExitPolicy = .init(), handle: I.Handle = .end) -> I {
    var machine = entered(policy)
    _ = machine.handle(.handleDrag(.began, handle, point: .zero, minute: nil))
    _ = machine.handle(.handleDrag(.ended, handle, point: .zero, minute: nil))
    _ = machine.handle(.draftChanged(session: 1, isDirty: true))
    return machine
}

private func gridCommands(_ commands: [I.Command]) -> [I.Command] { commands.filter(\.isGrid) }

// MARK: Entering, handles

@Test func enteringFreezesTheGridAndHandleTapsAndDragsChooseAHandle() {
    var machine = I()
    #expect(machine.handle(.enter(lunch)) == [.freeze(session: 1, lunch), .began(session: 1, lunch)])
    #expect(machine.editing?.target == lunch && machine.session?.handle == I.HandleState.none)
    // A tap chooses a handle (its time bubble), the same tap again lets it go, the other one switches.
    #expect(machine.handle(.handleTap(.start)) == [.handle(session: 1, .selected(.start))])
    #expect(machine.handle(.handleTap(.start)) == [.handle(session: 1, .none)])
    #expect(machine.handle(.handleTap(.start)) == [.handle(session: 1, .selected(.start))])
    #expect(machine.handle(.handleTap(.end)) == [.handle(session: 1, .selected(.end))])
    // A drag: dragging while the finger moves, then chosen; its steps go to the editing parts with the minute under the finger.
    let p = CGPoint(x: 120, y: 300)
    #expect(machine.handle(.handleDrag(.began, .start, point: p, minute: 700)) == [.handle(session: 1, .dragging(.start)), .dragHandle(session: 1, .began, .start, point: p, minute: 700)])
    #expect(machine.handle(.handleDrag(.moved, .start, point: p, minute: 705)) == [.dragHandle(session: 1, .moved, .start, point: p, minute: 705)])
    #expect(machine.handle(.handleDrag(.moved, .end, point: p, minute: 705)).isEmpty)          // not the handle being dragged
    // When it ends the handle is let go (no bubble after a drag); it is still the edge last edited.
    #expect(machine.handle(.handleDrag(.ended, .start, point: p, minute: 705)) == [.dragHandle(session: 1, .ended, .start, point: p, minute: 705), .handle(session: 1, .none)])
    #expect(machine.session?.lastEdited == .start)
    // None of it touches the freeze, and a second enter while open is a tap on that event (the same one, no handle chosen: nothing).
    #expect(machine.handle(.enter(lunch)).isEmpty)
    #expect(machine.session?.id == 1)
}

@Test func nothingHappensWithoutASession() {
    var machine = I()
    for event: I.Event in [.handleTap(.end), .handleDrag(.began, .end, point: .zero, minute: nil), .tapOutside, .tapEvent(lunch), .selectedDayChanged(day), .cancel, .confirm,
                           .draftChanged(session: 1, isDirty: true), .commitFinished(session: 1, .init(day: day, startMinute: 0, endMinute: 1)), .commitFailed(session: 1)] {
        #expect(machine.handle(event).isEmpty)
    }
    #expect(machine.session == nil && machine.gestureMode { _ in nil } == .browse)
}

// MARK: Confirm and cancel

@Test func confirmCommitsChangesAndKeepsTheGridFrozenUntilTheAnswer() {
    var machine = dirty()
    #expect(machine.handle(.confirm) == [.handle(session: 1, .none), .commit(session: 1)])
    #expect(machine.editing?.committing == true)
    // While the save is under way: touches, a cancel and another confirm do nothing; nothing unfreezes.
    for event: I.Event in [.handleTap(.start), .tapOutside, .tapEvent(meeting), .cancel, .confirm, .draftChanged(session: 1, isDirty: false)] { #expect(machine.handle(event).isEmpty) }
    #expect(machine.handle(.commitFinished(session: 7, .init(day: day, startMinute: 720, endMinute: 810))).isEmpty)   // another session's answer
    // The answer: the grid unfreezes at the edited edge (the end, last dragged) at its saved time.
    #expect(machine.handle(.commitFinished(session: 1, .init(day: day, startMinute: 720, endMinute: 810)))
            == [.unfreeze(session: 1, .edge(.end, day: day, minute: 810)), .ended(session: 1, .committed)])
    #expect(machine.session == nil)
}

@Test func aFailedCommitGoesBackToEditingWithTheChangesKept() {
    var machine = dirty()
    _ = machine.handle(.confirm)
    #expect(machine.handle(.commitFailed(session: 1)).isEmpty)                        // still frozen, nothing ended
    #expect(machine.editing?.isDirty == true && machine.editing?.committing == false)
    #expect(machine.handle(.handleTap(.start)) == [.handle(session: 1, .selected(.start))])   // editing again
}

@Test func confirmWithoutChangesAndCancelEndAtTheMiddle() {
    var machine = entered()
    #expect(machine.handle(.confirm) == [.unfreeze(session: 1, .middle), .ended(session: 1, .cancelled)])
    machine = dirty()
    #expect(machine.handle(.cancel) == [.discard(session: 1), .unfreeze(session: 1, .middle), .ended(session: 1, .discarded)])
    _ = machine.handle(.enter(meeting))
    #expect(machine.session?.id == 2)                                                  // a new session
}

// MARK: Leaving: a tap outside, another event

@Test func aTapOutsideLetsTheHandleGoThenEndsAsThePolicySays() {
    // Without changes: the handle first, then the session (a cancel).
    var machine = entered()
    _ = machine.handle(.handleTap(.end))
    #expect(machine.handle(.tapOutside) == [.handle(session: 1, .none)])
    #expect(machine.handle(.tapOutside) == [.unfreeze(session: 1, .middle), .ended(session: 1, .cancelled)])
    // With changes, by default: committed (a calendar keeps a drag).
    machine = dirty()
    #expect(machine.handle(.tapOutside) == [.handle(session: 1, .none), .commit(session: 1)])
    // Discarded.
    machine = dirty(.init(outsideTap: .discard))
    #expect(machine.handle(.tapOutside) == [.discard(session: 1), .unfreeze(session: 1, .middle), .ended(session: 1, .discarded)])
    // Asked: the session stays frozen and takes nothing but the answer (a confirm or a cancel).
    machine = dirty(.init(outsideTap: .ask))
    #expect(machine.handle(.tapOutside) == [.askExit(session: 1, .outsideTap)])
    #expect(machine.handle(.handleTap(.end)).isEmpty && machine.handle(.tapOutside).isEmpty && machine.editing != nil)
    #expect(machine.handle(.confirm) == [.handle(session: 1, .none), .commit(session: 1)])
    machine = dirty(.init(outsideTap: .ask))
    _ = machine.handle(.tapOutside)
    #expect(machine.handle(.cancel) == [.discard(session: 1), .unfreeze(session: 1, .middle), .ended(session: 1, .discarded)])
}

@Test func anotherEventMovesTheSessionWithoutUnfreezingOrLeavesWithChanges() {
    var machine = entered()
    _ = machine.handle(.handleTap(.start))
    let moved = machine.handle(.tapEvent(meeting))
    #expect(moved == [.retarget(session: 1, meeting), .began(session: 1, meeting)])
    #expect(!moved.contains { if case .unfreeze = $0 { true } else { false } })      // the grid stays frozen
    #expect(machine.editing?.target == meeting && machine.session?.handle == I.HandleState.none && machine.session?.lastEdited == nil)
    // The same event's body lets a chosen handle go and does nothing else.
    _ = machine.handle(.handleTap(.end))
    #expect(machine.handle(.tapEvent(meeting)) == [.handle(session: 1, .none)])
    #expect(machine.handle(.tapEvent(meeting)).isEmpty)
    // With changes another event is a way out, as a tap outside is.
    machine = dirty(.init(outsideTap: .ask))
    #expect(machine.handle(.tapEvent(meeting)) == [.askExit(session: 1, .otherEvent)])
}

// MARK: The selected day changes

@Test func aDayChangeUnfreezesAtOnceAndCommitsOrDiscards() {
    var machine = entered()
    #expect(machine.handle(.selectedDayChanged(day.adding(days: 1))) == [.unfreeze(session: 1, .middle), .ended(session: 1, .dayChanged)])
    // With changes (default): committed, and the grid lets go now (the days are moving); the answer only ends the session.
    machine = dirty()
    #expect(machine.handle(.selectedDayChanged(day.adding(days: 1))) == [.commit(session: 1), .unfreeze(session: 1, .middle)])
    #expect(machine.editing == nil && machine.session?.released == true && machine.gestureMode { _ in nil } == .browse)
    #expect(machine.handle(.selectedDayChanged(day.adding(days: 2))).isEmpty)        // let go once
    #expect(machine.handle(.enter(meeting)).isEmpty)                                    // the next session waits for the answer
    #expect(machine.handle(.commitFinished(session: 1, .init(day: day, startMinute: 720, endMinute: 810))) == [.ended(session: 1, .committed)])
    // A failure after the grid let go is said, and ends it.
    machine = dirty()
    _ = machine.handle(.selectedDayChanged(day.adding(days: 1)))
    #expect(machine.handle(.commitFailed(session: 1)) == [.ended(session: 1, .commitFailedAfterRelease)])
    #expect(machine.session == nil)
    // Discard.
    machine = dirty(.init(dayChange: .discard))
    #expect(machine.handle(.selectedDayChanged(day.adding(days: 1))) == [.discard(session: 1), .unfreeze(session: 1, .middle), .ended(session: 1, .dayChanged)])
    // `ask` cannot hold the days: taken as commit.
    machine = dirty(.init(dayChange: .ask))
    #expect(machine.handle(.selectedDayChanged(day.adding(days: 1))) == [.commit(session: 1), .unfreeze(session: 1, .middle)])
    // During a commit: the grid lets go at once, the commit goes on.
    machine = dirty()
    _ = machine.handle(.confirm)
    #expect(machine.handle(.selectedDayChanged(day.adding(days: 1))) == [.unfreeze(session: 1, .middle)])
    #expect(machine.handle(.commitFinished(session: 1, .init(day: day, startMinute: 720, endMinute: 810))) == [.ended(session: 1, .committed)])
}

// MARK: Keeping the grid frozen

@Test func theGridStaysInEditingWhileFrozenEvenWhenTheCardCannotBePlaced() {
    var machine = entered()
    let placed = FixedGridGestures.EditTarget(epoch: day.daysSinceUnixEpoch, blockID: lunch.blockID, frame: CGRect(x: 100, y: 200, width: 150, height: 60), canResizeStart: true, canResizeEnd: true)
    #expect(machine.gestureMode { _ in placed } == .editing(placed))
    // Its block gone after a reload: still editing (the days do not move, scroll and pinch go on), without handles.
    let unplaced = machine.gestureMode { _ in nil }
    let target = unplaced.target
    #expect(target?.canResizeStart == false && target?.canResizeEnd == false)
    for start: FixedGridGestures.Start in [.empty, .content(.event(lunch.blockID)), .gutter] {
        #expect(!FixedGridGestures.receives(.dateSwipe, start: start, mode: unplaced))
    }
    #expect(FixedGridGestures.start(at: EditHit.endHandle(of: placed.frame), gutter: 60, mode: unplaced) { .nothing } == .empty)
    // While a commit is under way the grid is still frozen.
    _ = machine.handle(.draftChanged(session: 1, isDirty: true))
    _ = machine.handle(.confirm)
    #expect(machine.gestureMode { _ in placed } == .editing(placed))
}

@MainActor
@Test func movingTheSessionToAnotherEventKeepsTheFrozenGridAndTheOriginalsStart() throws {
    let scenario = try #require(TemporalGridFixtures.all.first { $0.name.hasPrefix("3 ") })
    let days = try scenario.days.map { try fixtureTimeline($0, zone: zoneSeoul) }
    let first = days[0].day.daysSinceUnixEpoch
    var kept = Dictionary(uniqueKeysWithValues: days.map { ($0.day.daysSinceUnixEpoch, $0) })
    var revision = 1
    func inputs() -> FixedGridBrowseModel.Inputs {
        let now = kept
        return FixedGridBrowseModel.Inputs(zone: zoneSeoul, environment: FixedGridEnvironment(viewportHeight: 640, contentWidth: 165, textScale: 1), timelineFor: { now[$0.daysSinceUnixEpoch] }, revision: revision)
    }
    let model = FixedGridBrowseModel()
    let w = first + 2
    let bounds = (w - 1)...(w + 2)
    let timeline = try #require(kept[w])
    try #require(timeline.blocks.count >= 2)
    var original: [LocalDate: DayTimeline] = [:]
    for offset in -1...2 { let d = LocalDate(daysSinceUnixEpoch: w + offset); original[d] = kept[w + offset] }
    let drawn = model.shared(position: Double(w), bounds: bounds, inputs: inputs())
    let session = model.freeze(position: Double(w), bounds: bounds, windows: [w], zoomKey: 4, inputs: inputs(),
                               baseline: FixedGridEditBaseline(dataGeneration: 0, dataRevision: revision, days: original, target: (timeline.day, timeline.blocks[0])))
    let decided = model.decisionForDrawing(window: w, zoomKey: 4, isInteracting: false, inputs: inputs())
    // A day changes during the session, then the session moves to the second event.
    kept[w + 1] = try fixtureTimeline(TemporalGridFixtures.busy(w + 1 - first), zone: zoneSeoul)
    revision = 2
    model.retarget(session, target: (timeline.day, timeline.blocks[1]))
    let frozen = try #require(model.frozen)
    #expect(frozen.id == session && model.shared(position: Double(w), bounds: bounds, inputs: inputs()) == drawn)
    #expect(model.decisionForDrawing(window: w, zoomKey: 4, isInteracting: false, inputs: inputs()).layout == decided.layout)
    #expect(frozen.baseline.target?.eventKey == timeline.blocks[1].eventKey)
    // The original is still the session's start: the change made before the move is still seen.
    let changes = frozen.baseline.changes(dataGeneration: 0, dataRevision: revision) { kept[$0.daysSinceUnixEpoch] }
    #expect(changes.changedDays == [LocalDate(daysSinceUnixEpoch: w + 1)] && changes.target == .unchanged)
    model.retarget(session + 1, target: nil)                                            // another session's id: nothing
    #expect(model.frozen?.baseline.target?.eventKey == timeline.blocks[1].eventKey)
}

// MARK: The anchor after a save

@Test func theEdgeKeptIsTheHandleLastTouchedElseWhatTheSaveMoved() {
    func session(_ last: I.Handle?) -> I.Session { var s = I.Session(id: 1, target: lunch); s.lastEdited = last; return s }
    #expect(I.anchor(for: session(.start), committed: .init(day: day, startMinute: 700, endMinute: 780)) == .edge(.start, day: day, minute: 700))
    #expect(I.anchor(for: session(.end), committed: .init(day: day, startMinute: 700, endMinute: 800)) == .edge(.end, day: day, minute: 800))
    #expect(I.anchor(for: session(nil), committed: .init(day: day, startMinute: 720, endMinute: 810)) == .edge(.end, day: day, minute: 810))   // only the end moved
    #expect(I.anchor(for: session(nil), committed: .init(day: day, startMinute: 750, endMinute: 810)) == .edge(.start, day: day, minute: 750))
}

@MainActor
@Test func afterASaveTheEditedEdgeStaysAtItsHeightWhileTheAxisEasesToTheNewPlan() throws {
    let scenario = try #require(TemporalGridFixtures.all.first { $0.name.hasPrefix("3 ") })
    let days = try scenario.days.map { try fixtureTimeline($0, zone: zoneSeoul) }
    let first = days[0].day.daysSinceUnixEpoch
    var kept = Dictionary(uniqueKeysWithValues: days.map { ($0.day.daysSinceUnixEpoch, $0) })
    var revision = 1
    let viewport: CGFloat = 640, zoom: CGFloat = 3
    func inputs() -> FixedGridBrowseModel.Inputs {
        let now = kept
        return FixedGridBrowseModel.Inputs(zone: zoneSeoul, environment: FixedGridEnvironment(viewportHeight: viewport, contentWidth: 165, textScale: 1), timelineFor: { now[$0.daysSinceUnixEpoch] }, revision: revision)
    }
    var now: Double = 10
    let model = FixedGridBrowseModel()
    model.clock = { now }
    let w = first + 2
    let bounds = (w - 1)...(w + 2)
    _ = model.shared(position: Double(w), bounds: bounds, inputs: inputs())
    let timeline = try #require(kept[w])
    let session = model.freeze(position: Double(w), bounds: bounds, windows: [w], zoomKey: 12, inputs: inputs(),
                               baseline: FixedGridEditBaseline(dataGeneration: 0, dataRevision: revision, days: [:], target: (timeline.day, timeline.blocks[0])))
    // The save changed the day after (the plan moves under the frozen axis).
    kept[w + 1] = try fixtureTimeline(TemporalGridFixtures.busy(w + 1 - first), zone: zoneSeoul)
    revision = 2
    let frozen = model.shared(position: Double(w), bounds: bounds, inputs: inputs())
    let projection = WallClockProjection(day: timeline.day, zone: zoneSeoul)
    // The edited event: the one whose end the new plan moves the most (so keeping it in place is something the anchor does).
    let current = FixedGridBrowseModel().partition(window: w, inputs: inputs())
    func moved(_ block: EventBlock) -> CGFloat {
        let time = FixedGridUnfreezeAnchor.wallTime(of: .end, minute: block.endMinute, projection: projection)
        return abs(current.zoomed(viewportHeight: viewport, zoomScale: zoom).timeToY(time) - frozen.zoomed(viewportHeight: viewport, zoomScale: zoom).timeToY(time))
    }
    let block = try #require(timeline.blocks.max { moved($0) < moved($1) })
    // Its saved end is at 200 pt from the top of the screen.
    let edge = FixedGridUnfreezeAnchor.wallTime(of: .end, minute: block.endMinute, projection: projection)
    let offset = ContinuousDayAxis.anchoredOffset(time: edge, partition: frozen, zoom: zoom, viewport: viewport, focal: 200).offset
    let anchor = FixedGridUnfreezeAnchor.resolve(.edge(.end, day: timeline.day, minute: block.endMinute), frozen: frozen, projection: { _ in projection },
                                                 zoom: zoom, viewport: viewport, offset: offset)
    #expect(anchor.isEdge && abs(anchor.time - edge) < 1e-9)
    let axis = ElapsedMinuteAxisMapping(inner: TemporalAxisMapping(partition: frozen.zoomed(viewportHeight: viewport, zoomScale: zoom)), projection: projection)
    #expect(abs(anchor.focal - (axis.y(endMinute: block.endMinute) - offset)) < 1e-6)  // where the card's end is drawn

    model.unfreeze(session)
    var frames = 0, worst: CGFloat = 0
    var shown = model.shared(position: Double(w), bounds: bounds, inputs: inputs())
    repeat {
        now += 1.0 / 60
        frames += 1
        shown = model.shared(position: Double(w), bounds: bounds, inputs: inputs())
        let held = anchor.offset(on: shown, zoom: zoom, viewport: viewport)
        #expect(!held.clamped)
        worst = max(worst, abs(anchor.drift(on: shown, zoom: zoom, viewport: viewport, offset: held.offset)))
    } while model.isEasing && frames < 60
    #expect(frames >= 15 && frames <= 20 && worst < 1e-6, "frames \(frames) worst \(worst)")
    // Without the anchor the edge would have moved: the new plan puts it elsewhere at the old offset.
    #expect(abs(anchor.drift(on: shown, zoom: zoom, viewport: viewport, offset: offset)) > 1)
}

@Test func anEdgeOffScreenFallsBackToTheMiddleAndAnEndIsTheMinuteItEndsBefore() {
    let partition = TemporalGridPartition.uniform(slotCount: 12, totalHeight: 640)
    let projection = WallClockProjection(day: day, zone: zoneSeoul)
    // At 2×, scrolled to the top: 18:00 is at 2 × 480 = 960 pt, below a 640 pt screen.
    let off = FixedGridUnfreezeAnchor.resolve(.edge(.start, day: day, minute: 18 * 60), frozen: partition, projection: { _ in projection }, zoom: 2, viewport: 640, offset: 0)
    #expect(!off.isEdge && off.focal == 320 && abs(off.time - 6 * 60) < 1e-9)          // the time at the middle
    let on = FixedGridUnfreezeAnchor.resolve(.edge(.start, day: day, minute: 3 * 60), frozen: partition, projection: { _ in projection }, zoom: 2, viewport: 640, offset: 0)
    #expect(on.isEdge && abs(on.focal - 160) < 1e-9)
    #expect(FixedGridUnfreezeAnchor.resolve(.middle, frozen: partition, projection: { _ in projection }, zoom: 2, viewport: 640, offset: 0) == off)
    #expect(FixedGridUnfreezeAnchor.wallTime(of: .end, minute: 600, projection: projection) == 600)
    #expect(FixedGridUnfreezeAnchor.wallTime(of: .start, minute: 600, projection: projection) == 600)
}

// MARK: The router

@MainActor
@Test func theRouterSendsTheGridItsCommandsAndTheEditingPartsTheRest() {
    let router = FixedGridEditRouter()
    var grid: [I.Command] = [], editor: [I.Command] = []
    router.grid = { grid.append($0) }
    router.editor = { command in
        editor.append(command)
        // The editing parts answer through the same door (a drag makes the draft changed).
        if case let .dragHandle(session, .moved, _, _, _) = command { router.send(.draftChanged(session: session, isDirty: true)) }
    }
    router.send(.enter(lunch))
    router.send(.handleDrag(.began, .end, point: .zero, minute: 790))
    router.send(.handleDrag(.moved, .end, point: .zero, minute: 800))
    router.send(.handleDrag(.ended, .end, point: .zero, minute: 800))
    router.send(.confirm)
    router.send(.commitFinished(session: 1, .init(day: day, startMinute: 720, endMinute: 800)))
    #expect(grid == [.freeze(session: 1, lunch), .unfreeze(session: 1, .edge(.end, day: day, minute: 800))])
    #expect(editor.first == .began(session: 1, lunch) && editor.contains(.commit(session: 1)) && editor.last == .ended(session: 1, .committed))
    #expect(gridCommands(router.log) == grid && router.session == nil)
}

// MARK: Renaming

@Test func aTitleTapRenamesAndTheInnermostThingGoesFirst() {
    var machine = entered()
    // With a handle chosen, the title tap lets it go and brings the keyboard up.
    _ = machine.handle(.handleTap(.end))
    #expect(machine.handle(.tapTitle) == [.handle(session: 1, .none), .rename(session: 1, true)])
    #expect(machine.session?.renaming == true)
    #expect(machine.handle(.tapTitle).isEmpty)                                          // already renaming
    // A tap outside ends the renaming first; the session stays.
    #expect(machine.handle(.tapOutside) == [.rename(session: 1, false)])
    #expect(machine.editing != nil && machine.session?.renaming == false)
    // A handle touched while renaming ends it before choosing the handle.
    _ = machine.handle(.tapTitle)
    #expect(machine.handle(.handleTap(.start)) == [.rename(session: 1, false), .handle(session: 1, .selected(.start))])
    _ = machine.handle(.tapTitle)
    #expect(machine.handle(.handleDrag(.began, .end, point: .zero, minute: nil)).first == .rename(session: 1, false))
    _ = machine.handle(.handleDrag(.ended, .end, point: .zero, minute: nil))
    // The keyboard going away by itself ends it too.
    _ = machine.handle(.tapTitle)
    #expect(machine.handle(.endRename) == [.rename(session: 1, false)])
    #expect(machine.handle(.endRename).isEmpty)
}

@Test func doneWhileRenamingSavesAndAnUnchangedRenameJustEnds() {
    var machine = entered()
    _ = machine.handle(.tapTitle)
    _ = machine.handle(.draftChanged(session: 1, isDirty: true))                         // the title was typed
    #expect(machine.handle(.confirm) == [.rename(session: 1, false), .handle(session: 1, .none), .commit(session: 1)])
    var clean = entered()
    _ = clean.handle(.tapTitle)
    #expect(clean.handle(.confirm) == [.unfreeze(session: 1, .middle), .ended(session: 1, .cancelled)])
}
