import CoreGraphics
import NEOBudgetCalendar
import Testing
@testable import OnAllApp

// Reading days while the days move (Phase 2B): a day is kept as soon as it is read, a failed day does not throw the others away, a move does not make reads
// stale but a calendar change (`reload`) does, a stale read never overwrites a newer one, and a day being read is told apart from a failed one and from a day
// that is read and empty. Reads are slowed, held, reordered and failed through `AppModel.dayReadInterceptor`, on the synthetic calendar (`-demo`).
//
// Then the fixed grid's time axis while a day is missing: nothing is planned on a day that is not read (the shared axis is held), and when the day lands the
// axis eases to the new plan instead of jumping.

private struct Failure: Error {}

/// Holds chosen reads until they are let go, in any order, and can make them fail or answer with something else.
@MainActor
private final class ReadGate {
    private var held: [LocalDate: [CheckedContinuation<Void, Never>]] = [:]
    var blocked: Set<LocalDate> = []
    /// Only the first read of these days is held; later reads go straight through.
    var blockOnce: Set<LocalDate> = []
    var failing: Set<LocalDate> = []
    /// The read of a day answers with this instead (to tell a stale answer apart from the fresh one).
    var answer: [LocalDate: DayTimeline] = [:]
    private(set) var reads: [LocalDate] = []

    func waiting(_ day: LocalDate) -> Bool { !(held[day] ?? []).isEmpty }

    func release(_ day: LocalDate) {
        blocked.remove(day)
        for continuation in held.removeValue(forKey: day) ?? [] { continuation.resume() }
    }

    func releaseAll() { for day in Array(held.keys) { release(day) } }

    var interceptor: @MainActor (LocalDate, @escaping @MainActor () async throws -> DayTimeline) async throws -> DayTimeline {
        { [self] day, read in
            reads.append(day)
            let once = blockOnce.remove(day) != nil
            if blocked.contains(day) || once {
                await withCheckedContinuation { held[day, default: []].append($0) }
            }
            if failing.contains(day) { throw Failure() }
            let real = try await read()
            if let replaced = answer.removeValue(forKey: day) { return replaced }
            return real
        }
    }
}

@MainActor
private func readyModel() async throws -> AppModel {
    let model = try AppModel.demo()
    await model.start()
    #expect(model.phase == .ready)
    return model
}

@MainActor
private func until(_ condition: () -> Bool, _ note: Comment) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(condition(), note)
}

/// Every kept day is the day it is kept under, with its own events and transactions once each.
@MainActor
private func expectConsistent(_ model: AppModel, _ note: String) {
    for day in model.cachedDays {
        guard let timeline = model.cachedTimeline(for: day) else { Issue.record("\(note): \(day) listed but not kept"); continue }
        #expect(timeline.day == day, "\(note): \(day) holds \(timeline.day)")
        let blocks = timeline.blocks.map(\.id)
        #expect(Set(blocks).count == blocks.count, "\(note): an event twice on \(day)")
        let markers = timeline.markers.map(\.transactionID)
        #expect(Set(markers).count == markers.count, "\(note): a transaction twice on \(day)")
    }
}

// MARK: The model

@MainActor
@Test func aDayIsKeptTheMomentItIsReadNotWhenTheSlowestOneIs() async throws {
    let model = try await readyModel()
    let gate = ReadGate()
    defer { gate.releaseAll() }
    model.dayReadInterceptor = gate.interceptor
    let start = model.selectedDay
    let slow = start.adding(days: 4)                                                  // the farthest of the margin
    gate.blocked = [slow]
    let reading = Task { await model.loadMissing(extra: 2) }
    await until({ model.cachedTimeline(for: start.adding(days: -3)) != nil && model.cachedTimeline(for: start.adding(days: 3)) != nil }, "the near days landed")
    #expect(gate.waiting(slow) && model.cachedTimeline(for: slow) == nil)            // while the slow one is still being read
    #expect(model.loadState(for: slow) == .loading && model.loadState(for: start.adding(days: 3)) == .loaded)
    gate.release(slow)
    await reading.value
    #expect(model.loadState(for: slow) == .loaded)
    expectConsistent(model, "after")
}

