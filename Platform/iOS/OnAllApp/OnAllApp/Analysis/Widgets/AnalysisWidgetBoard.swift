import SwiftUI
import UIKit

struct WidgetPlacement: Codable, Identifiable, Equatable {
    var id = UUID()
    var spec: WidgetSpec
}

/// The user's widget list, kept on the device.
enum WidgetLayoutStore {
    static let key = "analysis.widgets.v1"
    static let standard: [WidgetSpec] = [
        .spec(.balance, .meter, .medium), .spec(.spent, .number, .small), .spec(.pending, .number, .small), .spec(.category, .list, .medium),
    ]

    static func load(_ defaults: UserDefaults = .standard) -> [WidgetPlacement] {
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([WidgetPlacement].self, from: data) {
            return saved.filter { WidgetSpec.all.contains($0.spec) }
        }
        return standard.map { WidgetPlacement(spec: $0) }
    }

    static func save(_ placements: [WidgetPlacement], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(placements) { defaults.set(data, forKey: key) }
    }
}

/// The top of the analysis tab: the widget grid, edit mode, and the add panel. Tapping a widget opens 모든 분석.
/// Add = tap a variant (goes to the end) or long-press it and drag onto the grid (lands where dropped). Placed widgets can be dragged too.
struct AnalysisWidgetBoard: View {
    let model: AppModel
    let snapshot: AnalysisSnapshot
    @Binding var month: AnalysisMonth

    private static let space = "analysisBoard"
    private static let sideMargin: CGFloat = 26
    private static let placeholderID = UUID()

    private enum Panel: Equatable { case closed, list, gallery(WidgetTopic) }

    private struct Drag {
        var spec: WidgetSpec
        var sourceID: UUID?
        var frozenFrame: CGRect?
        var location: CGPoint
        var index: Int
    }

