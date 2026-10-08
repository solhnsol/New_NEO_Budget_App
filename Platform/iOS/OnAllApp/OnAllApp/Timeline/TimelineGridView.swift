import NEOBudgetCalendar
import SwiftUI
import UIKit

enum TimelineSelection: Identifiable {
    case block(EventBlock)
    case allDay(AllDayItem)
    case marker(TransactionMarkerItem)

    var id: String {
        switch self {
        case let .block(block): return "block-" + block.id.rawValue
        case let .allDay(item): return "allday-" + item.id.rawValue
        case let .marker(marker): return "marker-" + marker.transactionID.rawValue
        }
    }
}

enum Haptics {
    @MainActor static func pickUp() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    @MainActor static func snap() { UISelectionFeedbackGenerator().selectionChanged() }
}

/// The scrolling hour grid. Block geometry comes from `TimelineGeometry`; this view only draws it and forwards
/// gestures to the `TimelineEditor`. Nothing here writes to the calendar.
struct TimelineGridView: View {
    static let space = "timeline-grid"

    let timeline: DayTimeline
    let zone: DisplayTimeZone
    let isToday: Bool
    let editor: TimelineEditor?
    let onSelect: (TimelineSelection) -> Void
    @State private var pressStartY: CGFloat = 0

    var body: some View {
        let geometry = TimelineGeometry(totalMinutes: timeline.totalMinutes)
        let marks = geometry.hourMarks(dayStartUnixMilliseconds: timeline.dayStartUnixMilliseconds, zone: zone)
        ScrollViewReader { proxy in
            ScrollView {
                GeometryReader { size in
                    ZStack(alignment: .topLeading) {
                        ForEach(marks, id: \.elapsedMinute) { mark in
                            HourRow(mark: mark, geometry: geometry, width: size.size.width)
                        }
                        ForEach(timeline.blocks, id: \.id) { block in
                            let frame = geometry.blockFrame(block, totalWidth: size.size.width)
                            EditableBlockView(
                                block: block, zoneIdentifier: timeline.timeZoneIdentifier, timeline: timeline,
                                geometry: geometry, editor: editor, onTap: { onSelect(.block(block)) }
                            )
                            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                            .offset(x: frame.minX, y: frame.minY)
                        }
                        MarkerRail(timeline: timeline, geometry: geometry, width: size.size.width, onSelect: onSelect)
                        if let editor, let preview = editor.preview, let frame = editor.previewFrame(totalWidth: size.size.width) {
                            PreviewBlockView(preview: preview, zoneIdentifier: timeline.timeZoneIdentifier)
                                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                                .offset(x: frame.minX, y: frame.minY)
                                .allowsHitTesting(false)
                        }
                        if isToday { NowLine(timeline: timeline, geometry: geometry, width: size.size.width) }
                    }
                    .coordinateSpace(name: Self.space)
                }
                .frame(height: geometry.contentHeight)
                .background {
                    if let editor { pickUpHost(editor: editor, geometry: geometry) }
                }
                // Scroll anchors need real layout frames; `offset` does not move a view's frame.
                .background(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(marks, id: \.elapsedMinute) { mark in
                            Color.clear.frame(height: 60 * geometry.pointsPerMinute).id("minute-\(mark.elapsedMinute)")
                        }
                    }
                }
            }
            .scrollDisabled(editor?.isActive ?? false)
            .onAppear { scroll(proxy, geometry: geometry) }
            .onChange(of: timeline.day) { _, _ in scroll(proxy, geometry: geometry) }
        }
    }

    /// Long press then drag: on a block it picks the block up, on empty space it starts a new event.
    private func pickUpHost(editor: TimelineEditor, geometry: TimelineGeometry) -> some View {
        GeometryReader { size in
            LongPressDragHost(
                onBegan: { point in
                    pressStartY = point.y
                    if let block = block(at: point, width: size.size.width, geometry: geometry) {
                        if editor.begin(.move, block: block, timeline: timeline, geometry: geometry) { Haptics.pickUp() }
                    } else if editor.beginCreate(atY: point.y, timeline: timeline, geometry: geometry) {
                        Haptics.pickUp()
                    }
                },
                onMoved: { point in
                    if editor.isCreating { editor.updateCreate(toY: point.y) } else { editor.update(translationY: point.y - pressStartY) }
                },
                onEnded: { editor.finish() }
            )
        }
    }

    /// The topmost block under a point in grid coordinates.
    private func block(at point: CGPoint, width: CGFloat, geometry: TimelineGeometry) -> EventBlock? {
        timeline.blocks.last { geometry.blockFrame($0, totalWidth: width).contains(point) }
    }

    /// Starts near the first block, or the working day if the day is empty, so the screen does not open on 00:00.
    private func scroll(_ proxy: ScrollViewProxy, geometry: TimelineGeometry) {
        let target = max(0, (timeline.blocks.map(\.displayStartMinute).min() ?? 8 * 60) - 60)
        let hour = (target / 60) * 60
        proxy.scrollTo("minute-\(hour)", anchor: .top)
    }
}

// MARK: Gestures
// Moving and creating use `LongPressDragHost` (see `TimelineGridView.pickUpHost`); resize handles are plain drags.

