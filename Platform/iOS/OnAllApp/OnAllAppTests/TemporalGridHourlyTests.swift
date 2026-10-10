import CoreGraphics
import Testing
@testable import OnAllApp

private typealias F = TemporalGridFixtures

private func hourly(_ scenario: AxisStabilityScenario, n: Int, main: Int = 3) -> TemporalGridPlan {
    var p = TemporalGridParameters.hourly(slotCount: n)
    p.viewportHeight = scenario.viewportHeight; p.textScale = scenario.textScale; p.allocation = scenario.parameters
    return TemporalGridPlanner.plan(window: TemporalWindow(days: Array(scenario.days[(main - 1)...(main + 2)]), mainIndex: 1), parameters: p)
}

@Test func hourOnlyPartitionsHaveWholeHourBoundariesAndNoCellUnderAnHour() {
    for scenario in F.all {
        for n in [10, 12, 16] {
            let result = hourly(scenario, n: n)
            let partition = result.partition
            #expect(partition.slotCount == n, "\(scenario.name) N=\(n)")
            #expect(!result.constraintsRelaxed)
            #expect(partition.boundaries.allSatisfy { $0.truncatingRemainder(dividingBy: 60) == 0 }, "\(scenario.name) N=\(n)")
            for slot in 0..<n {
                #expect(partition.minutes(inSlot: slot) >= 60)         // in particular never under 30 minutes
                #expect(partition.minutes(inSlot: slot) <= 480)
                #expect(abs(partition.top(ofSlot: slot + 1) - partition.top(ofSlot: slot) - scenario.viewportHeight / CGFloat(n)) < 1e-9)
            }
            #expect(partition.totalHeight == scenario.viewportHeight)
        }
    }
}

@Test func denseShortEventsDoNotSplitAnHourCell() {
    let scenario = F.gridRuns[3]                                       // 15 minute events in a row
    for n in [10, 12, 16] {
        let partition = hourly(scenario, n: n).partition
        for slot in 0..<n { #expect(partition.minutes(inSlot: slot) >= 60) }
    }
}

@Test func theSamePartitionIsPlannedWhateverWasPlannedBefore() {
    let a = hourly(F.stabilizationRuns[2], n: 12).partition
    _ = hourly(F.gridRuns[7], n: 16)
    #expect(hourly(F.stabilizationRuns[2], n: 12).partition == a)
}
