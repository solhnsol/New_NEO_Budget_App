import CoreGraphics
import NEOBudgetCalendar

/// What the fixed grid is drawn in: the room, the text size. The same four numbers always give the same window.
struct FixedGridEnvironment: Equatable {
    var viewportHeight: CGFloat
    var contentWidth: CGFloat
    var textScale: CGFloat
    /// Identifies the Dynamic Type setting the title widths were measured at.
    var contentSize: String = ""
}

/// The decisions for the two days on screen (and the ones around them), made once for as long as the days and the environment stay the same: the partition of
/// the day into equal-height cells, and the engine's layout on that partition.
struct FixedGridWindow {
    let partition: TemporalGridPartition
    /// `nil` while a day on screen is waiting to be read, and when one of them has a daylight-saving transition (see `WallClockProjection`): such days are drawn
    /// from their own data and the axis, without the engine's decisions.
    let layout: AdaptiveLayout?
    let titleWidths: [String: CGFloat]
}

/// Plans the fixed grid for Browse's four days (D-1 ... D+2) and keeps the result until a day or the environment changes. A scroll, a swipe or a redraw finds it
/// there; the planner (the dynamic programme) and the layout engine run only when something they read has changed, never per frame. Not thread-safe: it lives with
/// the view that draws.
@MainActor
final class FixedGridBrowseModel {
    static let parameters = TemporalGridParameters.hourly(slotCount: 12)

    let store = TemporalGridStore()
    /// How many windows were decided, and how many times the layout engine ran. For tests and diagnostics.
    private(set) var windowRuns = 0
    private(set) var layoutRuns = 0
    private(set) var windowHits = 0
    var measureTitle: (String) -> CGFloat = { TextMeasurer.titleWidth($0) }

    private struct Key: Equatable {
        let days: [LocalDate]
        let timelines: [DayTimeline?]
        let environment: FixedGridEnvironment
    }
    private var key: Key?
    private var cached: FixedGridWindow?
    private var projections: [LocalDate: WallClockProjection] = [:]

    func projection(for day: LocalDate, zone: DisplayTimeZone) -> WallClockProjection {
        if let found = projections[day] { return found }
        if projections.count > 16 { projections.removeAll() }
        let made = WallClockProjection(day: day, zone: zone)
        projections[day] = made
        return made
    }

    /// The axis a day is drawn on: the partition's, seen in the day's own (elapsed) minutes.
    func axis(for day: LocalDate, partition: TemporalGridPartition, zone: DisplayTimeZone) -> ElapsedMinuteAxisMapping {
        ElapsedMinuteAxisMapping(inner: TemporalAxisMapping(partition: partition), projection: projection(for: day, zone: zone))
    }

    /// `strip` is the model's strip: D-1, D, D+1, D+2 (more only during a far jump, which is not part of the window).
    func window(strip: [StripDay], zone: DisplayTimeZone, environment: FixedGridEnvironment) -> FixedGridWindow? {
        let four = Array(strip.prefix(4))
        guard four.count == 4, environment.viewportHeight > 1 else { return nil }
        let newKey = Key(days: four.map(\.day), timelines: four.map(\.timeline), environment: environment)
        if newKey == key, let cached { windowHits += 1; return cached }
        windowRuns += 1

        let days = four.map { entry -> AllocationDay in
            guard let timeline = entry.timeline else { return AllocationDay(day: entry.day, totalMinutes: 1440, events: [], transactions: []) }
            return projection(for: entry.day, zone: zone).projected(AllocationDay(timeline))
        }
        var parameters = Self.parameters
        parameters.viewportHeight = environment.viewportHeight
        parameters.textScale = environment.textScale
        let partition = store.plan(window: TemporalWindow(days: days, mainIndex: 1), parameters: parameters).partition

        var layout: AdaptiveLayout?
        var widths: [String: CGFloat] = [:]
        if let main = four[1].timeline, let secondary = four[2].timeline, main.totalMinutes == 1440, secondary.totalMinutes == 1440 {
            var input = AllocationInput(
                main: AllocationDay(main), secondary: AllocationDay(secondary),
                viewportHeight: environment.viewportHeight, contentWidth: environment.contentWidth, textScale: environment.textScale
            )
            for timeline in [main, secondary] { for block in timeline.blocks { input.titleWidths[block.title] = measureTitle(block.title) } }
            input.fixedAxis = partition.timelineAxis().axis
            widths = input.titleWidths
            layout = AdaptiveLayoutEngine.layout(input)
            layoutRuns += 1
        } else {
            for entry in four { for block in entry.timeline?.blocks ?? [] { widths[block.title] = measureTitle(block.title) } }
        }
        let made = FixedGridWindow(partition: partition, layout: layout, titleWidths: widths)
        key = newKey
        cached = made
        return made
    }