    @State private var placements = WidgetLayoutStore.load()
    @State private var editing = false
    @State private var selected: UUID?
    @State private var panel = Panel.closed
    @State private var panelShown = false
    @State private var sizeFilter: WidgetSize?
    @State private var drag: Drag?
    @State private var gridFrame = CGRect.zero
    @State private var showAll = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var data: AnalysisWidgetData { .make(rows: snapshot.rows, month: month, today: snapshot.today) }
    private var motion: Animation { Theme.Motion.resolved(Theme.Motion.widgetRearrange, reduceMotion: reduceMotion) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width - Self.sideMargin * 2
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        VStack(spacing: 0) {
                            grid(width: width).padding(.horizontal, Self.sideMargin).padding(.top, 14)
                            if editing { sizePicker; addButton }
                        }
                        .padding(.bottom, Theme.Space.xxl)
                    }
                    .scrollIndicators(.hidden)
                }
                if panel != .closed {
                    Theme.textPrimary.opacity(panelShown ? 0.42 : 0).ignoresSafeArea().onTapGesture { closePanel() }.allowsHitTesting(drag == nil)
                    panelView(width: proxy.size.width - Theme.cardMargin * 2, height: proxy.size.height)
                        .offset(y: panelShown ? 0 : proxy.size.height)
                }
                if let drag {
                    let box = WidgetPacker.size(drag.spec.size, unit: WidgetPacker.unit(width: width))
                    AnalysisWidgetView(spec: drag.spec, data: data, size: box)
                        .scaleEffect(1.04).shadow(color: .black.opacity(0.2), radius: 14, y: 8)
                        .position(drag.location).allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: Self.space)
        }
        .background(Theme.background)
        .navigationDestination(isPresented: $showAll) { AnalysisHome(model: model, snapshot: snapshot, month: $month) }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: placements) { _, new in WidgetLayoutStore.save(new) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "\(month.year)년").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).frame(height: 18)
                Text("분석").font(Theme.Typo.h1).tracking(-0.5).foregroundStyle(Theme.textPrimary).frame(height: 34)
            }
            Spacer()
            Menu {
                ForEach(0..<6, id: \.self) { back in
                    let option = AnalysisMonth(snapshot.today).moved(by: -back)
                    Button(option.title) { month = option }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(month.month)월")
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                }
                .font(.onAll(size: 15, weight: .medium)).foregroundStyle(Theme.textSecondary).frame(minHeight: Theme.hitTarget)
            }
            Button(editing ? "완료" : "편집") { withAnimation(motion) { editing.toggle(); selected = nil; if !editing { closePanel() } } }
                .font(.onAll(size: 15, weight: .semibold)).foregroundStyle(Theme.accent).frame(minWidth: 36, minHeight: Theme.hitTarget).padding(.leading, 6)
        }
        .padding(.horizontal, 24).padding(.top, 16)
    }

    // MARK: Grid

    /// What is laid out now: the widgets, minus the one being dragged, with an empty slot where the drag would land.
    private func layout(width: CGFloat) -> (frames: [UUID: CGRect], height: CGFloat, slot: CGRect?) {
        var items = placements.filter { $0.id != drag?.sourceID }.map { ($0.id, $0.spec.size) }
        if let drag { items.insert((Self.placeholderID, drag.spec.size), at: min(drag.index, items.count)) }
        let packed = WidgetPacker.frames(items.map(\.1), width: width)
        var frames: [UUID: CGRect] = [:]
        for (item, frame) in zip(items, packed.frames) { frames[item.0] = frame }
        return (frames, packed.height, frames[Self.placeholderID])
    }

    private func grid(width: CGFloat) -> some View {
        let packed = layout(width: width)
        let unit = WidgetPacker.unit(width: width)
        return ZStack(alignment: .topLeading) {
            if let slot = packed.slot {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.accentLine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(Theme.accentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .frame(width: slot.width, height: slot.height).offset(x: slot.minX, y: slot.minY)
            }
            ForEach(placements) { placement in
                let isSource = placement.id == drag?.sourceID
                let frame = packed.frames[placement.id] ?? drag?.frozenFrame ?? .zero
                widget(placement, unit: unit)
                    .opacity(isSource ? 0 : 1)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: width, height: max(packed.height, 1), alignment: .topLeading)
        .animation(motion, value: packed.frames)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { gridFrame = $0 }
    }

    private func widget(_ placement: WidgetPlacement, unit: CGFloat) -> some View {
        let box = WidgetPacker.size(placement.spec.size, unit: unit)
        let lifted = editing && selected == placement.id
        return AnalysisWidgetView(spec: placement.spec, data: data, size: box)
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: 25, style: .continuous).strokeBorder(Theme.accentLine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .padding(-3).opacity(lifted ? 0 : 1)
                }
            }
            .background { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface).shadow(color: .black.opacity(lifted ? 0.2 : 0), radius: 14, y: 10) }
            .overlay(alignment: .topLeading) {
                if editing {
                    Button { remove(placement.id) } label: {
                        Text("−").font(.system(size: 18, weight: .medium)).foregroundStyle(.white).frame(width: 26, height: 26)
                            .background(Theme.actionBar, in: Circle()).overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
                            .frame(width: Theme.hitTarget, height: Theme.hitTarget)
                    }
                    .offset(x: -18, y: -18).accessibilityLabel("\(placement.spec.topic.title) 지우기")
                    .transition(.opacity)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture {
                if editing { withAnimation(motion) { selected = selected == placement.id ? nil : placement.id } } else { showAll = true }
            }
            .gesture(pickGesture(spec: placement.spec, source: placement.id))
    }

    private var sizePicker: some View {
        let current = placements.first { $0.id == selected }
        return Group {
            if let current, current.spec.sizes().count > 1 {
                HStack(spacing: 4) {
                    ForEach(current.spec.sizes(), id: \.size) { option in
                        let on = option.size == current.spec.size
                        Button { resize(current.id, to: option.size) } label: {
                            Text(option.size.title).font(.onAll(size: 13, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Theme.accentStrong : Theme.textTertiary)
                                .padding(.horizontal, 18).frame(height: Theme.segmentHeight)
                                .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous))
                .padding(.top, 12)
            }
        }
    }

    private var addButton: some View {
        Button { openPanel(.list) } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                Text("위젯 추가").font(.onAll(size: 15, weight: .semibold))
            }
            .foregroundStyle(Theme.accent).frame(maxWidth: .infinity, minHeight: Theme.primaryButtonHeight)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).strokeBorder(Theme.accentLine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
        .padding(.horizontal, Theme.cardMargin).padding(.top, 16)
    }

    // MARK: Changes

    private func remove(_ id: UUID) { withAnimation(motion) { placements.removeAll { $0.id == id }; if selected == id { selected = nil } } }

    private func resize(_ id: UUID, to size: WidgetSize) {
        guard let index = placements.firstIndex(where: { $0.id == id }), let next = placements[index].spec.sizes().first(where: { $0.size == size }) else { return }
        withAnimation(motion) { placements[index].spec = next }
    }

    /// Tap on a gallery variant: it goes to the end and the panel closes, still in edit mode.
    private func addToEnd(_ spec: WidgetSpec) {
        let placement = WidgetPlacement(spec: spec)
        withAnimation(motion) { placements.append(placement); editing = true; selected = placement.id }
        closePanel()
    }

    // MARK: Drag

    private func pickGesture(spec: WidgetSpec, source: UUID?) -> some Gesture {
        LongPressGesture(minimumDuration: Theme.Motion.longPressSeconds)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                guard case .second(true, let touch?) = value else { return }
                if drag == nil { beginDrag(spec: spec, source: source, at: touch.location) } else { moveDrag(to: touch.location) }
            }
            .onEnded { _ in if drag != nil { dropDrag() } }
    }

    private func gridWidth() -> CGFloat { gridFrame.width }

    private func insertionIndex(at location: CGPoint, excluding source: UUID?) -> Int {
        let rest = placements.filter { $0.id != source }
        let frames = WidgetPacker.frames(rest.map(\.spec.size), width: gridWidth()).frames
        return WidgetPacker.insertionIndex(frames, at: CGPoint(x: location.x - gridFrame.minX, y: location.y - gridFrame.minY))
    }

    private func beginDrag(spec: WidgetSpec, source: UUID?, at location: CGPoint) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        var frozen: CGRect?
        if let source, let index = placements.firstIndex(where: { $0.id == source }) {
            frozen = WidgetPacker.frames(placements.map(\.spec.size), width: gridWidth()).frames[index]
        }
        withAnimation(motion) {
            editing = true
            panelShown = false
            drag = Drag(spec: spec, sourceID: source, frozenFrame: frozen, location: location, index: insertionIndex(at: location, excluding: source))
        }
    }

    private func moveDrag(to location: CGPoint) {
        guard var current = drag else { return }
        current.location = location
        let index = insertionIndex(at: location, excluding: current.sourceID)
        if index != current.index { UISelectionFeedbackGenerator().selectionChanged() }
        current.index = index
        drag = current
    }

    private func dropDrag() {
        guard let current = drag else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(motion) {
            var rest = placements.filter { $0.id != current.sourceID }
            let placed = placements.first { $0.id == current.sourceID } ?? WidgetPlacement(spec: current.spec)
            rest.insert(placed, at: min(current.index, rest.count))
            placements = rest
            selected = placed.id
            drag = nil
        }
        panel = .closed
    }

    // MARK: Add panel

    private func openPanel(_ next: Panel) {
        panel = next
        withAnimation(Theme.Motion.sheet) { panelShown = true }
    }

    private func closePanel() {
        withAnimation(Theme.Motion.sheet) { panelShown = false }
        Task { try? await Task.sleep(for: .milliseconds(350)); if !panelShown { panel = .closed; sizeFilter = nil } }
    }

    private func panelView(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(Theme.disabled).frame(width: 36, height: 4).padding(.top, 8).padding(.bottom, 14)
            switch panel {
            case .gallery(let topic): gallery(topic, width: width)
            default: topicList
            }
        }
        .frame(maxWidth: .infinity).frame(height: height, alignment: .top)
        .background(Theme.surface, in: UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.sheet, topTrailingRadius: Theme.Radius.sheet, style: .continuous))
        .ignoresSafeArea(edges: .bottom)
    }

    private var topicList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("위젯 추가").font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 24).padding(.vertical, Theme.Space.m)
            ScrollView {
                ForEach(WidgetTopic.allCases, id: \.self) { topic in
                    Button { sizeFilter = nil; panel = .gallery(topic) } label: {
                        HStack(spacing: Theme.Space.m) {
                            Thumbnail(topic: topic)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                                Text(styleSummary(topic)).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 24).frame(minHeight: 64).contentShape(Rectangle())
                    }
                    .buttonStyle(.onAllRow)
                    if topic != WidgetTopic.allCases.last { Divider().overlay(Theme.divider).padding(.horizontal, 24) }
                }
            }
        }
    }

    private func styleSummary(_ topic: WidgetTopic) -> String {
        var seen: [String] = []
        for spec in WidgetSpec.variants(of: topic) where !seen.contains(spec.style.title) { seen.append(spec.style.title) }
        return seen.joined(separator: " · ")
    }

    private func gallery(_ topic: WidgetTopic, width: CGFloat) -> some View {
        let unit = WidgetPacker.unit(width: width)
        let variants = WidgetSpec.variants(of: topic).filter { sizeFilter == nil || $0.size == sizeFilter }
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Button { panel = .list } label: { Image(systemName: "chevron.left").font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary).frame(width: Theme.hitTarget, height: Theme.hitTarget) }
                    .accessibilityLabel("뒤로")
                Text(topic.title).font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, Theme.Space.s)
            HStack(spacing: Theme.Space.s) {
                chip("전체", isOn: sizeFilter == nil) { sizeFilter = nil }
                ForEach(WidgetSize.allCases, id: \.self) { size in chip(size.title, isOn: sizeFilter == size) { sizeFilter = size } }
            }
            .padding(.horizontal, Theme.cardMargin)
            ScrollView {
                VStack(spacing: Theme.Space.m) {
                    ForEach(variants) { spec in
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            HStack {
                                Text(spec.style.title).font(Theme.Typo.label).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text("\(spec.size.title) \(spec.size.spec)").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                            }
                            AnalysisWidgetView(spec: spec, data: data, size: WidgetPacker.size(spec.size, unit: unit))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.divider))
                                .contentShape(Rectangle())
                                .onTapGesture { addToEnd(spec) }
                                .gesture(pickGesture(spec: spec, source: nil))
                        }
                    }
                }
                .padding(.horizontal, Theme.cardMargin).padding(.bottom, Theme.Space.xxl)
            }
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.Typo.chip).foregroundStyle(isOn ? Theme.accentStrong : Theme.textSecondary)
                .padding(.horizontal, Theme.Space.m).frame(height: Theme.chipHeight)
                .background(isOn ? Theme.accentSoft : Theme.fill, in: Capsule())
        }
    }
}

