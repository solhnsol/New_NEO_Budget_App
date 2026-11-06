import CoreGraphics
import NEOBudgetCalendar
import Testing
@testable import OnAllApp

private typealias F = TemporalGridFixtures

private func parameters(_ n: Int = 12, viewport: CGFloat = 640, scale: CGFloat = 1) -> TemporalGridParameters {
    var p = TemporalGridParameters.with(slotCount: n)
    p.viewportHeight = viewport
    p.textScale = scale
    return p
}

private func window(_ scenario: AxisStabilityScenario, main: Int = 3) -> TemporalWindow {
    TemporalWindow(days: Array(scenario.days[(main - 1)...(main + 2)]), mainIndex: 1)
}

private func plan(_ scenario: AxisStabilityScenario, n: Int = 12, main: Int = 3) -> TemporalGridPlan {
    var p = parameters(n, viewport: scenario.viewportHeight, scale: scenario.textScale)
    p.allocation = scenario.parameters
    return TemporalGridPlanner.plan(window: window(scenario, main: main), parameters: p)
}

private let everyRun = F.all

// MARK: Invariants on every fixture and every N

@Test func everyFixtureGetsExactlyNEqualCellsThatCoverTheDay() {
    for scenario in everyRun {
        for n in [10, 12, 16] {
            let result = plan(scenario, n: n)
            let partition = result.partition
            #expect(partition.slotCount == n, "\(scenario.name) N=\(n)")
            #expect(partition.boundaries.count == n + 1)
            #expect(partition.boundaries.first == 0 && partition.boundaries.last == 1440)
            #expect(zip(partition.boundaries, partition.boundaries.dropFirst()).allSatisfy { $0 < $1 })
            #expect(partition.totalHeight == scenario.viewportHeight)
            #expect(partition.slotHeight == scenario.viewportHeight / CGFloat(n))
            #expect(partition.wholeMinuteBoundaries != nil)
            for slot in 0..<n {
                #expect(partition.minutes(inSlot: slot) >= Double(result.effectiveMinSlotMinutes), "\(scenario.name) N=\(n) cell \(slot)")
                #expect(partition.minutes(inSlot: slot) <= Double(result.effectiveMaxSlotMinutes), "\(scenario.name) N=\(n) cell \(slot)")
            }
            #expect(!result.constraintsRelaxed)
        }
    }
}

@Test func theSameInputGivesTheSamePartitionWhateverWasComputedBefore() {
    let a = F.stabilizationRuns[2], b = F.gridRuns[3]
    let cold = plan(a).partition
    // Plan something else in between, and ask again through a store that is warm, cold, and full of other windows.
    _ = plan(b)
    let store = TemporalGridStore(limit: 4)
    var p = parameters(); p.allocation = a.parameters
    let first = store.plan(window: window(a), parameters: p).partition
    for main in 2...5 { _ = store.plan(window: window(b, main: main), parameters: p) }
    let again = store.plan(window: window(a), parameters: p).partition
    let fresh = TemporalGridStore().plan(window: window(a), parameters: p).partition
    #expect(cold == first && first == again && again == fresh)
    // The order of the events inside a day is not part of the input.
    var shuffled = a.days
    shuffled = shuffled.map { day in AllocationDay(day: day.day, totalMinutes: day.totalMinutes, events: day.events.reversed(), transactions: day.transactions.reversed()) }
    let reordered = TemporalGridPlanner.plan(window: TemporalWindow(days: Array(shuffled[2...5]), mainIndex: 1), parameters: p).partition
    #expect(reordered == cold)
}

@Test func planningTwiceGivesTheSameBreakdownDownToTheLastDigit() {
    let one = plan(F.gridRuns[4]), two = plan(F.gridRuns[4])
    #expect(one == two)
}

// MARK: Constraints and their policy

