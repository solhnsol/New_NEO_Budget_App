import CoreGraphics
import NEOBudgetCalendar
import Testing
@testable import OnAllApp

// Fixtures: runs of nine consecutive synthetic days (no real data). The first and last two only serve as surroundings of the windows compared.

private let firstDay = (try? LocalDate(year: 2027, month: 3, day: 1)) ?? { fatalError("date") }()

private func day(_ index: Int, events: [(Int, Int)] = [], transactions: [Int] = [], linkedPerEvent: Int = 0) -> AllocationDay {
    let date = firstDay.adding(days: index)
    let built = events.enumerated().map { offset, range -> AllocationEvent in
        let linked = (0..<linkedPerEvent).map { n in
            AllocationTransaction(id: "t\(index)-\(offset)-\(n)", minute: range.0 + min(n, max(0, range.1 - range.0 - 1)), kind: .spend, currency: "KRW", minorUnits: 3_000)
        }
        return AllocationEvent(id: "e\(index)-\(offset)", title: "일정 \(offset)", startMinute: range.0, endMinute: range.1, linked: linked)
    }
    let loose = transactions.enumerated().map { offset, minute in
        AllocationTransaction(id: "x\(index)-\(offset)", minute: minute, kind: .spend, currency: "KRW", minorUnits: 2_000)
    }
    return AllocationDay(day: date, totalMinutes: 24 * 60, events: built, transactions: loose)
}

private func hours(_ from: Int, _ to: Int) -> (Int, Int) { (from * 60, to * 60) }

private func busy(_ index: Int) -> AllocationDay {
    day(index, events: (8..<20).map { hours($0, $0 + 1) } + [(9 * 60 + 10, 9 * 60 + 30), (13 * 60, 13 * 60 + 20)], transactions: [9 * 60, 12 * 60, 15 * 60, 18 * 60], linkedPerEvent: 2)
}

private func scenarios() -> [AxisStabilityScenario] {
    var result: [AxisStabilityScenario] = []
    result.append(AxisStabilityScenario(name: "1 모두 한가한 6일", days: (0..<9).map { day($0, events: [hours(14, 15)]) }))
    result.append(AxisStabilityScenario(name: "2 하루만 매우 바쁨", days: (0..<9).map { $0 == 4 ? busy($0) : day($0, events: [hours(14, 15)]) }))
    result.append(AxisStabilityScenario(name: "3 바쁨/한가 번갈아", days: (0..<9).map { $0 % 2 == 0 ? busy($0) : day($0, events: [hours(10, 11)]) }))
    result.append(AxisStabilityScenario(name: "4 시간대가 분산", days: (0..<9).map { day($0, events: [hours(6 + $0 * 2, 7 + $0 * 2), hours(7 + $0 * 2, 8 + $0 * 2)], transactions: [(6 + $0 * 2) * 60 + 30]) }))
    result.append(AxisStabilityScenario(name: "5 긴 일정+짧은 일정", days: (0..<9).map { day($0, events: [hours(9, 18), (10 * 60, 10 * 60 + 20), (12 * 60, 12 * 60 + 10), (15 * 60, 15 * 60 + 25)], linkedPerEvent: $0 % 3) }))
    result.append(AxisStabilityScenario(name: "6 거래 밀집", days: (0..<9).map { $0 % 3 == 1 ? day($0, events: [hours(9, 10)], transactions: (0..<14).map { 14 * 60 + $0 * 2 }) : day($0, events: [hours(11, 12)], transactions: [13 * 60]) }))
    result.append(AxisStabilityScenario(name: "7 겹치는 일정 많음", days: (0..<9).map { $0 % 2 == 0 ? day($0, events: [hours(9, 17), hours(10, 15), hours(11, 14), (12 * 60, 12 * 60 + 30), (9 * 60 + 30, 11 * 60)]) : day($0, events: [hours(13, 14)]) }))
    result.append(AxisStabilityScenario(name: "8 자정을 넘는 일정", days: (0..<9).map { day($0, events: [(0, 2 * 60), (22 * 60, 24 * 60), hours(12, 13)]) }))
    result.append(AxisStabilityScenario(name: "9 작은 viewport", days: (0..<9).map { $0 % 2 == 0 ? busy($0) : day($0, events: [hours(10, 11), hours(16, 17)]) }, viewportHeight: 360))
    result.append(AxisStabilityScenario(name: "10 큰 Dynamic Type", days: (0..<9).map { $0 % 2 == 0 ? busy($0) : day($0, events: [hours(10, 11), hours(16, 17)], linkedPerEvent: 1) }, textScale: 2.2))
    return result
}

private func f(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }

// MARK: Invariants

