import CoreGraphics
import Testing
@testable import OnAllApp

private typealias F = TemporalGridFixtures

private func hourly(_ scenario: AxisStabilityScenario, n: Int = 12, main: Int = 3) -> TemporalGridPartition {
    var p = TemporalGridParameters.hourly(slotCount: n)
    p.viewportHeight = scenario.viewportHeight; p.textScale = scenario.textScale; p.allocation = scenario.parameters
    return TemporalGridPlanner.plan(window: TemporalWindow(days: Array(scenario.days[(main - 1)...(main + 2)]), mainIndex: 1), parameters: p).partition
}

private let scenarios: [AxisStabilityScenario] = [F.stabilizationRuns[2], F.gridRuns[3], F.gridRuns[7], F.gridRuns[8], F.demoTransRun()]

@Test func theImportanceOrderCoversEveryHourOnceAndStartsWithTheEnds() {
    #expect(HourAxis.importance.count == 25 && Set(HourAxis.importance) == Set(0...24))
    #expect(Array(HourAxis.importance.prefix(4)) == [0, 24, 12, 6])
}

@Test func everyTickIsAtTheRealYOfItsHourAndLabelsFollowIt() {
    for scenario in scenarios {
        let base = hourly(scenario)
        for zoom in [1.0, 2.3, 8.0] as [CGFloat] {
            let shown = base.zoomed(viewportHeight: scenario.viewportHeight, zoomScale: zoom)
            let metrics = HourAxis.Metrics()
            let states = HourAxis.layout(partition: shown, metrics: metrics)
            #expect(states.count == 25)
            for state in states {
                #expect(state.y == shown.timeToY(Double(state.hour * 60)))                 // exactly the coordinate map's
                #expect(abs(shown.yToTime(state.y) - Double(state.hour * 60)) < 1e-9)
                if state.hour != 0 && state.hour != 24 { #expect(state.labelCentre == state.y) }
                #expect(state.labelOpacity <= state.tickOpacity + 1e-12)
                #expect(state.tickOpacity >= 0 && state.tickOpacity <= 1)
            }
            #expect(states.first?.labelCentre == metrics.labelHeight / 2)
            #expect(states.last?.labelCentre == shown.totalHeight - metrics.labelHeight / 2)
        }
    }
}

@Test func noTwoLabelsAndNoTwoTicksThatAreBothThereTouchAtAnyZoomOrTextSize() {
    for scenario in scenarios {
        for n in [10, 12, 16] {
            let base = hourly(scenario, n: n)
            for scale in [1.0, 2.2, 3.0] as [CGFloat] {
                let metrics = HourAxis.Metrics(textScale: scale)
                for step in 0...70 {
                    let shown = base.zoomed(viewportHeight: scenario.viewportHeight, zoomScale: CGFloat(1 + Double(step) * 0.1))
                    let states = HourAxis.layout(partition: shown, metrics: metrics)
                    for (i, a) in states.enumerated() {
                        for b in states[(i + 1)...] {
                            // The less important of two hours that are closer than the gap has no opacity at all.
                            if a.labelOpacity > 0 && b.labelOpacity > 0 { #expect(abs(a.labelCentre - b.labelCentre) > metrics.labelGap, "\(scenario.name) N=\(n) step \(step)") }
                            if a.tickOpacity > 0 && b.tickOpacity > 0 { #expect(abs(a.y - b.y) > metrics.tickGap) }
                        }
                    }
                    // A label that is whole never reaches over an edge of the axis.
                    for state in states where state.labelOpacity > 0.999 {
                        #expect(state.labelCentre - metrics.labelHeight / 2 >= -1e-6 && state.labelCentre + metrics.labelHeight / 2 <= shown.totalHeight + 1e-6)
                    }
                }
            }
        }
    }
}

@Test func zoomingInOnlyEverAddsAndZoomingOutRetracesTheSamePath() {
    for scenario in scenarios {
        let base = hourly(scenario)
        let metrics = HourAxis.Metrics()
        func at(_ zoom: Double) -> [HourAxisState] { HourAxis.layout(partition: base.zoomed(viewportHeight: scenario.viewportHeight, zoomScale: CGFloat(zoom)), metrics: metrics) }
        var previous = at(1)
        var up: [Double: [HourAxisState]] = [1: previous]
        for step in 1...700 {
            let zoom = 1 + Double(step) * 0.01
            let now = at(zoom)
            for (a, b) in zip(previous, now) {
                #expect(b.tickOpacity >= a.tickOpacity - 1e-12 && b.labelOpacity >= a.labelOpacity - 1e-12, "\(scenario.name) hour \(a.hour) zoom \(zoom)")   // never takes away while zooming in
            }
            previous = now
            if step % 50 == 0 { up[zoom] = now }
        }
        // Going back down passes through exactly the states it came up through (the opacities are a function of the space now, not of the path).
        for zoom in stride(from: 8.0, through: 1.0, by: -0.5) {
            let key = up.keys.min { abs($0 - zoom) < abs($1 - zoom) }!
            if abs(key - zoom) < 1e-9 { #expect(at(zoom) == up[key]) }
        }
    }
}

@Test func opacityChangesContinuouslyWithTheZoomAndWithTheDayMove() {
    for scenario in scenarios {
        let a = hourly(scenario, main: 1), b = hourly(scenario, main: 4)       // two windows that differ as much as the fixtures allow
        let metrics = HourAxis.Metrics()
        // Zoom in steps of 1%: no label or tick changes by more than a small amount per step (the ramps are several points long).
        var previous: [HourAxisState]?
        var worstZoom = 0.0
        for step in 0...700 {
            let states = HourAxis.layout(partition: a.zoomed(viewportHeight: scenario.viewportHeight, zoomScale: CGFloat(1 + Double(step) * 0.01)), metrics: metrics)
            if let previous { for (x, y) in zip(previous, states) { worstZoom = max(worstZoom, abs(x.labelOpacity - y.labelOpacity), abs(x.tickOpacity - y.tickOpacity)) } }
            previous = states
        }
        print("AXIS  \(scenario.name): largest opacity change per 1% zoom \(String(format: "%.3f", worstZoom))")
        #expect(worstZoom < 0.45, "\(scenario.name) zoom \(worstZoom)")
        // Between the two days in 1% steps, at 1x and at 3x, forwards and then backwards: continuous, and the backwards pass retraces the forwards one.
        for zoom in [1.0, 3.0] as [CGFloat] {
            var forward: [[HourAxisState]] = []
            for step in 0...100 {
                let blend = TemporalGridPartition.interpolated(from: a, to: b, progress: Double(step) / 100)!.zoomed(viewportHeight: scenario.viewportHeight, zoomScale: zoom)
                forward.append(HourAxis.layout(partition: blend, metrics: metrics))
            }
            var worst = 0.0
            for (x, y) in zip(forward, forward.dropFirst()) {
                for (s, t) in zip(x, y) {
                    worst = max(worst, abs(s.labelOpacity - t.labelOpacity), abs(s.tickOpacity - t.tickOpacity))
                    #expect(abs(s.y - t.y) < 12 * zoom)            // a tick moves a bounded distance per 1% of the move: no position jump
                }
            }
            print("AXIS  \(scenario.name): largest opacity change per 1% of the day move at \(zoom)x \(String(format: "%.3f", worst))")
            #expect(worst < 0.45, "\(scenario.name) day move zoom \(zoom): \(worst)")
            for step in stride(from: 100, through: 0, by: -1) {
                let blend = TemporalGridPartition.interpolated(from: a, to: b, progress: Double(step) / 100)!.zoomed(viewportHeight: scenario.viewportHeight, zoomScale: zoom)
                #expect(HourAxis.layout(partition: blend, metrics: metrics) == forward[step])
            }
        }
    }
}

@Test func atTheAxisEdgesTheFirstAndLastLabelsStayAndOthersFadeBeforeBeingCut() {
    let base = hourly(F.gridRuns[7], n: 16)
    let metrics = HourAxis.Metrics()
    let states = HourAxis.layout(partition: base, metrics: metrics)
    let first = states[0], last = states[24]
    #expect(first.labelOpacity > 0 && last.labelOpacity > 0)
    for state in states where state.hour != 0 && state.hour != 24 {
        if state.y < metrics.labelHeight / 2 { #expect(state.labelOpacity < 1) }
        if base.totalHeight - state.y < metrics.labelHeight / 2 { #expect(state.labelOpacity < 1) }
    }
}

@Test func largerTextWritesFewerLabelsNeverOverlappingOnes() {
    let base = hourly(F.stabilizationRuns[2])
    func count(_ scale: CGFloat) -> Int { HourAxis.layout(partition: base, metrics: HourAxis.Metrics(textScale: scale)).filter { $0.labelOpacity > 0.5 }.count }
    #expect(count(1.0) >= count(1.4))
    #expect(HourAxis.Metrics(textScale: 3).labelHeight == HourAxis.Metrics(textScale: 1.4).labelHeight)       // the axis column is a fixed width: the label size stops growing
}

@Test func laidOutPerFrameWithoutPlanning() {
    let scenario = F.gridRuns[7]
    let base = hourly(scenario)
    let metrics = HourAxis.Metrics()
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for frame in 0..<500 { _ = HourAxis.layout(partition: base.zoomed(viewportHeight: 640, zoomScale: CGFloat(1 + 7 * Double(frame) / 500)), metrics: metrics) }
    }
    let ms = (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) / 500
    print("AXIS  tick layout per frame: \(String(format: "%.4f", ms)) ms (25 ticks, Debug)")
    #expect(ms < 1)
}