@Test func whenNoPartitionSatisfiesTheLengthLimitsTheyAreRelaxedAndSaid() {
    // 2 cells of at most 8 hours cannot cover 24 hours.
    var p = parameters(2)
    var result = TemporalGridPlanner.plan(window: window(F.stabilizationRuns[0]), parameters: p)
    #expect(result.constraintsRelaxed)
    #expect(result.partition.slotCount == 2)
    #expect(result.effectiveMaxSlotMinutes >= 720)
    #expect(result.partition.boundaries == [0, 720, 1440])
    // 200 cells of at least 10 minutes cannot fit in 24 hours.
    p = parameters(200)
    result = TemporalGridPlanner.plan(window: window(F.stabilizationRuns[0]), parameters: p)
    #expect(result.constraintsRelaxed)
    #expect(result.partition.slotCount == 200)
    #expect(result.effectiveMinSlotMinutes <= 5)
    #expect(zip(result.partition.boundaries, result.partition.boundaries.dropFirst()).allSatisfy { $0 < $1 })
    // A cell count that fits is not relaxed.
    #expect(!TemporalGridPlanner.plan(window: window(F.stabilizationRuns[0]), parameters: parameters(16)).constraintsRelaxed)
}

@Test func theCandidateStepIsOnlyTheSearchResolutionAndNoTimeIsRounded() {
    // Events at 10:03-10:20 and 10:21-10:29 and a transaction at 10:07: the partition is searched in 5 minute steps, but each time is placed exactly.
    let day = F.day(3, events: [(603, 620), (621, 629)], transactions: [607])
    let days = (0..<9).map { $0 == 3 ? day : F.day($0) }
    let result = TemporalGridPlanner.plan(window: TemporalWindow(days: Array(days[2...5]), mainIndex: 1), parameters: parameters())
    let partition = result.partition
    #expect(partition.boundaries.allSatisfy { $0.truncatingRemainder(dividingBy: 5) == 0 })
    let entities = GridDayEntities.make(day)
    #expect(entities.events.map(\.startMinute) == [603, 621])         // untouched
    #expect(entities.events.map(\.endMinute) == [620, 629])
    let placed = GridPlacement.place(entities, partition: partition, metrics: .standard(), transactionPitch: 26)
    // The height is the difference of the two true ends: 17 minutes and 8 minutes of whatever the cell scale is there.
    for event in placed.events {
        #expect(abs(event.height - partition.height(from: Double(event.startMinute), to: Double(event.endMinute))) < 1e-9)
    }
    #expect(placed.events[0].height > placed.events[1].height || partition.minutesPerPoint(atMinute: 603) != partition.minutesPerPoint(atMinute: 621))
}

// MARK: The cost of rounder boundaries never beats readability

@Test func hourBoundariesAreChosenWhenNothingNeedsFinerOnesAndFinerOnesWhenSomethingDoes() {
    let empty = plan(F.gridRuns[0]).partition
    #expect(empty.boundaries.allSatisfy { Int($0) % 60 == 0 })        // an empty day: all on the hour
    let dense = plan(F.gridRuns[3], n: 16).partition                   // 15 minute events in a row at 9:00-11:00
    #expect(dense.boundaries.contains { Int($0) % 60 != 0 })            // finer boundaries appear where the information is
}

@Test func preferringRoundTimesNeverCostsReadabilityComparedWithAHourOnlySearch() {
    var finer = 0, same = 0
    for scenario in everyRun {
        var fine = parameters(12, viewport: scenario.viewportHeight, scale: scenario.textScale); fine.allocation = scenario.parameters
        var hourly = fine; hourly.candidateStepMinutes = 60
        let w = window(scenario)
        let profiles = w.days.map { TemporalDemandProfile.make($0, parameters: fine) }
        let claims = TemporalGridPlanner.weightedClaims(profiles: profiles, mainIndex: 1, parameters: fine)
        let a = TemporalGridPlanner.plan(window: w, parameters: fine).partition
        let b = TemporalGridPlanner.plan(window: w, parameters: hourly).partition
        func readability(_ partition: TemporalGridPartition) -> Double {
            TemporalGridPlanner.evaluate(partition: partition, claims: claims, mass: [Double](repeating: 0, count: 1440), alignment: [Double](repeating: 0, count: 1441), parameters: fine).exactClaimCost
        }
        // The same claims, charged by true height: the search that may use any 5 minute boundary is at least as readable as the hour-only one.
        #expect(readability(a) <= readability(b) + 0.05, "\(scenario.name)")
        if a.boundaries.contains(where: { Int($0) % 60 != 0 }) { finer += 1 } else { same += 1 }
    }
    #expect(finer > 0 && same > 0)       // finer boundaries are used for some days, hour boundaries are enough for others
}

