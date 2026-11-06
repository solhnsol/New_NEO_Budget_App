import CoreGraphics
import Foundation

/// The three ways of drawing time that are compared on the same days, the same viewport and the same measuring: the engine's two-day axis,
/// the four-day stabilized axis, and the fixed-cell temporal grid. What is written on an event or a transaction is judged by the same
/// `GridPlacement` for all three (height alone, via `EventPresentation`), so the comparison is about the axis and nothing else.
enum GridMethod: Hashable, Sendable {
    case twoDay
    case fourDay
    case temporal(slotCount: Int)

    var name: String {
        switch self {
        case .twoDay: return "2일(기존)"
        case .fourDay: return "4일"
        case .temporal(let n): return "격자 N=\(n)"
        }
    }
}

struct GridWindowSample {
    let main: Int
    let totalHeight: CGFloat
    /// The y of every quarter hour (97 values from 00:00 to 24:00).
    let samples: [CGFloat]
    let boundaries: [Double]?
    let mainPlacement: GridDayPlacement
    let secondaryPlacement: GridDayPlacement
    let mainEntities: GridDayEntities
}

struct GridMethodReport {
    let method: GridMethod
    var windows: [GridWindowSample] = []
    /// Time to plan and place all windows, in seconds, from nothing remembered.
    var seconds = 0.0
    var cacheEntries = 0
    var cacheBytes = 0

    var heights: [CGFloat] { windows.map(\.totalHeight) }
    var meanHeight: CGFloat { mean(heights) }
    var maxHeight: CGFloat { heights.max() ?? 0 }
    var heightRange: CGFloat { (heights.max() ?? 0) - (heights.min() ?? 0) }

    var transitions: [(maxShift: CGFloat, meanShift: CGFloat, boundaryMax: Double, boundaryMean: Double)] {
        zip(windows, windows.dropFirst()).map { a, b in
            let shifts = zip(a.samples, b.samples).map { abs($0 - $1) }
            var boundaryMax = 0.0, boundaryMean = 0.0
            if let x = a.boundaries, let y = b.boundaries {
                let deltas = zip(x, y).map { abs($0 - $1) }
                boundaryMax = deltas.max() ?? 0
                boundaryMean = deltas.reduce(0, +) / Double(max(1, deltas.count))
            }
            return (shifts.max() ?? 0, mean(shifts), boundaryMax, boundaryMean)
        }
    }
    var maxYShift: CGFloat { transitions.map(\.maxShift).max() ?? 0 }
    var meanYShift: CGFloat { mean(transitions.map(\.meanShift)) }
    var maxBoundaryShift: Double { transitions.map(\.boundaryMax).max() ?? 0 }
    var meanBoundaryShift: Double { let v = transitions.map(\.boundaryMean); return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

    /// Per window means over the main day.
    var mainEvents: Double { avg(windows.map { Double($0.mainPlacement.events.count) }) }
    var mainTitlesShown: Double { avg(windows.map { Double($0.mainPlacement.titlesShown) }) }
    var mainLinesOnly: Double { avg(windows.map { Double($0.mainPlacement.linesOnly) }) }
    var mainSlivers: Double { avg(windows.map { Double($0.mainPlacement.slivers) }) }
    var mainIndependentTransactions: Double { avg(windows.map { Double($0.mainPlacement.independent.count) }) }
    var mainTransactionTextShown: Double { avg(windows.map { Double($0.mainPlacement.transactionTextShown) }) }
    var mainHiddenTransactionRatio: Double { avg(windows.map(\.mainPlacement.hiddenTransactionRatio)) }
    /// Every event and every transaction of the main day has a place (a dot or a card at its real time) in every window.
    var accessPreserved: Bool {
        windows.allSatisfy { w in
            Set(w.mainPlacement.events.map(\.id)) == Set(w.mainEntities.events.map(\.id))
                && Set(w.mainPlacement.transactions.map(\.id)) == Set(w.mainEntities.transactions.map(\.id))
        }
    }
    var secondsPerWindow: Double { windows.isEmpty ? 0 : seconds / Double(windows.count) }

    private func mean(_ values: [CGFloat]) -> CGFloat { values.isEmpty ? 0 : values.reduce(0, +) / CGFloat(values.count) }
    private func avg(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
}

enum TemporalGridComparison {
    static let quarterHourSamples = stride(from: 0, through: 24 * 60, by: 15).map { Double($0) }

    static func report(
        _ scenario: AxisStabilityScenario, method: GridMethod, grid base: TemporalGridParameters = .default, store: TemporalGridStore? = nil
    ) -> GridMethodReport {
        var report = GridMethodReport(method: method)
        let metrics = EventPresentation.Metrics.standard(scale: scenario.textScale)
        let pitch = GridPlacement.transactionPitch(scenario.parameters, textScale: scenario.textScale)
        let range = AxisStability.commonRange(scenario)
        let engineCache = AxisDemandCache()
        let theStore = store ?? TemporalGridStore()
        var parameters = base
        parameters.viewportHeight = scenario.viewportHeight
        parameters.textScale = scenario.textScale
        parameters.allocation = scenario.parameters
        if case .temporal(let n) = method { parameters.slotCount = n }

        let clock = ContinuousClock()
        var built: [(main: Int, y: (Double) -> CGFloat, height: CGFloat, boundaries: [Double]?)] = []
        let elapsed = clock.measure {
            for main in range {
                switch method {
                case .twoDay, .fourDay:
                    let window = AxisStability.layoutWindow(scenario, main: main, variant: method == .twoDay ? .engineTwoDay : .fourDay, cache: engineCache)
                    let axis = window.layout.axis
                    built.append((main, { axis.y(minute: Int($0.rounded())) }, axis.height, nil))
                case .temporal:
                    let days = Array(scenario.days[(main - 1)...(main + 2)])
                    let plan = theStore.plan(window: TemporalWindow(days: days, mainIndex: 1), parameters: parameters)
                    let partition = plan.partition
                    built.append((main, { partition.timeToY($0) }, partition.totalHeight, partition.boundaries))
                }
            }
        }
        report.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        for item in built {
            let mainEntities = GridDayEntities.make(scenario.days[item.main])
            let secondaryEntities = GridDayEntities.make(scenario.days[item.main + 1])
            report.windows.append(GridWindowSample(
                main: item.main, totalHeight: item.height, samples: quarterHourSamples.map { item.y($0) }, boundaries: item.boundaries,
                mainPlacement: GridPlacement.place(mainEntities, y: item.y, metrics: metrics, transactionPitch: pitch),
                secondaryPlacement: GridPlacement.place(secondaryEntities, y: item.y, metrics: metrics, transactionPitch: pitch),
                mainEntities: mainEntities
            ))
        }
        if case .temporal = method { report.cacheEntries = theStore.entryCount; report.cacheBytes = theStore.approximateBytes }
        if method == .fourDay { report.cacheEntries = engineCache.count }
        return report
    }
}
