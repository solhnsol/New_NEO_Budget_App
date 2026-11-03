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
        WidgetSpec.all[12], WidgetSpec.all[14], WidgetSpec.all[0], WidgetSpec.all[8], WidgetSpec.all[10],
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
            let width = proxy.size.width - Theme.cardMargin * 2
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: Theme.Space.l) {
                        grid(width: width)
                        if editing { sizePicker; addButton }
                        allAnalysisRow
                    }
                    .padding(.horizontal, Theme.cardMargin).padding(.bottom, Theme.Space.xxl)
                }
                .scrollIndicators(.hidden)
                if panel != .closed {
                    Color.black.opacity(panelShown ? 0.3 : 0).ignoresSafeArea().onTapGesture { closePanel() }.allowsHitTesting(drag == nil)
                    panelView(width: width, height: proxy.size.height * 0.78)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(0..<6, id: \.self) { back in
                        let option = AnalysisMonth(snapshot.today).moved(by: -back)
                        Button(option.title) { month = option }
                    }
                } label: { Label("\(month.month)월", systemImage: "chevron.down").labelStyle(.titleAndIcon) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(editing ? "완료" : "편집") { withAnimation(motion) { editing.toggle(); selected = nil; if !editing { closePanel() } } }
            }
        }
        .onChange(of: placements) { _, new in WidgetLayoutStore.save(new) }
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
        return AnalysisWidgetView(spec: placement.spec, data: data, size: box)
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(selected == placement.id ? Theme.accent : Theme.accentLine, style: StrokeStyle(lineWidth: selected == placement.id ? 2 : 1, dash: selected == placement.id ? [] : [5, 4]))
                }
            }
            .overlay(alignment: .topLeading) {
                if editing {
                    Button { remove(placement.id) } label: {
                        Image(systemName: "minus").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(Theme.actionBar, in: Circle())
                            .frame(width: Theme.hitTarget, height: Theme.hitTarget)
                    }
                    .offset(x: -10, y: -10).accessibilityLabel("\(placement.spec.topic.title) 지우기")
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .onTapGesture {
                if editing { withAnimation(motion) { selected = selected == placement.id ? nil : placement.id } } else { showAll = true }
            }
            .gesture(pickGesture(spec: placement.spec, source: placement.id))
    }

    private var sizePicker: some View {
        let current = placements.first { $0.id == selected }
        return Group {
            if let current, current.spec.sizes().count > 1 {
                Picker("크기", selection: Binding(get: { current.spec.size }, set: { resize(current.id, to: $0) })) {
                    ForEach(current.spec.sizes(), id: \.size) { Text($0.size.title).tag($0.size) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 260)
            }
        }
    }

    private var addButton: some View {
        Button { openPanel(.list) } label: {
            Label("위젯 추가", systemImage: "plus").font(Theme.Typo.button).foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: Theme.primaryButtonHeight)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).strokeBorder(Theme.accentLine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
    }

    private var allAnalysisRow: some View {
        Button { showAll = true } label: {
            HStack {
                Text("모든 분석").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.l).frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.onAllRow)
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
            Capsule().fill(Theme.disabled).frame(width: 36, height: 5).padding(.vertical, Theme.Space.s)
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
                .padding(.horizontal, Theme.cardMargin).padding(.vertical, Theme.Space.m)
            ScrollView {
                ForEach(WidgetTopic.allCases, id: \.self) { topic in
                    Button { sizeFilter = nil; panel = .gallery(topic) } label: {
                        HStack(spacing: Theme.Space.m) {
                            IconTile(systemName: topic.symbol)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                                Text(styleSummary(topic)).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, Theme.cardMargin).frame(minHeight: Theme.rowHeight + 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.onAllRow)
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
                Button { panel = .list } label: { Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: Theme.hitTarget, height: Theme.hitTarget) }
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
                VStack(spacing: Theme.Space.l) {
                    ForEach(variants) { spec in
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
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
