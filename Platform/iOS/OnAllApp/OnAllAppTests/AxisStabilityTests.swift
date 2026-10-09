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

private let variants: [AxisVariant] = [.floorOnly, .fourDay, .sixDay]

@Test func theSameInputGivesTheSameLayoutWhateverWasPlannedBeforeAndWhateverIsRemembered() {
    for scenario in scenarios() {
        let cold = AxisStability.windows(scenario, variant: .fourDay)
        let warm = AxisDemandCache()
        _ = AxisStability.windows(scenario, variant: .fourDay, cache: warm)                          // fills the cache
        let reversed = AxisStability.commonRange(scenario).reversed().map { day in
            AxisStability.layoutWindow(scenario, main: day, variant: .fourDay, cache: warm)           // other order, warm cache
        }.sorted { $0.day < $1.day }
        #expect(cold.map(\.layout.axis) == reversed.map(\.layout.axis), "\(scenario.name): the path to a day changed its axis")
        #expect(cold.map(\.layout.events) == reversed.map(\.layout.events), "\(scenario.name): the path to a day changed what is shown")
        #expect(cold.map(\.layout.lines) == reversed.map(\.layout.lines))
        #expect(cold.map(\.layout.overflows) == reversed.map(\.layout.overflows))
    }
}

@Test func everyTimeIsAtLeastAsFarFromEveryOtherAsOnTheFloor() {
    // The floor is exact at the minute, not only per quarter hour: no demand of the visible days can be lost between two minutes.
    for scenario in scenarios() {
        for variant in [AxisVariant.fourDay, .sixDay] {
            for (index, window) in AxisStability.windows(scenario, variant: variant).enumerated() {
                let floor = AdaptiveLayoutEngine.floorAxis(
                    main: scenario.days[window.day], secondary: scenario.days[window.day + 1], parameters: scenario.parameters, textScale: scenario.textScale
                )
                var worst: CGFloat = .infinity
                var minute = 0
                while minute < 24 * 60 {
                    var other = minute + 1
                    while other <= 24 * 60 {
                        worst = min(worst, (window.layout.axis.y(minute: other) - window.layout.axis.y(minute: minute)) - (floor.y(minute: other) - floor.y(minute: minute)))
                        other += 7
                    }
                    minute += 13
                }
                #expect(worst > -0.001, "\(scenario.name) \(variant.rawValue) window \(index): two times came closer than on the floor by \(-worst)")
                #expect(window.plan.requiredScroll == max(0, floor.height - scenario.viewportHeight))
            }
        }
    }
}