// MARK: Weights

@Test func dayWeightsScalePreferencesButNeverThePresenceOfAnEvent() {
    let scenario = F.stabilizationRuns[2]
    var base = parameters(); base.allocation = scenario.parameters
    let profiles = window(scenario).days.map { TemporalDemandProfile.make($0, parameters: base) }
    func claims(_ p: TemporalGridParameters) -> [WeightedTemporalClaim] { TemporalGridPlanner.weightedClaims(profiles: profiles, mainIndex: 1, parameters: p) }
    var equal = base; equal.dayWeights = [1, 1, 1, 1]
    var skewed = base; skewed.dayWeights = [0.05, 1, 0.5, 0.05]
    let presenceBase = claims(base).filter { $0.claim.kind == .presence }.map(\.weight)
    #expect(Set(presenceBase).count == 1)
    #expect(presenceBase == claims(equal).filter { $0.claim.kind == .presence }.map(\.weight))
    #expect(presenceBase == claims(skewed).filter { $0.claim.kind == .presence }.map(\.weight))
    // Preference claims do follow the weights: the main day's identity claims weigh more than a neighbour's.
    let identity = claims(base).filter { $0.claim.kind == .eventIdentity }
    #expect(Set(identity.filter { $0.dayOffset == 0 }.map(\.weight)) == [base.weights.eventIdentity * 1.0])
    #expect(Set(identity.filter { $0.dayOffset == -1 }.map(\.weight)) == [base.weights.eventIdentity * 0.25])
    // A day weight of zero removes the day from the window but still leaves every other day's presence untouched.
    var none = base; none.dayWeights = [0, 1, 0, 0]
    #expect(claims(none).allSatisfy { $0.dayOffset == 0 })
}

@Test func aLongEventAsksForItsEdgesAndNotForItsWholeLength() {
    let day = F.day(3, events: [F.hours(9, 18)])
    let profile = TemporalDemandProfile.make(day, parameters: parameters())
    let kinds = profile.claims.map(\.kind)
    #expect(kinds.filter { $0 == .longEventEdge }.count == 2)
    #expect(!kinds.contains(.eventIdentity))
    let edges = profile.claims.filter { $0.kind == .longEventEdge }
    #expect(edges.allSatisfy { $0.end - $0.start == 30 })
    #expect(edges.map(\.start).sorted() == [540, 1050])
    // A short event is identified as a whole.
    let short = TemporalDemandProfile.make(F.day(3, events: [(600, 630)]), parameters: parameters())
    #expect(short.claims.map(\.kind).contains(.eventIdentity))
    #expect(!short.claims.map(\.kind).contains(.longEventEdge))
    // An empty stretch asks for nothing.
    #expect(TemporalDemandProfile.make(F.day(3), parameters: parameters()).claims.isEmpty)
}

// MARK: Resolution goes where the information is

@Test func aPartitionPutsMoreResolutionWhereTheMainDayIsBusyThanAUniformOneDoes() {
    for scenario in [F.stabilizationRuns[1], F.gridRuns[3], F.gridRuns[5], F.stabilizationRuns[4]] {
        let result = plan(scenario)
        let uniform = TemporalGridPartition.uniform(slotCount: 12, totalHeight: 640)
        let mainDay = scenario.days[3]
        let entities = GridDayEntities.make(mainDay)
        let metrics = EventPresentation.Metrics.standard()
        let planned = GridPlacement.place(entities, partition: result.partition, metrics: metrics, transactionPitch: 26)
        let even = GridPlacement.place(entities, partition: uniform, metrics: metrics, transactionPitch: 26)
        #expect(planned.titlesShown >= even.titlesShown, "\(scenario.name)")
        #expect(planned.transactionTextShown >= even.transactionTextShown, "\(scenario.name)")
    }
}