    // MARK: Continuous planning (swipe and zoom)

    /// What a window is planned from: the kept days, as they are now.
    struct Inputs {
        let zone: DisplayTimeZone
        let environment: FixedGridEnvironment
        let timelineFor: (LocalDate) -> DayTimeline?
        let revision: Int
    }

    /// The engine's decisions for one window at one zoom, with the widths its titles were measured at.
    struct Decision {
        let layout: AdaptiveLayout?
        let titleWidths: [String: CGFloat]
    }

    private struct PartitionEntry {
        let timelines: [DayTimeline?]
        var checkedRevision: Int
        let partition: TemporalGridPartition
    }
    private struct LayoutKey: Hashable { let window: Int; let zoomKey: Int }
    private struct LayoutEntry {
        let timelines: [DayTimeline?]
        var checkedRevision: Int
        let decision: Decision
    }
    private var environmentKey: FixedGridEnvironment?
    private var partitions: [Int: PartitionEntry] = [:]
    private var decisions: [LayoutKey: LayoutEntry] = [:]
    private var inflight: Set<Int> = []
    private var titleWidthCache: [String: CGFloat] = [:]
    /// Partitions planned off the main thread, partitions a frame had to plan itself because none was ready, and layout engine runs. For tests and diagnostics.
    private(set) var backgroundPlans = 0
    private(set) var framePlans = 0
    private(set) var continuousLayoutRuns = 0
    private(set) var partitionHits = 0

    /// The zoom a layout is decided at: a quarter of a unit is the same decision, so a pinch that ends near where it was needs no new run.
    static func zoomKey(_ zoom: CGFloat) -> Int { Int((zoom * 4).rounded()) }

    private func days(of window: Int, inputs: Inputs) -> [DayTimeline?] {
        (-1...2).map { inputs.timelineFor(LocalDate(daysSinceUnixEpoch: window + $0)) }
    }

    private func reset(for environment: FixedGridEnvironment) {
        guard environmentKey != environment else { return }
        environmentKey = environment
        partitions = [:]
        decisions = [:]
        inflight = []
        if titleWidthCache.count > 400 || environmentKey?.contentSize != environment.contentSize { titleWidthCache = [:] }
    }

    private func allocationDays(of window: Int, timelines: [DayTimeline?], zone: DisplayTimeZone) -> [AllocationDay] {
        timelines.enumerated().map { index, timeline in
            let day = LocalDate(daysSinceUnixEpoch: window + index - 1)
            guard let timeline else { return AllocationDay(day: day, totalMinutes: 1440, events: [], transactions: []) }
            return projection(for: day, zone: zone).projected(AllocationDay(timeline))
        }
    }

    private func parameters(_ environment: FixedGridEnvironment) -> TemporalGridParameters {
        var parameters = Self.parameters
        parameters.viewportHeight = environment.viewportHeight
        parameters.textScale = environment.textScale
        return parameters
    }

    /// Whether what an entry was made from is still what the kept days are. Compares the days themselves only when they have changed since it last looked.
    private func isCurrent(_ timelines: [DayTimeline?], checkedRevision: inout Int, window: Int, inputs: Inputs) -> Bool {
        if checkedRevision == inputs.revision { return true }
        guard days(of: window, inputs: inputs) == timelines else { return false }
        checkedRevision = inputs.revision
        return true
    }