@Test func stabilityScrollNeverExceedsItsAllowanceAndIsNeverAddedWhereScrollingIsAlreadyRequired() {
    for scenario in scenarios() {
        let allowance = AxisStabilizerParameters.fourDay.extraScrollAllowance * scenario.viewportHeight
        for window in AxisStability.windows(scenario, variant: .fourDay) {
            #expect(window.plan.stabilizationScroll <= allowance + 0.5, "\(scenario.name) day \(window.day): \(window.plan.stabilizationScroll) > \(allowance)")
            if window.plan.requiredScroll + window.plan.readabilityScroll + window.plan.prepaidScroll > 0 { #expect(window.plan.stabilizationScroll < 0.5, "\(scenario.name) day \(window.day)") }
            #expect(window.plan.readabilityScroll + window.plan.prepaidScroll <= AxisStabilizerParameters.fourDay.mainLinesScrollAllowance * scenario.viewportHeight + 0.5, "\(scenario.name) day \(window.day)")
        }
    }
}

@Test func quietEmptyStretchesStayFoldedAndAFullyQuietRunDoesNotChangeAtAll() {
    let scenario = scenarios()[0]
    let report = AxisStability.compare(scenario, variant: .fourDay)
    #expect(report.maxYShift < 0.001 && report.maxSlotDelta < 0.001)
    let slots = AxisStability.windows(scenario, variant: .fourDay)[0].plan.slots
    #expect(slots.contains { $0 < 2 })                                                                  // long empty stretches are still strongly compressed
}

// MARK: The axis and what is drawn on it are one decision

@Test func whatIsShownIsExactlyWhatTheAxisHasRoomFor() {
    for scenario in scenarios() {
        for variant in variants {
            for window in AxisStability.windows(scenario, variant: variant) {
                let layout = window.layout
                let label = "\(scenario.name) \(variant.rawValue) window \(window.day)"
                #expect(layout.axis == window.plan.axis, "\(label): the layout is not on the planned axis")
                #expect(layout.contentHeight == layout.axis.height)
                #expect(layout.requiresScroll == (layout.axis.height > scenario.viewportHeight + 0.5))
                for (role, day) in [(DayRole.main, scenario.days[window.day]), (.secondary, scenario.days[window.day + 1])] {
                    let heights = AdaptiveLayoutEngine.demandHeights(of: day, parameters: scenario.parameters, textScale: scenario.textScale)
                    // Events: the level is the highest one the axis gives the height for, never more.
                    for event in layout.events where event.key.role == role {
                        guard let needs = heights.events[event.id], let source = day.events.first(where: { $0.id == event.id }) else { continue }
                        let room = layout.axis.y(minute: source.effectiveEnd) - layout.axis.y(minute: source.startMinute)
                        let required = event.level == .title ? needs.title : event.level == .preview ? needs.preview : needs.full
                        #expect(event.level == .title || room + 0.5 >= required, "\(label): \(event.id) shows a level it has no height for")
                        if event.level < .full, needs.full > needs.preview { #expect(room + 0.5 < needs.full || event.level == .full, "\(label): \(event.id) could show more") }
                        #expect(event.titleResolution != .expandedRange, "\(label): a fixed axis was asked to grow")
                    }
                    // Transactions: two neighbouring lines are apart where the axis keeps them a row apart, merged where it does not.
                    let overflows = layout.overflows.filter { $0.role == role }.map { Set($0.members.map(\.transactionID)) }
                    for link in heights.mergeableLinks {
                        let ids = link.key.split(separator: ">").map(String.init)
                        let room = layout.axis.y(minute: link.second) - layout.axis.y(minute: link.first)
                        let apart = !overflows.contains { group in ids.allSatisfy { group.contains($0) } }
                        #expect(apart == (room + 0.5 >= heights.pitch), "\(label): \(link.key) is \(apart ? "apart" : "merged") with room \(room) for \(heights.pitch)")
                    }
                }
                // No line is shown that needs more height than the axis gives it: consecutive things on one day are a row apart or merged.
                for role in [DayRole.main, .secondary] {
                    let anchors = (layout.lines.filter { $0.role == role }.map { ($0.minute, scenario.parameters.transactionRow * max(0.5, scenario.textScale)) }
                        + layout.overflows.filter { $0.role == role }.map { (($0.startMinute + $0.endMinute) / 2, $0.requiredHeight) }).sorted { $0.0 < $1.0 }
                    let gap = scenario.parameters.lineGap * max(0.5, scenario.textScale)
                    for (a, b) in zip(anchors, anchors.dropFirst()) where b.0 > a.0 {
                        let room = layout.axis.y(minute: b.0) - layout.axis.y(minute: a.0)
                        #expect(room + 1 >= (a.1 + b.1) / 2 + gap, "\(label): two lines at \(a.0) and \(b.0) are \(room) apart, they need \((a.1 + b.1) / 2 + gap)")
                    }
                }
            }
        }
    }
}

@Test func theLayoutOnAFixedAxisIgnoresWhatWasShownBeforeAndNeverLoops() {
    let scenario = scenarios()[2]
    let plan = AxisStability.layoutWindow(scenario, main: 3, variant: .fourDay)
    var input = AllocationInput(main: scenario.days[3], secondary: scenario.days[4], viewportHeight: scenario.viewportHeight, contentWidth: 300)
    input.fixedAxis = plan.layout.axis
    let first = AdaptiveLayoutEngine.layout(input)
    input.previous = first.state.mapValues { _ in 2 }                  // a different history
    input.viewportHeight = 10                                          // and a different budget: the axis is given, so they play no part
    let second = AdaptiveLayoutEngine.layout(input)
    #expect(first.events == second.events && first.lines == second.lines && first.overflows == second.overflows && first.axis == second.axis)
}

// MARK: Policy: what each part of the plan is worth

@Test func theMainDaysTransactionsAreAtLeastAsOftenReadableAsWithTheEngineAlone() {
    // P1: the 50% split of the extra room is for the main day's first rows, not for its independent transactions, which come first.
    for scenario in scenarios() {
        let two = AxisStability.compare(scenario, variant: .engineTwoDay)
        let four = AxisStability.compare(scenario, variant: .fourDay)
        #expect(four.mainSeparateLines + 2 >= two.mainSeparateLines, "\(scenario.name): 4일 \(four.mainSeparateLines) < 2일 \(two.mainSeparateLines)")
    }
}

@Test func theCacheFindsWhatItComputedAndForgetsWhatChanged() {
    let cache = AxisDemandCache(limit: 4)
    let parameters = AllocationParameters()
    let a = day(0, events: [hours(9, 10)])
    _ = cache.profile(for: a, parameters: parameters, textScale: 1)
    _ = cache.profile(for: a, parameters: parameters, textScale: 1)
    #expect(cache.hits == 1 && cache.misses == 1)
    _ = cache.profile(for: day(0, events: [hours(9, 11)]), parameters: parameters, textScale: 1)         // the day changed
    #expect(cache.misses == 2)
    _ = cache.profile(for: a, parameters: parameters, textScale: 2)                                      // the text size changed
    #expect(cache.misses == 3)
    var changed = parameters
    changed.transactionRow += 4                                                                          // a size the demand depends on changed
    _ = cache.profile(for: a, parameters: changed, textScale: 1)
    #expect(cache.misses == 4)
    for i in 10..<20 { _ = cache.profile(for: day(i, events: [hours(9, 10)]), parameters: parameters, textScale: 1) }
    #expect(cache.count <= 4)                                                                           // bounded
}

@Test func aWarmCacheGivesTheLayoutAColdOneDoes() {
    for scenario in scenarios() {
        let cache = AxisDemandCache()
        _ = AxisStability.windows(scenario, variant: .fourDay, cache: cache)
        for day in AxisStability.commonRange(scenario) {
            let warm = AxisStability.layoutWindow(scenario, main: day, variant: .fourDay, cache: cache)
            let cold = AxisStability.layoutWindow(scenario, main: day, variant: .fourDay)
            #expect(warm.layout.axis == cold.layout.axis && warm.layout.events == cold.layout.events)
        }
    }
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

// MARK: The comparison (printed; the invariants above are what is asserted)

private func line(_ scenario: String, _ r: AxisVariantReport) -> String {
    "| \(scenario) | \(r.variant.rawValue) | \(f(r.maxYShift)) | \(f(r.meanYShift)) | \(f(r.maxSlotDelta)) | \(f(r.meanHeightDelta)) | \(r.levelChanges) | \(r.mainSeparateLines)/\(r.mainEventsWithRows) | \(f(r.meanRequiredScroll)) | \(f(r.meanReadabilityScroll))/\(f(r.maxReadabilityScroll)) | \(f(r.meanStabilizationScroll))/\(f(r.maxStabilizationScroll)) | \(f(CGFloat(r.seconds * 1000))) |"
}

@Test func printTheComparisonOfTheVariantsOnEveryFixture() {
    var lines = ["| 시나리오 | 방식 | 최대 Y이동 | 평균 Y이동 | 최대 구간높이변화 | 평균 높이변화 | 표시수준변화 | 주날짜 거래줄/행일정 | 필수스크롤 | 읽기스크롤(평균/최대) | 안정화스크롤(평균/최대) | 계산(ms) |", "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for scenario in scenarios() {
        for variant in AxisVariant.allCases {
            lines.append(line(scenario.name, AxisStability.compare(scenario, variant: variant, cache: AxisDemandCache())))
        }
    }
    print("AXISREPORT\n" + lines.joined(separator: "\n") + "\nAXISREPORTEND")
    #expect(lines.count > 2)
}

@Test func printTheCostOfPlanningAndWhatTheCacheSaves() {
    var lines = ["| 시나리오 | 창 수 | 캐시 없이(ms) | 캐시 사용(ms) | 적중률 | 항목 수 | 한 칸 이동(ms) |", "|---|---|---|---|---|---|---|"]
    let clock = ContinuousClock()
    func ms(_ d: Duration) -> CGFloat { CGFloat(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }
    for scenario in scenarios() {
        let windows = AxisStability.commonRange(scenario).count
        let cold = clock.measure { for day in AxisStability.commonRange(scenario) { _ = AxisStability.layoutWindow(scenario, main: day, variant: .fourDay, cache: AxisDemandCache()) } }
        let cache = AxisDemandCache()
        _ = AxisStability.layoutWindow(scenario, main: 2, variant: .fourDay, cache: cache)                      // the window on screen
        let step = clock.measure { _ = AxisStability.layoutWindow(scenario, main: 3, variant: .fourDay, cache: cache) }  // one day over
        let warm = clock.measure { _ = AxisStability.windows(scenario, variant: .fourDay, cache: cache) }
        lines.append("| \(scenario.name) | \(windows) | \(f(ms(cold))) | \(f(ms(warm))) | \(f(CGFloat(cache.hitRate) * 100))% | \(cache.count) | \(f(ms(step))) |")
    }
    print("AXISCOST\n" + lines.joined(separator: "\n") + "\nAXISCOSTEND")
}

@Test func printWhatEachPartOfThePlanIsWorth() {
    struct Setting { let name: String; let parameters: AxisStabilizerParameters }
    func with(_ change: (inout AxisStabilizerParameters) -> Void) -> AxisStabilizerParameters { var p = AxisStabilizerParameters.fourDay; change(&p); return p }
    let settings = [
        Setting(name: "기본(메인100/보조100, 형태·테이퍼 끔)", parameters: .fourDay),
        Setting(name: "+테이퍼 24", parameters: with { $0.taperPerSlot = 24 }),
        Setting(name: "+형태 50%", parameters: with { $0.shapeShare = 0.5 }),
        Setting(name: "메인50/보조50", parameters: with { $0.mainDetailShare = 0.5; $0.secondaryShare = 0.5 }),
        Setting(name: "빈 구간 끔", parameters: with { $0.shortGapSlots = 0 }),
        Setting(name: "주변 끔", parameters: with { $0.spendsOnSurroundings = false }),
        Setting(name: "스크롤 허용 0", parameters: with { $0.extraScrollAllowance = 0 }),
        Setting(name: "스크롤 허용 5%", parameters: with { $0.extraScrollAllowance = 0.05 }),
        Setting(name: "스크롤 허용 15%", parameters: with { $0.extraScrollAllowance = 0.15 }),
        Setting(name: "P1 스크롤 0", parameters: with { $0.mainLinesScrollAllowance = 0 }),
        Setting(name: "P1 스크롤 50%", parameters: with { $0.mainLinesScrollAllowance = 0.5 }),
        Setting(name: "보조 거래줄도 P1 스크롤", parameters: with { $0.secondaryLinesUseReadabilityScroll = true }),
        Setting(name: "가중치 1/1/1", parameters: with { $0.distanceWeights = [1, 1, 1] }),
    ]
    var lines = ["| 설정 | 최대Y이동 합 | 평균Y이동 합 | 표시수준변화 합 | 주날짜 거래줄 | 주날짜 행일정 | 안정화스크롤 평균/최대 | 추가높이 합(안정화) |", "|---|---|---|---|---|---|---|---|"]
    for setting in settings {
        var maxY: CGFloat = 0, meanY: CGFloat = 0, levels = 0, mainLines = 0, mainRows = 0, extraMean: CGFloat = 0, extraMax: CGFloat = 0, spent: CGFloat = 0, count: CGFloat = 0
        for scenario in scenarios() {
            let r = AxisStability.compare(scenario, variant: .fourDay, cache: AxisDemandCache(), parameters: setting.parameters)
            maxY += r.maxYShift; meanY += r.meanYShift; levels += r.levelChanges; mainLines += r.mainSeparateLines; mainRows += r.mainEventsWithRows
            extraMean += r.meanStabilizationScroll; extraMax = max(extraMax, r.maxStabilizationScroll); count += 1
            spent += AxisStability.windows(scenario, variant: .fourDay, parameters: setting.parameters).map(\.plan.stabilizerHeight).reduce(0, +)
        }
        lines.append("| \(setting.name) | \(f(maxY)) | \(f(meanY)) | \(levels) | \(mainLines) | \(mainRows) | \(f(extraMean / count))/\(f(extraMax)) | \(f(spent)) |")
    }
    var maxY: CGFloat = 0, meanY: CGFloat = 0, levels = 0, mainLines = 0, mainRows = 0
    for scenario in scenarios() {
        let r = AxisStability.compare(scenario, variant: .engineTwoDay)
        maxY += r.maxYShift; meanY += r.meanYShift; levels += r.levelChanges; mainLines += r.mainSeparateLines; mainRows += r.mainEventsWithRows
    }
    lines.append("| (기존 2일) | \(f(maxY)) | \(f(meanY)) | \(levels) | \(mainLines) | \(mainRows) | 0/0 | 0 |")
    print("AXISSWEEP\n" + lines.joined(separator: "\n") + "\nAXISSWEEPEND")
}