@Test func theLongestCellsAreTheQuietOnesAndTheShortestAreWhereTheMainDayIsBusy() {
    let result = plan(F.gridRuns[3])                                   // 15 minute events 9:00-11:00 on the main day
    let partition = result.partition
    let busySlots = (0..<partition.slotCount).filter { partition.start(ofSlot: $0) < 660 && partition.end(ofSlot: $0) > 540 }
    let quietSlots = (0..<partition.slotCount).filter { partition.end(ofSlot: $0) <= 360 }
    let busyAverage = busySlots.map { partition.minutes(inSlot: $0) }.reduce(0, +) / Double(busySlots.count)
    let quietAverage = quietSlots.map { partition.minutes(inSlot: $0) }.reduce(0, +) / Double(max(1, quietSlots.count))
    #expect(busyAverage < quietAverage)
}

@Test func aLongEventDoesNotGetResolutionJustForBeingLong() {
    let day = F.day(3, events: [F.hours(9, 18)], titles: ["하루"])
    let days = (0..<9).map { $0 == 3 ? day : F.day($0) }
    let partition = TemporalGridPlanner.plan(window: TemporalWindow(days: Array(days[2...5]), mainIndex: 1), parameters: parameters()).partition
    // Boundaries inside the event's middle are not needed: most of its length is covered by long cells.
    let inside = (0..<partition.slotCount).filter { partition.start(ofSlot: $0) >= 600 && partition.end(ofSlot: $0) <= 1020 }
    let insideMinutes = inside.map { partition.minutes(inSlot: $0) }.reduce(0, +)
    #expect(insideMinutes >= 240 || inside.count <= 4)
    // And the event still is a tall card.
    let placed = GridPlacement.place(GridDayEntities.make(day), partition: partition, metrics: .standard(), transactionPitch: 26)
    #expect(placed.events[0].presentation.level >= .low)
}

@Test func busyOnDifferentDaysAtDifferentTimesBothGetResolution() {
    let scenario = F.gridRuns[5]                                        // even days busy in the morning, odd days in the afternoon
    let partition = plan(scenario, main: 4).partition                   // main day 4 (mornings), secondary day 5 (afternoons)
    func shortCells(_ range: Range<Int>) -> Int { (0..<partition.slotCount).filter { partition.start(ofSlot: $0) >= Double(range.lowerBound) && partition.end(ofSlot: $0) <= Double(range.upperBound) && partition.minutes(inSlot: $0) <= 90 }.count }
    #expect(shortCells(480..<720) >= 2)
    #expect(shortCells(900..<1200) >= 2)
}

// MARK: Zoom does not replan

@Test func zoomingNeverPlansAgain() {
    let store = TemporalGridStore()
    let scenario = F.stabilizationRuns[2]
    var p = parameters(); p.allocation = scenario.parameters
    let base = store.plan(window: window(scenario), parameters: p).partition
    store.resetCounters()
    for zoom in stride(from: 1.0, through: 3.0, by: 0.25) {
        let zoomed = base.zoomed(viewportHeight: 640, zoomScale: CGFloat(zoom))
        #expect(zoomed.boundaries == base.boundaries)
        #expect(zoomed.totalHeight == 640 * CGFloat(zoom))
    }
    #expect(store.planRuns == 0 && store.profileBuilds == 0)
}

// MARK: The existing engine on the adapter axis

@Test func theEngineLaysOutOnTheGridAxisAsItIsAndEveryTransactionStaysReachable() {
    for scenario in [F.stabilizationRuns[2], F.gridRuns[3], F.gridRuns[6]] {
        let result = plan(scenario)
        let adapted = result.partition.timelineAxis()
        #expect(adapted.isExact)
        var input = AllocationInput(
            main: scenario.days[3], secondary: scenario.days[4], viewportHeight: scenario.viewportHeight, contentWidth: scenario.contentWidth,
            textScale: scenario.textScale, parameters: scenario.parameters
        )
        input.fixedAxis = adapted.axis
        let layout = AdaptiveLayoutEngine.layout(input)
        #expect(layout.axis == adapted.axis)
        #expect(abs(layout.contentHeight - scenario.viewportHeight) < 1e-6)
        // Independent transactions are lines or members of an overflow: none is dropped.
        let independent = Set(scenario.days[3].transactions.map(\.id))
        #expect(independent.isSubset(of: layout.reachableTransactionIDs))
        #expect(layout.events.filter { $0.key.role == .main }.count == scenario.days[3].events.count)
    }
}
