import SwiftUI

#if DEBUG
/// `-render-grid`: the temporal grid prototype on its own screen, isolated from the Browse timeline. A day is cut into N cells of one height
/// each; what a cell stands for changes. Synthetic fixtures only (`TemporalGridFixtures`).
///
/// Launch arguments (all optional): `-grid-fixture <0...29>`, `-grid-n <10|12|16>`, `-grid-zoom <1...8>`, `-grid-p <0...1>`,
/// `-grid-main <window>`, `-grid-scale <1|1.5|2.2|3>`, `-grid-policy <hourly|fine>`, `-grid-script <zoom|swipe|days>`, `-grid-anchor off` (plays a short animation).
/// `-render-continuous` is the same screen with the continuous day space's panel (position, rendered and planned days, cache, anchor) shown.
struct RenderGridScreen: View {
    private static let fixtures = TemporalGridFixtures.all

    /// The two planned partitions and the hour-tick plan, kept until what they depend on changes: a pinch or a scroll frame never reaches the store.
    final class StateMemo {
        var key = ""
        var state: GridState?
        var windows: [Int: TemporalGridPartition] = [:]
    }

    @State private var fixtureIndex = RenderGridScreen.argument("-grid-fixture").flatMap { Int($0) } ?? 2
    @State private var slotCount = RenderGridScreen.argument("-grid-n").flatMap { Int($0) } ?? 12
    /// The grid's zoom and the scroll that goes with it live in the pinch scroll view; the screen around it does not observe them.
    @State private var pinch = PinchZoomModel(zoom: RenderGridScreen.argument("-grid-zoom").flatMap(Double.init).map { CGFloat($0) } ?? 1)
    /// Where the window is along the days, as an explicit state (`DayMoveModel`); `window` and `progress` below are its day and fraction.
    @State private var move = DayMoveModel(day: 3, bounds: 1...5)
    @State private var dragStart: Double?
    @State private var ticking = false
    /// Keep the time at the middle of the screen while the days move (on), or keep the scroll offset in points as before (off): the comparison.
    @State private var anchorOn = RenderGridScreen.argument("-grid-anchor") != "off"
    @State private var anchorTime: Double?
    @State private var lastAnchor: ContinuousDayAxis.AnchoredOffset?
    private static let showsPanel = ProcessInfo.processInfo.arguments.contains("-render-continuous")
    @State private var memo = StateMemo()
    @State private var progress: Double = RenderGridScreen.argument("-grid-p").flatMap(Double.init) ?? 0
    @State private var window = RenderGridScreen.argument("-grid-main").flatMap { Int($0) } ?? 3
    @State private var textScale: Double = RenderGridScreen.argument("-grid-scale").flatMap(Double.init) ?? 1
    @State private var hourly = RenderGridScreen.argument("-grid-policy") != "fine"
    @State private var selected: String?
    @State private var store = TemporalGridStore()
    @State private var counters = FrameCounters()

    final class FrameCounters {
        var placements = 0
        var entityBuilds = 0
    }

    /// The days' static entities, found by day, built once.
    final class EntityCache {
        var value: [String: GridDayEntities] = [:]
    }
    @State private var entityCache = EntityCache()

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private var scenario: AxisStabilityScenario { Self.fixtures[min(max(fixtureIndex, 0), Self.fixtures.count - 1)] }
    private var windows: ClosedRange<Int> { 1...(scenario.days.count - 4) }
    private var firstWindow: Int { min(max(window, windows.lowerBound), windows.upperBound) }

    var body: some View {
        _ = (move.position, anchorOn, lastAnchor)          // the panel below reads these inside closures: this screen must re-evaluate when they change
        return GeometryReader { outer in
            VStack(spacing: 0) {
                controls
                Divider()
                grid(width: outer.size.width)
                Divider()
                StatusBar(model: pinch) { pinch.viewportHeight > 1 ? statusLine(computeState(viewport: pinch.viewportHeight)) : "" }
            }
        }
        .font(.system(size: 11))
        .task {
            // The model starts on the launch window (and the launch fraction, held where it is).
            move = DayMoveModel(day: firstWindow, bounds: windows)
            if progress > 0 { move.drag(to: Double(firstWindow) + progress) }
            await runScript()
        }
        .onChange(of: fixtureIndex) { _, _ in move = DayMoveModel(day: firstWindow, bounds: windows); progress = 0; counters.entityBuilds = 0 }
    }

