import SwiftUI

#if DEBUG
/// `-render-grid`: the temporal grid prototype on its own screen, isolated from the Browse timeline. A day is cut into N cells of one height
/// each; what a cell stands for changes. Synthetic fixtures only (`TemporalGridFixtures`).
///
/// Launch arguments (all optional): `-grid-fixture <0...29>`, `-grid-n <10|12|16>`, `-grid-zoom <1...3>`, `-grid-p <0...1>`,
/// `-grid-main <window>`, `-grid-scale <1|1.5|2.2|3>`.
struct RenderGridScreen: View {
    private static let fixtures = TemporalGridFixtures.all

    @State private var fixtureIndex = RenderGridScreen.argument("-grid-fixture").flatMap { Int($0) } ?? 2
    @State private var slotCount = RenderGridScreen.argument("-grid-n").flatMap { Int($0) } ?? 12
    @State private var zoom: Double = RenderGridScreen.argument("-grid-zoom").flatMap(Double.init) ?? 1
    @State private var progress: Double = RenderGridScreen.argument("-grid-p").flatMap(Double.init) ?? 0
    @State private var window = RenderGridScreen.argument("-grid-main").flatMap { Int($0) } ?? 3
    @State private var textScale: Double = RenderGridScreen.argument("-grid-scale").flatMap(Double.init) ?? 1
    @State private var selected: String?
    @State private var store = TemporalGridStore()
    @State private var counters = FrameCounters()