/// The small picture beside a topic in the add list: a miniature of how that topic is drawn.
private struct Thumbnail: View {
    let topic: WidgetTopic

    var body: some View {
        Group {
            switch topic {
            case .week, .monthTrend: bars
            case .category, .activity, .pending: rows
            case .calendar: split
            default: number
            }
        }
        .frame(width: 76, height: 48).background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array([0.45, 0.3, 0.8, 0.5, 0.65, 1.0, 0.4].enumerated()), id: \.offset) { index, h in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(index == 5 ? Theme.accent : Theme.accentLine).frame(width: 6, height: 26 * h)
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 5) {
            ForEach(Array([1.0, 0.6, 0.35].enumerated()), id: \.offset) { index, w in
                HStack(spacing: 4) {
                    Circle().fill(Theme.accentLine).frame(width: 7, height: 7)
                    Capsule().fill(index == 0 ? Theme.accent : Theme.accentLine).frame(width: 36 * w, height: 4)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var split: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 1.5) {
                ForEach(Array([27.0, 52, 9, 12].enumerated()), id: \.offset) { index, w in
                    Rectangle().fill([Theme.CalendarTint.blue.color, Theme.CalendarTint.orange.color, Theme.CalendarTint.green.color, Theme.disabled][index]).frame(width: w * 0.5)
                }
            }
            .clipShape(Capsule()).frame(height: 6)
            Capsule().fill(Theme.accentLine).frame(width: 30, height: 4)
        }
    }

    private var number: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(Theme.disabled.opacity(0.6)).frame(width: 22, height: 3)
            Capsule().fill(Theme.accent).frame(width: 44, height: 8)
        }
    }
}