private struct EditableBlockView: View {
    let block: EventBlock
    let zoneIdentifier: String
    let timeline: DayTimeline
    let geometry: TimelineGeometry
    let editor: TimelineEditor?
    let onTap: () -> Void

    @GestureState private var resizingTop = false
    @GestureState private var resizingBottom = false

    var body: some View {
        EventBlockView(block: block, zoneIdentifier: zoneIdentifier)
            .opacity(editor?.activeBlockID == block.id ? 0.3 : 1)
            .overlay { if let editor, block.isEditable, block.state == .normal { handles(editor) } }
            .onTapGesture(perform: onTap)
            .onChange(of: resizingTop) { _, isActive in if !isActive { editor?.finish() } }
            .onChange(of: resizingBottom) { _, isActive in if !isActive { editor?.finish() } }
    }

    private func handles(_ editor: TimelineEditor) -> some View {
        let height = geometry.y(minute: block.displayEndMinute) - geometry.y(minute: block.displayStartMinute)
        let zone = max(10, min(18, height / 3))
        return VStack(spacing: 0) {
            if !block.continuesFromPreviousDay {
                handle(.resizeStart, editor: editor, height: zone, state: $resizingTop, alignment: .top)
            } else {
                Color.clear.frame(height: zone)
            }
            Spacer(minLength: 0)
            if !block.continuesToNextDay {
                handle(.resizeEnd, editor: editor, height: zone, state: $resizingBottom, alignment: .bottom)
            } else {
                Color.clear.frame(height: zone)
            }
        }
    }

    private func handle(
        _ kind: TimelineEditPlanner.Kind, editor: TimelineEditor, height: CGFloat, state: GestureState<Bool>, alignment: Alignment
    ) -> some View {
        Color.clear
            .frame(height: height)
            .contentShape(Rectangle())
            .overlay(alignment: alignment) {
                Capsule().fill(.white).overlay(Capsule().stroke(Color.secondary.opacity(0.6), lineWidth: 0.5))
                    .frame(width: 26, height: 4).padding(.vertical, 2)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineGridView.space))
                    .updating(state) { _, flag, _ in flag = true }
                    .onChanged { drag in
                        if editor.mode == .idle {
                            guard editor.begin(kind, block: block, timeline: timeline, geometry: geometry) else { return }
                            Haptics.pickUp()
                        }
                        editor.update(translationY: drag.location.y - drag.startLocation.y)
                    }
            )
            .accessibilityHidden(true)
    }
}

private struct PreviewBlockView: View {
    let preview: TimelineEditor.Preview
    let zoneIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(preview.title ?? "새 일정").font(.caption.weight(.semibold)).lineLimit(1)
            Text(Formatting.timeRange(preview.range.startUnixMilliseconds, preview.range.endUnixMilliseconds, zoneIdentifier: zoneIdentifier))
                .font(.system(size: 11).monospacedDigit())
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.accentColor.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(preview.wasClamped ? Color.orange : Color.accentColor, lineWidth: 2))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

private struct HourRow: View {
    let mark: TimelineGeometry.HourMark
    let geometry: TimelineGeometry
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(Formatting.hourLabel(mark.wallHour))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: geometry.gutterWidth - 6, alignment: .trailing)
                .offset(y: -7)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 0.5)
                .padding(.leading, geometry.gutterWidth)
        }
        .frame(width: width, alignment: .topLeading)
        .offset(y: geometry.y(minute: mark.elapsedMinute))
        .accessibilityHidden(true)
    }
}

private struct NowLine: View {
    let timeline: DayTimeline
    let geometry: TimelineGeometry
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
                .padding(.leading, geometry.gutterWidth - 4)
                .frame(width: width, alignment: .leading)
                .offset(y: geometry.y(minute: minute) - 4)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
        }
    }
}

private struct MarkerRail: View {
    let timeline: DayTimeline
    let geometry: TimelineGeometry
    let width: CGFloat
    let onSelect: (TimelineSelection) -> Void

    var body: some View {
        let positions = geometry.markerYPositions(minutes: timeline.markers.map(\.positionMinute))
        ForEach(Array(timeline.markers.enumerated()), id: \.element.transactionID) { index, marker in
            Button { onSelect(.marker(marker)) } label: {
                HStack(spacing: 3) {
                    Image(systemName: marker.flow == .refund ? "arrow.uturn.backward.circle.fill" : "creditcard.fill")
                        .font(.caption2)
                    Text(Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .foregroundStyle(marker.flow == .refund ? Color.green : Color.orange)
                .background((marker.flow == .refund ? Color.green : Color.orange).opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(
                    marker.flow == .refund ? Color.green : Color.orange,
                    style: StrokeStyle(lineWidth: 1, dash: marker.timePrecision == .approximate ? [3] : [])
                ))
            }
            .buttonStyle(.plain)
            .frame(width: geometry.markerRailWidth - 4, alignment: .trailing)
            .offset(x: width - geometry.markerRailWidth, y: positions[index] - 10)
            .accessibilityLabel("지출 \(marker.title ?? "") \(Formatting.money(marker.amount.minorUnits, currency: marker.amount.currency))")
        }
    }
}