@MainActor
@Test func aFailedDayDoesNotThrowTheOthersAwayAndIsToldApartFromLoadingAndFromEmpty() async throws {
    let model = try await readyModel()
    let gate = ReadGate()
    defer { gate.releaseAll() }
    model.dayReadInterceptor = gate.interceptor
    let start = model.selectedDay
    let broken = start.adding(days: 3)
    gate.failing = [broken]
    let epoch = Double(start.daysSinceUnixEpoch)
    await model.prefetch(forPosition: epoch + 1.5, target: start.daysSinceUnixEpoch + 2)    // needs D ... D+4: D+3 (fails) then D+4
    #expect(gate.reads == [broken, start.adding(days: 4)])
    #expect(model.cachedTimeline(for: start.adding(days: 4)) != nil)                    // read after the failure, still kept
    #expect(model.loadState(for: broken) == .failed && model.failedDays == [broken])
    #expect(model.phase == .ready)                                                       // a day off the screen failing is not the screen failing
    // A day that is read and has nothing on it is loaded, not loading or failed.
    var empty: LocalDate?
    for offset in (5...60) {
        let day = start.adding(days: offset)
        if let read = await model.readDays([day]).first?.timeline, read.blocks.isEmpty, read.markers.isEmpty { empty = day; model.adopt([StripDay(day: day, timeline: read)]); break }
    }
    if let empty { #expect(model.loadState(for: empty) == .loaded) }
    #expect(model.loadState(for: start.adding(days: 80)) == .notRead)
    // Asked for again, it is read again and the failure is gone.
    gate.failing = []
    await model.prefetch(forPosition: epoch + 1.5, target: start.daysSinceUnixEpoch + 2)
    #expect(model.loadState(for: broken) == .loaded && model.failedDays.isEmpty)
    expectConsistent(model, "after")
}

@MainActor
@Test func aVisibleDayFailingStillFailsTheScreenAsBefore() async throws {
    let model = try await readyModel()
    let gate = ReadGate()
    defer { gate.releaseAll() }
    model.dayReadInterceptor = gate.interceptor
    let far = model.selectedDay.adding(days: 30)
    gate.failing = [far.adding(days: 1)]
    #expect(model.moveTo(far))
    await model.loadMissing()
    #expect(model.phase == .failed("일정과 거래를 불러오지 못했습니다."))
    #expect(model.cachedTimeline(for: far) != nil && model.cachedTimeline(for: far.adding(days: 2)) != nil)      // the others were kept
    gate.failing = []
    await model.loadMissing()
    #expect(model.phase == .ready && model.visibleTimelines.count == 2)
}

@MainActor
@Test func forTheFixedGridAVisibleDayFailingIsThatColumnsFailureNotTheScreens() async throws {
    let model = try await readyModel()
    let gate = ReadGate()
    defer { gate.releaseAll() }
    model.dayReadInterceptor = gate.interceptor
    let far = model.selectedDay.adding(days: 30)
    gate.failing = [far.adding(days: 1)]
    #expect(model.moveTo(far))
    await model.loadMissing(extra: 2, policy: DayPrefetchPolicy.browse.cachePolicy, failsScreen: false)
    #expect(model.phase == .ready)
    #expect(model.loadState(for: far.adding(days: 1)) == .failed && model.loadState(for: far) == .loaded)
    gate.failing = []
    await model.prefetch(forPosition: Double(far.daysSinceUnixEpoch))                   // what the grid's retry does
    #expect(model.visibleTimelines.count == 2 && model.failedDays.isEmpty)
}

@MainActor
@Test func aMoveDoesNotThrowAwayTheReadsItOutranAndADayIsReadOnceForTwoAskers() async throws {
    let model = try await readyModel()
    let policy = DayPrefetchPolicy.browse
    await model.loadMissing(extra: policy.readAhead, policy: policy.cachePolicy)
    let gate = ReadGate()
    defer { gate.releaseAll() }
    model.dayReadInterceptor = gate.interceptor
    let start = model.selectedDay
    let ahead = [start.adding(days: 5), start.adding(days: 6)]
    gate.blocked = Set(ahead)
    let reads = model.dayReads
    // A flick is heading two days on; the move is taken over a day on (the selected day follows) before the reads land, and its own read asks for the same days.
    let flight = Task { await model.prefetch(forPosition: Double(start.daysSinceUnixEpoch) + 1.6, target: start.daysSinceUnixEpoch + 4) }   // needs D ... D+6
    await until({ gate.waiting(ahead[0]) }, "the flight is reading")
    #expect(model.moveTo(start.adding(days: 2)))
    let settle = Task { await model.loadMissing(extra: policy.readAhead, policy: policy.cachePolicy) }
    try await Task.sleep(for: .milliseconds(30))
    gate.release(ahead[1])                                                              // out of order: the farther one first
    gate.release(ahead[0])
    await flight.value
    await settle.value
    #expect(ahead.allSatisfy { model.cachedTimeline(for: $0) != nil })                  // the flight's reads were kept
    #expect(model.dayReads - reads == Set(gate.reads).count)                           // and nothing was read twice
    #expect(model.staleReadsDropped == 0)
    #expect(model.cachedDays.isSuperset(of: DayCachePolicy.standard.required(around: model.selectedDay)))
    expectConsistent(model, "after")
}

@MainActor
@Test func aReadThatACalendarChangeOvertookIsDroppedAndNeverOverwritesTheFreshDay() async throws {
    let model = try await readyModel()
    let gate = ReadGate()
    defer { gate.releaseAll() }
    model.dayReadInterceptor = gate.interceptor
    let start = model.selectedDay
    #expect(model.moveTo(start.adding(days: 1)))
    let day = start.adding(days: 3)                                                     // not kept yet, and one of the days a reload around D+1 reads
    // The old read of the day is held; when let go it answers with another day's data, so an overwrite would show.
    let wrong = try #require(await model.readDays([start.adding(days: 50)]).first?.timeline)
    gate.blockOnce = [day]
    let pending = model.dataGeneration
    let flight = Task { await model.prefetch(forPosition: Double(start.daysSinceUnixEpoch + 1), target: nil) }
    await until({ gate.waiting(day) }, "the old read is under way")
    await model.reload()                                                                // the calendar changed under the read: this reads the day afresh
    #expect(model.dataGeneration == pending + 1)
    let fresh = try #require(model.cachedTimeline(for: day))
    gate.answer = [day: wrong]
    gate.release(day)
    await flight.value
    #expect(model.cachedTimeline(for: day) == fresh && model.cachedTimeline(for: day)?.day == day)
    #expect(model.staleReadsDropped >= 1)
    expectConsistent(model, "after")
}

@MainActor
@Test func aStormOfMovesWithSlowReadsLandingInAnyOrderLeavesTheCacheWhole() async throws {
    let model = try await readyModel()
    let policy = DayPrefetchPolicy.browse
    await model.loadMissing(extra: policy.readAhead, policy: policy.cachePolicy)
    var seed: UInt64 = 0x5eed
    func next(_ range: ClosedRange<Int>) -> Int {                                      // deterministic: a small LCG
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return range.lowerBound + Int((seed >> 33) % UInt64(range.count))
    }
    var delays: [Int] = (0..<400).map { _ in next(0...40) }
    var failEvery = 0
    model.dayReadInterceptor = { _, read in
        failEvery += 1
        let wait = delays.isEmpty ? 5 : delays.removeFirst()
        try await Task.sleep(for: .milliseconds(wait))
        if failEvery % 9 == 0 { throw Failure() }                                       // some reads fail
        return try await read()
    }
    let start = model.selectedDay.daysSinceUnixEpoch
    var selected = start
    var tasks: [Task<Void, Never>] = []
    // Flicks forward and back, each a few positions on the way, the selected day following some of them before the reads land, reversals in flight.
    for step in 0..<40 {
        let direction = next(0...9) < 7 ? 1 : -1
        let target = selected + direction
        for fraction in [0.3, 0.6, 0.9] {
            let position = Double(selected) + Double(direction) * fraction
            tasks.append(Task { await model.prefetch(forPosition: position, target: target, policy: policy) })
            try await Task.sleep(for: .milliseconds(next(0...12)))
        }
        if next(0...2) > 0 {
            selected = target
            _ = model.moveTo(LocalDate(daysSinceUnixEpoch: selected))
            tasks.append(Task { await model.loadMissing(extra: policy.readAhead, policy: policy.cachePolicy) })
        }
        if step % 10 == 9 { tasks.append(Task { await model.reload() }) }               // the calendar changes now and then
        #expect(model.cachedDays.count <= policy.cachePolicy.capacity + 6, "step \(step)")
        expectConsistent(model, "step \(step)")
    }
    for task in tasks { await task.value }
    model.dayReadInterceptor = nil
    await model.loadMissing(extra: policy.readAhead, policy: policy.cachePolicy)
    await model.prefetch(forPosition: Double(selected), policy: policy)
    expectConsistent(model, "after")
    #expect(model.selectedDay.daysSinceUnixEpoch == selected)
    #expect(model.cachedDays.isSuperset(of: DayCachePolicy.standard.required(around: model.selectedDay)))
    #expect(model.cachedDays.count <= policy.cachePolicy.capacity)
    #expect(model.failedDays.isEmpty)
    #expect(DayPrefetchPolicy.neededDays(position: Double(selected)).allSatisfy { model.loadState(for: LocalDate(daysSinceUnixEpoch: $0)) == .loaded })
    #expect(model.phase == .ready)
}

// MARK: The time axis while a day is missing

private let seoul = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()

@MainActor
private final class Clock { var now: Double = 100 }

private struct AxisRig {
    let timelines: [Int: DayTimeline]
    let first: Int
    let environment: FixedGridEnvironment

    init(_ prefix: String) throws {
        let scenario = try #require(TemporalGridFixtures.all.first { $0.name.hasPrefix(prefix) })
        let days = try scenario.days.map { try fixtureTimeline($0) }
        first = days[0].day.daysSinceUnixEpoch
        timelines = Dictionary(uniqueKeysWithValues: days.map { ($0.day.daysSinceUnixEpoch, $0) })
        environment = FixedGridEnvironment(viewportHeight: 640, contentWidth: 165, textScale: scenario.textScale)
    }

    func inputs(revision: Int, missing: Set<Int> = []) -> FixedGridBrowseModel.Inputs {
        let kept = timelines.filter { !missing.contains($0.key) }
        return FixedGridBrowseModel.Inputs(zone: seoul, environment: environment, timelineFor: { kept[$0.daysSinceUnixEpoch] }, revision: revision)
    }
}

private func largestStep(_ a: TemporalGridPartition, _ b: TemporalGridPartition) -> Double {
    zip(a.boundaries, b.boundaries).map { abs($0 - $1) }.max() ?? 0
}

@MainActor
@Test func aWindowWithADayNotReadIsNotPlannedAndTheSharedAxisIsHeld() async throws {
    let rig = try AxisRig("3 ")
    let model = FixedGridBrowseModel()
    let w = rig.first + 2
    let absent = w + 3                                                                   // read by window w+1 (w ... w+3), not by window w (w-1 ... w+2)
    let inputs = rig.inputs(revision: 1, missing: [absent])
    let rested = model.partition(window: w, inputs: inputs)                             // w reads w-1 ... w+2: all there, planned
    #expect(model.framePlans == 1)
    // Moving towards w+1, whose window reads the missing day: nothing is planned for it, and the axis stays the one on screen.
    for step in 1...10 {
        let shown = model.shared(position: Double(w) + Double(step) / 10, bounds: (w - 1)...(w + 2), inputs: inputs)
        #expect(largestStep(shown, rested) < 1e-9, "step \(step)")
    }
    #expect(model.framePlans == 1 && model.heldPartitions >= 10)
    // Planning ahead skips it too.
    var ready = 0
    model.warm(windows: [w + 1], inputs: inputs) { ready += 1 }
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.backgroundPlans == 0 && ready == 0)
    // No engine run on a window with a day missing, and none on the held axis.
    let runs = model.continuousLayoutRuns
    let decision = model.decision(window: w + 1, zoomKey: 4, inputs: inputs)
    #expect(model.continuousLayoutRuns == runs && decision.layout == nil)
}

