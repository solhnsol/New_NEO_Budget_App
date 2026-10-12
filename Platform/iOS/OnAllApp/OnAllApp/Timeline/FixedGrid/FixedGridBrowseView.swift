import Combine
import NEOBudgetCalendar
import SwiftUI

/// Browse on the fixed Temporal Grid (`BrowseAxisMode.fixedGrid`). The day is cut into N equal-height cells (hour boundaries) that fit the screen at 1×; what is drawn on
/// it is the product's own: `DayRenderPlan` (prepared once per day and layout, placed on the grid's axis), the same event cards, titles, transaction lines and overflow cards,
/// and the same touch plan. Two things move it:
///
/// - **The days**: a finger drags the day line directly (`DayMoveModel`, `DayAxisGeometry`, `ContinuousDayAxis`: every column and the hour axis use the one time partition
///   that is the blend of the two windows around the position). Letting go flicks to a day or back (the model's spring); a finger that comes down on a moving day line takes it
///   over; the next flick may begin before the last has settled. `AppModel.selectedDay` follows when the line comes to rest, or when a new touch takes over a move that has
///   passed a day.
/// - **The zoom**: a pinch 1×…8× about the fingers' centre (`PinchZoomScrollView`), scrolling and its inertia with it. While the days move on a zoomed view the time at the
///   middle of the screen stays where it is (`AnchorState`).
///
/// Nothing here plans on a gesture frame: the partitions of the windows around the selected day are planned off the main thread when the day, the data or the room change
/// (`FixedGridBrowseModel.warm`), the engine's decisions are made per window and rested zoom, and a frame only blends, scales and places. No timeline editor is involved: nothing
/// is created, moved or resized here, and the screen says so.
struct FixedGridBrowseView: View {
    let model: AppModel
    let today: LocalDate
    let zone: DisplayTimeZone
    let onSelect: (TimelineSelection) -> Void
    /// `AppModel.selectedDay` is to move by this many days (the screen moves it with the days already read and reads what the new window is missing).
    var onMoveDays: (Int) -> Void = { _ in }
    @Binding var pendingDays: Int

    @State private var move: DayMoveModel
    @State private var position: Double
    @State private var pinch = PinchZoomModel()
    @State private var planner = FixedGridBrowseModel()
    @State private var preparations = DayPlanPreparations(limit: 16)
    @State private var anchorState: AnchorState
    @State private var dragStart: Double?
    @State private var ticking = false
    @State private var caughtTarget: Int?
    @State private var lastNeeded: ClosedRange<Int>?
    @State private var choice: TouchChoice?
    @State private var noticeEmphasis = false
    @State private var planningVersion = 0
    @State private var restedZoomKey = 4
    @State private var room = Room()
    /// The room as the screen last heard of it (the `Room` above is for code outside a frame; these make planning ahead start when the room becomes known or changes).
    @State private var knownViewport: CGFloat = 0
    @State private var knownWidth: CGFloat = 0
    /// Bumped while a window's partition eases to a new plan (a day arrived), so the frames of the easing are drawn.
    @State private var axisTick = 0
    @Environment(\.dynamicTypeSize) private var dynamicType

    /// The width the grid has, for the parts that run outside a frame (the spring's ticker, the planning ahead), and what runs between frames.
    final class Room {
        var width: CGFloat = 0
        var easing = false
        /// Reads of a day on screen that failed and were tried again.
        var retries: [LocalDate: Int] = [:]
        var probePath: String?
        var probeWrite: Task<Void, Never>?
    }

