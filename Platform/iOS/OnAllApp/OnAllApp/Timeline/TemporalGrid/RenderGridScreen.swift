import SwiftUI

#if DEBUG
/// `-render-grid`: the temporal grid prototype on its own screen, isolated from the Browse timeline. A day is cut into N cells of one height
/// each; what a cell stands for changes. Synthetic fixtures only (`TemporalGridFixtures`).
///
/// Launch arguments (all optional): `-grid-fixture <0...29>`, `-grid-n <10|12|16>`, `-grid-zoom <1...8>`, `-grid-p <0...1>`,
/// `-grid-main <window>`, `-grid-scale <1|1.5|2.2|3>`, `-grid-policy <hourly|fine>`, `-grid-script <zoom|swipe>` (plays a short animation).
struct RenderGridScreen: View {
    private static let fixtures = TemporalGridFixtures.all

    /// The two planned partitions and the hour-tick plan, kept until what they depend on changes: a pinch or a scroll frame never reaches the store.
    final class StateMemo {
        var key = ""
        var state: GridState?
        var tickKey = ""
        var ticks: HourTickPlan?
    }

    @State private var fixtureIndex = RenderGridScreen.argument("-grid-fixture").flatMap { Int($0) } ?? 2
    @State private var slotCount = RenderGridScreen.argument("-grid-n").flatMap { Int($0) } ?? 12
    /// The grid's zoom and the scroll that goes with it live in the pinch scroll view; the screen around it does not observe them.
    @State private var pinch = PinchZoomModel(zoom: RenderGridScreen.argument("-grid-zoom").flatMap(Double.init).map { CGFloat($0) } ?? 1)
    @State private var dateDrag: (base: Int, startReal: Double)?
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
        GeometryReader { outer in
            VStack(spacing: 0) {
                controls
                Divider()
                grid(width: outer.size.width)
                Divider()
                StatusBar(model: pinch) { pinch.viewportHeight > 1 ? statusLine(computeState(viewport: pinch.viewportHeight)) : "" }
            }
        }
        .font(.system(size: 11))
        .task { await runScript() }
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

    private struct ZoomReadout: View {
        @ObservedObject var model: PinchZoomModel
        var body: some View {
            HStack {
                Text("확대 \(String(format: "%.2f", Double(model.zoom)))×").monospacedDigit().frame(width: 74, alignment: .leading)
                Slider(value: Binding(get: { Double(model.zoom) }, set: { model.setZoom?(CGFloat($0), model.viewportHeight / 2) }), in: 1...8)
            }
        }
    }

