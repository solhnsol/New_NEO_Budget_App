import CoreGraphics
import NEOBudgetCalendar

/// How an axis planner is compared with another over a run of days, and what the comparison measures. Pure: the same days give the same
/// numbers, except for the timings, which are measured separately and never take part in a comparison of axes.
enum AxisVariant: String, CaseIterable, Sendable {
    /// The engine as it is: the layout it makes for the two visible days within the viewport.
    case engineTwoDay = "2일(기존)"
    /// Only what the two visible days cannot do without: the floor, with everything shown as the floor allows. A lower bound, not a candidate.
    case floorOnly = "바닥만"
    case fourDay = "4일"
    case sixDay = "6일(실험)"
}

/// A run of consecutive days and the screen they are shown on.
struct AxisStabilityScenario {
    let name: String
    let days: [AllocationDay]
    var viewportHeight: CGFloat = 640
    var textScale: CGFloat = 1
    var parameters = AllocationParameters()
    var contentWidth: CGFloat = 300
}

/// The layout of one window (visible days D and D+1) and what its axis cost.
struct StabilityWindow {
    let day: Int
    let plan: PlannedAxis
    let layout: AdaptiveLayout
}

/// What changed between two neighbouring windows (D and D+1).
struct AxisTransitionMetrics: Equatable {
    /// Largest and mean change of a quarter hour's height, in points.
    var maxSlotDelta: CGFloat
    var meanSlotDelta: CGFloat
    /// Largest and mean change of where the same time is drawn (from the top of the day), sampled every quarter hour.
    var maxYShift: CGFloat
    var meanYShift: CGFloat
    var heightDelta: CGFloat
    /// Items of the day that is on screen in both windows whose form differs (events at another level, transaction lines kept apart or not).
    var levelChanges: Int
}

struct AxisWindowCost: Equatable {
    var height: CGFloat
    var requiredScroll: CGFloat
    var stabilizationScroll: CGFloat
    var readabilityScroll: CGFloat = 0
    var prepaidScroll: CGFloat = 0
    /// Of the main day: how many events show more than their title, and how many of its transactions are lines of their own.
    var mainEventsWithRows: Int
    var mainSeparateLines: Int
}

struct AxisVariantReport {
    let variant: AxisVariant
    var transitions: [AxisTransitionMetrics] = []
    var windows: [AxisWindowCost] = []
    /// Time to plan and lay out all windows, in seconds.
    var seconds: Double = 0

    var maxYShift: CGFloat { transitions.map(\.maxYShift).max() ?? 0 }
    var meanYShift: CGFloat { average(transitions.map(\.meanYShift)) }
    var maxSlotDelta: CGFloat { transitions.map(\.maxSlotDelta).max() ?? 0 }
    var meanSlotDelta: CGFloat { average(transitions.map(\.meanSlotDelta)) }
    var meanHeightDelta: CGFloat { average(transitions.map(\.heightDelta)) }
    var levelChanges: Int { transitions.map(\.levelChanges).reduce(0, +) }
    var meanRequiredScroll: CGFloat { average(windows.map(\.requiredScroll)) }
    var meanStabilizationScroll: CGFloat { average(windows.map(\.stabilizationScroll)) }
    var maxStabilizationScroll: CGFloat { windows.map(\.stabilizationScroll).max() ?? 0 }
    var meanReadabilityScroll: CGFloat { average(windows.map { $0.readabilityScroll + $0.prepaidScroll }) }
    var maxReadabilityScroll: CGFloat { windows.map { $0.readabilityScroll + $0.prepaidScroll }.max() ?? 0 }
    var mainSeparateLines: Int { windows.map(\.mainSeparateLines).reduce(0, +) }
    var mainEventsWithRows: Int { windows.map(\.mainEventsWithRows).reduce(0, +) }

    private func average(_ values: [CGFloat]) -> CGFloat { values.isEmpty ? 0 : values.reduce(0, +) / CGFloat(values.count) }
}

enum AxisStability {
    /// The windows every variant can be planned for, so that all variants are compared over the same moves.
    static func commonRange(_ scenario: AxisStabilityScenario) -> Range<Int> { 2..<max(2, scenario.days.count - 3) }

    static func windows(
        _ scenario: AxisStabilityScenario, variant: AxisVariant, cache: AxisDemandCache? = nil, parameters: AxisStabilizerParameters = .fourDay
    ) -> [StabilityWindow] {
        commonRange(scenario).map { layoutWindow(scenario, main: $0, variant: variant, cache: cache, parameters: parameters) }
    }

