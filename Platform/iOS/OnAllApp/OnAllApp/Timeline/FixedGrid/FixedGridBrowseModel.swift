import CoreGraphics
import QuartzCore
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
            layout = BrowseProbe.measure(.engine) { AdaptiveLayoutEngine.layout(input) }
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
        /// The planned partition the engine ran on.
        let partition: TemporalGridPartition
        let decision: Decision
    }
    private var environmentKey: FixedGridEnvironment?
    private var partitions: [Int: PartitionEntry] = [:]
    /// The partition last handed out for each window (planned, held or mid-transition): what is on screen for it now.
    private var shown: [Int: TemporalGridPartition] = [:]
    /// A window's partition easing from what was on screen to its new plan (a day arrived, or a day's data changed).
    private struct Transition { let from: TemporalGridPartition; let began: CFTimeInterval }
    private var transitions: [Int: Transition] = [:]
    /// How long a window's partition takes to ease to a new plan.
    static let transitionDuration: CFTimeInterval = 0.3
    /// The clock transitions run on (tests set it).
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }
    private var decisions: [LayoutKey: LayoutEntry] = [:]
    private var inflight: Set<Int> = []
    private var titleWidthCache: [String: CGFloat] = [:]
    /// Partitions planned off the main thread, partitions a frame had to plan itself because none was ready, and layout engine runs. For tests and diagnostics.
    private(set) var backgroundPlans = 0
    private(set) var framePlans = 0
    private(set) var continuousLayoutRuns = 0
    private(set) var partitionHits = 0
    /// Partitions handed out without planning because a day of the window was not read yet (the window's last one, a neighbour's, or the even one).
    private(set) var heldPartitions = 0
    /// Transitions begun from what was on screen to a new plan.
    private(set) var transitionsBegun = 0

    /// The zoom a layout is decided at: a quarter of a unit is the same decision, so a pinch that ends near where it was needs no new run.
    static func zoomKey(_ zoom: CGFloat) -> Int { Int((zoom * 4).rounded()) }

    /// The zoom a frame's decisions are for: where an easing pinch comes to rest while it eases back inside 1 … 8× (its frames pass through other keys, and
    /// none of them is a zoom anyone will rest at), the zoom itself otherwise. Held to 1 … 8×.
    func plannedZoomKey(current: CGFloat, settling: CGFloat?) -> Int {
        Self.zoomKey(ProbeExperiment.legacyZoomKey ? current : PinchZoomMath.clamped(settling ?? current))
    }

    /// Where everything of a day goes under one decision, on the shared axis: what the screen draws and touches, and what the tests check.
    func renderPlan(
        _ timeline: DayTimeline, source: FixedGridColumns.Source, decision: Decision, partition: TemporalGridPartition, zone: DisplayTimeZone,
        layoutWidth: CGFloat, textScale: CGFloat, metrics: EventPresentation.Metrics?, preparations: DayPlanPreparations
    ) -> DayRenderPlan {
        DayRenderPlan(
            prepared: preparations.prepared(timeline: timeline, role: source.role, layout: decision.layout),
            geometry: axis(for: timeline.day, partition: partition, zone: zone), layoutWidth: layoutWidth, textScale: textScale,
            metrics: metrics, titleWidth: { decision.titleWidths[$0] ?? DayContentLayout.estimatedTitleWidth($0, extra: 14) }
        )
    }

    /// Engine runs a frame asked for (a decision missing when it was drawn), as against those made between frames by the planning ahead.
    private(set) var drawingEngineRuns = 0

    private func days(of window: Int, inputs: Inputs) -> [DayTimeline?] {
        (-1...2).map { inputs.timelineFor(LocalDate(daysSinceUnixEpoch: window + $0)) }
    }

    private func reset(for environment: FixedGridEnvironment) {
        guard environmentKey != environment else { return }
        environmentKey = environment
        partitions = [:]
        decisions = [:]
        inflight = []
        shown = [:]
        transitions = [:]
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

    /// The partition of a window as it is drawn now:
    /// - the planned one (easing to it from what was on screen, for `transitionDuration`, when it replaced something else);
    /// - while a day of the window is not read yet: **nothing is planned** (a plan of an unread day as an empty one would be thrown away when the day lands, and
    ///   the axis would jump twice). What was on screen for the window is held, or a neighbour's plan, or the even partition when there is nothing yet;
    /// - only when every day is read and no plan is ready (a swipe that outran the planning ahead, or a changed day): one planned here.
    func partition(window: Int, inputs: Inputs) -> TemporalGridPartition {
        let result: TemporalGridPartition
        if let planned = plannedPartition(window: window, inputs: inputs) {
            result = easing(window: window, to: planned)
        } else {
            let timelines = days(of: window, inputs: inputs)
            if timelines.contains(where: { $0 == nil }) {
                heldPartitions += 1
                result = held(window: window, inputs: inputs)
            } else {
                framePlans += 1
                let plan = BrowseProbe.measure(.framePlan) {
                    TemporalGridPlanner.plan(
                        profiles: allocationDays(of: window, timelines: timelines, zone: inputs.zone).map { TemporalDemandProfile.make($0, parameters: parameters(inputs.environment)) },
                        mainIndex: 1, parameters: parameters(inputs.environment))
                }
                partitions[window] = PartitionEntry(timelines: timelines, checkedRevision: inputs.revision, partition: plan.partition)
                beginTransition(window: window, to: plan.partition)
                result = easing(window: window, to: plan.partition)
            }
        }
        shown[window] = result
        return result
    }

    /// What a window shows while one of its days is being read: what it showed last, else the nearest window's (planned or shown), else the even partition.
    private func held(window: Int, inputs: Inputs) -> TemporalGridPartition {
        if let last = shown[window] { return last }
        let near = (1...3).lazy.flatMap { [window - $0, window + $0] }.first { self.partitions[$0] != nil || self.shown[$0] != nil }
        if let near, let found = shown[near] ?? partitions[near]?.partition { return found }
        return TemporalGridPartition.uniform(slotCount: Self.parameters.slotCount, totalHeight: inputs.environment.viewportHeight)
    }

    /// A new plan for a window that already had something on screen: ease from that to the plan.
    private func beginTransition(window: Int, to planned: TemporalGridPartition) {
        guard let from = shown[window], from != planned, from.slotCount == planned.slotCount, from.totalHeight == planned.totalHeight else { return }
        transitions[window] = Transition(from: from, began: clock())
        transitionsBegun += 1
        BrowseProbe.mark(.axisTransition)
    }

    private func easing(window: Int, to planned: TemporalGridPartition) -> TemporalGridPartition {
        guard let transition = transitions[window] else { return planned }
        let t = (clock() - transition.began) / Self.transitionDuration
        guard t < 1 else { transitions[window] = nil; return planned }
        let eased = 1 - pow(1 - max(0, t), 3)
        return TemporalGridPartition.interpolated(from: transition.from, to: planned, progress: eased) ?? planned
    }

    /// Whether some window's partition is still easing to a new plan (the screen draws frames until none is).
    var isEasing: Bool {
        let now = clock()
        if let thaw, now - thaw.began < Self.transitionDuration { return true }
        return transitions.values.contains { now - $0.began < Self.transitionDuration }
    }

    // MARK: Edit sessions (freeze / unfreeze)

    /// What an edit session holds still: the shared time partition and the engine's decisions as they were drawn when it began, and the data they were made
    /// from (`baseline`, for telling what changed outside meanwhile). While frozen, days are still read, the cache still changes and the planning ahead still
    /// plans (the partitions it makes wait for the end of the session); only what is drawn stays.
    struct Freeze {
        let id: Int
        let position: Double
        /// Unzoomed, as `shared` returns it.
        let partition: TemporalGridPartition
        let decisions: [Int: Decision]
        let zoomKey: Int
        let baseline: FixedGridEditBaseline
    }
    private(set) var frozen: Freeze?
    private var freezes = 0
    /// After a session: what was drawn during it, easing into what is planned now (the partition), and the decisions it drew with (the screen crossfades
    /// them to the new ones over the same time).
    private struct Thaw { let partition: TemporalGridPartition; let decisions: [Int: Decision]; let began: CFTimeInterval }
    private var thaw: Thaw?

    /// Begins an edit session at `position` (at rest), with the decisions for `zoomKey` of the windows `windows` drawn now. Returns the session's id; a session
    /// already open is returned as it is (one at a time).
    @discardableResult
    func freeze(position: Double, bounds: ClosedRange<Int>, windows: Set<Int>, zoomKey: Int, inputs: Inputs, baseline: FixedGridEditBaseline) -> Int {
        if let frozen { return frozen.id }
        let partition = shared(position: position, bounds: bounds, inputs: inputs)
        var decisions: [Int: Decision] = [:]
        for window in windows { decisions[window] = decisionForDrawing(window: window, zoomKey: zoomKey, isInteracting: false, inputs: inputs) }
        freezes += 1
        thaw = nil
        frozen = Freeze(id: freezes, position: position, partition: partition, decisions: decisions, zoomKey: zoomKey, baseline: baseline)
        return freezes
    }

    /// Ends the session `id`: what is drawn eases from the frozen partition to the one planned now, over `transitionDuration` (no jump), and the decisions
    /// pass from the frozen ones to the current ones over the same time (`thawing`).
    func unfreeze(_ id: Int) {
        guard let frozen, frozen.id == id else { return }
        thaw = Thaw(partition: frozen.partition, decisions: frozen.decisions, began: clock())
        self.frozen = nil
    }

    /// The session `id` moves to another event on the same frozen grid (nothing drawn changes): the original keeps the session's start (generation, revision,
    /// days) and takes the new target as it was in those days when they hold it, else as it is now.
    func retarget(_ id: Int, target: (day: LocalDate, block: EventBlock)?) {
        guard let old = frozen, old.id == id else { return }
        let baseline = old.baseline
        let original = target.map { target in (target.day, baseline.days[target.day]?.blocks.first { $0.eventKey == target.block.eventKey } ?? target.block) }
        frozen = Freeze(
            id: old.id, position: old.position, partition: old.partition, decisions: old.decisions, zoomKey: old.zoomKey,
            baseline: FixedGridEditBaseline(dataGeneration: baseline.dataGeneration, dataRevision: baseline.dataRevision, days: baseline.days, target: original)
        )
    }

    /// While a session's end eases in: the decision a window was drawn with during the session, and how far (0 … 1) the new one has come.
    func thawing(window: Int) -> (decision: Decision, weight: Double)? {
        guard let thaw, let decision = thaw.decisions[window] else { return nil }
        let t = (clock() - thaw.began) / Self.transitionDuration
        guard t < 1 else { return nil }
        return (decision, 1 - pow(1 - max(0, t), 3))
    }

    private func frozenPartition(_ frozen: Freeze, inputs: Inputs) -> TemporalGridPartition {
        // The same times in the same cells; only the height follows the room (a rotation during a session).
        guard frozen.partition.totalHeight != inputs.environment.viewportHeight, inputs.environment.viewportHeight > 1 else { return frozen.partition }
        return TemporalGridPartition(boundaries: frozen.partition.boundaries, totalHeight: inputs.environment.viewportHeight) ?? frozen.partition
    }

    /// The shared time partition at a position: the blend of the two planned windows around it (`ContinuousDayAxis`).
    /// Only the windows it used keep what they showed: a window the days have left is not on screen, so a later plan for it has nothing to ease from.
    /// During an edit session it is the frozen partition, whatever the data does; at a session's end it eases from that to this.
    func shared(position: Double, bounds: ClosedRange<Int>, inputs: Inputs) -> TemporalGridPartition {
        if let frozen { return frozenPartition(frozen, inputs: inputs) }
        var used: Set<Int> = []
        var result = ContinuousDayAxis.partition(at: position, bounds: bounds) { used.insert($0); return partition(window: $0, inputs: inputs) }
        if shown.count > used.count { shown = shown.filter { used.contains($0.key) } }
        if let thaw {
            let t = (clock() - thaw.began) / Self.transitionDuration
            if t >= 1 { self.thaw = nil }
            else { result = TemporalGridPartition.interpolated(from: thaw.partition, to: result, progress: 1 - pow(1 - max(0, t), 3)) ?? result }
        }
        return result
    }

    /// Plans the windows that are not planned yet, off the main thread, nearest first, and calls `ready` after each so the screen can draw with it. A frame never waits for this.
    func warm(windows: [Int], inputs: Inputs, ready: @escaping @MainActor () -> Void) {
        reset(for: inputs.environment)
        for window in windows where plannedPartition(window: window, inputs: inputs) == nil && !inflight.contains(window) {
            let timelines = days(of: window, inputs: inputs)
            // A window with a day not read yet is not planned: the plan would be of an empty day. It is planned when the day lands (the data revision changes).
            guard !timelines.contains(where: { $0 == nil }) else { continue }
            inflight.insert(window)
            let allocation = allocationDays(of: window, timelines: timelines, zone: inputs.zone)
            let parameters = parameters(inputs.environment)
            let environment = inputs.environment
            let revision = inputs.revision
            Task.detached(priority: .userInitiated) { [weak self] in
                let profiles = allocation.map { TemporalDemandProfile.make($0, parameters: parameters) }
                let plan = TemporalGridPlanner.plan(profiles: profiles, mainIndex: 1, parameters: parameters)
                await MainActor.run {
                    guard let self else { return }
                    BrowseProbe.measure(.warmLand) {
                        self.inflight.remove(window)
                        guard self.environmentKey == environment else { return }
                        self.backgroundPlans += 1
                        self.partitions[window] = PartitionEntry(timelines: timelines, checkedRevision: revision, partition: plan.partition)
                        self.beginTransition(window: window, to: plan.partition)
                    }
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
    ///
    /// The engine runs only on the window's planned partition (never on a held or easing one). While a day of the window is being read the last decision made
    /// for the window is kept, or, with none, the days are drawn without the engine (`nil` layout).
    func decision(window: Int, zoomKey: Int, inputs: Inputs) -> Decision {
        _ = partition(window: window, inputs: inputs)
        let key = LayoutKey(window: window, zoomKey: zoomKey)
        let timelines = days(of: window, inputs: inputs)
        guard let partition = partitions[window]?.partition, !timelines.contains(where: { $0 == nil }) else {
            if let kept = decisions[key] ?? decisions.filter({ $0.key.window == window }).min(by: { abs($0.key.zoomKey - zoomKey) < abs($1.key.zoomKey - zoomKey) })?.value {
                return kept.decision
            }
            var widths: [String: CGFloat] = [:]
            for timeline in timelines { for block in timeline?.blocks ?? [] { widths[block.title] = titleWidth(block.title) } }
            return Decision(layout: nil, titleWidths: widths)
        }
        let main = timelines[1], secondary = timelines[2]
        if let found = decisions[key], found.partition == partition {
            let unchanged = found.timelines[1] == main && found.timelines[2] == secondary
            if found.checkedRevision == inputs.revision || unchanged {
                if found.checkedRevision != inputs.revision { decisions[key] = LayoutEntry(timelines: found.timelines, checkedRevision: inputs.revision, partition: partition, decision: found.decision) }
                return found.decision
            }
        }
        var widths: [String: CGFloat] = [:]
        for timeline in timelines { for block in timeline?.blocks ?? [] { widths[block.title] = titleWidth(block.title) } }
        let layout = runEngine(main: main, secondary: secondary, partition: partition, zoomKey: zoomKey, widths: widths, environment: inputs.environment)
        let made = Decision(layout: layout, titleWidths: widths)
        decisions[key] = LayoutEntry(timelines: timelines, checkedRevision: inputs.revision, partition: partition, decision: made)
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
        return BrowseProbe.measure(.engine) { AdaptiveLayoutEngine.layout(input) }
    }

    /// Whether a decision for this window and zoom is already made.
    func hasDecision(window: Int, zoomKey: Int) -> Bool {
        guard let found = decisions[LayoutKey(window: window, zoomKey: zoomKey)] else { return false }
        return partitions[window].map { $0.partition == found.partition } ?? true
    }

    /// The decision to draw with: the one for `zoomKey`, or, while a pinch has the zoom moving, the nearest one made already for this window (a pinch frame never runs the engine).
    func decisionForDrawing(window: Int, zoomKey: Int, isInteracting: Bool, inputs: Inputs) -> Decision {
        if let frozen { return frozen.decisions[window] ?? Decision(layout: nil, titleWidths: [:]) }      // the session's, whatever the zoom or the data
        if isInteracting, !hasDecision(window: window, zoomKey: zoomKey) {
            let near = decisions.filter { $0.key.window == window }.min { abs($0.key.zoomKey - zoomKey) < abs($1.key.zoomKey - zoomKey) }
            if let near { return near.value.decision }
        }
        let runs = continuousLayoutRuns
        defer { drawingEngineRuns += continuousLayoutRuns - runs }
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