    /// `-grid-script zoom`: zoom 1 → 3 → 1; `-grid-script swipe`: p 0 → 1. For a short screen recording.
    private func runScript() async {
        guard let script = Self.argument("-grid-script") else { return }
        try? await Task.sleep(for: .seconds(1))
        let steps = 90
        switch script {
        case "zoom":
            for step in 0...steps { pinch.setZoom?(1 + 2 * CGFloat(step) / CGFloat(steps), pinch.viewportHeight / 2); try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .seconds(1))
            for step in 0...steps { pinch.setZoom?(3 - 2 * CGFloat(step) / CGFloat(steps), pinch.viewportHeight / 2); try? await Task.sleep(for: .milliseconds(50)) }
        case "swipe":
            for step in 0...steps { progress = Double(step) / Double(steps); try? await Task.sleep(for: .milliseconds(50)) }
        default: break
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("fixture", selection: $fixtureIndex) {
                    ForEach(Self.fixtures.indices, id: \.self) { Text(Self.fixtures[$0].name).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
                Spacer()
                Stepper("날짜 \(firstWindow)", value: $window, in: windows).labelsHidden()
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
                Slider(value: $progress, in: 0...1)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { value in
                    Button("\(Int(value * 100))") { progress = value }.buttonStyle(.bordered).controlSize(.mini)
                }
            }
            summary
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var summary: some View {
        let state = computeState(viewport: 1)
        return VStack(alignment: .leading, spacing: 1) {
            Text("A(D) " + Self.boundaryText(state.a.boundaries)).monospacedDigit().font(.system(size: 8))
            Text("B(D+1) " + Self.boundaryText(state.b.boundaries)).monospacedDigit().font(.system(size: 8))
        }
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
    private func computeState(viewport: CGFloat) -> GridState {
        let key = "\(fixtureIndex)|\(firstWindow)|\(slotCount)|\(hourly)|\(textScale)|\(Int(viewport.rounded()))"
        if memo.key == key, let state = memo.state { return state }
        let p = parameters(viewport: max(viewport, 1))
        let main = firstWindow
        let days = scenario.days
        func plan(_ main: Int) -> TemporalGridPartition {
            store.plan(window: TemporalWindow(days: Array(days[(main - 1)...(main + 2)]), mainIndex: 1), parameters: p).partition
        }
        let state = GridState(a: plan(main), b: plan(min(main + 1, windows.upperBound)))
        memo.key = key
        memo.state = state
        return state
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
        let state = computeState(viewport: viewport)
        let blend = TemporalGridPartition.interpolated(from: state.a, to: state.b, progress: progress) ?? state.a
        let shown = blend.zoomed(viewportHeight: viewport, zoomScale: zoom)
        let a = state.a.zoomed(viewportHeight: viewport, zoomScale: zoom), b = state.b.zoomed(viewportHeight: viewport, zoomScale: zoom)
        return AnyView(ZStack(alignment: .topLeading) {
            cells(shown: shown, a: a, b: b, blend: blend, zoom: Double(zoom), width: width)
            columns(partition: shown, width: width, window: window)
        }
        .frame(width: width, height: shown.totalHeight, alignment: .topLeading))
    }

    /// The day move: a horizontal drag sets where between the days the grid is (the same `p` as the slider), and lets go on the nearer day.
    /// The zoom is not touched, so it stays across days.
    private func handleDateDrag(_ phase: DateDragPhase, width: CGFloat) {
        let columnWidth = (width - Self.gutter) / 2
        func real(_ translation: CGFloat) -> Double {
            let start = dateDrag?.startReal ?? Double(firstWindow) + progress
            return min(max(start - Double(translation / columnWidth), Double(windows.lowerBound)), Double(windows.upperBound))
        }
        func set(_ position: Double) {
            let base = min(Int(position.rounded(.down)), windows.upperBound)
            window = base
            progress = base >= windows.upperBound ? 0 : position - Double(base)
        }
        switch phase {
        case .changed(let translation):
            if dateDrag == nil { dateDrag = (firstWindow, Double(firstWindow) + progress) }
            set(real(translation))
        case .ended(let velocity):
            let position = Double(window) + progress
            let projected = position - Double(velocity / columnWidth) * 0.12
            let target = min(max(projected.rounded(), Double(windows.lowerBound)), Double(windows.upperBound))
            dateDrag = nil
            Task { @MainActor in
                let steps = 10
                for step in 1...steps { set(position + (target - position) * Double(step) / Double(steps)); try? await Task.sleep(for: .milliseconds(16)) }
                set(target)
            }
        case .cancelled:
            let target = (Double(window) + progress).rounded()
            dateDrag = nil
            set(target)
        }
    }

    /// The tick plan of a partition at zoom 1, remembered for the same partition (a pinch frame asks for the same one again and again).
    private func tickPlan(_ partition: TemporalGridPartition) -> HourTickPlan {
        let key = "\(memo.key)|\(partition.boundaries.hashValue)"
        if memo.tickKey == key, let plan = memo.ticks { return plan }
        let plan = HourTickPlan.make(partition: partition)
        memo.tickKey = key
        memo.ticks = plan
        return plan
    }

    /// The fixed horizontal lines (one style for every cell, at the same y at every p), the compression rail and the hour ticks of the shared axis.
    private func cells(shown: TemporalGridPartition, a: TemporalGridPartition, b: TemporalGridPartition, blend: TemporalGridPartition, zoom: Double, width: CGFloat) -> some View {
        let ticks = tickPlan(blend)
        let boundaryHours = Set(blend.boundaries.filter { $0.truncatingRemainder(dividingBy: 60) == 0 }.map { Int($0 / 60) })
        let labelHeight = HourTickPlan.labelLineHeight()
        return ZStack(alignment: .topLeading) {
            ForEach(0..<shown.slotCount, id: \.self) { slot in
                let top = shown.top(ofSlot: slot)
                Path { path in path.move(to: CGPoint(x: Self.gutter, y: top)); path.addLine(to: CGPoint(x: width, y: top)) }
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 0.6)
                // The rail takes the look of the first day's cell and then of the second's; between them it is both, faded.
                rail(a, slot, shown.slotHeight).opacity(1 - progress).offset(x: Self.railX, y: top)
                rail(b, slot, shown.slotHeight).opacity(progress).offset(x: Self.railX, y: top)
            }
            Path { path in path.move(to: CGPoint(x: Self.gutter, y: 0)); path.addLine(to: CGPoint(x: Self.gutter, y: shown.totalHeight)) }
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            // A tick at the real y of every whole hour, on the axis only; the label of the hours that fit.
            ForEach(0...24, id: \.self) { hour in
                let y = shown.timeToY(Double(hour * 60))
                let alpha = ticks.opacity(hour: hour, zoom: zoom)
                Path { path in path.move(to: CGPoint(x: Self.railX + 5, y: y)); path.addLine(to: CGPoint(x: Self.gutter, y: y)) }
                    .stroke(Color.secondary.opacity(0.35 + 0.35 * alpha), lineWidth: alpha > 0 ? 1 : 0.6)
                if alpha > 0 {
                    Text(Self.fmt(Double(hour * 60)))
                        .font(.system(size: 10, weight: boundaryHours.contains(hour) ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(boundaryHours.contains(hour) ? Color.primary : Color.secondary)
                        .frame(width: Self.railX - 5, height: labelHeight, alignment: .trailing)
                        .opacity(alpha)
                        .offset(x: 2, y: min(max(y - labelHeight / 2, 0), shown.totalHeight - labelHeight))
                }
            }
        }
    }

    /// One cell of the compression rail: a line for up to an hour, a faint dotted line up to three, a fold (zigzag) beyond.
    private func rail(_ partition: TemporalGridPartition, _ slot: Int, _ height: CGFloat) -> some View {
        let style = SlotCompression(minutes: partition.minutes(inSlot: slot))
        return Path { path in
            let inset: CGFloat = 2
            switch style {
            case .continuous, .dotted:
                path.move(to: CGPoint(x: 2, y: inset)); path.addLine(to: CGPoint(x: 2, y: height - inset))
            case .folded:
                path.move(to: CGPoint(x: 2, y: inset))
                var y = inset, flip = true
                while y < height - inset {
                    y = min(height - inset, y + 5)
                    path.addLine(to: CGPoint(x: flip ? 5 : -1, y: y))
                    flip.toggle()
                }
            }
        }
        .stroke(
            Color.secondary.opacity(style == .continuous ? 0.7 : (style == .dotted ? 0.5 : 0.8)),
            style: StrokeStyle(lineWidth: style == .continuous ? 2 : (style == .dotted ? 1.6 : 1), lineCap: .round, lineJoin: .round, dash: style == .dotted ? [0.1, 4] : [])
        )
        .frame(width: 6, height: height)
    }

    // MARK: Columns

    private func columns(partition: TemporalGridPartition, width: CGFloat, window: ClosedRange<CGFloat>) -> some View {
        let columnWidth = (width - Self.gutter) / 2
        let metrics = EventPresentation.Metrics.standard(scale: CGFloat(textScale))
        let pitch = GridPlacement.transactionPitch(scenario.parameters, textScale: CGFloat(textScale))
        let first = firstWindow
        return HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { offset in
                let day = scenario.days[first + offset]
                column(day: day, partition: partition, metrics: metrics, pitch: pitch, width: columnWidth, window: window, role: offset == 0 ? "D" : (offset == 1 ? "D+1" : "D+2"))
            }
        }
        // The three days slide left by one column as p goes 0 → 1: the day swipe.
        .offset(x: Self.gutter - CGFloat(progress) * columnWidth)
        .frame(width: width, alignment: .leading)
        .clipShape(Rectangle().path(in: CGRect(x: Self.gutter, y: 0, width: width - Self.gutter, height: partition.totalHeight)))
    }

    private func column(day: AllocationDay, partition: TemporalGridPartition, metrics: EventPresentation.Metrics, pitch: CGFloat, width: CGFloat, window: ClosedRange<CGFloat>, role: String) -> some View {
        let entities = entitiesCache(day)
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
    private func entitiesCache(_ day: AllocationDay) -> GridDayEntities {
        let key = "\(fixtureIndex)-\(day.day.daysSinceUnixEpoch)"
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
