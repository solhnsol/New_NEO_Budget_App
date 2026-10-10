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

// MARK: Ticks

private func plan(_ scenario: AxisStabilityScenario, n: Int = 12) -> (TemporalGridPartition, HourTickPlan) {
    let partition = hourly(scenario, n: n).partition
    return (partition, HourTickPlan.make(partition: partition))
}

@Test func everyHourHasATickAtItsExactY() {
    let (partition, _) = plan(F.gridRuns[3])
    for hour in 0...24 {
        let y = partition.timeToY(Double(hour * 60))
        #expect(abs(partition.yToTime(y) - Double(hour * 60)) < 1e-9)
    }
    #expect(partition.timeToY(0) == 0 && abs(partition.timeToY(1440) - partition.totalHeight) < 1e-9)
    // Zoomed: the same ticks, scaled.
    let zoomed = partition.zoomed(viewportHeight: partition.totalHeight, zoomScale: 2.5)
    for hour in 0...24 { #expect(abs(zoomed.timeToY(Double(hour * 60)) - 2.5 * partition.timeToY(Double(hour * 60))) < 1e-9) }
}

@Test func noTwoWrittenLabelsTouchAtAnyZoomAndZoomingOnlyAddsLabels() {
    for scenario in F.all {
        for n in [10, 12, 16] {
            let (partition, ticks) = plan(scenario, n: n)
            var previous: [Int] = []
            for step in 0...40 {
                let zoom = 1 + Double(step) * 0.05
                let shown = ticks.labelled(zoom: zoom)
                #expect(Set(previous).isSubset(of: Set(shown)), "\(scenario.name) N=\(n) zoom \(zoom)")        // nothing flickers off when zooming in
                previous = shown
                let height = partition.totalHeight * CGFloat(zoom)
                let centres = shown.map { ticks.centre(hour: $0, y: partition.timeToY(Double($0 * 60)), totalHeight: partition.totalHeight, zoom: zoom) }.sorted()
                for (a, b) in zip(centres, centres.dropFirst()) { #expect(b - a >= ticks.minimumGap - 1e-6, "\(scenario.name) N=\(n) zoom \(zoom)") }
                // None is cut off by the axis' edge.
                for centre in centres { #expect(centre >= ticks.labelHeight / 2 - 1e-6 && centre <= height - ticks.labelHeight / 2 + 1e-6, "\(scenario.name) N=\(n) zoom \(zoom)") }
            }
        }
    }
}

@Test func theGridsOwnBoundariesAreLabelledBeforeAnyOtherHour() {
    for scenario in [F.stabilizationRuns[2], F.gridRuns[3], F.gridRuns[7]] {
        let (partition, ticks) = plan(scenario)
        let boundaryHours = Set(partition.boundaries.map { Int($0 / 60) })
        var seenOther = false
        for (index, hour) in ticks.order.enumerated() {
            if boundaryHours.contains(hour) { #expect(!seenOther) } else { seenOther = true }
            if index > 0 { #expect(ticks.requiredZoom[index] >= ticks.requiredZoom[index - 1]) }
        }
        #expect(ticks.order.count == 25 && Set(ticks.order).count == 25)
    }
}

@Test func labelsAppearGraduallyAndAreWholeAfterTheRamp() {
    let (_, ticks) = plan(F.gridRuns[7], n: 16)
    for (index, hour) in ticks.order.enumerated() where ticks.requiredZoom[index] > 1 {
        let z = ticks.requiredZoom[index]
        #expect(ticks.opacity(hour: hour, zoom: z - 0.01) == 0)
        let mid = ticks.opacity(hour: hour, zoom: z + HourTickPlan.rampZoom / 2)
        #expect(mid > 0 && mid < 1)
        #expect(ticks.opacity(hour: hour, zoom: z + HourTickPlan.rampZoom) >= 0.999999)
        // Monotone in zoom both ways: fading in on the way up is fading out on the way down.
        #expect(ticks.opacity(hour: hour, zoom: z + 0.2) >= ticks.opacity(hour: hour, zoom: z + 0.1))
    }
}

@Test func theAdditionsAreSpreadEvenlyOverTheDay() {
    // A short axis (240 pt for 12 equal cells: 20 pt per cell) cannot write every hour; at every zoom the written ones are spread evenly.
    let partition = TemporalGridPartition.uniform(slotCount: 12, totalHeight: 240)
    let ticks = HourTickPlan.make(partition: partition)
    for step in 0...20 {
        let zoom = 1 + Double(step) * 0.1
        let shown = ticks.labelled(zoom: zoom).map { partition.timeToY(Double($0 * 60)) }.sorted()
        let gaps = zip(shown, shown.dropFirst()).map { $1 - $0 }
        guard let largest = gaps.max(), let smallest = gaps.min() else { continue }
        #expect(largest <= 2.01 * smallest + 1e-6, "zoom \(zoom)")
    }
}