@Test func theSameInputGivesTheSameAxisWhateverWasPlannedBefore() {
    for scenario in scenarios() {
        let cold = AxisStability.windows(scenario, variant: .fourDay)
        let warm = AxisDemandCache()
        _ = AxisStability.windows(scenario, variant: .fourDay, cache: warm)                          // fills the cache
        let reversed = AxisStability.commonRange(scenario).reversed().map { day in
            (day, AxisStability.planWindow(scenario, main: day, variant: .fourDay, radius: (1, 1), cache: warm))   // other order, warm cache
        }.sorted { $0.0 < $1.0 }
        #expect(cold.map(\.axis.slots) == reversed.map(\.1.slots), "\(scenario.name): the path to a day changed its axis")
    }
}

@Test func theFloorOfTheTwoVisibleDaysIsNeverGivenUp() {
    for scenario in scenarios() {
        for variant in [AxisVariant.fourDay, .sixDay] {
            let floors = AxisStability.windows(scenario, variant: .floorOnly)
            let planned = AxisStability.windows(scenario, variant: variant)
            for (floor, plan) in zip(floors, planned) {
                #expect(zip(floor.axis.slots, plan.axis.slots).allSatisfy { $1 + 0.001 >= $0 }, "\(scenario.name) \(variant.rawValue) day \(plan.day)")
                #expect(plan.axis.requiredScroll == floor.axis.requiredScroll)                         // the required scroll is exactly the floor's
            }
        }
    }
}

@Test func stabilityScrollNeverExceedsItsAllowanceAndIsZeroWithoutIt() {
    for scenario in scenarios() {
        let allowance = AxisStabilizerParameters.fourDay.extraScrollAllowance * scenario.viewportHeight
        for plan in AxisStability.windows(scenario, variant: .fourDay) {
            #expect(plan.axis.stabilizationScroll <= allowance + 0.5, "\(scenario.name) day \(plan.day): \(plan.axis.stabilizationScroll) > \(allowance)")
        }
        // No allowance, no room: nothing is added beyond the floor.
        var parameters = AxisStabilizerParameters.fourDay
        parameters.extraScrollAllowance = 0
        let cache = AxisDemandCache()
        let profiles = (0..<4).map { cache.profile(for: scenario.days[$0], parameters: scenario.parameters, textScale: scenario.textScale) }
        let floor = cache.floor(main: profiles[1], secondary: profiles[2], mainDay: scenario.days[1], secondaryDay: scenario.days[2], parameters: scenario.parameters, textScale: scenario.textScale)
        let tight = AxisStabilizer.plan(window: profiles, mainIndex: 1, floor: floor, viewport: floor.reduce(0, +), parameters: parameters)
        #expect(tight.stabilizationScroll < 0.5)
    }
}

@Test func quietEmptyStretchesStayFoldedAndAFullyQuietRunDoesNotChangeAtAll() {
    let scenario = scenarios()[0]
    let report = AxisStability.compare(scenario, variant: .fourDay)
    #expect(report.maxYShift < 0.001 && report.maxSlotDelta < 0.001)
    let slots = AxisStability.windows(scenario, variant: .fourDay)[0].axis.slots
    #expect(slots.contains { $0 < 2 })                                                                  // long empty stretches are still strongly compressed
}

@Test func theCacheFindsWhatItComputedAndForgetsWhatChanged() {
    let cache = AxisDemandCache(limit: 4)
    let parameters = AllocationParameters()
    let a = day(0, events: [hours(9, 10)]), b = day(1, events: [hours(9, 10)])
    _ = cache.profile(for: a, parameters: parameters, textScale: 1)
    _ = cache.profile(for: a, parameters: parameters, textScale: 1)
    #expect(cache.hits == 1 && cache.misses == 1)
    _ = cache.profile(for: day(0, events: [hours(9, 11)]), parameters: parameters, textScale: 1)         // the day changed
    #expect(cache.misses == 2)
    _ = cache.profile(for: a, parameters: parameters, textScale: 2)                                      // the text size changed
    #expect(cache.misses == 3)
    for i in 10..<20 { _ = cache.profile(for: day(i, events: [hours(9, 10)]), parameters: parameters, textScale: 1) }
    #expect(cache.count <= 4)                                                                           // bounded
    _ = b
}

@Test func stepsOneDayAtATimeReuseThreeOfFourProfiles() {
    let scenario = scenarios()[2]
    let cache = AxisDemandCache()
    _ = AxisStability.windows(scenario, variant: .fourDay, cache: cache)
    let windows = AxisStability.commonRange(scenario).count
    // Each window needs four profiles and one floor; after the first, only the day that came in is new.
    #expect(cache.misses <= 4 + (windows - 1) + windows)
    #expect(cache.hitRate > 0.4)
}

@Test func noStabilityScrollIsAddedWhereTheVisibleDaysAlreadyNeedToScroll() {
    for scenario in scenarios() where scenario.viewportHeight < 400 || scenario.textScale > 2 {
        for plan in AxisStability.windows(scenario, variant: .fourDay) where plan.axis.requiredScroll > 0 {
            #expect(plan.axis.stabilizationScroll < 0.5, "\(scenario.name) day \(plan.day)")
        }
    }
}

