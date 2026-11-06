import SwiftUI

#if DEBUG
/// `-precision-bubble-fixture [scenario]`: the precision bubble on a stand-in grid, on its own. One synthetic event on a plain 24-hour day inside the real
/// `PinchZoomScrollView` (scroll, 1–8× pinch), its two handles, and the bubble over the scroll view kept in place by `PrecisionAnchorTracker`. The fixture
/// plays the owner of the edit: it moves its own minutes by ±15 when the bubble asks; the bubble itself computes nothing.
///
/// Tap a handle dot to open its bubble. Scenarios (for screenshots): `center`, `top` (start handle near the top → below), `bottom` (end handle near the
/// bottom → above), `left` / `right` (card at a screen edge), `zoomed` (6×), `offscreen` (handle scrolled away → pinned), `ax` (accessibility text),
/// `limit` (end 15 minutes after start: steps that would cross are off).
struct PrecisionBubbleFixture: View {
    @StateObject private var state = PrecisionBubbleFixtureState()
    @StateObject private var pinch = PinchZoomModel()
    @StateObject private var tracker = PrecisionAnchorTracker()
    @State private var typeSize: DynamicTypeSize = .large

    static let launchArgument = "-precision-bubble-fixture"
    private static let gutter: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            controls
            GeometryReader { proxy in
                PinchZoomScrollView(model: pinch, onDateDrag: { _ in }) { zoom, viewport, _ in
                    content(width: proxy.size.width, zoom: zoom, viewport: viewport)
                }
                .overlay {
                    TrackedPrecisionBubbleOverlay(input: state.input, tracker: tracker, onAction: state.apply)
                        .dynamicTypeSize(typeSize)
                }
                .onAppear { state.width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in state.width = width }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .task { await start() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("경계", selection: $state.edge) {
                Text("시작").tag(PrecisionEdge?.some(.start))
                Text("종료").tag(PrecisionEdge?.some(.end))
                Text("닫힘").tag(PrecisionEdge?.none)
            }
            .pickerStyle(.segmented)
            HStack {
                Picker("위치", selection: $state.column) {
                    ForEach(PrecisionBubbleFixtureState.Column.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("글자", selection: $typeSize) {
                    Text("기본").tag(DynamicTypeSize.large)
                    Text("xxxL").tag(DynamicTypeSize.xxxLarge)
                    Text("AX3").tag(DynamicTypeSize.accessibility3)
                }
                .pickerStyle(.menu)
            }
            Text(state.summary + " · 줌 \(String(format: "%.1f", pinch.zoom))×")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("fixture-summary")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .dynamicTypeSize(.large)
    }

    private func content(width: CGFloat, zoom: CGFloat, viewport: CGFloat) -> some View {
        let height = max(1, viewport * zoom)
        let card = state.cardFrame(width: width, contentHeight: height)
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: width, height: height)
            ForEach(0...24, id: \.self) { hour in
                let y = height * CGFloat(hour) / 24
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: width - Self.gutter, height: 0.5).offset(x: Self.gutter, y: y)
                if hour < 24 {
                    Text(Formatting.hourLabel(hour)).font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: Self.gutter - 6, alignment: .trailing).offset(y: y - 6)
                }
                if zoom >= 3, hour < 24 {
                    ForEach(1...3, id: \.self) { quarter in
                        Rectangle().fill(Color.secondary.opacity(0.12)).frame(width: width - Self.gutter, height: 0.5)
                            .offset(x: Self.gutter, y: y + height / 96 * CGFloat(quarter))
                    }
                }
            }
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    Text("팀 회의").font(.caption.weight(.semibold)).padding(6)
                }
                .frame(width: card.width, height: card.height)
                .offset(x: card.minX, y: card.minY)
            handle(.start, at: EditHit.startHandle(of: card))
            handle(.end, at: EditHit.endHandle(of: card))
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func handle(_ edge: PrecisionEdge, at center: CGPoint) -> some View {
        let target = EditHit.touchFrame(around: center)
        return Circle().fill(Color.white).overlay(Circle().stroke(Color.accentColor, lineWidth: 2)).frame(width: 12, height: 12)
            .frame(width: target.width, height: target.height)
            .contentShape(Circle())
            .onTapGesture { state.edge = edge }
            .offset(x: target.minX, y: target.minY)
            .accessibilityElement()
            .accessibilityLabel(edge == .start ? "시작 핸들" : "종료 핸들")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { state.edge = edge }
    }