    final class FrameCounters {
        var placements = 0
        var entityBuilds = 0
    }

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
                Text(statusLine(computeState(viewport: 1))).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 8).padding(.vertical, 2)
            }
        }
        .font(.system(size: 11))
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
                Picker("글자", selection: $textScale) { ForEach([1.0, 1.5, 2.2, 3.0], id: \.self) { Text("×\($0.formatted())").tag($0) } }.pickerStyle(.segmented)
            }
            HStack {
                Text("확대 \(zoom.formatted(.number.precision(.fractionLength(2))))×").monospacedDigit().frame(width: 74, alignment: .leading)
                Slider(value: $zoom, in: 1...3)
            }
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
        var p = TemporalGridParameters.with(slotCount: slotCount)
        p.viewportHeight = viewport
        p.textScale = CGFloat(textScale)
        p.allocation = scenario.parameters
        return p
    }

    /// The two partitions (for the window starting at D and the one starting at D+1). Planned only when the day, N, text size or viewport change.
    private func computeState(viewport: CGFloat) -> GridState {
        let p = parameters(viewport: max(viewport, 1))
        let main = firstWindow
        let days = scenario.days
        func plan(_ main: Int) -> TemporalGridPartition {
            store.plan(window: TemporalWindow(days: Array(days[(main - 1)...(main + 2)]), mainIndex: 1), parameters: p).partition
        }
        return GridState(a: plan(main), b: plan(min(main + 1, windows.upperBound)))
    }

    // MARK: Grid

    private static let gutter: CGFloat = 58

    private func grid(width: CGFloat) -> some View {
        GeometryReader { area in
            let viewport = area.size.height
            let state = computeState(viewport: viewport)
            let blend = TemporalGridPartition.interpolated(from: state.a, to: state.b, progress: progress) ?? state.a
            let shown = blend.zoomed(viewportHeight: viewport, zoomScale: CGFloat(zoom))
            let a = state.a.zoomed(viewportHeight: viewport, zoomScale: CGFloat(zoom)), b = state.b.zoomed(viewportHeight: viewport, zoomScale: CGFloat(zoom))
            ScrollView(.vertical, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    cells(shown: shown, a: a, b: b, width: width)
                    columns(partition: shown, width: width)
                }
                .frame(width: width, height: shown.totalHeight, alignment: .topLeading)
            }
        }
    }

    private func cells(shown: TemporalGridPartition, a: TemporalGridPartition, b: TemporalGridPartition, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<shown.slotCount, id: \.self) { slot in
                let compression = SlotCompression(minutes: shown.minutes(inSlot: slot))
                let top = shown.top(ofSlot: slot)
                Rectangle().fill(Self.tint(compression)).frame(width: width, height: shown.slotHeight).offset(y: top)
                // The line at the top of the cell: the same y at every p.
                Path { path in path.move(to: CGPoint(x: 0, y: top)); path.addLine(to: CGPoint(x: width, y: top)) }
                    .stroke(Color.secondary.opacity(Self.lineOpacity(compression)), style: StrokeStyle(lineWidth: compression == .normal ? 0.8 : 1, dash: compression >= .dashed ? [4, 3] : []))
                label(slot: slot, a: a, b: b, compression: compression)
                    .frame(width: Self.gutter - 4, height: shown.slotHeight, alignment: .topLeading)
                    .offset(x: 3, y: top)
                if compression == .folded {
                    Text("⌇ 접힘").font(.system(size: 8)).foregroundStyle(.orange).offset(x: 6, y: top + shown.slotHeight - 12)
                }
            }
        }
    }

    /// The cell's start and end, crossfading from the day before's to the day after's while p changes.
    private func label(slot: Int, a: TemporalGridPartition, b: TemporalGridPartition, compression: SlotCompression) -> some View {
        ZStack(alignment: .topLeading) {
            cellText(a, slot, compression).opacity(1 - progress)
            cellText(b, slot, compression).opacity(progress)
        }
    }

    private func cellText(_ partition: TemporalGridPartition, _ slot: Int, _ compression: SlotCompression) -> some View {
        let own = SlotCompression(minutes: partition.minutes(inSlot: slot))
        return VStack(alignment: .leading, spacing: 0) {
            Text(Self.fmt(partition.start(ofSlot: slot))).font(.system(size: 10, weight: .semibold)).monospacedDigit()
            if own >= .light || partition.slotHeight >= 44 {
                Text("~\(Self.fmt(partition.end(ofSlot: slot)))").font(.system(size: 8)).foregroundStyle(.secondary).monospacedDigit()
            }
            if own >= .dashed {
                Text(Self.duration(partition.minutes(inSlot: slot))).font(.system(size: 8, weight: .medium)).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Columns

    private func columns(partition: TemporalGridPartition, width: CGFloat) -> some View {
        let columnWidth = (width - Self.gutter) / 2
        let metrics = EventPresentation.Metrics.standard(scale: CGFloat(textScale))
        let pitch = GridPlacement.transactionPitch(scenario.parameters, textScale: CGFloat(textScale))
        let first = firstWindow
        return HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { offset in
                let day = scenario.days[first + offset]
                column(day: day, partition: partition, metrics: metrics, pitch: pitch, width: columnWidth, role: offset == 0 ? "D" : (offset == 1 ? "D+1" : "D+2"))
            }
        }
        // The three days slide left by one column as p goes 0 → 1: the day swipe.
        .offset(x: Self.gutter - CGFloat(progress) * columnWidth)
        .frame(width: width, alignment: .leading)
        .clipShape(Rectangle().path(in: CGRect(x: Self.gutter, y: 0, width: width - Self.gutter, height: partition.totalHeight)))
    }

    private func column(day: AllocationDay, partition: TemporalGridPartition, metrics: EventPresentation.Metrics, pitch: CGFloat, width: CGFloat, role: String) -> some View {
        counters.placements += 1
        let entities = GridDayEntities.make(day)
        let placed = GridPlacement.place(entities, partition: partition, metrics: metrics, transactionPitch: pitch)
        let scale = CGFloat(textScale)
        return ZStack(alignment: .topLeading) {
            Text("\(role)  \(placed.events.count)일정").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).offset(x: 3, y: 1)
            ForEach(placed.events, id: \.id) { event in
                eventView(event, title: entities.events.first { $0.id == event.id }?.title ?? "", width: width, scale: scale)
            }
            ForEach(Array(placed.independent.enumerated()), id: \.offset) { _, transaction in
                transactionView(transaction, width: width, scale: scale)
            }
        }
        .frame(width: width, height: partition.totalHeight, alignment: .topLeading)
    }

    private func eventView(_ event: GridEventPlacement, title: String, width: CGFloat, scale: CGFloat) -> some View {
        let presentation = event.presentation
        let drawn = max(event.height, 2)
        let tint = Self.color(for: event.id)
        let top = event.top - (drawn - event.height) / 2
        let touch = max(drawn, 44)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: min(4, drawn / 2))
                .fill(tint.opacity(0.10 + 0.20 * presentation.card + (1 - presentation.card) * 0.55))
                .overlay(RoundedRectangle(cornerRadius: min(4, drawn / 2)).stroke(tint.opacity(0.35 + 0.4 * (1 - presentation.card)), lineWidth: presentation.card > 0.5 ? 0.8 : 0))
                .frame(width: width - 26, height: drawn)
            if presentation.title > 0 {
                Text(title).font(.system(size: 12 * scale, weight: .semibold)).lineLimit(1).opacity(presentation.title)
                    .padding(.horizontal, 4).padding(.top, 2 * scale).frame(width: width - 26, alignment: .leading)
            }
            if presentation.endTime > 0 {
                Text("\(Self.fmt(Double(event.startMinute)))–\(Self.fmt(Double(event.endMinute)))").font(.system(size: 9 * scale)).monospacedDigit()
                    .foregroundStyle(.secondary).opacity(presentation.endTime).padding(.horizontal, 4)
                    .frame(width: width - 26, height: drawn, alignment: .bottomLeading).padding(.bottom, 2)
            }
        }
        .frame(width: width - 26, height: drawn, alignment: .topLeading)
        .offset(x: 4, y: top)
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: width - 26, height: touch).contentShape(Rectangle())
                .offset(x: 4, y: event.top - (touch - event.height) / 2)
                .onTapGesture { selected = "\(title) \(Self.fmt(Double(event.startMinute)))–\(Self.fmt(Double(event.endMinute)))" }
        }
    }

    private func transactionView(_ transaction: GridTransactionPlacement, width: CGFloat, scale: CGFloat) -> some View {
        ZStack(alignment: .trailing) {
            if transaction.reveal > 0.5 {
                Text("₩4,500 \(transaction.id.suffix(3))").font(.system(size: 10 * scale)).monospacedDigit().opacity(transaction.reveal >= 1 ? 1 : (transaction.reveal - 0.5) * 2)
                    .padding(.trailing, 12)
            }
            Circle().fill(Color.pink).frame(width: 6, height: 6).offset(x: 3)
        }
        .frame(width: width - 4, height: 14, alignment: .trailing)
        .offset(x: 0, y: transaction.y - 7)
        .onTapGesture { selected = "거래 \(transaction.id) \(Self.fmt(Double(transaction.minute)))" }
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

    static func tint(_ compression: SlotCompression) -> Color {
        switch compression {
        case .normal: return .clear
        case .light: return Color.gray.opacity(0.04)
        case .dashed: return Color.gray.opacity(0.09)
        case .folded: return Color.orange.opacity(0.10)
        }
    }

    static func lineOpacity(_ compression: SlotCompression) -> Double {
        switch compression {
        case .normal: return 0.55
        case .light: return 0.3
        case .dashed: return 0.3
        case .folded: return 0.45
        }
    }

    static func color(for id: String) -> Color {
        let palette: [Color] = [.blue, .green, .purple, .orange, .teal, .indigo]
        var hash = 0
        for scalar in id.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }
}
#endif