    static func layoutWindow(
        _ scenario: AxisStabilityScenario, main: Int, variant: AxisVariant, cache: AxisDemandCache? = nil, parameters tuned: AxisStabilizerParameters = .fourDay
    ) -> StabilityWindow {
        let mainDay = scenario.days[main], secondaryDay = scenario.days[main + 1]
        func input() -> AllocationInput {
            AllocationInput(
                main: mainDay, secondary: secondaryDay, viewportHeight: scenario.viewportHeight, contentWidth: scenario.contentWidth,
                textScale: scenario.textScale, parameters: scenario.parameters
            )
        }
        let floorTotal = { AdaptiveLayoutEngine.floorAxis(main: mainDay, secondary: secondaryDay, parameters: scenario.parameters, textScale: scenario.textScale) }
        switch variant {
        case .engineTwoDay:
            let layout = AdaptiveLayoutEngine.layout(input())
            let plan = PlannedAxis(
                axis: layout.axis, slots: slotHeights(layout.axis), floorHeight: floorTotal().height, mainLinesHeight: 0, mainRowsHeight: 0,
                secondaryHeight: 0, surroundingsHeight: 0, openGapHeight: 0, taperHeight: 0, readabilityScroll: 0, prepaidScroll: 0, viewportHeight: scenario.viewportHeight
            )
            return StabilityWindow(day: main, plan: plan, layout: layout)
        case .floorOnly:
            let floor = floorTotal()
            var request = input()
            request.fixedAxis = floor
            let plan = PlannedAxis(
                axis: floor, slots: slotHeights(floor), floorHeight: floor.height, mainLinesHeight: 0, mainRowsHeight: 0, secondaryHeight: 0,
                surroundingsHeight: 0, openGapHeight: 0, taperHeight: 0, readabilityScroll: 0, prepaidScroll: 0, viewportHeight: scenario.viewportHeight
            )
            return StabilityWindow(day: main, plan: plan, layout: AdaptiveLayoutEngine.layout(request))
        case .fourDay, .sixDay:
            var stabilizer = tuned
            let radius = variant == .fourDay ? 1 : 2
            stabilizer.before = radius
            stabilizer.after = radius
            let made = StabilizedLayout.make(
                days: Array(scenario.days[(main - radius)...(main + 1 + radius)]), mainIndex: radius, viewport: scenario.viewportHeight,
                contentWidth: scenario.contentWidth, textScale: scenario.textScale, parameters: scenario.parameters, stabilizer: stabilizer,
                cache: cache ?? AxisDemandCache()
            )
            return StabilityWindow(day: main, plan: made.plan, layout: made.layout)
        }
    }

    static func compare(
        _ scenario: AxisStabilityScenario, variant: AxisVariant, cache: AxisDemandCache? = nil, parameters: AxisStabilizerParameters = .fourDay
    ) -> AxisVariantReport {
        var report = AxisVariantReport(variant: variant)
        let clock = ContinuousClock()
        var planned: [StabilityWindow] = []
        let elapsed = clock.measure { planned = windows(scenario, variant: variant, cache: cache, parameters: parameters) }
        report.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        report.windows = planned.map { window in
            AxisWindowCost(
                height: window.plan.height, requiredScroll: window.plan.requiredScroll, stabilizationScroll: window.plan.stabilizationScroll,
                readabilityScroll: window.plan.readabilityScroll, prepaidScroll: window.plan.prepaidScroll,
                mainEventsWithRows: window.layout.events.filter { $0.key.role == .main && $0.level != .title }.count,
                mainSeparateLines: window.layout.lines.filter { $0.role == .main }.count
            )
        }
        for (first, second) in zip(planned, planned.dropFirst()) where second.day == first.day + 1 {
            report.transitions.append(transition(from: first, to: second))
        }
        return report
    }

    static func transition(from first: StabilityWindow, to second: StabilityWindow) -> AxisTransitionMetrics {
        let deltas = zip(first.plan.slots, second.plan.slots).map { abs($0 - $1) }
        var shifts: [CGFloat] = []
        var minute = 0
        while minute <= 24 * 60 {
            shifts.append(abs(first.layout.axis.y(minute: minute) - second.layout.axis.y(minute: minute)))
            minute += AxisStabilizer.slotMinutes
        }
        return AxisTransitionMetrics(
            maxSlotDelta: deltas.max() ?? 0, meanSlotDelta: deltas.reduce(0, +) / CGFloat(max(1, deltas.count)),
            maxYShift: shifts.max() ?? 0, meanYShift: shifts.reduce(0, +) / CGFloat(max(1, shifts.count)),
            heightDelta: abs(first.layout.axis.height - second.layout.axis.height),
            levelChanges: formChanges(from: first.layout, role: .secondary, to: second.layout, role: .main)
        )
    }

    /// How many items of the day on screen in both layouts (secondary in the first, main in the second) are shown in another form:
    /// an event at another level, a transaction a line of its own in one and part of an overflow in the other.
    static func formChanges(from first: AdaptiveLayout, role firstRole: DayRole, to second: AdaptiveLayout, role secondRole: DayRole) -> Int {
        func levels(_ layout: AdaptiveLayout, _ role: DayRole) -> [String: EventLevel] {
            Dictionary(uniqueKeysWithValues: layout.events.filter { $0.key.role == role }.map { ($0.id, $0.level) })
        }
        func separate(_ layout: AdaptiveLayout, _ role: DayRole) -> Set<String> { Set(layout.lines.filter { $0.role == role }.map(\.transactionID)) }
        let a = levels(first, firstRole), b = levels(second, secondRole)
        var changes = a.keys.filter { a[$0] != b[$0] }.count
        changes += separate(first, firstRole).symmetricDifference(separate(second, secondRole)).count
        return changes
    }
}