    private func start() async {
        tracker.track { [weak state, weak pinch] in
            guard let state, let pinch, state.edge != nil, let offset = pinch.currentOffset?(), pinch.viewportHeight > 1 else { return nil }
            return state.anchorInViewport(zoom: pinch.zoom, viewport: pinch.viewportHeight, offset: offset)
        }
        guard let scenario = Self.scenario else { return }
        try? await Task.sleep(for: .milliseconds(400))                                 // the scroll view is attached and laid out
        apply(scenario)
    }

    static var scenario: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: launchArgument), arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("-") else { return nil }
        return arguments[index + 1]
    }

    /// Puts the grid where a scenario wants the handle: `zoom`, then the handle's time `fromTop` points below the top of the viewport.
    private func apply(_ scenario: String) {
        let viewport = pinch.viewportHeight
        func show(_ edge: PrecisionEdge, zoom: CGFloat, fromTop: CGFloat) {
            state.edge = edge
            pinch.setZoom?(zoom, 0)
            let minute = edge == .start ? state.startMinute : state.endMinute
            _ = pinch.setOffset?(viewport * zoom * CGFloat(minute) / 1440 - fromTop)
        }
        switch scenario {
        case "top": show(.start, zoom: 3, fromTop: 30)
        case "bottom": show(.end, zoom: 3, fromTop: viewport - 30)
        case "left": state.column = .left; show(.end, zoom: 2, fromTop: viewport * 0.4)
        case "right": state.column = .right; show(.start, zoom: 2, fromTop: viewport * 0.5)
        case "zoomed": show(.start, zoom: 6, fromTop: viewport * 0.45)
        case "offscreen": show(.start, zoom: 4, fromTop: -80)
        case "ax": typeSize = .accessibility3; show(.start, zoom: 2, fromTop: viewport * 0.45)
        case "limit": state.endMinute = state.startMinute + 15; show(.end, zoom: 4, fromTop: viewport * 0.4)
        default: show(.start, zoom: 1, fromTop: viewport * CGFloat(state.startMinute) / 1440)
        }
    }
}

/// The fixture's stand-in for an edit's owner: one event's minutes on one day, moved by the bubble's actions, kept at least 15 minutes long.
@MainActor
final class PrecisionBubbleFixtureState: ObservableObject {
    enum Column: CaseIterable { case left, center, right
        var title: String { switch self { case .left: "왼쪽"; case .center: "가운데"; case .right: "오른쪽" } }
    }

    @Published var edge: PrecisionEdge? = .start
    @Published var startMinute = 9 * 60
    @Published var endMinute = 10 * 60 + 30
    @Published var column = Column.center
    var width: CGFloat = 0

    private let zone = TimeZone(identifier: "Asia/Seoul")!
    /// 2026-10-13 00:00 in Seoul.
    private let dayStart = Date(timeIntervalSince1970: 1_791_817_200)
    private static let step = 15

    var input: PrecisionBubbleInput? {
        guard let edge else { return nil }
        let minute = edge == .start ? startMinute : endMinute
        let (low, high) = edge == .start ? (0, endMinute - Self.step) : (startMinute + Self.step, 24 * 60)
        return PrecisionBubbleInput(
            edge: edge, instant: dayStart.addingTimeInterval(TimeInterval(minute * 60)), timeZone: zone,
            canDecrement: minute - Self.step >= low, canIncrement: minute + Self.step <= high,
            choices: PrecisionWheelChoices.make(
                low: dayStart.addingTimeInterval(TimeInterval(low * 60)), high: dayStart.addingTimeInterval(TimeInterval(high * 60)), dayStart: dayStart
            )
        )
    }