@MainActor
@Test func withNothingOnScreenYetAWindowWaitingForADayShowsTheEvenPartition() throws {
    let rig = try AxisRig("14 ")
    let model = FixedGridBrowseModel()
    let w = rig.first + 2
    let shown = model.partition(window: w, inputs: rig.inputs(revision: 1, missing: [w + 1]))
    #expect(shown == TemporalGridPartition.uniform(slotCount: FixedGridBrowseModel.parameters.slotCount, totalHeight: 640))
    #expect(model.framePlans == 0)
}

@MainActor
@Test func whenTheMissingDayLandsTheAxisEasesToTheNewPlanInsteadOfJumping() async throws {
    // Fixtures whose days differ, so the window waiting for a day and its plan usually differ.
    var eased = 0
    for prefix in ["2 ", "3 ", "4 ", "6 "] {
        let rig = try AxisRig(prefix)
        let model = FixedGridBrowseModel()
        let clock = Clock()
        model.clock = { clock.now }
        let w = rig.first + 2
        let absent = w + 2
        let waiting = rig.inputs(revision: 1, missing: [absent])
        // Window w-1 is on screen and planned; the days move to w, whose context day is still being read: w shows w-1's axis.
        _ = model.partition(window: w - 1, inputs: rig.inputs(revision: 1))
        let held = model.shared(position: Double(w), bounds: (w - 1)...(w + 2), inputs: waiting)
        #expect(largestStep(held, FixedGridBrowseModel().partition(window: w - 1, inputs: rig.inputs(revision: 1))) < 1e-9, "\(prefix) held")
        // The day lands (a new data revision). The plan is made, and the axis eases to it over `transitionDuration`.
        let landed = rig.inputs(revision: 2)
        let target = FixedGridBrowseModel().partition(window: w, inputs: landed)
        var previous = model.shared(position: Double(w), bounds: (w - 1)...(w + 2), inputs: landed)
        guard largestStep(held, target) > 1e-9 else {
            // The plan is what was held: nothing to ease, and the axis is already right.
            #expect(model.transitionsBegun == 0 && largestStep(previous, target) < 1e-9, "\(prefix)")
            continue
        }
        eased += 1
        #expect(model.transitionsBegun == 1, "\(prefix)")
        #expect(largestStep(previous, held) < 1e-9, "\(prefix) the first frame after the landing is what was on screen")
        let total = largestStep(held, target)
        var steps: [Double] = []
        while model.isEasing {
            clock.now += 1.0 / 60
            let next = model.shared(position: Double(w), bounds: (w - 1)...(w + 2), inputs: landed)
            steps.append(largestStep(previous, next))
            previous = next
        }
        #expect(previous == target, "\(prefix) ends exactly on the plan")
        #expect(steps.count >= 15 && steps.count <= 20, "\(prefix) \(steps.count) frames")
        // No frame moves a boundary by more than a sixth of the whole change (an ease-out cubic over 18 frames moves at most ~1/6 in its first frame).
        #expect(steps.allSatisfy { $0 <= total / 5 + 1e-9 }, "\(prefix) largest step \(steps.max() ?? 0) of \(total) min")
        // The decision is made on the plan, not on the easing axis: once, and not again while it eases.
        _ = model.decision(window: w, zoomKey: 4, inputs: landed)
        let runs = model.continuousLayoutRuns
        _ = model.decision(window: w, zoomKey: 4, inputs: landed)
        #expect(model.continuousLayoutRuns == runs)
    }
    #expect(eased >= 2)
}

@MainActor
@Test func aWindowTheDaysHaveLeftHasNothingToEaseFromWhenItsPlanChanges() throws {
    let rig = try AxisRig("14 ")
    let model = FixedGridBrowseModel()
    let w = rig.first + 2
    _ = model.shared(position: Double(w - 1), bounds: (w - 2)...(w + 2), inputs: rig.inputs(revision: 1))
    _ = model.shared(position: Double(w + 1), bounds: (w - 2)...(w + 2), inputs: rig.inputs(revision: 1))      // w-1 is off screen now
    let changed = try fixtureTimeline(TemporalGridFixtures.day(0, events: [(8 * 60, 9 * 60), (8 * 60 + 5, 9 * 60)], transactions: [500]))
    let inputs = FixedGridBrowseModel.Inputs(
        zone: seoul, environment: rig.environment,
        timelineFor: { $0.daysSinceUnixEpoch == w - 2 ? changed : rig.timelines[$0.daysSinceUnixEpoch] }, revision: 2)
    _ = model.partition(window: w - 1, inputs: inputs)
    #expect(model.transitionsBegun == 0)
}
