import CoreGraphics
import NEOBudgetCalendar

/// How an axis planner is compared with another over a run of days, and what the comparison measures. Pure: the same days give the same
/// numbers, except for the timings, which are measured separately and never take part in a comparison of axes.
enum AxisVariant: String, CaseIterable, Sendable {
    /// The engine as it is: the axis of its own layout for the two visible days.
    case engineTwoDay = "2일(기존)"
    /// Only what the two visible days cannot do without: the floor (no stability, no detail). A lower bound, not a candidate.
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
}

/// What changed between two neighbouring windows (D and D+1), and what the planned axis cost.
struct AxisTransitionMetrics: Equatable {
    /// Largest and mean change of a quarter hour's height, in points.
    var maxSlotDelta: CGFloat
    var meanSlotDelta: CGFloat
    /// Largest and mean change of where the same time is drawn (from the top of the day), sampled every quarter hour.
    var maxYShift: CGFloat
    var meanYShift: CGFloat
    var heightDelta: CGFloat
    /// Items of the day that is on screen in both windows whose form differs (events at another level, transaction lines merged or not).
    var levelChanges: Int
}

struct AxisWindowCost: Equatable {
    var height: CGFloat
    var requiredScroll: CGFloat
    var stabilizationScroll: CGFloat
}

struct AxisVariantReport {
    let variant: AxisVariant
    var transitions: [AxisTransitionMetrics] = []
    var windows: [AxisWindowCost] = []
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

    private func average(_ values: [CGFloat]) -> CGFloat { values.isEmpty ? 0 : values.reduce(0, +) / CGFloat(values.count) }
}

enum AxisStability {
    /// The planned axis of every window D (visible days D and D+1) the scenario has the days around for, per variant.
    /// The windows every variant can be planned for, so that all variants are compared over the same moves.
    static func commonRange(_ scenario: AxisStabilityScenario) -> Range<Int> { 2..<max(2, scenario.days.count - 3) }

    static func windows(
        _ scenario: AxisStabilityScenario, variant: AxisVariant, cache: AxisDemandCache? = nil, parameters: AxisStabilizerParameters = .fourDay
    ) -> [(day: Int, axis: PlannedAxis)] {
        let radius: (before: Int, after: Int)
        switch variant {
        case .engineTwoDay, .floorOnly: radius = (0, 0)
        case .fourDay: radius = (1, 1)
        case .sixDay: radius = (2, 2)
        }
        var result: [(Int, PlannedAxis)] = []
        for day in commonRange(scenario) {
            result.append((day, planWindow(scenario, main: day, variant: variant, radius: radius, cache: cache, parameters: parameters)))
        }
        return result
    }

    static func planWindow(
        _ scenario: AxisStabilityScenario, main: Int, variant: AxisVariant, radius: (before: Int, after: Int), cache: AxisDemandCache?,
        parameters tuned: AxisStabilizerParameters = .fourDay
    ) -> PlannedAxis {
        let mainDay = scenario.days[main], secondaryDay = scenario.days[main + 1]
        if variant == .engineTwoDay {
            let input = AllocationInput(
                main: mainDay, secondary: secondaryDay, viewportHeight: scenario.viewportHeight, contentWidth: 300,
                textScale: scenario.textScale, parameters: scenario.parameters
            )
            let axis = AdaptiveLayoutEngine.layout(input).axis
            let floorTotal = AdaptiveLayoutEngine.floorAxis(main: mainDay, secondary: secondaryDay, parameters: scenario.parameters, textScale: scenario.textScale).height
            return PlannedAxis(
                axis: axis, slots: slotHeights(axis), floorHeight: floorTotal, mainDetailHeight: 0, secondaryDetailHeight: 0,
                stabilizerHeight: 0, viewportHeight: scenario.viewportHeight
            )
        }
        let cache = cache ?? AxisDemandCache()
        let indices = (main - radius.before)...(main + 1 + radius.after)
        let profiles = indices.map { cache.profile(for: scenario.days[$0], parameters: scenario.parameters, textScale: scenario.textScale) }
        let mainIndex = radius.before
        let floor = cache.floor(
            main: profiles[mainIndex], secondary: profiles[mainIndex + 1], mainDay: mainDay, secondaryDay: secondaryDay,
            parameters: scenario.parameters, textScale: scenario.textScale
        )
        if variant == .floorOnly {
            return PlannedAxis(
                axis: AxisStabilizer.axis(fromSlots: floor, floor: floor), slots: floor, floorHeight: floor.reduce(0, +), mainDetailHeight: 0,
                secondaryDetailHeight: 0, stabilizerHeight: 0, viewportHeight: scenario.viewportHeight
            )
        }
        var parameters = tuned
        parameters.before = radius.before
        parameters.after = radius.after
        return AxisStabilizer.plan(window: profiles, mainIndex: mainIndex, floor: floor, viewport: scenario.viewportHeight, parameters: parameters)
    }

