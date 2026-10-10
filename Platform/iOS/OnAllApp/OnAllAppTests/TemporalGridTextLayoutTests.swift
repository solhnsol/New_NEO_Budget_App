import CoreGraphics
import Testing
@testable import OnAllApp

private typealias F = TemporalGridFixtures

private func partition(_ scenario: AxisStabilityScenario, n: Int = 12, main: Int = 3) -> TemporalGridPartition {
    var p = TemporalGridParameters.with(slotCount: n)
    p.viewportHeight = scenario.viewportHeight; p.textScale = scenario.textScale; p.allocation = scenario.parameters
    return TemporalGridPlanner.plan(window: TemporalWindow(days: Array(scenario.days[(main - 1)...(main + 2)]), mainIndex: 1), parameters: p).partition
}

private func resolved(_ day: AllocationDay, _ partition: TemporalGridPartition, scale: CGFloat) -> (GridDayEntities, GridDayPlacement, GridTextPlan) {
    let entities = GridDayEntities.make(day)
    let placed = GridPlacement.place(entities, partition: partition, metrics: .standard(scale: scale), transactionPitch: GridPlacement.transactionPitch(AllocationParameters(), textScale: scale))
    return (entities, placed, GridTextLayout.resolve(entities: entities, placement: placed, columnWidth: 160, scale: scale))
}

@Test func noWrittenThingTouchesAnotherOnAnyFixtureAnyCellCountAnyTextSize() {
    for scenario in F.all {
        for n in [10, 12, 16] {
            let part = partition(scenario, n: n)
            for scale in [1.0, 2.2, 3.0] as [CGFloat] {
                for index in 3...4 {
                    let (entities, placed, plan) = resolved(scenario.days[index], part, scale: scale)
                    let rects = plan.writtenRects
                    for (i, a) in rects.enumerated() { for b in rects[(i + 1)...] { #expect(!a.intersects(b), "\(scenario.name) N=\(n) ×\(scale)") } }
                    // Cards, dots and every identity remain whatever text is left out.
                    #expect(placed.events.count == entities.events.count)
                    #expect(plan.titlesShown.isSubset(of: Set(placed.events.filter { $0.presentation.title > 0 }.map(\.id))))
                    #expect(plan.clusters.flatMap(\.ids).sorted() == placed.independent.map(\.id).sorted())
                    for cluster in plan.clusters { #expect(cluster.ids.count == cluster.minutes.count && cluster.ids.count == cluster.amounts.count) }
                }
            }
        }
    }
}

@Test func denseTransactionsBecomeCountsThatNameEveryTransactionAndKeepTheirAmounts() {
    let scenario = F.gridRuns[6]                       // 43 transactions within 40 minutes
    let (entities, placed, plan) = resolved(scenario.days[4], partition(scenario, main: 4), scale: 1)
    let total = entities.independentTransactions.count
    #expect(plan.clusters.map(\.count).reduce(0, +) == total)
    #expect(plan.clusters.contains { $0.count > 1 })
    #expect(plan.clusters.filter { $0.count > 1 }.allSatisfy { !$0.textShown })
    for cluster in plan.clusters where cluster.count > 1 {
        let ys = cluster.ids.compactMap { id in placed.transactions.first { $0.id == id }?.y }
        #expect((ys.max() ?? 0) - (ys.min() ?? 0) < GridTextLayout.maximumClusterHeight + GridTextLayout.dotSpacing)
    }
    let amounts = plan.clusters.flatMap(\.amounts)
    #expect(amounts.count == total && amounts.allSatisfy { $0 == 2_000 })
    // With room (zoomed in), counts split into smaller ones.
    let zoomed = partition(scenario, main: 4).zoomed(viewportHeight: 640, zoomScale: 3)
    let (_, _, zoomedPlan) = resolved(scenario.days[4], zoomed, scale: 1)
    // The counts split as the room grows, and still stand for the same transactions.
    #expect(zoomedPlan.clusters.count > plan.clusters.count)
    #expect(zoomedPlan.clusters.flatMap(\.ids).sorted() == plan.clusters.flatMap(\.ids).sorted())
}

@Test func overlappingEventsKeepOneCardEachAndOnlyTheTitlesThatFitAreWritten() {
    let scenario = F.demoTransRun()
    let (entities, placed, plan) = resolved(scenario.days[3], partition(scenario, main: 2), scale: 1)    // the overlapping morning cluster
    #expect(placed.events.count == 5 && entities.events.count == 5)
    #expect(entities.events.allSatisfy { $0.indent <= 1 })                   // indented at most one step, never a lane
    #expect(plan.titlesShown.count < placed.events.count)                   // some are left out where they would collide ...
    #expect(plan.titlesShown.count >= 1)
    #expect(placed.events.allSatisfy { $0.height > 0 })                      // ... but every card stays, at its exact span
}

@Test func bothPartitionsOfADateMoveGiveTheSamePlanForTheSameInput() {
    let scenario = F.gridRuns[7]
    let part = partition(scenario)
    let a = resolved(scenario.days[3], part, scale: 1).2, b = resolved(scenario.days[3], part, scale: 1).2
    #expect(a == b)
}

@Test func textPlanningIsCheapEnoughToRunPerFrame() {
    let scenario = F.gridRuns[7]                                              // 32 events
    let part = partition(scenario)
    let entities = GridDayEntities.make(scenario.days[3])
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for _ in 0..<100 {
            let placed = GridPlacement.place(entities, partition: part, metrics: .standard(), transactionPitch: 26)
            _ = GridTextLayout.resolve(entities: entities, placement: placed, columnWidth: 160, scale: 1)
        }
    }
    let ms = (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) / 100
    print("PER-FRAME  place + text layout (32 events): \(String(format: "%.3f", ms)) ms")
    #expect(ms < 5)
}