    var summary: String { "시작 \(Formatting.clock(minute: startMinute)) · 종료 \(Formatting.clock(minute: endMinute))" }

    func apply(_ action: PrecisionBubbleAction) {
        guard let edge, let input else { return }
        switch action {
        case .dismiss: self.edge = nil
        case .decrement15 where input.canDecrement:
            if edge == .start { startMinute -= Self.step } else { endMinute -= Self.step }
        case .increment15 where input.canIncrement:
            if edge == .start { startMinute += Self.step } else { endMinute += Self.step }
        case let .set(instant):
            let minute = Int(instant.timeIntervalSince(dayStart) / 60)
            if edge == .start { startMinute = minute } else { endMinute = minute }
        default: break
        }
    }

    /// The card in the content: a third of the day column, at the chosen place.
    func cardFrame(width: CGFloat, contentHeight: CGFloat) -> CGRect {
        let gutter: CGFloat = 52
        let column = max(0, width - gutter)
        let cardWidth = column * 0.42
        let x: CGFloat = switch self.column {
        case .left: gutter + 2
        case .center: gutter + (column - cardWidth) / 2
        case .right: width - cardWidth - 2
        }
        let top = contentHeight * CGFloat(startMinute) / 1440, bottom = contentHeight * CGFloat(endMinute) / 1440
        return CGRect(x: x, y: top, width: cardWidth, height: bottom - top)
    }

    func anchorInViewport(zoom: CGFloat, viewport: CGFloat, offset: CGFloat) -> CGPoint? {
        guard let edge else { return nil }
        let card = cardFrame(width: width, contentHeight: viewport * zoom)
        let content = edge == .start ? EditHit.startHandle(of: card) : EditHit.endHandle(of: card)
        return PrecisionAnchorTracker.viewportPoint(content: content, offset: offset)
    }
}

// MARK: - Previews

private struct PrecisionPreviewStage: View {
    let input: PrecisionBubbleInput?
    let anchor: CGPoint
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemGroupedBackground)
            Circle().fill(Color.white).overlay(Circle().stroke(Color.accentColor, lineWidth: 2)).frame(width: 12, height: 12)
                .offset(x: anchor.x - 6, y: anchor.y - 6)
            PrecisionBubbleOverlay(input: input, anchor: anchor) { print("precision bubble:", $0) }
        }
        .frame(width: 393, height: 420)
    }
}

private let previewDay = Date(timeIntervalSince1970: 1_791_817_200 + 14 * 3600 + 15 * 60)
private let previewZone = TimeZone(identifier: "Asia/Seoul")!

#Preview("시작 · 위") {
    PrecisionPreviewStage(input: PrecisionBubbleInput(edge: .start, instant: previewDay, timeZone: previewZone), anchor: CGPoint(x: 220, y: 260))
}

#Preview("종료 · 아래, 늦추기 불가") {
    PrecisionPreviewStage(input: PrecisionBubbleInput(edge: .end, instant: previewDay, timeZone: previewZone, canIncrement: false), anchor: CGPoint(x: 120, y: 120))
}

#Preview("위쪽 끝 → 아래로") {
    PrecisionPreviewStage(input: PrecisionBubbleInput(edge: .start, instant: previewDay, timeZone: previewZone), anchor: CGPoint(x: 370, y: 30))
}

#Preview("자정 종료 · AX3") {
    PrecisionPreviewStage(input: PrecisionBubbleInput(edge: .end, instant: previewDay.addingTimeInterval(9 * 3600 + 45 * 60), timeZone: previewZone), anchor: CGPoint(x: 60, y: 60))
        .dynamicTypeSize(.accessibility3)
}

#Preview("고정 격자 대역") { PrecisionBubbleFixture() }
#endif
