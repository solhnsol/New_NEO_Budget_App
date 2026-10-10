import CoreGraphics
import Testing
@testable import OnAllApp

// Measurements: the engine's two-day axis, the four-day stabilized axis and the fixed-cell temporal grid on the same fixtures, the same viewport
// and the same judge of what is written (`GridPlacement`). Lines starting with "TG|" are the tables in docs/temporal-grid-prototype.md.

private typealias F = TemporalGridFixtures

private func f1(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
private func f1(_ v: Double) -> String { String(format: "%.1f", v) }
private func f2(_ v: Double) -> String { String(format: "%.2f", v) }
private func ms(_ seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }

private let methods: [GridMethod] = [.twoDay, .fourDay, .temporal(slotCount: 12)]

private func row(_ name: String, _ r: GridMethodReport) -> String {
    let grid: String
    if case .temporal = r.method { grid = "\(f1(r.maxBoundaryShift))/\(f1(r.meanBoundaryShift))" } else { grid = "—" }
    return "TG|\(name)|\(r.method.name)|\(f1(r.meanHeight)) (\(f1(r.heightRange)))|\(f1(r.maxYShift))|\(f1(r.meanYShift))|\(grid)|\(f1(r.mainTitlesShown))/\(f1(r.mainEvents))|\(f1(r.mainLinesOnly))|\(f1(r.mainSlivers))|\(f1(r.mainTransactionTextShown))/\(f1(r.mainIndependentTransactions))|\(f2(r.mainHiddenTransactionRatio))|\(r.accessPreserved ? "예" : "아니오")|\(ms(r.secondsPerWindow))"
}

@Test func printTheThreeMethodsOnEveryFixture() {
    print("TG|시나리오|방식|높이 평균(범위)|최대Y이동|평균Y이동|경계이동 최대/평균(분)|제목표시/일정(주날짜)|E0선|E1|거래글자/독립거래|숨김비율|접근보존|계산(ms/창)")
    var totals: [GridMethod: (max: CGFloat, mean: CGFloat, titles: Double, events: Double, lines: Double, tx: Double, txAll: Double, hidden: Double, count: Int, seconds: Double, height: CGFloat)] = [:]
    for scenario in F.all {
        for method in methods {
            let report = TemporalGridComparison.report(scenario, method: method)
            print(row(scenario.name, report))
            var t = totals[method] ?? (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            t.max += report.maxYShift; t.mean += report.meanYShift; t.titles += report.mainTitlesShown; t.events += report.mainEvents
            t.lines += report.mainLinesOnly; t.tx += report.mainTransactionTextShown; t.txAll += report.mainIndependentTransactions
            t.hidden += report.mainHiddenTransactionRatio; t.count += 1; t.seconds += report.secondsPerWindow; t.height += report.meanHeight
            totals[method] = t
            if case .temporal = method {
                #expect(report.windows.allSatisfy { $0.totalHeight == scenario.viewportHeight })
                #expect(report.accessPreserved)
            }
        }
    }
    print("TG|합계|방식|최대Y이동 합|평균Y이동 합|제목표시 합/일정 합|E0선 합|거래글자 합/독립거래 합|숨김비율 평균|평균 높이 평균|계산 평균(ms/창)")
    for method in methods {
        let t = totals[method]!
        print("TG|합계|\(method.name)|\(f1(t.max))|\(f1(t.mean))|\(f1(t.titles))/\(f1(t.events))|\(f1(t.lines))|\(f1(t.tx))/\(f1(t.txAll))|\(f2(t.hidden / Double(t.count)))|\(f1(t.height / CGFloat(t.count)))|\(ms(t.seconds / Double(t.count)))")
    }
}

@Test func printWhereTheGridIsWorseThanTheExistingAxes() {
    // Every fixture and measure where the grid (N=12) loses to the two-day or four-day axis on the same days.
    print("TG|나쁜 사례|시나리오|지표|격자|2일|4일")
    var worse = 0
    for scenario in F.all {
        let two = TemporalGridComparison.report(scenario, method: .twoDay)
        let four = TemporalGridComparison.report(scenario, method: .fourDay)
        let grid = TemporalGridComparison.report(scenario, method: .temporal(slotCount: 12))
        func check(_ name: String, grid g: Double, two t: Double, four f: Double, lowerIsBetter: Bool, tolerance: Double = 0.05) {
            let loses = lowerIsBetter ? (g > min(t, f) + tolerance) : (g < max(t, f) - tolerance)
            if loses { worse += 1; print("TG|나쁜 사례|\(scenario.name)|\(name)|\(f1(g))|\(f1(t))|\(f1(f))") }
        }
        check("제목 표시(주날짜)", grid: grid.mainTitlesShown, two: two.mainTitlesShown, four: four.mainTitlesShown, lowerIsBetter: false)
        check("거래 글자 표시", grid: grid.mainTransactionTextShown, two: two.mainTransactionTextShown, four: four.mainTransactionTextShown, lowerIsBetter: false)
        check("E0 선으로 축약", grid: grid.mainLinesOnly, two: two.mainLinesOnly, four: four.mainLinesOnly, lowerIsBetter: true)
        check("평균 Y 이동", grid: Double(grid.meanYShift), two: Double(two.meanYShift), four: Double(four.meanYShift), lowerIsBetter: true, tolerance: 1)
        check("최대 Y 이동", grid: Double(grid.maxYShift), two: Double(two.maxYShift), four: Double(four.maxYShift), lowerIsBetter: true, tolerance: 1)
    }
    print("TG|나쁜 사례 수|\(worse)")
}

@Test func printTenTwelveAndSixteenCells() {
    print("TG|N|시나리오 합계|최대Y이동 합|평균Y이동 합|제목표시 합/일정 합|E0선 합|E1 합|거래글자 합/독립거래 합|숨김비율 평균|경계이동 평균(분)|슬롯 높이(pt)|계산(ms/창, 차가운 캐시)")
    for n in [10, 12, 16] {
        var max: CGFloat = 0, mean: CGFloat = 0, titles = 0.0, events = 0.0, lines = 0.0, slivers = 0.0, tx = 0.0, txAll = 0.0, hidden = 0.0, boundary = 0.0, seconds = 0.0
        for scenario in F.all {
            let report = TemporalGridComparison.report(scenario, method: .temporal(slotCount: n))
            max += report.maxYShift; mean += report.meanYShift; titles += report.mainTitlesShown; events += report.mainEvents
            lines += report.mainLinesOnly; slivers += report.mainSlivers; tx += report.mainTransactionTextShown; txAll += report.mainIndependentTransactions
            hidden += report.mainHiddenTransactionRatio; boundary += report.meanBoundaryShift; seconds += report.secondsPerWindow
        }
        let count = Double(F.all.count)
        print("TG|\(n)|\(F.all.count)|\(f1(max))|\(f1(mean))|\(f1(titles))/\(f1(events))|\(f1(lines))|\(f1(slivers))|\(f1(tx))/\(f1(txAll))|\(f2(hidden / count))|\(f2(boundary / count))|\(f1(640 / CGFloat(n)))|\(ms(seconds / count))")
    }
}

@Test func printWhatEachPartOfTheCostIsWorth() {
    struct Setting { let name: String; let change: (inout TemporalGridParameters) -> Void }
    let settings: [Setting] = [
        Setting(name: "기본") { _ in },
        Setting(name: "정각 선호 끔") { $0.roundness = .init(halfHour: 0, quarterHour: 0, other: 0) },
        Setting(name: "정각 선호 5배") { $0.roundness = .init(halfHour: 0.1, quarterHour: 0.2, other: 0.35) },
        Setting(name: "불균형 비용 끔") { $0.imbalance.perStepSquared = 0 },
        Setting(name: "불균형 비용 5배") { $0.imbalance.perStepSquared = 0.05 },
        Setting(name: "혼잡 비용 끔") { $0.weights.crowd = 0 },
        Setting(name: "경계 정렬 보상 끔") { $0.weights.edgeAlignment = 0 },
        Setting(name: "날짜 가중치 1/1/1/1") { $0.dayWeights = [1, 1, 1, 1] },
        Setting(name: "메인만(0/1/0/0)") { $0.dayWeights = [0, 1, 0, 0] },
        Setting(name: "메인+다음(0/1/1/0)") { $0.dayWeights = [0, 1, 1, 0] },
        Setting(name: "긴 일정도 전체 구간 요구") { $0.weights.longEventMinutes = 100_000 },
        Setting(name: "최대 구간 4시간") { $0.maxSlotMinutes = 240 },
        Setting(name: "후보 15분") { $0.candidateStepMinutes = 15 },
    ]
    print("TG|설정|최대Y이동 합|평균Y이동 합|제목표시 합/일정 합|E0선 합|거래글자 합|경계이동 평균(분)")
    for setting in settings {
        var parameters = TemporalGridParameters.default
        setting.change(&parameters)
        var max: CGFloat = 0, mean: CGFloat = 0, titles = 0.0, events = 0.0, lines = 0.0, tx = 0.0, boundary = 0.0
        for scenario in F.all {
            let report = TemporalGridComparison.report(scenario, method: .temporal(slotCount: 12), grid: parameters)
            max += report.maxYShift; mean += report.meanYShift; titles += report.mainTitlesShown; events += report.mainEvents
            lines += report.mainLinesOnly; tx += report.mainTransactionTextShown; boundary += report.meanBoundaryShift
        }
        print("TG|\(setting.name)|\(f1(max))|\(f1(mean))|\(f1(titles))/\(f1(events))|\(f1(lines))|\(f1(tx))|\(f2(boundary / Double(F.all.count)))")
    }
}

@Test func printTheLimitsOfTheCostApproximation() {
    // The search charges a claim to the cells it overlaps, each at that cell's own scale; the finished partition is charged by true height.
    // Also: where the planner thought a title was met and the renderer then did not write it in full.
    print("TG|근사|시나리오|N|검색 목적함수|정확한 claim 비용|서비스 불가 claim|claim 수|예측 제목 충족|실제 제목 전체 표시|불일치")
    var worst = 0.0
    for scenario in F.all {
        for n in [10, 12, 16] {
            var p = TemporalGridParameters.with(slotCount: n)
            p.viewportHeight = scenario.viewportHeight; p.textScale = scenario.textScale; p.allocation = scenario.parameters
            let main = 3
            let result = TemporalGridPlanner.plan(window: TemporalWindow(days: Array(scenario.days[(main - 1)...(main + 2)]), mainIndex: 1), parameters: p)
            let day = scenario.days[main]
            let placed = GridPlacement.place(GridDayEntities.make(day), partition: result.partition, metrics: .standard(scale: scenario.textScale), transactionPitch: GridPlacement.transactionPitch(scenario.parameters, textScale: scenario.textScale))
            // Predicted: a short event whose height reaches the claim's need (title + ramp). Actual: the presentation's title fully shown.
            let need = EventPresentation.Metrics.standard(scale: scenario.textScale)
            let predicted = placed.events.filter { $0.height >= need.titleNeed + need.ramp - 1e-6 }.count
            let actual = placed.titlesShown
            let gap = abs(result.breakdown.modelCost - result.breakdown.exactClaimCost)
            worst = max(worst, gap)
            if n == 12 || predicted != actual {
                print("TG|근사|\(scenario.name)|\(n)|\(f2(result.breakdown.modelCost))|\(f2(result.breakdown.exactClaimCost))|\(result.unservableClaimCount)|\(result.claimCount)|\(predicted)|\(actual)|\(predicted == actual ? "—" : "다름")")
            }
        }
    }
    // The old engine's idea of what a title needs, against what the renderer needs to write the title in full.
    let engineTitle = AdaptiveLayoutEngine.demandHeights(of: F.busy(0), parameters: AllocationParameters(), textScale: 1).events.values.map(\.title).max() ?? 0
    let metrics = EventPresentation.Metrics.standard()
    print("TG|근사|엔진 제목 높이 \(f1(engineTitle))pt, EventPresentation 제목 첫 등장 \(f1(metrics.titleNeed))pt, 전체 표시 \(f1(metrics.titleNeed + metrics.ramp))pt")
}

@Test func printTheCostOfPlanningAndTheCache() {
    func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    let clock = ContinuousClock()
    print("TG|성능|시나리오|N|프로필+DP 차가운 계산(ms)|캐시 적중(ms)|프로필 수|캐시 항목|캐시 바이트(근사)")
    for scenario in [F.stabilizationRuns[2], F.gridRuns[7], F.gridRuns[6], F.demoTransRun()] {
        for n in [10, 12, 16] {
            var p = TemporalGridParameters.with(slotCount: n)
            p.viewportHeight = scenario.viewportHeight; p.textScale = scenario.textScale; p.allocation = scenario.parameters
            let store = TemporalGridStore()
            let window = TemporalWindow(days: Array(scenario.days[2...5]), mainIndex: 1)
            let cold = clock.measure { _ = store.plan(window: window, parameters: p) }
            let warm = clock.measure { _ = store.plan(window: window, parameters: p) }
            print("TG|성능|\(scenario.name)|\(n)|\(String(format: "%.2f", ms(cold)))|\(String(format: "%.3f", ms(warm)))|\(store.profileBuilds)|\(store.entryCount)|\(store.approximateBytes)")
        }
    }
    // A move by one day reuses three of the four profiles and plans once.
    let scenario = F.stabilizationRuns[2]
    var p = TemporalGridParameters.default; p.allocation = scenario.parameters
    let store = TemporalGridStore()
    _ = store.plan(window: TemporalWindow(days: Array(scenario.days[1...4]), mainIndex: 1), parameters: p)
    store.resetCounters()
    _ = store.plan(window: TemporalWindow(days: Array(scenario.days[2...5]), mainIndex: 1), parameters: p)
    print("TG|성능|하루 이동|프로필 새로 계산 \(store.profileBuilds)|분할 계산 \(store.planRuns)")
    #expect(store.profileBuilds == 1 && store.planRuns == 1)
    // The cache is bounded.
    let small = TemporalGridStore(limit: 3)
    for main in 1..<6 { _ = small.plan(window: TemporalWindow(days: Array(scenario.days[(main - 1)...(main + 2)]), mainIndex: 1), parameters: p) }
    #expect(small.entryCount <= 6)
}