    /// What each step of a move cost and how far apart the steps were, in milliseconds (reported by the DEBUG scripts).
    final class Costs {
        var apply: [Double] = []
        var intervals: [Double] = []
        var last: CFAbsoluteTime = 0
        func record(apply ms: Double) {
            apply.append(ms)
            let now = CFAbsoluteTimeGetCurrent()
            if last > 0, now - last < 0.2 { intervals.append((now - last) * 1000) }
            last = now
        }
        func summary(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "—" }
            let sorted = values.sorted()
            return String(format: "mean %.3f / p50 %.3f / p99 %.3f / max %.3f ms (n=%d)", values.reduce(0, +) / Double(values.count), sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))], sorted.last ?? 0, values.count)
        }
    }
    @State private var costs = Costs()

    /// The display link's own interval, for the DEBUG scripts: how long the main thread kept each frame waiting.
    @MainActor final class FrameMeter: NSObject {
        var intervals: [Double] = []
        private var last: CFTimeInterval = 0
        private var link: CADisplayLink?
        func start() { intervals = []; last = 0; let link = CADisplayLink(target: self, selector: #selector(tick(_:))); link.add(to: .main, forMode: .common); self.link = link }
        func stop() { link?.invalidate(); link = nil }
        @objc private func tick(_ link: CADisplayLink) { if last > 0 { intervals.append((link.timestamp - last) * 1000) }; last = link.timestamp }
    }

    private static let gutter: CGFloat = 60
    private static let trailing: CGFloat = 6
    private static let visibleColumns = 2

    init(model: AppModel, today: LocalDate, zone: DisplayTimeZone, onSelect: @escaping (TimelineSelection) -> Void, onMoveDays: @escaping (Int) -> Void, pendingDays: Binding<Int>) {
        self.model = model
        self.today = today
        self.zone = zone
        self.onSelect = onSelect
        self.onMoveDays = onMoveDays
        _pendingDays = pendingDays
        let selected = model.selectedDay.daysSinceUnixEpoch
        _move = State(initialValue: DayMoveModel(day: selected, bounds: FixedGridMove.bounds(around: selected), maximumHop: DayPrefetchPolicy.browse.maximumHop))
        _position = State(initialValue: Double(selected))
        _anchorState = State(initialValue: AnchorState(position: Double(selected)))
    }

    private var selectedEpoch: Int { model.selectedDay.daysSinceUnixEpoch }
    private var textScale: CGFloat { TextMeasurer.textScale() }

    private func geometry(width: CGFloat) -> DayAxisGeometry {
        DayAxisGeometry(dayWidth: (width - Self.gutter) / CGFloat(Self.visibleColumns), visibleColumns: Self.visibleColumns)
    }

    var body: some View {
        let probe = BrowseProbe.begin(.screenBody)
        defer { BrowseProbe.end(probe) }
        _ = (position, planningVersion, model.dataRevision, axisTick)   // this screen re-evaluates when the days move, planning ahead lands, the kept days change or the axis eases
        return GeometryReader { outer in
            VStack(spacing: 0) {
                headerStrip(width: outer.size.width)
                Divider()
                EditingNotice(emphasised: noticeEmphasis)
                grid(width: outer.size.width)
            }
            .onAppear { room.width = outer.size.width; knownWidth = outer.size.width }
            .onChange(of: outer.size.width) { _, width in room.width = width; knownWidth = width }
        }
        .confirmationDialog("무엇을 선택할까요?", isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }), titleVisibility: .visible, presenting: choice) { choice in
            ForEach(choice.options) { option in Button(option.label) { option.action() } }
            Button("취소", role: .cancel) {}
        }
        .task {
            // The days around the selected one and the margin the cache keeps ahead (the screen read only the four it draws).
            let policy = DayPrefetchPolicy.browse
            await model.loadMissing(extra: policy.readAhead, policy: policy.cachePolicy, failsScreen: false)
        }
        .task { await runDebugScript() }
        .task { startProbeIfAsked() }
        .task(id: failedOnScreen) { await retryFailedOnScreen() }
        .task(id: WarmKey(selected: selectedEpoch, revision: model.dataRevision, version: planningVersion, zoomKey: restedZoomKey, viewport: knownViewport, text: "\(dynamicType)", width: knownWidth)) {
            await warmAhead()
        }
        .onReceive(pinch.$viewportHeight.removeDuplicates()) { knownViewport = $0 }
        .onReceive(pinch.$isInteracting.removeDuplicates().filter { !$0 }) { _ in restedZoomKey = FixedGridBrowseModel.zoomKey(pinch.zoom); writeProbeSoon() }
        .onChange(of: model.selectedDay) { _, _ in selectionChangedOutside() }
    }

    private struct WarmKey: Equatable {
        let selected: Int
        let revision: Int
        let version: Int
        let zoomKey: Int
        let viewport: CGFloat
        let text: String
        let width: CGFloat
    }

    // MARK: Header

    /// The day names and all-day events follow the same position: the days around the one the position is in, slid by the fraction.
    private func headerStrip(width: CGFloat) -> some View {
        let first = Int(position.rounded(.down))
        let columnWidth = geometry(width: width).dayWidth
        let strip = (-1...2).map { offset -> StripDay in
            let day = LocalDate(daysSinceUnixEpoch: first + offset)
            return StripDay(day: day, timeline: model.cachedTimeline(for: day))
        }
        return DayHeaderStrip(strip: strip, today: today, swipeOffset: -CGFloat(position - Double(first)) * columnWidth, onSelect: { onSelect(.allDay($0)) })
    }

    // MARK: Grid

    private func inputs(viewport: CGFloat, width: CGFloat) -> FixedGridBrowseModel.Inputs {
        let environment = FixedGridEnvironment(
            viewportHeight: viewport, contentWidth: max(0, geometry(width: width).dayWidth - Self.trailing), textScale: textScale, contentSize: "\(dynamicType)"
        )
        return FixedGridBrowseModel.Inputs(zone: zone, environment: environment, timelineFor: { model.cachedTimeline(for: $0) }, revision: model.dataRevision)
    }

    /// What one frame is drawn from: the shared partition at the position and zoom, and the engine's decisions for the window nearest the position.
    private struct Frame {
        let shown: TemporalGridPartition
        let decision: FixedGridBrowseModel.Decision
        let layoutWindow: Int
    }

    private func frame(zoom: CGFloat, viewport: CGFloat, width: CGFloat) -> Frame {
        let inputs = inputs(viewport: viewport, width: width)
        let bounds = move.bounds
        let shown = planner.shared(position: position, bounds: bounds, inputs: inputs).zoomed(viewportHeight: viewport, zoomScale: zoom)
        let layoutWindow = min(max(Int(position.rounded()), bounds.lowerBound), bounds.upperBound)
        let decision = planner.decisionForDrawing(window: layoutWindow, zoomKey: FixedGridBrowseModel.zoomKey(zoom), isInteracting: pinch.isInteracting, inputs: inputs)
        if planner.isEasing { easeAxis() }
        return Frame(shown: shown, decision: decision, layoutWindow: layoutWindow)
    }

    private func grid(width: CGFloat) -> some View {
        PinchZoomScrollView(model: pinch, onDateDrag: { handleDateDrag($0, width: width) }) { zoom, viewport, window in
            gridContent(width: width, zoom: zoom, viewport: viewport, window: window)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) { loadingMarks(width: width) }
    }

    /// A day on screen that is not kept yet says whether it is being read or could not be read (a kept day with nothing on it is drawn as the empty day it is).
    private func loadingMarks(width: CGFloat) -> some View {
        let geometry = geometry(width: width)
        let missing = geometry.renderedDays(at: position).filter { model.cachedTimeline(for: LocalDate(daysSinceUnixEpoch: $0)) == nil }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(missing), id: \.self) { epoch in
                DayLoadingMark(state: model.loadState(for: LocalDate(daysSinceUnixEpoch: epoch)))
                    .frame(width: geometry.dayWidth)
                    .offset(x: geometry.x(ofDay: Double(epoch), at: position) - Self.gutter, y: 12)
            }
        }
        .frame(width: max(0, width - Self.gutter), height: 56, alignment: .topLeading)
        .clipped()
        .offset(x: Self.gutter)
        .allowsHitTesting(false)
    }

    /// The days on screen whose read failed (tried again a few times, a second apart).
    private var failedOnScreen: [LocalDate] {
        [model.selectedDay, model.selectedDay.adding(days: 1)].filter { model.loadState(for: $0) == .failed }
    }

    private func retryFailedOnScreen() async {
        let days = failedOnScreen.filter { (room.retries[$0] ?? 0) < 3 }
        guard !days.isEmpty else { return }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, move.phase == .resting else { return }
        for day in days { room.retries[day, default: 0] += 1 }
        await model.prefetch(forPosition: Double(selectedEpoch))
    }

    private func gridContent(width: CGFloat, zoom: CGFloat, viewport: CGFloat, window: ClosedRange<CGFloat>) -> AnyView {
        guard viewport > 1, width > Self.gutter else { return AnyView(Color.clear.frame(width: max(width, 1), height: 1)) }
        let frame = frame(zoom: zoom, viewport: viewport, width: width)
        let geometry = geometry(width: width)
        let layoutWidth = Self.gutter + geometry.dayWidth
        let height = frame.shown.totalHeight
        let days = geometry.renderedDays(at: position).filter { model.cachedTimeline(for: LocalDate(daysSinceUnixEpoch: $0)) != nil }
        return AnyView(
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: width, height: height)
                FixedHourAxis(partition: frame.shown, width: width, gutter: Self.gutter, scale: textScale)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(days), id: \.self) { epoch in
                        if let timeline = model.cachedTimeline(for: LocalDate(daysSinceUnixEpoch: epoch)) {
                            dayContent(timeline, epoch: epoch, frame: frame, layoutWidth: layoutWidth, window: window)
                                .frame(width: layoutWidth, height: height, alignment: .topLeading)
                                .offset(x: geometry.x(ofDay: Double(epoch), at: position) - Self.gutter)
                        }
                    }
                }
                .frame(width: max(0, width - Self.gutter), height: height, alignment: .topLeading)
                .clipped()
                .offset(x: Self.gutter)
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { location in handleTap(at: location, width: width, zoom: zoom, viewport: viewport) }
            .onLongPressGesture(minimumDuration: 0.6) { emphasiseNotice() }
        )
    }

    private func role(ofEpoch epoch: Int, layoutWindow: Int) -> DayRole? {
        if epoch == layoutWindow { return .main }
        if epoch == layoutWindow + 1 { return .secondary }
        return nil
    }

    /// Where everything of a day goes, from the day's prepared data and the shared axis. Drawing and touching both use it.
    private func plan(_ timeline: DayTimeline, epoch: Int, frame: Frame, layoutWidth: CGFloat) -> DayRenderPlan {
        DayRenderPlan(
            prepared: preparations.prepared(timeline: timeline, role: role(ofEpoch: epoch, layoutWindow: frame.layoutWindow), layout: frame.decision.layout),
            geometry: planner.axis(for: timeline.day, partition: frame.shown, zone: zone), layoutWidth: layoutWidth, textScale: textScale,
            metrics: TextMeasurer.presentationMetrics(), titleWidth: { frame.decision.titleWidths[$0] ?? DayContentLayout.estimatedTitleWidth($0, extra: 14) }
        )
    }

    private func dayContent(_ timeline: DayTimeline, epoch: Int, frame: Frame, layoutWidth width: CGFloat, window: ClosedRange<CGFloat>) -> some View {
        let plan = plan(timeline, epoch: epoch, frame: frame, layoutWidth: width)
        let axis = planner.axis(for: timeline.day, partition: frame.shown, zone: zone)
        let scale = textScale
        let overlayFrames = plan.lines.filter { $0.reveal > 0 }.map(\.frame) + plan.overflows.map(\.frame)
        let coveringFrames = plan.lines.map(\.frame) + plan.overflows.map(\.frame)
        // Only what reaches the built window (a viewport beyond the screen each side) is made into views; the plan above is for all of it.
        func reaches(_ rect: CGRect) -> Bool { rect.maxY >= window.lowerBound && rect.minY <= window.upperBound }
        let events = plan.events.filter { reaches($0.drawnFrame) || ($0.header.map(reaches) ?? false) }
        return ZStack(alignment: .topLeading) {
            ForEach(events, id: \.block.id) { item in
                FixedBlockCell(item: item, zoneIdentifier: timeline.timeZoneIdentifier, scale: scale, overlays: overlayFrames)
            }
            ForEach(events, id: \.block.id) { item in
                if let header = item.header {
                    EventHeaderView(block: item.block, rect: header, zoneIdentifier: timeline.timeZoneIdentifier)
                } else if item.showsTitleInCard {
                    EventTitleLayer(
                        block: item.block, frame: item.frame, place: item.title, columnRight: axis.gutterWidth + axis.contentWidth(totalWidth: width),
                        scale: scale, zoneIdentifier: timeline.timeZoneIdentifier, presentation: item.presentation,
                        maxTitleWidth: item.titleMaxWidth, startFits: item.startTimeFits,
                        startIsCovered: coveringFrames.contains { $0.intersects(CGRect(x: item.frame.maxX - 48, y: item.frame.minY + 3, width: 48, height: 11)) }
                    )
                }
            }
            ForEach(plan.lines.filter { reaches($0.frame) }, id: \.id) { line in TransactionLineView(item: line, scale: scale, edge: axis.gutterWidth, overEvent: plan.events.contains { $0.frame.intersects(line.frame) }) }
            ForEach(plan.overflows.filter { reaches($0.frame) }, id: \.id) { overflow in OverflowCardView(item: overflow, scale: scale, edge: axis.gutterWidth, overEvent: plan.events.contains { $0.frame.intersects(overflow.frame) }) }
            if timeline.day == today { FixedNowLine(timeline: timeline, axis: axis, width: width) }
        }
    }

    // MARK: Touch

    /// One tap handler for everything of the days, decided by the plan that was drawn. Taps count when the days are at rest (a finger that comes down on a moving day line stops
    /// it instead).
    private func handleTap(at point: CGPoint, width: CGFloat, zoom: CGFloat, viewport: CGFloat) {
        guard move.phase == .resting, point.x >= Self.gutter else { return }
        let geometry = geometry(width: width)
        let frame = frame(zoom: zoom, viewport: viewport, width: width)
        let epoch = Int((position + Double((point.x - Self.gutter) / geometry.dayWidth)).rounded(.down))
        guard let timeline = model.cachedTimeline(for: LocalDate(daysSinceUnixEpoch: epoch)) else { return }
        let local = CGPoint(x: point.x - (geometry.x(ofDay: Double(epoch), at: position) + 0), y: point.y)
        let plan = plan(timeline, epoch: epoch, frame: frame, layoutWidth: Self.gutter + geometry.dayWidth)
        switch plan.hit(at: local) {
        case .nothing: break
        case let .event(id): perform(.event(id), in: timeline, plan: plan)
        case let .line(id): perform(.line(id), in: timeline, plan: plan)
        case let .overflow(id): perform(.overflow(id), in: timeline, plan: plan)
        case let .choose(candidates):
            choice = TouchChoice(options: candidates.map { candidate in
                TouchChoice.Option(id: "\(candidate)", label: FixedGridTouch.label(of: candidate, in: timeline, plan: plan)) { perform(candidate, in: timeline, plan: plan) }
            })
        }
    }

    private func perform(_ candidate: DayRenderPlan.Candidate, in timeline: DayTimeline, plan: DayRenderPlan) {
        if let selection = FixedGridTouch.selection(for: candidate, in: timeline, plan: plan) { onSelect(selection) }
    }

    private func emphasiseNotice() {
        noticeEmphasis = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            noticeEmphasis = false
        }
    }

    // MARK: Moving the days

    /// The swipe is `DayMoveModel`'s `drag`/`release` (days per second); this reads its position back. A finger coming down stops a flight under it at once; a new drag takes over
    /// from the position the flight had reached; nothing is ignored while days are moving.
    private func handleDateDrag(_ phase: DateDragPhase, width: CGFloat) {
        let geometry = geometry(width: width)
        switch phase {
        case .touchDown:
            guard move.phase == .settling else { return }
            caughtTarget = move.target
            move.beginDrag()
            takeOverSelection()
            applyMove()
        case .began:
            BrowseProbe.mark(.dragBegan)
            caughtTarget = nil
            if move.phase != .dragging { move.beginDrag() }
            takeOverSelection()
            dragStart = move.position
        case .changed(let translation):
            if dragStart == nil { dragStart = move.position; if move.phase != .dragging { move.beginDrag() } }
            let raw = geometry.position(startingAt: dragStart ?? move.position, translation: translation)
            move.drag(to: DayPrefetchPolicy.browse.clampedPosition(raw, selected: selectedEpoch))
            applyMove()
        case .ended(let velocity):
            BrowseProbe.mark(.released)
            dragStart = nil
            move.release(velocity: -Double(velocity / geometry.dayWidth))
            holdToHop()
            startTicker()
        case .cancelled:
            dragStart = nil
            move.release(velocity: 0)
            holdToHop()
            startTicker()
        case .touchUp:
            guard let caught = caughtTarget, move.phase == .dragging, dragStart == nil else { return }
            caughtTarget = nil
            move.retarget(to: caught)                       // nothing swiped: the flight goes on to where it was going
            startTicker()
        }
    }

    /// A release carries the days at most `maximumHop` from the selected day (a swipe never skips a day, as in Browse): the model's own limit is from where the finger was, which
    /// may already be a day away.
    private func holdToHop() {
        let target = FixedGridMove.held(target: move.target, selected: selectedEpoch)
        if target != move.target { move.retarget(to: target) }
    }

    /// A new touch on a move that has already passed a day: the selected day is that day now, so the next flick is measured from it (and its days are kept).
    private func takeOverSelection() {
        let delta = FixedGridMove.takeOver(position: move.position, selected: selectedEpoch)
        guard delta != 0 else { return }
        onMoveDays(delta)
        rebase(keeping: move.position)
    }

    /// The model around the selected day, with the days either side the cache keeps; at `position` (dragging) or at rest on the day.
    private func rebase(keeping position: Double?) {
        let selected = selectedEpoch
        var next = DayMoveModel(day: selected, bounds: FixedGridMove.bounds(around: selected), maximumHop: DayPrefetchPolicy.browse.maximumHop)
        if let position { next.beginDrag(); next.drag(to: position) }
        move = next
    }

    /// Show the model's position: the day and fraction the columns and the time blend are drawn at, the week strip's pending day, the days read ahead, and the scroll that keeps
    /// the anchor.
    private func applyMove() {
        let started = CFAbsoluteTimeGetCurrent()
        let probe = BrowseProbe.begin(.applyMove)
        defer { costs.record(apply: (CFAbsoluteTimeGetCurrent() - started) * 1000); BrowseProbe.end(probe) }
        position = move.position
        let pending = FixedGridMove.pending(position: move.position, selected: selectedEpoch)
        if pendingDays != pending {
            BrowseProbe.mark(.boundary)
            pendingDays = pending
            BrowseProbe.measure(.haptics) { Haptics.snap() }
        }
        prefetch()
        holdAnchor()
    }

    /// The scroll that keeps the time at the middle of the screen where it was, on the partition drawn now (the days moving, or the axis easing to a new plan).
    private func holdAnchor() {
        let userMoved = pinch.consumeUserMoved()
        let viewport = pinch.viewportHeight
        guard viewport > 1, room.width > Self.gutter else { anchorState.release(at: move.position); return }
        let inputs = inputs(viewport: viewport, width: room.width)
        let bounds = move.bounds
        let result = anchorState.offset(
            forPosition: move.position, currentOffset: pinch.currentOffset?() ?? 0, userMoved: userMoved, zoom: pinch.zoom, viewport: viewport, focal: viewport / 2,
            partitionAt: { planner.shared(position: $0, bounds: bounds, inputs: inputs) }
        )
        // Not applied while the person has the scroll in hand: the anchor is taken again from where they leave it.
        if pinch.setOffset?(result.offset) == false { anchorState.release(at: move.position) }
    }

    /// Draws the frames of an axis easing to a new plan (a day arrived while it was held), keeping the time at the middle of the screen where it is.
    private func easeAxis() {
        guard !room.easing else { return }
        room.easing = true
        Task { @MainActor in
            defer { room.easing = false }
            repeat {
                try? await Task.sleep(for: .milliseconds(8))
                BrowseProbe.measure(.transitionTick) {
                    axisTick &+= 1
                    if move.phase == .resting { holdAnchor() }
                }
            } while planner.isEasing
        }
    }

    /// The days the position needs are read ahead (`AppModel.prefetch`) whenever what it needs changes, never on every frame.
    private func prefetch() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-browse-temporal-noprefetch") { return }
        #endif
        let target = move.phase == .resting ? nil : move.target
        let needed = DayPrefetchPolicy.neededDays(position: move.position, target: target)
        guard needed != lastNeeded else { return }
        lastNeeded = needed
        let position = move.position
        Task { await model.prefetch(forPosition: position, target: target) }
    }

    /// Advances the spring by real elapsed time, once per display frame, while there is something to settle.
    private func startTicker() {
        guard !ticking else { return }
        ticking = true
        Task { @MainActor in
            let clock = ContinuousClock()
            var last = clock.now
            while move.phase == .settling {
                try? await Task.sleep(for: .milliseconds(8))
                let now = clock.now
                let elapsed = now - last
                last = now
                move.advance(by: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                applyMove()
            }
            ticking = false
            pinch.stopPace?()
            if move.phase == .resting { commit() }
        }
    }

    /// The days have come to rest: the selected day, the week strip and the cache take the day the line is on.
    private func commit() {
        BrowseProbe.mark(.rested)
        writeProbeSoon()
        let day = Int(move.position.rounded())
        if day != selectedEpoch { onMoveDays(day - selectedEpoch) }
        rebase(keeping: nil)
        position = move.position
        if pendingDays != 0 { pendingDays = 0 }
        lastNeeded = nil
        prefetch()
        selectionChangedOutside()
    }

    /// The selected day was changed by something else (the week strip, the header's arrows, "오늘"): the days run to it, or jump when it is far.
    private func selectionChangedOutside() {
        guard move.phase == .resting, Double(selectedEpoch) != move.position else { return }
        let distance = selectedEpoch - Int(move.position.rounded())
        let from = Int(move.position.rounded())
        guard abs(distance) <= 3 else { rebase(keeping: nil); position = move.position; anchorState.release(at: move.position); return }
        let low = min(from, selectedEpoch) - 1, high = max(from, selectedEpoch) + 2
        var next = DayMoveModel(day: from, bounds: low...high, maximumHop: abs(distance))
        next.retarget(to: selectedEpoch)
        move = next
        startTicker()
    }


    // MARK: DEBUG scripts

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `-browse-temporal-zoom <1...8>` starts at that zoom; `-browse-temporal-script zoom|days` plays a short sequence (what a pinch and a run of flicks do, without fingers);
    /// `-browse-temporal-log <path>` writes what it measured. DEBUG builds only.
    private func runDebugScript() async {
        #if DEBUG
        let zoom = Self.argument("-browse-temporal-zoom").flatMap(Double.init).map { CGFloat($0) }
        let script = Self.argument("-browse-temporal-script")
        guard zoom != nil || script != nil else { return }
        while pinch.viewportHeight < 2 || room.width < 2 { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(600))
        if let zoom { pinch.setZoom?(zoom, pinch.viewportHeight / 2); restedZoomKey = FixedGridBrowseModel.zoomKey(zoom) }
        guard let script else { return }
        try? await Task.sleep(for: .milliseconds(800))
        costs = Costs()
        BrowseProbeRecorder.shared.start()
        let meter = FrameMeter()
        meter.start()
        let started = CFAbsoluteTimeGetCurrent()
        let reads = model.dayReads
        switch script {
        case "zoom":
            let steps = 160
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let z = 1 + 7 * CGFloat(t < 0.5 ? t * 2 : 2 - t * 2)
                let begun = CFAbsoluteTimeGetCurrent()
                pinch.setZoom?(z, pinch.viewportHeight / 2)
                costs.record(apply: (CFAbsoluteTimeGetCurrent() - begun) * 1000)
                try? await Task.sleep(for: .milliseconds(16))
            }
        case "days", "days-twice":
            // Rapid taps add up, a reversal in flight, then a longer run. "days-twice" plays it once to build everything, then measures the second time.
            for pass in 0..<(script == "days-twice" ? 2 : 1) {
                if pass == 1 { while move.phase != .resting { try? await Task.sleep(for: .milliseconds(50)) }; try? await Task.sleep(for: .milliseconds(600)); costs = Costs() }
                for (delta, wait) in [(1, 120), (1, 150), (-1, 200), (-1, 100), (1, 500), (1, 140), (1, 140), (-1, 900), (1, 60), (-2, 1200)] {
                    move.retarget(by: delta)
                    startTicker()
                    try? await Task.sleep(for: .milliseconds(wait))
                }
            }
            while move.phase != .resting { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(400))
        case "swipes", "swipes-zoomed":
            // Real drag phases through the same handler the recognizer calls: slow drags across the halfway line and back, past it, a hard flick, a touch
            // that catches a flight and swipes on, a reversal mid-flight. 8 ms per finger sample (120 Hz touches).
            if script == "swipes-zoomed" { pinch.setZoom?(3, pinch.viewportHeight / 2); restedZoomKey = FixedGridBrowseModel.zoomKey(3); try? await Task.sleep(for: .milliseconds(600)) }
            let width = room.width
            let day = geometry(width: width).dayWidth
            func swipe(_ points: [CGFloat], velocity: CGFloat, caught: Bool = false) async {
                if caught { handleDateDrag(.touchDown, width: width) }
                handleDateDrag(.began, width: width)
                for x in points { handleDateDrag(.changed(translationX: x), width: width); try? await Task.sleep(for: .milliseconds(8)) }
                handleDateDrag(.ended(velocityX: velocity), width: width)
            }
            func ramp(to x: CGFloat, steps: Int) -> [CGFloat] { (1...steps).map { x * CGFloat($0) / CGFloat(steps) } }
            for _ in 0..<2 {
                await swipe(ramp(to: -0.4 * day, steps: 40), velocity: 0)                                  // short slow drag: returns
                try? await Task.sleep(for: .milliseconds(700))
                await swipe(ramp(to: -0.7 * day, steps: 50), velocity: 0)                                  // past half: next day
                try? await Task.sleep(for: .milliseconds(800))
                await swipe(ramp(to: -0.25 * day, steps: 8), velocity: -1800)                              // hard flick
                try? await Task.sleep(for: .milliseconds(180))
                await swipe(ramp(to: -0.3 * day, steps: 10), velocity: -1600, caught: true)               // caught mid-flight, flicked on
                try? await Task.sleep(for: .milliseconds(150))
                await swipe(ramp(to: 0.35 * day, steps: 12), velocity: 1700, caught: true)                // reversal mid-flight
                try? await Task.sleep(for: .milliseconds(900))
                await swipe(ramp(to: 0.6 * day, steps: 40) + ramp(to: 0.6 * day, steps: 40).reversed().map { $0 * 0.5 }, velocity: 0)   // across the line and back
                try? await Task.sleep(for: .milliseconds(900))
            }
            while move.phase != .resting { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(400))
        default: break
        }
        let seconds = CFAbsoluteTimeGetCurrent() - started
        meter.stop()
        let nominal = meter.intervals.sorted().dropFirst(meter.intervals.count / 2).first ?? 16.7
        let late = meter.intervals.filter { $0 > nominal * 1.5 }.count
        let text = """
        script \(script) zoom \(String(format: "%.2f", Double(pinch.zoom))) seconds \(String(format: "%.2f", seconds))
        step cost: \(costs.summary(costs.apply))
        step interval: \(costs.summary(costs.intervals))
        display frames: \(costs.summary(meter.intervals)); late (>1.5x median) \(late) of \(meter.intervals.count)
        view build: \(pinch.buildSummary)
        partitions: background \(planner.backgroundPlans), planned in a frame \(planner.framePlans), engine runs \(planner.continuousLayoutRuns), found \(planner.partitionHits)
        day reads during script: \(model.dayReads - reads), cached \(model.cachedDays.count), selected \(model.selectedDay.daysSinceUnixEpoch - Int(Date().timeIntervalSince1970 / 86400))d from today, position \(String(format: "%.3f", move.position))
        """
        let report = text + "\n" + "partitions held while a day was read \(planner.heldPartitions), axis transitions \(planner.transitionsBegun); reads dropped as stale \(model.staleReadsDropped), failed now \(model.failedDays.count)\n" + BrowseProbeRecorder.shared.report(title: script)
        print("MEASURE browse-temporal\n" + report)
        if let path = Self.argument("-browse-temporal-log") { try? report.write(toFile: path, atomically: true, encoding: .utf8) }
        #endif
    }

    // MARK: Measuring by hand

    /// `-browse-temporal-probe <path>`: records from the first appearance and writes the report (cumulative) each time the days come to rest or a pinch ends,
    /// so real touches can be measured. DEBUG builds only.
    private func startProbeIfAsked() {
        #if DEBUG
        guard let path = Self.argument("-browse-temporal-probe") else { return }
        room.probePath = path
        BrowseProbeRecorder.shared.start()
        #endif
    }

    private func writeProbeSoon() {
        #if DEBUG
        guard let path = room.probePath else { return }
        room.probeWrite?.cancel()
        room.probeWrite = Task { @MainActor [planner, model] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let header = "selected \(model.selectedDay.daysSinceUnixEpoch); day reads \(model.dayReads); cached \(model.cachedDays.count); held partitions \(planner.heldPartitions); axis transitions \(planner.transitionsBegun); planned in a frame \(planner.framePlans), background \(planner.backgroundPlans), engine runs \(planner.continuousLayoutRuns); stale reads dropped \(model.staleReadsDropped)\n"
            try? (header + BrowseProbeRecorder.shared.report(title: "by hand")).write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
    }

    // MARK: Planning ahead

    /// Plans the windows around the selected day off the main thread, then makes the engine's decisions for them at the rested zoom, one at a time between frames.
    private func warmAhead() async {
        let viewport = pinch.viewportHeight
        guard viewport > 1, room.width > Self.gutter else { return }
        let inputs = inputs(viewport: viewport, width: room.width)
        let selected = selectedEpoch
        let windows = [selected, selected + 1, selected - 1, selected + 2]
        planner.warm(windows: windows, inputs: inputs) { planningVersion += 1 }
        for window in windows {
            guard !Task.isCancelled else { return }
            if planner.plannedPartition(window: window, inputs: inputs) != nil, !planner.hasDecision(window: window, zoomKey: restedZoomKey) {
                BrowseProbe.measure(.warmAhead) { _ = planner.decision(window: window, zoomKey: restedZoomKey, inputs: inputs) }
            }
            await Task.yield()
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// What a touch candidate opens, and what to call it in a choice. Pure of the view, so it is tested.
enum FixedGridTouch {
    static func selection(for candidate: DayRenderPlan.Candidate, in timeline: DayTimeline, plan: DayRenderPlan) -> TimelineSelection? {
        switch candidate {
        case let .event(id):
            return timeline.blocks.first { $0.id == id }.map { .event($0) }
        case let .line(id):
            if let marker = timeline.markers.first(where: { $0.transactionID.rawValue == id }) { return .marker(marker) }
            if let item = timeline.blocks.flatMap(\.allocations).first(where: { $0.transactionID.rawValue == id }) {
                return .allocation(item, eventTitle: plan.lines.first { $0.id == id }?.linkedEventTitle)
            }
            return nil
        case let .overflow(id):
            return plan.overflows.first { $0.id == id }.map { .overflow(OverflowSelection($0, displays: DayRenderPlan.displays(of: timeline))) }
        }
    }

    static func label(of candidate: DayRenderPlan.Candidate, in timeline: DayTimeline, plan: DayRenderPlan) -> String {
        switch candidate {
        case let .event(id): return "일정 " + (timeline.blocks.first { $0.id == id }?.title ?? "")
        case let .line(id):
            let display = plan.lines.first { $0.id == id }?.display
            return "거래 " + (display?.title ?? "") + " " + (display.map { Formatting.money($0.amount.minorUnits, currency: $0.amount.currency) } ?? "")
        case let .overflow(id): return plan.overflows.first { $0.id == id }.map { OverflowCardView.summary($0) } ?? "거래 묶음"
        }
    }
}

// MARK: Pieces

/// What a day on screen that is not kept yet shows: that it is being read, or that it could not be read (and is tried again).
private struct DayLoadingMark: View {
    let state: AppModel.DayLoadState

    var body: some View {
        HStack(spacing: 6) {
            if state == .failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("불러오지 못했습니다")
            } else {
                ProgressView().controlSize(.mini)
                Text("불러오는 중")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// The line that says what this view does not do.
private struct EditingNotice: View {
    let emphasised: Bool

    var body: some View {
        Label(BrowseAxisMode.editingNotice, systemImage: "lock.fill")
            .font(.caption2)
            .lineLimit(3)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(emphasised ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(emphasised ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.08))
            .animation(.easeInOut(duration: 0.2), value: emphasised)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BrowseAxisMode.editingNotice)
    }
}

/// One event card. A tap is the grid's single tap handler's (the same plan decides what is touched), so the card carries none; VoiceOver's default action opens it.
private struct FixedBlockCell: View {
    let item: DayRenderPlan.EventItem
    let zoneIdentifier: String
    let scale: CGFloat
    var overlays: [CGRect] = []

    var body: some View {
        let frame = item.drawnFrame
        EventBlockView(
            block: item.block, height: frame.height, titleOffset: item.title.dy, rows: item.insideRows,
            presentation: item.presentation, scale: scale, hasHeader: item.header != nil, zoneIdentifier: zoneIdentifier,
            endIsCovered: overlays.contains { $0.intersects(CGRect(x: frame.maxX - 48, y: frame.maxY - 16, width: 48, height: 16)) },
            startIsCovered: overlays.contains { $0.intersects(CGRect(x: frame.maxX - 48, y: frame.minY + 3, width: 48, height: 11)) },
            anchors: item.insideAnchors.map { $0 - frame.minY }
        )
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .offset(x: frame.minX, y: frame.minY)
    }
}

/// The hour axis of the fixed grid: a line at every cell boundary across the days, and the whole hours on the gutter as `HourAxis` decides (only as many as the room
/// leaves between them). Hours are wall-clock hours.
private struct FixedHourAxis: View {
    let partition: TemporalGridPartition
    let width: CGFloat
    let gutter: CGFloat
    let scale: CGFloat

    var body: some View {
        let metrics = HourAxis.Metrics(textScale: scale)
        let states = HourAxis.layout(partition: partition, metrics: metrics)
        ZStack(alignment: .topLeading) {
            ForEach(0..<partition.slotCount, id: \.self) { slot in
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: max(0, width - gutter), height: 0.5)
                    .offset(x: gutter, y: partition.top(ofSlot: slot))
            }
            ForEach(states, id: \.hour) { state in
                if state.labelOpacity > 0.003 {
                    Text(Formatting.hourLabel(state.hour % 24))
                        .font(.system(size: metrics.labelFontSize).monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: gutter - 6, height: metrics.labelHeight, alignment: .trailing)
                        .opacity(state.labelOpacity)
                        .offset(y: state.labelCentre - metrics.labelHeight / 2)
                }
            }
        }
        .frame(width: width, height: partition.totalHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

private struct FixedNowLine: View {
    let timeline: DayTimeline
    let axis: ElapsedMinuteAxisMapping
    let width: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            let nowMs = Int64(context.date.timeIntervalSince1970 * 1_000)
            let minute = Int((nowMs - timeline.dayStartUnixMilliseconds) / 60_000)
            if minute >= 0, minute <= timeline.totalMinutes {
                HStack(spacing: 0) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Rectangle().fill(.red).frame(height: 1)
                }
                .padding(.leading, axis.gutterWidth - 4)
                .frame(width: width, alignment: .leading)
                .offset(y: axis.y(minute: minute) - 4)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
        }
    }
}