// MARK: The comparison (printed; the invariants above are what is asserted)

@Test func printTheComparisonOfTheVariantsOnEveryFixture() {
    var lines = ["| 시나리오 | 방식 | 최대 Y이동 | 평균 Y이동 | 최대 구간높이변화 | 평균 높이변화 | 표시수준변화 | 필수스크롤 | 안정화스크롤(평균/최대) | 계산(ms) |", "|---|---|---|---|---|---|---|---|---|---|"]
    for scenario in scenarios() {
        for variant in AxisVariant.allCases {
            let r = AxisStability.compare(scenario, variant: variant, cache: AxisDemandCache())
            lines.append("| \(scenario.name) | \(variant.rawValue) | \(f(r.maxYShift)) | \(f(r.meanYShift)) | \(f(r.maxSlotDelta)) | \(f(r.meanHeightDelta)) | \(r.levelChanges) | \(f(r.meanRequiredScroll)) | \(f(r.meanStabilizationScroll))/\(f(r.maxStabilizationScroll)) | \(f(CGFloat(r.seconds * 1000))) |")
        }
    }
    print("AXISREPORT\n" + lines.joined(separator: "\n") + "\nAXISREPORTEND")
    #expect(lines.count > 2)
}

// MARK: Parameter sweep (printed): how the settings trade stability against the room they spend

@Test func printTheParameterSweep() {
    struct Setting { let name: String; let parameters: AxisStabilizerParameters }
    var settings: [Setting] = []
    for mainShare in [1.0, 0.5, 0.25] as [CGFloat] {
        for weights in [[0.5, 0.25, 0.125], [1, 1, 1], [0.8, 0.5, 0.3]] as [[CGFloat]] {
            for taper in [12, 24] as [CGFloat] {
                var p = AxisStabilizerParameters.fourDay
                p.mainDetailShare = mainShare
                p.distanceWeights = weights
                p.taperPerSlot = taper
                settings.append(Setting(name: "main \(mainShare) w\(weights[0]) taper \(taper)", parameters: p))
            }
        }
    }
    var lines = ["| 설정 | 최대Y이동 합 | 평균Y이동 합 | 표시수준변화 합 | 안정화스크롤 최대 |", "|---|---|---|---|---|"]
    for setting in settings {
        var maxY: CGFloat = 0, meanY: CGFloat = 0, levels = 0, extra: CGFloat = 0
        for scenario in scenarios() {
            let r = AxisStability.compare(scenario, variant: .fourDay, cache: AxisDemandCache(), parameters: setting.parameters)
            maxY += r.maxYShift; meanY += r.meanYShift; levels += r.levelChanges; extra = max(extra, r.maxStabilizationScroll)
        }
        lines.append("| \(setting.name) | \(f(maxY)) | \(f(meanY)) | \(levels) | \(f(extra)) |")
    }
    var twoMax: CGFloat = 0, twoMean: CGFloat = 0, twoLevels = 0
    for scenario in scenarios() {
        let r = AxisStability.compare(scenario, variant: .engineTwoDay)
        twoMax += r.maxYShift; twoMean += r.meanYShift; twoLevels += r.levelChanges
    }
    lines.append("| (기존 2일) | \(f(twoMax)) | \(f(twoMean)) | \(twoLevels) | 0 |")
    print("AXISSWEEP\n" + lines.joined(separator: "\n") + "\nAXISSWEEPEND")
}

@Test func printTheCostOfPlanningAndWhatTheCacheSaves() {
    var lines = ["| 시나리오 | 창 수 | 캐시 없이(ms) | 캐시 사용(ms) | 적중률 | 항목 수 |", "|---|---|---|---|---|---|"]
    let clock = ContinuousClock()
    for scenario in scenarios() {
        let windows = AxisStability.commonRange(scenario).count
        var cold = Duration.zero, warm = Duration.zero
        // Without a cache every window computes its four days again.
        cold = clock.measure { for day in AxisStability.commonRange(scenario) { _ = AxisStability.planWindow(scenario, main: day, variant: .fourDay, radius: (1, 1), cache: AxisDemandCache()) } }
        let cache = AxisDemandCache()
        warm = clock.measure { _ = AxisStability.windows(scenario, variant: .fourDay, cache: cache) }
        func ms(_ d: Duration) -> CGFloat { CGFloat(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }
        lines.append("| \(scenario.name) | \(windows) | \(f(ms(cold))) | \(f(ms(warm))) | \(f(CGFloat(cache.hitRate) * 100))% | \(cache.count) |")
    }
    print("AXISCOST\n" + lines.joined(separator: "\n") + "\nAXISCOSTEND")
}