    static func compare(_ scenario: AxisStabilityScenario, variant: AxisVariant, cache: AxisDemandCache? = nil, parameters: AxisStabilizerParameters = .fourDay) -> AxisVariantReport {
        var report = AxisVariantReport(variant: variant)
        let clock = ContinuousClock()
        var planned: [(day: Int, axis: PlannedAxis)] = []
        let elapsed = clock.measure { planned = windows(scenario, variant: variant, cache: cache, parameters: parameters) }
        report.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        report.windows = planned.map { AxisWindowCost(height: $0.axis.height, requiredScroll: $0.axis.requiredScroll, stabilizationScroll: $0.axis.stabilizationScroll) }
        for (first, second) in zip(planned, planned.dropFirst()) where second.day == first.day + 1 {
            report.transitions.append(transition(from: first, to: second, scenario: scenario))
        }
        return report
    }

    static func transition(
        from first: (day: Int, axis: PlannedAxis), to second: (day: Int, axis: PlannedAxis), scenario: AxisStabilityScenario
    ) -> AxisTransitionMetrics {
        let deltas = zip(first.axis.slots, second.axis.slots).map { abs($0 - $1) }
        var shifts: [CGFloat] = []
        var minute = 0
        while minute <= 24 * 60 {
            shifts.append(abs(first.axis.axis.y(minute: minute) - second.axis.axis.y(minute: minute)))
            minute += AxisStabilizer.slotMinutes
        }
        let shared = scenario.days[second.day]                    // on screen in both windows (secondary in the first, main in the second)
        let heights = AdaptiveLayoutEngine.demandHeights(of: shared, parameters: scenario.parameters, textScale: scenario.textScale)
        let before = form(of: shared, heights: heights, axis: first.axis.axis)
        let after = form(of: shared, heights: heights, axis: second.axis.axis)
        let changes = before.keys.filter { before[$0] != after[$0] }.count
        return AxisTransitionMetrics(
            maxSlotDelta: deltas.max() ?? 0, meanSlotDelta: deltas.reduce(0, +) / CGFloat(max(1, deltas.count)),
            maxYShift: shifts.max() ?? 0, meanYShift: shifts.reduce(0, +) / CGFloat(max(1, shifts.count)),
            heightDelta: abs(first.axis.height - second.axis.height), levelChanges: changes
        )
    }

    /// The form each item of a day takes on an axis: an event's level (the highest whose height its minutes have), a transaction pair's
    /// merged or kept apart. Judged by the height the axis gives, with no budget: the same rule for every variant.
    static func form(of day: AllocationDay, heights: AdaptiveLayoutEngine.DemandHeights, axis: TimelineAxis) -> [String: Int] {
        var result: [String: Int] = [:]
        for event in day.events {
            guard let needs = heights.events[event.id] else { continue }
            let room = axis.y(minute: event.effectiveEnd) - axis.y(minute: event.startMinute)
            result["e:" + event.id] = room + 0.5 >= needs.full ? 2 : room + 0.5 >= needs.preview ? 1 : 0
        }
        for link in heights.mergeableLinks {
            let room = axis.y(minute: link.second) - axis.y(minute: link.first)
            result["l:" + link.key] = room + 0.5 >= heights.pitch ? 1 : 0
        }
        return result
    }
}