    private struct StatusBar: View {
        @ObservedObject var model: PinchZoomModel
        let text: () -> String
        var body: some View {
            Text("\(text()) · 줌 \(String(format: "%.2f", Double(model.zoom)))× · 프레임 빌드 \(model.buildSummary) · \(model.paceSummary)")
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .topLeading)
                .padding(.horizontal, 8).padding(.vertical, 2)
        }
    }

    /// Re-evaluated when the zoom or the viewport height changes (the first layout), so what it shows is never one frame behind.
    private struct SummaryHost: View {
        @ObservedObject var model: PinchZoomModel
        let content: () -> AnyView
        var body: some View { content() }
    }

    private struct ZoomReadout: View {
        @ObservedObject var model: PinchZoomModel
        var body: some View {
            HStack {
                Text("확대 \(String(format: "%.2f", Double(model.zoom)))×").monospacedDigit().frame(width: 74, alignment: .leading)
                Slider(value: Binding(get: { Double(model.zoom) }, set: { model.setZoom?(CGFloat($0), model.viewportHeight / 2) }), in: 1...8)
            }
        }
    }

    /// `-grid-script zoom`: zoom 1 → 8 → 1; `-grid-script swipe`: p 0 → 1, back to 0.5, on to 1. For a short screen recording.
    private func runScript() async {
        guard let script = Self.argument("-grid-script") else { return }
        try? await Task.sleep(for: .seconds(1))
        let steps = 120
        switch script {
        case "zoom":
            // 1 → 8 → 1, anchored at the middle of the screen.
            for step in 0...steps { pinch.setZoom?(1 + 7 * CGFloat(step) / CGFloat(steps), pinch.viewportHeight / 2); try? await Task.sleep(for: .milliseconds(40)) }
            try? await Task.sleep(for: .milliseconds(600))
            for step in 0...steps { pinch.setZoom?(8 - 7 * CGFloat(step) / CGFloat(steps), pinch.viewportHeight / 2); try? await Task.sleep(for: .milliseconds(40)) }
        case "swipe":
            // The day move 0 → 1, a reversal half way back, then on to 1 again.
            let path: [Double] = (0...60).map { Double($0) / 60 } + (1...30).map { 1 - Double($0) / 60 } + (1...60).map { 0.5 + Double($0) / 120 }
            for value in path { setProgress(value); try? await Task.sleep(for: .milliseconds(40)) }
        case "days":
            // Fast taps (+1 +1 +1), a reversal in the flight, then a long way back: the move model's own motion at zoom 3.
            pinch.setZoom?(3, pinch.viewportHeight / 2)
            try? await Task.sleep(for: .milliseconds(500))
            // Scroll to 12:00 at the middle of the screen, so the anchor has something to hold.
            let viewport = pinch.viewportHeight
            pinch.setOffset?(ContinuousDayAxis.anchoredOffset(time: 12 * 60, partition: sharedPartition(position: position, viewport: viewport), zoom: pinch.zoom, viewport: viewport, focal: viewport / 2).offset)
            try? await Task.sleep(for: .milliseconds(800))
            moveBy(1); try? await Task.sleep(for: .milliseconds(150))
            moveBy(1); try? await Task.sleep(for: .milliseconds(150))
            moveBy(1); try? await Task.sleep(for: .milliseconds(500))
            moveBy(-2); try? await Task.sleep(for: .milliseconds(1200))
            moveBy(-3); try? await Task.sleep(for: .milliseconds(300))
            moveBy(4)
        default: break
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Menu {
                    ForEach(Self.fixtures.indices, id: \.self) { index in Button(Self.fixtures[index].name) { fixtureIndex = index } }
                } label: {
                    Text(scenario.name).lineLimit(1).frame(maxWidth: 170, alignment: .leading)
                }
                Spacer()
                Button("−3") { moveBy(-3) }.buttonStyle(.bordered).controlSize(.mini)
                Button("−1") { moveBy(-1) }.buttonStyle(.bordered).controlSize(.mini)
                Button("+1") { moveBy(1) }.buttonStyle(.bordered).controlSize(.mini)
                Button("+3") { moveBy(3) }.buttonStyle(.bordered).controlSize(.mini)
                Text("D=\(firstWindow)").monospacedDigit()
            }
            HStack {
                Picker("N", selection: $slotCount) { ForEach([10, 12, 16], id: \.self) { Text("N=\($0)").tag($0) } }.pickerStyle(.segmented)
                Picker("정책", selection: $hourly) { Text("정각").tag(true); Text("5분").tag(false) }.pickerStyle(.segmented).frame(width: 90)
                Picker("글자", selection: $textScale) { ForEach([1.0, 1.5, 2.2, 3.0], id: \.self) { Text("×\($0.formatted())").tag($0) } }.pickerStyle(.segmented)
            }
            ZoomReadout(model: pinch)
            HStack {
                Text("p \(progress.formatted(.number.precision(.fractionLength(2))))").monospacedDigit().frame(width: 74, alignment: .leading)
                Slider(value: Binding(get: { progress }, set: { setProgress($0) }), in: 0...1)
                ForEach([0.0, 0.5, 1.0], id: \.self) { value in
                    Button("\(Int(value * 100))") { setProgress(value) }.buttonStyle(.bordered).controlSize(.mini).fixedSize()
                }
                Button(anchorOn ? "앵커 ON" : "앵커 OFF") { anchorOn.toggle() }.buttonStyle(.bordered).controlSize(.mini).fixedSize()
            }
            SummaryHost(model: pinch) { summary }.frame(height: Self.showsPanel ? 74 : 24, alignment: .topLeading)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var summary: AnyView {
        guard pinch.viewportHeight > 1 else { return AnyView(EmptyView()) }
        let state = computeState(viewport: pinch.viewportHeight)
        return AnyView(VStack(alignment: .leading, spacing: 1) {
            Text("A(D) " + Self.boundaryText(state.a.boundaries)).monospacedDigit().font(.system(size: 8))
            Text("B(D+1) " + Self.boundaryText(state.b.boundaries)).monospacedDigit().font(.system(size: 8))
            if Self.showsPanel { panel }
        })
    }

    private static func boundaryText(_ boundaries: [Double]) -> String { boundaries.map { fmt($0) }.joined(separator: " ") }

    private func statusLine(_ state: GridState) -> String {
        let a = state.a.wholeMinuteBoundaries ?? [], b = state.b.wholeMinuteBoundaries ?? []
        let changed = zip(a, b).map { abs($0 - $1) }
        let selectedText = selected.map { " · 선택 \($0)" } ?? ""
        return "경계 변화 최대 \(changed.max() ?? 0)분 평균 \(changed.isEmpty ? 0 : changed.reduce(0, +) / changed.count)분 · 최적화 \(store.planRuns)회 프로필 \(store.profileBuilds)회\(selectedText)"
    }

    // MARK: State

    struct GridState {
        let a: TemporalGridPartition
        let b: TemporalGridPartition
    }

    private func parameters(viewport: CGFloat) -> TemporalGridParameters {
        var p = hourly ? TemporalGridParameters.hourly(slotCount: slotCount) : TemporalGridParameters.with(slotCount: slotCount)
        p.viewportHeight = viewport
        p.textScale = CGFloat(textScale)
        p.allocation = scenario.parameters
        return p
    }

    /// The two partitions (for the window starting at D and the one starting at D+1). Planned only when the day, N, text size or viewport change.
    private func settingsKey(_ viewport: CGFloat) -> String {
        "\(fixtureIndex)|\(slotCount)|\(hourly)|\(textScale)|\(Int(viewport.rounded()))"
    }

    /// The partition planned for the window whose main day is `window`, found in the memo (a day or a pinch frame never reaches the store).
    private func windowPartition(_ window: Int, viewport: CGFloat) -> TemporalGridPartition {
        let key = settingsKey(viewport)
        if memo.key != key { memo.key = key; memo.windows = [:]; memo.state = nil }
        let clamped = min(max(window, windows.lowerBound), windows.upperBound)
        if let found = memo.windows[clamped] { return found }
        let p = parameters(viewport: max(viewport, 1))
        let made = store.plan(window: TemporalWindow(days: Array(scenario.days[(clamped - 1)...(clamped + 2)]), mainIndex: 1), parameters: p).partition
        memo.windows[clamped] = made
        return made
    }

    /// The shared time partition at the window's position: the blend of the two windows around it.
    private func sharedPartition(position: Double, viewport: CGFloat) -> TemporalGridPartition {
        ContinuousDayAxis.partition(at: position, bounds: windows) { windowPartition($0, viewport: viewport) }
    }

    private func computeState(viewport: CGFloat) -> GridState {
        GridState(a: windowPartition(firstWindow, viewport: viewport), b: windowPartition(firstWindow + 1, viewport: viewport))
    }

    // MARK: Grid

    private static let gutter: CGFloat = 58
    private static let railX: CGFloat = 50

    private func grid(width: CGFloat) -> some View {
        PinchZoomScrollView(model: pinch, onDateDrag: { handleDateDrag($0, width: width) }) { zoom, viewport, window in
            gridContent(width: width, zoom: zoom, viewport: viewport, window: window)
        }
    }

    /// Everything of one frame at `zoom`: the cells and axis, and the three day columns. The two planned partitions come from the memo; a frame only
    /// scales them and places the items (no planning, no day analysis: the static entities are cached).
    private func gridContent(width: CGFloat, zoom: CGFloat, viewport: CGFloat, window: ClosedRange<CGFloat>) -> AnyView {
        guard viewport > 1 else { return AnyView(Color.clear.frame(width: width, height: 1)) }    // before the first layout
        let shown = sharedPartition(position: Double(firstWindow) + progress, viewport: viewport).zoomed(viewportHeight: viewport, zoomScale: zoom)
        return AnyView(ZStack(alignment: .topLeading) {
            cells(shown: shown, width: width)
            columns(partition: shown, width: width, window: window)
        }
        .frame(width: width, height: shown.totalHeight, alignment: .topLeading))
    }

    // MARK: The day move (state model; the real swipe is a later stage)

    private var position: Double { Double(firstWindow) + progress }

    /// A window onto the day line: columns of the width a day has on this screen.
    private func geometry(width: CGFloat) -> DayAxisGeometry { DayAxisGeometry(dayWidth: (width - Self.gutter) / 2) }

    /// A horizontal drag is the move model's `drag`/`release` (`Double` days per second); the screen only reads the model's position back.
    private func handleDateDrag(_ phase: DateDragPhase, width: CGFloat) {
        let geometry = geometry(width: width)
        switch phase {
        case .changed(let translation):
            if dragStart == nil { beginMove(); move.beginDrag(); dragStart = move.position }
            move.drag(to: geometry.position(startingAt: dragStart ?? move.position, translation: translation))
            applyMove()
        case .ended(let velocity):
            dragStart = nil
            move.release(velocity: -Double(velocity / geometry.dayWidth))
            startTicker()
        case .cancelled:
            dragStart = nil
            move.release(velocity: 0)
            startTicker()
        }
    }

    /// Rapid taps add up and a tap during a flight keeps its speed; a drag that begins in a flight takes over from where it is.
    private func moveBy(_ delta: Int) {
        beginMove()
        move.retarget(by: delta)
        startTicker()
    }

    private func setProgress(_ value: Double) {
        beginMove()
        move.drag(to: Double(firstWindow) + value)
        applyMove()
    }

    /// At the start of a move from rest: which time is at the middle of the screen, to hold it there while the days move.
    private func beginMove() {
        guard !move.isMoving, pinch.viewportHeight > 1 else { return }
        let viewport = pinch.viewportHeight
        let partition = sharedPartition(position: move.position, viewport: viewport)
        anchorTime = ContinuousDayAxis.time(atOffset: pinch.currentOffset?() ?? 0, partition: partition, zoom: pinch.zoom, viewport: viewport, focal: viewport / 2)
    }

    /// Show the model's position: the day and fraction the columns and the time blend are drawn at, and the scroll that keeps the anchor.
    private func applyMove() {
        window = move.day
        progress = move.progress
        guard anchorOn, let time = anchorTime, pinch.viewportHeight > 1 else { lastAnchor = nil; return }
        let viewport = pinch.viewportHeight
        let result = ContinuousDayAxis.anchoredOffset(time: time, partition: sharedPartition(position: move.position, viewport: viewport), zoom: pinch.zoom, viewport: viewport, focal: viewport / 2)
        lastAnchor = result
        pinch.setOffset?(result.offset)
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
        }
    }

    /// What the continuous space is doing now (`-render-continuous`).
    private var panel: some View {
        let geometry = geometry(width: UIScreen.main.bounds.width)
        let rendered = geometry.renderedDays(at: move.position)
        let planning = geometry.planningDays(at: move.position, bounds: windows)
        let viewport = max(pinch.viewportHeight, 1)
        let shared = sharedPartition(position: move.position, viewport: viewport)
        let noon = shared.timeToY(720)
        let phase = move.phase == .resting ? "정지" : (move.phase == .dragging ? "드래그" : "정착")
        let anchor = anchorTime.map { String(format: "%02d:%02d", Int($0) / 60, Int($0) % 60) } ?? "—"
        let anchored = lastAnchor.map { $0.clamped ? String(format: "한계 잔차 %.0f분", $0.residualMinutes) : "유지" } ?? "—"
        return VStack(alignment: .leading, spacing: 1) {
            Text(String(format: "위치 %.3f일 · %@ · 목표 %d · 속도 %.2f/s", move.position, phase, move.target, move.velocity)).monospacedDigit()
            Text("그리는 날 \(rendered.lowerBound)…\(rendered.upperBound) · 계획 날 \(planning.lowerBound)…\(planning.upperBound) · 계획 \(store.planRuns) 프로필 \(store.profileBuilds) 적중 \(Int(store.hitRate * 100))% 엔티티 \(counters.entityBuilds)")
            Text(String(format: "공유 y(12:00)=%.2f · 앵커 %@ %@ · %@", noon, anchor, anchored, anchorOn ? "시각 앵커" : "pt 유지"))
        }
        .font(.system(size: 8)).foregroundStyle(.secondary)
    }

    /// The fixed horizontal lines (one style for every cell, at the same y at every p) and the time axis: one thin solid line, with a tick at the
    /// real y of every whole hour and the label of the hours that have room. Whether an hour is drawn depends only on the space there is at this
    /// instant (`HourAxis`); where it is drawn is always `timeToY`.
    private func cells(shown: TemporalGridPartition, width: CGFloat) -> some View {
        let metrics = HourAxis.Metrics(textScale: CGFloat(textScale))
        let states = HourAxis.layout(partition: shown, metrics: metrics)
        return ZStack(alignment: .topLeading) {
            ForEach(0..<shown.slotCount, id: \.self) { slot in
                let top = shown.top(ofSlot: slot)
                Path { path in path.move(to: CGPoint(x: Self.gutter, y: top)); path.addLine(to: CGPoint(x: width, y: top)) }
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 0.6)
            }
            // The axis: always the same thin solid line.
            Path { path in path.move(to: CGPoint(x: Self.railX, y: 0)); path.addLine(to: CGPoint(x: Self.railX, y: shown.totalHeight)) }
                .stroke(Color.secondary.opacity(0.5), lineWidth: 0.8)
            ForEach(states, id: \.hour) { state in
                if state.tickOpacity > 0.003 {
                    Path { path in
                        path.move(to: CGPoint(x: Self.railX, y: state.y))
                        path.addLine(to: CGPoint(x: Self.railX + 3 + 3 * CGFloat(state.labelOpacity), y: state.y))
                    }
                    .stroke(Color.secondary.opacity(0.7 * state.tickOpacity), lineWidth: 0.8)
                }
                if state.labelOpacity > 0.003 {
                    Text(Self.fmt(Double(state.hour * 60)))
                        .font(.system(size: metrics.labelFontSize, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Color.primary)
                        .frame(width: Self.railX - 5, height: metrics.labelHeight, alignment: .trailing)
                        .opacity(state.labelOpacity)
                        .offset(x: 2, y: state.labelCentre - metrics.labelHeight / 2)
                }
            }
        }
    }

    // MARK: Columns

    private func columns(partition: TemporalGridPartition, width: CGFloat, window: ClosedRange<CGFloat>) -> some View {
        let geometry = DayAxisGeometry(dayWidth: (width - Self.gutter) / 2)
        let metrics = EventPresentation.Metrics.standard(scale: CGFloat(textScale))
        let pitch = GridPlacement.transactionPitch(scenario.parameters, textScale: CGFloat(textScale))
        let position = position
        // Only the days that reach the window are drawn; each at its fixed width, at x = (day − position) · width.
        let days = geometry.renderedDays(at: position).filter { scenario.days.indices.contains($0) }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(days), id: \.self) { index in
                column(day: scenario.days[index], dayIndex: index, partition: partition, metrics: metrics, pitch: pitch, width: geometry.dayWidth, window: window, role: "D\(index)")
                    .offset(x: Self.gutter + geometry.x(ofDay: Double(index), at: position))
            }
        }
        .frame(width: width, alignment: .leading)
        .clipShape(Rectangle().path(in: CGRect(x: Self.gutter, y: 0, width: width - Self.gutter, height: partition.totalHeight)))
    }

    private func column(day: AllocationDay, dayIndex: Int, partition: TemporalGridPartition, metrics: EventPresentation.Metrics, pitch: CGFloat, width: CGFloat, window: ClosedRange<CGFloat>, role: String) -> some View {
        let entities = entitiesCache(day, index: dayIndex)
        let placed = GridPlacement.place(entities, partition: partition, metrics: metrics, transactionPitch: pitch)
        let scale = CGFloat(textScale)
        let text = GridTextLayout.resolve(entities: entities, placement: placed, columnWidth: width, scale: scale)
        let sources = Dictionary(entities.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ZStack(alignment: .topLeading) {
            Text("\(role)  \(placed.events.count)일정").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).offset(x: 3, y: 1)
            // Only what reaches the built window (a viewport beyond the screen each side) is made into views; the plan above is for all.
            ForEach(placed.events.filter { $0.bottom >= window.lowerBound && $0.top <= window.upperBound }, id: \.id) { event in
                if let source = sources[event.id] {
                    eventView(event, source: source, width: width, scale: scale)
                }
            }
            ForEach(placed.events.filter { $0.bottom >= window.lowerBound && $0.top <= window.upperBound }, id: \.id) { event in
                if let source = sources[event.id] {
                    eventText(event, source: source, showsTitle: text.titlesShown.contains(event.id), showsTime: text.timesShown.contains(event.id), width: width, scale: scale)
                }
            }
            ForEach(Array(text.clusters.enumerated()).filter { window.contains($0.element.y) }, id: \.offset) { _, cluster in
                clusterView(cluster, width: width, scale: scale)
            }
        }
        .frame(width: width, height: partition.totalHeight, alignment: .topLeading)
    }

    /// The static part of a day (which events and transactions it has) is built once per day, not per frame.
    private func entitiesCache(_ day: AllocationDay, index: Int) -> GridDayEntities {
        let key = "\(fixtureIndex)-\(index)"
        if let found = entityCache.value[key] { return found }
        let made = GridDayEntities.make(day)
        counters.entityBuilds += 1
        entityCache.value[key] = made
        return made
    }

    /// The card alone. Its title and time are drawn in a layer above every card (`eventText`), so a card on top of another never covers a title.
    private func eventView(_ event: GridEventPlacement, source: GridDayEntities.Event, width: CGFloat, scale: CGFloat) -> some View {
        let presentation = event.presentation
        let drawn = max(event.height, 2)
        let tint = Self.color(for: event.id)
        let top = event.top - (drawn - event.height) / 2
        let touch = max(drawn, 44)
        let indent = CGFloat(source.indent) * 10
        let cardWidth = width - 26 - indent - (source.pullsInOnRight ? 8 : 0)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: min(4, drawn / 2))
                .fill(tint.opacity(0.10 + 0.20 * presentation.card + (1 - presentation.card) * 0.55))
                .overlay(RoundedRectangle(cornerRadius: min(4, drawn / 2)).stroke(tint.opacity(0.35 + 0.4 * (1 - presentation.card)), lineWidth: presentation.card > 0.5 ? 0.8 : 0))
                .frame(width: cardWidth, height: drawn)
        }
        .frame(width: cardWidth, height: drawn, alignment: .topLeading)
        .offset(x: 4 + indent, y: top)
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: cardWidth, height: touch).contentShape(Rectangle())
                .offset(x: 4 + indent, y: event.top - (touch - event.height) / 2)
                .onTapGesture { selected = "\(source.title) \(Self.fmt(Double(event.startMinute)))–\(Self.fmt(Double(event.endMinute)))" }
        }
    }

    private func eventText(_ event: GridEventPlacement, source: GridDayEntities.Event, showsTitle: Bool, showsTime: Bool, width: CGFloat, scale: CGFloat) -> some View {
        let presentation = event.presentation
        let drawn = max(event.height, 2)
        let top = event.top - (drawn - event.height) / 2
        let indent = CGFloat(source.indent) * 10
        let cardWidth = width - 26 - indent - (source.pullsInOnRight ? 8 : 0)
        return ZStack(alignment: .topLeading) {
            if showsTitle {
                Text(source.title).font(.system(size: 12 * scale, weight: .semibold)).lineLimit(1).opacity(presentation.title)
                    .padding(.horizontal, 4).padding(.top, 2 * scale).frame(width: cardWidth, alignment: .leading)
            }
            if showsTime {
                Text("\(Self.fmt(Double(event.startMinute)))–\(Self.fmt(Double(event.endMinute)))").font(.system(size: 9 * scale)).monospacedDigit()
                    .foregroundStyle(.secondary).opacity(presentation.endTime).padding(.horizontal, 4)
                    .frame(width: cardWidth, height: drawn, alignment: .bottomLeading).padding(.bottom, 2)
            }
        }
        .frame(width: cardWidth, height: drawn, alignment: .topLeading)
        .offset(x: 4 + indent, y: top)
        .allowsHitTesting(false)
    }

    /// One transaction: its dot and, when there is room, its text. Dots that would touch are one count; the count is tappable and names every
    /// transaction (id, time, amount) it stands for.
    private func clusterView(_ cluster: GridTransactionCluster, width: CGFloat, scale: CGFloat) -> some View {
        ZStack(alignment: .trailing) {
            if cluster.count > 1 {
                Text("\(cluster.count)").font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 13)
                    .background(Capsule().fill(Color.pink)).offset(x: 1)
            } else {
                if cluster.textShown {
                    Text(GridTextLayout.amountText(cluster.amounts.first ?? nil)).font(.system(size: 10 * scale)).monospacedDigit().padding(.trailing, 12)
                }
                Circle().fill(Color.pink).frame(width: 6, height: 6).offset(x: 3)
            }
        }
        .frame(width: width - 4, height: 14, alignment: .trailing)
        .offset(x: 0, y: cluster.y - 7)
        .onTapGesture {
            let items = zip(zip(cluster.ids, cluster.minutes), cluster.amounts).map { "\($0.0) \(Self.fmt(Double($0.1))) \(GridTextLayout.amountText($1))" }
            selected = "거래 \(cluster.count)건: " + items.joined(separator: ", ")
        }
    }

    // MARK: Helpers

    static func fmt(_ minute: Double) -> String {
        let total = Int(minute.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m % 60 == 0 ? "\(m / 60)시간" : "\(m / 60)시간 \(m % 60)분"
    }

    static func color(for id: String) -> Color {
        let palette: [Color] = [.blue, .green, .purple, .orange, .teal, .indigo]
        var hash = 0
        for scalar in id.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }
}
#endif