    /// The partition planned for the window whose first shown day is `window`, if it has been planned (by `warm` or an earlier frame). Never plans.
    func plannedPartition(window: Int, inputs: Inputs) -> TemporalGridPartition? {
        reset(for: inputs.environment)
        guard var entry = partitions[window] else { return nil }
        guard isCurrent(entry.timelines, checkedRevision: &entry.checkedRevision, window: window, inputs: inputs) else { partitions[window] = nil; return nil }
        partitions[window] = entry
        partitionHits += 1
        return entry.partition
    }

    /// The partition of a window: the planned one, or (only when none is ready, which a swipe that outran the planning ahead can cause) one planned here.
    func partition(window: Int, inputs: Inputs) -> TemporalGridPartition {
        if let planned = plannedPartition(window: window, inputs: inputs) { return planned }
        framePlans += 1
        let timelines = days(of: window, inputs: inputs)
        let plan = TemporalGridPlanner.plan(
            profiles: allocationDays(of: window, timelines: timelines, zone: inputs.zone).map { TemporalDemandProfile.make($0, parameters: parameters(inputs.environment)) },
            mainIndex: 1, parameters: parameters(inputs.environment))
        partitions[window] = PartitionEntry(timelines: timelines, checkedRevision: inputs.revision, partition: plan.partition)
        return plan.partition
    }

    /// The shared time partition at a position: the blend of the two planned windows around it (`ContinuousDayAxis`).
    func shared(position: Double, bounds: ClosedRange<Int>, inputs: Inputs) -> TemporalGridPartition {
        ContinuousDayAxis.partition(at: position, bounds: bounds) { partition(window: $0, inputs: inputs) }
    }

    /// Plans the windows that are not planned yet, off the main thread, nearest first, and calls `ready` after each so the screen can draw with it. A frame never waits for this.
    func warm(windows: [Int], inputs: Inputs, ready: @escaping @MainActor () -> Void) {
        reset(for: inputs.environment)
        for window in windows where plannedPartition(window: window, inputs: inputs) == nil && !inflight.contains(window) {
            inflight.insert(window)
            let timelines = days(of: window, inputs: inputs)
            let allocation = allocationDays(of: window, timelines: timelines, zone: inputs.zone)
            let parameters = parameters(inputs.environment)
            let environment = inputs.environment
            let revision = inputs.revision
            Task.detached(priority: .userInitiated) { [weak self] in
                let profiles = allocation.map { TemporalDemandProfile.make($0, parameters: parameters) }
                let plan = TemporalGridPlanner.plan(profiles: profiles, mainIndex: 1, parameters: parameters)
                await MainActor.run {
                    guard let self else { return }
                    self.inflight.remove(window)
                    guard self.environmentKey == environment else { return }
                    self.backgroundPlans += 1
                    self.partitions[window] = PartitionEntry(timelines: timelines, checkedRevision: revision, partition: plan.partition)
                    ready()
                }
            }
        }
    }

    private func titleWidth(_ title: String) -> CGFloat {
        if let found = titleWidthCache[title] { return found }
        let made = measureTitle(title)
        titleWidthCache[title] = made
        return made
    }

