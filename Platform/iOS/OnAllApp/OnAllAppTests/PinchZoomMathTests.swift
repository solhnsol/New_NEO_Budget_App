import CoreGraphics
import Testing
@testable import OnAllApp

private typealias F = TemporalGridFixtures
private typealias M = PinchZoomMath

private func hourly(_ scenario: AxisStabilityScenario, n: Int = 12, main: Int = 3) -> TemporalGridPartition {
    var p = TemporalGridParameters.hourly(slotCount: n)
    p.viewportHeight = scenario.viewportHeight; p.textScale = scenario.textScale; p.allocation = scenario.parameters
    return TemporalGridPlanner.plan(window: TemporalWindow(days: Array(scenario.days[(main - 1)...(main + 2)]), mainIndex: 1), parameters: p).partition
}

/// A fixed pseudo-random sequence (no clock): the same every run.
private struct Sequence {
    var state: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

@Test func theRubberBandIsTheIdentityInsideTheRangeAndSaturatesOutsideIt() {
    for z in stride(from: 1.0, through: 8.0, by: 0.25) { #expect(M.rubberBanded(CGFloat(z)) == CGFloat(z)) }
    var previous: CGFloat = -1
    for raw in stride(from: 0.1, through: 40.0, by: 0.01) {
        let shown = M.rubberBanded(CGFloat(raw))
        #expect(shown >= previous)                                              // monotone: reversing a pinch reverses the zoom at once
        previous = shown
        #expect(shown < 8 + M.upperStretch + 1e-9 && shown > 1 - M.lowerStretch - 1e-9)
    }
    // Continuous at both ends with the slope of the fingers there, then it gives way.
    #expect(abs(M.rubberBanded(8.0001) - 8.0001) < 1e-3 && abs(M.rubberBanded(0.9999) - 0.9999) < 1e-3)
    #expect(M.rubberBanded(8.3) < 8.3 && M.rubberBanded(0.8) > 0.8)
    // Letting go comes back inside the range.
    #expect(M.clamped(8.4) == 8 && M.clamped(0.9) == 1 && M.clamped(3) == 3)
}

@Test func atOneTimesTheWholeDayFitsTheViewportAndThereIsNothingToScroll() {
    let partition = hourly(F.stabilizationRuns[2]).zoomed(viewportHeight: 640, zoomScale: 1)
    #expect(partition.totalHeight == 640)
    #expect(M.offsetRange(zoom: 1, viewport: 640) == 0...0)
    #expect(M.offsetRange(zoom: 8, viewport: 640) == 0...(640 * 7))
    #expect(M.clampedOffset(300, zoom: 1, viewport: 640) == 0)
}

@Test func theTimeUnderTheFingersStaysUnderTheFingersThroughAnyPinchSequence() {
    let base = hourly(F.stabilizationRuns[2])
    let viewport: CGFloat = 640
    var random = Sequence()
    var unclampedSteps = 0, clampedSteps = 0
    var worstMinutes = 0.0
    for _ in 0..<300 {
        // A scroll state, a pinch with a start centre, a scale path that goes out and back, and a centre that moves.
        let startZoom = CGFloat(1 + random.next() * 6)
        let offset = M.clampedOffset(CGFloat(random.next()) * viewport * startZoom, zoom: startZoom, viewport: viewport)
        var focal = CGFloat(random.next()) * viewport
        let start = base.zoomed(viewportHeight: viewport, zoomScale: startZoom)
        let anchorTime = start.yToTime(offset + focal)
        let fraction = M.anchorFraction(offset: offset, focal: focal, zoom: startZoom, viewport: viewport)
        for step in 0..<20 {
            let scale = CGFloat(exp((random.next() - 0.5) * 3))                    // 0.22 ... 4.5
            focal = min(max(focal + CGFloat(random.next() - 0.5) * 30, 0), viewport)  // the centre drifts: a pan
            let now = M.step(startZoom: startZoom, scale: scale, fraction: fraction, focal: focal, viewport: viewport)
            let shown = base.zoomed(viewportHeight: viewport, zoomScale: now.zoom)
            let wanted = M.offset(keepingFraction: fraction, atFocal: focal, zoom: now.zoom, viewport: viewport)
            #expect(now.offset >= 0 && now.offset <= max(0, viewport * now.zoom - viewport))
            if abs(wanted - now.offset) < 1e-9 {
                unclampedSteps += 1
                let error = abs(shown.yToTime(now.offset + focal) - anchorTime)
                worstMinutes = max(worstMinutes, error)
                #expect(error < 1e-6, "step \(step)")
            } else {
                clampedSteps += 1       // the grid has no more room on that side: the time cannot stay put, and the offset stops at the end
            }
        }
    }
    #expect(unclampedSteps > 1000 && clampedSteps > 0)
    #expect(worstMinutes < 1e-6)
}

@Test func aPinchAtTheEdgesOfTheScreenAndOfTheDayStaysInsideTheGrid() {
    let viewport: CGFloat = 640
    for focal in [0, 1, 320, 639, 640] as [CGFloat] {
        for fraction in [0, 0.001, 0.5, 0.999, 1] as [CGFloat] {
            for scale in [0.2, 0.9, 1, 2, 7, 30] as [CGFloat] {
                let now = M.step(startZoom: 1, scale: scale, fraction: fraction, focal: focal, viewport: viewport)
                #expect(now.offset >= 0 && now.offset <= max(0, viewport * now.zoom - viewport) + 1e-9)
                #expect(now.zoom >= 1 - M.lowerStretch && now.zoom <= 8 + M.upperStretch)
            }
        }
    }
}

@Test func lettingGoBetweenTheStretchAndTheEndKeepsTheSameTimeWhereverTheGridAllows() {
    let viewport: CGFloat = 640
    let fraction: CGFloat = 0.5, focal: CGFloat = 320
    let rest = M.rest(zoom: 8.4, fraction: fraction, focal: focal, viewport: viewport)
    #expect(rest.zoom == 8)
    #expect(abs(M.anchorFraction(offset: rest.offset, focal: focal, zoom: 8, viewport: viewport) - fraction) < 1e-9)
    let low = M.rest(zoom: 0.9, fraction: fraction, focal: focal, viewport: viewport)
    #expect(low.zoom == 1 && low.offset == 0)
    // The slider's zoom keeps the time under the middle of the screen.
    let after = M.offsetAfterZoom(from: 2, to: 5, offset: 200, focal: 320, viewport: viewport)
    #expect(abs(M.anchorFraction(offset: after, focal: 320, zoom: 5, viewport: viewport) - M.anchorFraction(offset: 200, focal: 320, zoom: 2, viewport: viewport)) < 1e-9)
}

@Test func timeCoordinatesStayExactAtEveryZoomUpToEight() {
    let base = hourly(F.stabilizationRuns[2])
    for zoom in stride(from: 1.0, through: 8.0, by: 0.37) {
        let shown = base.zoomed(viewportHeight: 640, zoomScale: CGFloat(zoom))
        #expect(shown.boundaries == base.boundaries)
        for hour in 0...24 { #expect(abs(shown.timeToY(Double(hour * 60)) - base.timeToY(Double(hour * 60)) * CGFloat(zoom)) < 1e-9) }
        for minute in stride(from: 0.0, through: 1440.0, by: 13.7) { #expect(abs(shown.yToTime(shown.timeToY(minute)) - minute) < 1e-9) }
    }
}

@Test func theBuiltWindowAlwaysCoversTheScreenWithAViewportToSpare() {
    let viewport: CGFloat = 573
    for offset in stride(from: 0.0, through: 573.0 * 7, by: 7.3) {
        let band = M.visibleBand(offset: CGFloat(offset), viewport: viewport)
        let window = M.buildWindow(band: band, viewport: viewport)
        #expect(window.lowerBound <= CGFloat(offset) - viewport * 0.5 + 1e-6)
        #expect(window.upperBound >= CGFloat(offset) + viewport * 1.5 - 1e-6)
    }
}

@Test func noWrittenThingTouchesAnotherAtAnyZoomUpToEight() {
    for scenario in [F.gridRuns[3], F.gridRuns[7], F.gridRuns[8], F.gridRuns[6]] {
        let base = hourly(scenario, main: scenario.name.hasPrefix("17") ? 4 : 3)
        let ticks = HourTickPlan.make(partition: base)
        for scale in [1.0, 3.0] as [CGFloat] {
            for step in 0...35 {
                let zoom = CGFloat(1 + Double(step) * 0.2)
                let shown = base.zoomed(viewportHeight: scenario.viewportHeight, zoomScale: zoom)
                let day = scenario.days[scenario.name.hasPrefix("17") ? 4 : 3]
                let entities = GridDayEntities.make(day)
                let placed = GridPlacement.place(entities, partition: shown, metrics: .standard(scale: scale), transactionPitch: GridPlacement.transactionPitch(AllocationParameters(), textScale: scale))
                let plan = GridTextLayout.resolve(entities: entities, placement: placed, columnWidth: 160, scale: scale)
                for (i, a) in plan.writtenRects.enumerated() { for b in plan.writtenRects[(i + 1)...] { #expect(!a.intersects(b), "\(scenario.name) zoom \(zoom) ×\(scale)") } }
                #expect(plan.clusters.flatMap(\.ids).sorted() == placed.independent.map(\.id).sorted())
                let centres = ticks.labelled(zoom: Double(zoom)).map { ticks.centre(hour: $0, y: base.timeToY(Double($0 * 60)), totalHeight: base.totalHeight, zoom: Double(zoom)) }.sorted()
                for (a, b) in zip(centres, centres.dropFirst()) { #expect(b - a >= ticks.minimumGap - 1e-6) }
            }
        }
    }
}

@Test func aPinchFrameDoesNoPlanningAndCostsLittle() {
    let scenario = F.gridRuns[7]                                                  // 32 events
    let store = TemporalGridStore()
    var p = TemporalGridParameters.hourly(slotCount: 12)
    p.viewportHeight = scenario.viewportHeight; p.allocation = scenario.parameters
    let base = store.plan(window: TemporalWindow(days: Array(scenario.days[2...5]), mainIndex: 1), parameters: p).partition
    let entities = [3, 4, 5].map { GridDayEntities.make(scenario.days[$0]) }
    let ticks = HourTickPlan.make(partition: base)
    store.resetCounters()
    let clock = ContinuousClock()
    var worst = 0.0, total = 0.0
    let frames = 240
    for frame in 0..<frames {
        let zoom = CGFloat(1 + 7 * (0.5 - 0.5 * cos(Double(frame) / Double(frames) * 2 * Double.pi)))   // 1 → 8 → 1
        let elapsed = clock.measure {
            let shown = base.zoomed(viewportHeight: 640, zoomScale: zoom)
            for entity in entities {
                let placed = GridPlacement.place(entity, partition: shown, metrics: .standard(), transactionPitch: 26)
                _ = GridTextLayout.resolve(entities: entity, placement: placed, columnWidth: 160, scale: 1)
            }
            for hour in 0...24 { _ = ticks.opacity(hour: hour, zoom: Double(zoom)) }
        }
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        worst = max(worst, ms); total += ms
    }
    print("PINCH  per frame (3 columns × 32 events + ticks): mean \(String(format: "%.3f", total / Double(frames))) ms, worst \(String(format: "%.3f", worst)) ms over \(frames) frames; plans \(store.planRuns), profiles \(store.profileBuilds)")
    #expect(store.planRuns == 0 && store.profileBuilds == 0)
    #expect(total / Double(frames) < 4)         // a 120 Hz frame is 8.3 ms; this is the model's share, in a Debug build
}