    /// The engine's decisions for the window (`window` is its first shown day) at `zoomKey / 4`× (the cells at that zoom are the axis). `nil` layout for a window
    /// that has a day waiting to be read or one with a daylight-saving change (see `WallClockProjection`).
    func decision(window: Int, zoomKey: Int, inputs: Inputs) -> Decision {
        let partition = partition(window: window, inputs: inputs)
        let key = LayoutKey(window: window, zoomKey: zoomKey)
        let main = inputs.timelineFor(LocalDate(daysSinceUnixEpoch: window))
        let secondary = inputs.timelineFor(LocalDate(daysSinceUnixEpoch: window + 1))
        if let found = decisions[key] {
            let unchanged = found.timelines[1] == main && found.timelines[2] == secondary
            if found.checkedRevision == inputs.revision || unchanged {
                if found.checkedRevision != inputs.revision { decisions[key] = LayoutEntry(timelines: found.timelines, checkedRevision: inputs.revision, decision: found.decision) }
                return found.decision
            }
        }
        let timelines = days(of: window, inputs: inputs)
        var widths: [String: CGFloat] = [:]
        for timeline in timelines { for block in timeline?.blocks ?? [] { widths[block.title] = titleWidth(block.title) } }
        let layout = runEngine(main: main, secondary: secondary, partition: partition, zoomKey: zoomKey, widths: widths, environment: inputs.environment)
        let made = Decision(layout: layout, titleWidths: widths)
        decisions[key] = LayoutEntry(timelines: timelines, checkedRevision: inputs.revision, decision: made)
        if decisions.count > 24 { decisions = decisions.filter { abs($0.key.window - window) <= 3 } }
        return made
    }

    private func runEngine(main: DayTimeline?, secondary: DayTimeline?, partition: TemporalGridPartition, zoomKey: Int, widths: [String: CGFloat], environment: FixedGridEnvironment) -> AdaptiveLayout? {
        guard let main, let secondary, main.totalMinutes == 1440, secondary.totalMinutes == 1440 else { return nil }
        let zoom = CGFloat(zoomKey) / 4
        var input = AllocationInput(
            main: AllocationDay(main), secondary: AllocationDay(secondary),
            viewportHeight: environment.viewportHeight * zoom, contentWidth: environment.contentWidth, textScale: environment.textScale
        )
        input.titleWidths = widths
        input.fixedAxis = partition.zoomed(viewportHeight: environment.viewportHeight, zoomScale: zoom).timelineAxis().axis
        continuousLayoutRuns += 1
        return AdaptiveLayoutEngine.layout(input)
    }

    /// Whether a decision for this window and zoom is already made.
    func hasDecision(window: Int, zoomKey: Int) -> Bool { decisions[LayoutKey(window: window, zoomKey: zoomKey)] != nil }

    /// The decision to draw with: the one for `zoomKey`, or, while a pinch has the zoom moving, the nearest one made already for this window (a pinch frame never runs the engine).
    func decisionForDrawing(window: Int, zoomKey: Int, isInteracting: Bool, inputs: Inputs) -> Decision {
        if isInteracting, !hasDecision(window: window, zoomKey: zoomKey) {
            let near = decisions.filter { $0.key.window == window }.min { abs($0.key.zoomKey - zoomKey) < abs($1.key.zoomKey - zoomKey) }
            if let near { return near.value.decision }
        }
        return decision(window: window, zoomKey: zoomKey, inputs: inputs)
    }
}

/// The rules the fixed grid's day move follows that are not the spring's: how far a release may carry the days from the selected one, which day the week strip shows as
/// pending, and when a touch makes the selected day the day the move has reached. Pure, so they are tested; `DayMoveModel` is the only state machine.
enum FixedGridMove {
    /// The target of a release held to `hop` days from the selected day (a swipe never skips a day, however far the finger had already carried the days).
    static func held(target: Int, selected: Int, hop: Int = DayPrefetchPolicy.browse.maximumHop) -> Int { min(max(target, selected - hop), selected + hop) }

    /// -1, 0 or +1: where the week strip's highlight is while the days move (the nearest day, as a step from the selected one).
    static func pending(position: Double, selected: Int) -> Int { min(max(Int(position.rounded()) - selected, -1), 1) }

    /// By how many days the selected day follows when a new touch takes over a move at `position` (0 when it is still the nearest day).
    static func takeOver(position: Double, selected: Int) -> Int { Int(position.rounded()) - selected }

    /// The days the model's windows run over around a selected day: one before, and two after (what the cache keeps and the planner plans ahead).
    static func bounds(around selected: Int) -> ClosedRange<Int> { (selected - 1)...(selected + 2) }
}
