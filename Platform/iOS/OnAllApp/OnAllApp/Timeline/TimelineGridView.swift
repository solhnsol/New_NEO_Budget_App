import NEOBudgetCalendar
import SwiftUI
import UIKit

/// What opens a detail sheet. Event blocks do not: they expand in place.
enum TimelineSelection: Identifiable {
    case allDay(AllDayItem)
    case marker(TransactionMarkerItem)

    var id: String {
        switch self {
        case let .allDay(item): return "allday-" + item.id.rawValue
        case let .marker(marker): return "marker-" + marker.transactionID.rawValue
        }
    }
}

enum Haptics {
    /// The event came off the grid and follows the finger.
    @MainActor static func pickUp() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    /// Time editing opened for an event. Lighter than picking it up, because nothing moves yet.
    @MainActor static func enterEdit() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor static func snap() { UISelectionFeedbackGenerator().selectionChanged() }
}

/// The scrolling hour grid. It has two shapes, both from `TimelineEditor.geometry`:
/// - **browse**: the day folded so it reads at a glance; events and unlinked transactions at full size, quiet stretches folded.
/// - **edit**: the same fold, with only the neighbourhood of the selected event's two handles enlarged so 15 minute steps
///   are comfortable to drag. The middle of a long event stays folded.
///
/// Gestures, in edit mode and out of it:
/// - tap an event: open it in place. Tap anywhere else: leave edit mode.
/// - first long press on an event: enter edit mode. Nothing moves.
/// - plain drag: scroll, always. Only a touch that starts on a handle does anything else.
/// - drag a handle: change the start or end time.
/// - second long press on the selected event, then drag: move it. Haptic when it picks up.
/// This view only draws and forwards touches to the editor; nothing here writes to the calendar.
struct TimelineGridView: View {
    let timeline: DayTimeline
    let zone: DisplayTimeZone
    let isToday: Bool
    let editor: TimelineEditor
    let onSelect: (TimelineSelection) -> Void
    @State private var reveal: EditGestureHost.RevealRequest?

    private static let transition = Animation.easeInOut(duration: 0.28)
    private static let edgePadding: CGFloat = EditHit.handleRadius

    var body: some View {
        let geometry = editor.geometry
        let marks = geometry.hourMarks(dayStartUnixMilliseconds: timeline.dayStartUnixMilliseconds, zone: zone)
        ScrollViewReader { proxy in
            ScrollView {
                GeometryReader { size in
                    let width = size.size.width
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { location in
                                if TimelineGestureRouter.tapEndsEditing(on: .emptyTime) {
                                    editor.collapseAll(anchorMinute: editor.geometry.minute(atY: location.y))
                                }
                            }
                            .frame(width: width, height: geometry.contentHeight)
                        ForEach(marks, id: \.elapsedMinute) { mark in
                            HourRow(mark: mark, geometry: geometry, width: width)
                        }
                        ForEach(geometry.axis.foldedSegments, id: \.startMinute) { segment in
                            FoldRow(segment: segment, geometry: geometry, width: width)
                        }
                        ForEach(timeline.blocks.filter { !editor.isExpanded($0) }, id: \.id) { block in
                            let frame = frame(of: block, width: width)
                            BlockCell(block: block, frame: frame, zoneIdentifier: timeline.timeZoneIdentifier, editor: editor)
                        }
                        // The opened event is drawn last so it sits over its neighbours.
                        ForEach(timeline.blocks.filter { editor.isExpanded($0) }, id: \.id) { block in
                            let frame = frame(of: block, width: width)
                            QuarterMarks(block: block, geometry: geometry, timeline: timeline, zone: zone)
                            BlockCell(block: block, frame: frame, zoneIdentifier: timeline.timeZoneIdentifier, editor: editor)
                        }
                        MarkerRail(timeline: timeline, geometry: geometry, width: width, onSelect: onSelect)
                        if let block = selectedBlock, !editor.isExpanded(block), !editor.isActive {
                            let frame = frame(of: block, width: width)
                            if !block.continuesFromPreviousDay {
                                EditHandle(kind: .resizeStart, block: block, center: EditHit.startHandle(of: frame), editor: editor, zoneIdentifier: timeline.timeZoneIdentifier)
                            }
                            if !block.continuesToNextDay {
                                EditHandle(kind: .resizeEnd, block: block, center: EditHit.endHandle(of: frame), editor: editor, zoneIdentifier: timeline.timeZoneIdentifier)
                            }
                        }
                        if let frame = editor.previewFrame(totalWidth: width), let preview = editor.preview {
                            PreviewBlockView(preview: preview, zoneIdentifier: timeline.timeZoneIdentifier)
                                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                                .offset(x: frame.minX, y: frame.minY)
                                .allowsHitTesting(false)
                        }
                        if isToday { NowLine(timeline: timeline, geometry: geometry, width: width) }
                    }
                    .background { gestureHost(width: width, geometry: geometry) }
                    .onChange(of: editor.expandedKey) { _, key in revealWhenOpened(key, width: width) }
                }
                .frame(height: geometry.contentHeight)
                .animation(Self.transition, value: editor.editAnchors)
                .animation(Self.transition, value: editor.expandedKey)
                // Scroll anchors need real layout frames; `offset` does not move a view's frame.
                .background(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(geometry.axis.segments, id: \.startMinute) { segment in
                            Color.clear.frame(height: segment.height).id("segment-\(segment.startMinute)")
                        }
                    }
                }
                // Room for a handle (and the first hour label) at the very top or bottom of the day.
                .padding(.vertical, Self.edgePadding)
            }
            .scrollDisabled(editor.isActive)
            .onAppear { scrollToStart(proxy, geometry: geometry) }
            .onChange(of: timeline.day) { _, _ in scrollToStart(proxy, geometry: editor.geometry) }
        }
    }

    // MARK: Gestures

    private func gestureHost(width: CGFloat, geometry: TimelineGeometry) -> some View {
        EditGestureHost(
            panEnabled: editor.isEditing,
            scrollRequest: editor.scrollRequest,
            reveal: reveal,
            longPress: { phase, point in longPress(phase, point, width: width) },
            panStartsAt: { point in
                TimelineGestureRouter.panBegins(on: touchTarget(at: point, width: width), isEditing: editor.isEditing)
            },
            pan: { phase, point in pan(phase, point, width: width) }
        )
    }

    /// Long press. On an event: the first one enters edit mode and nothing moves; once that event is selected, a long press on
    /// it picks it up, and the drag that follows moves it. On a handle: nothing (the handle's own drag does the work). On
    /// empty time: starts a new event there.
    private func longPress(_ phase: EditGestureHost.Phase, _ point: CGPoint, width: CGFloat) {
        switch phase {
        case .began:
            let pressMinute = editor.geometry.minute(atY: point.y)
            let target = touchTarget(at: point, width: width)
            let hitBlock = block(at: point, width: width)
            switch TimelineGestureRouter.longPress(on: target, isEditing: editor.isEditing) {
            case .ignore:
                return
            case .pickUp:
                // Second long press: pick the selected event up. The axis is already settled, so the finger stays put.
                guard let block = hitBlock else { return }
                editor.setFingerAnchor(y: point.y)
                if editor.begin(.move, block: block, timeline: timeline, geometry: editor.geometry) { Haptics.pickUp() }
            case .enterEditMode:
                if let block = hitBlock, editor.enterEditMode(for: block, pressMinute: pressMinute) { Haptics.enterEdit() }
            case .startNewEvent:
                guard editor.focusForCreate(atMinute: pressMinute) else { return }
                let after = editor.geometry
                if editor.beginCreate(atY: after.y(minute: pressMinute), timeline: timeline, geometry: after) { Haptics.pickUp() }
            }
        case .moved:
            guard editor.mode == .dragging else { return }
            if editor.isCreating { editor.updateCreate(toY: point.y) } else { editor.update(fingerY: point.y) }
        case .ended:
            editor.finish()
        }
    }

    /// Pan, edit mode only, and only for a touch that began on a handle: changes that edge. A touch anywhere else never
    /// reaches this; it scrolls.
    private func pan(_ phase: EditGestureHost.Phase, _ point: CGPoint, width: CGFloat) {
        switch phase {
        case .began:
            guard let block = selectedBlock, let hit = editHandle(at: point, width: width) else { return }
            editor.setFingerAnchor(y: point.y)
            if editor.begin(hit == .resizeStart ? .resizeStart : .resizeEnd, block: block, timeline: timeline, geometry: editor.geometry) {
                Haptics.pickUp()
            }
        case .moved:
            editor.update(fingerY: point.y)
        case .ended:
            editor.finish()
        }
    }

    private var selectedBlock: EventBlock? { timeline.blocks.first { editor.isSelected($0) } }

    /// Classifies a point in grid coordinates for `TimelineGestureRouter`.
    private func touchTarget(at point: CGPoint, width: CGFloat) -> TimelineTouchTarget {
        if let handle = editHandle(at: point, width: width) { return .handle(handle) }
        guard let hit = block(at: point, width: width) else { return .emptyTime }
        return editor.isSelected(hit) ? .selectedEvent : .otherEvent
    }

    /// The handle of the selected event under a point (grid coordinates), if any.
    private func editHandle(at point: CGPoint, width: CGFloat) -> EditHit? {
        guard editor.isEditing, editor.mode == .idle, let block = selectedBlock, !editor.isExpanded(block) else { return nil }
        let frame = frame(of: block, width: width)
        return EditHit.handle(at: point, frame: frame, canResizeStart: !block.continuesFromPreviousDay, canResizeEnd: !block.continuesToNextDay)
    }

    /// The topmost block under a point in grid coordinates.
    private func block(at point: CGPoint, width: CGFloat) -> EventBlock? {
        // The opened event is on top, then later blocks over earlier ones.
        let ordered = timeline.blocks.filter { !editor.isExpanded($0) } + timeline.blocks.filter { editor.isExpanded($0) }
        return ordered.last { frame(of: $0, width: width).contains(point) }
    }

    private func frame(of block: EventBlock, width: CGFloat) -> CGRect {
        editor.geometry.blockFrame(block, totalWidth: width, expanded: editor.isExpanded(block))
    }

    /// After an event opens, bring all of it into view; its content is taller than the block was.
    private func revealWhenOpened(_ key: CalendarEventKey?, width: CGFloat) {
        guard let key, let block = timeline.blocks.first(where: { $0.eventKey == key }) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(340))          // after the open animation settles
            guard editor.expandedKey == key else { return }
            reveal = EditGestureHost.RevealRequest(rect: frame(of: block, width: width))
        }
    }

    /// A day that already fits about one screen stays at the top. A taller one opens near the current time (today).
    private func scrollToStart(_ proxy: ScrollViewProxy, geometry: TimelineGeometry) {
        guard isToday, geometry.contentHeight > 760 else { return }
        let nowMinute = Int((Date().timeIntervalSince1970 * 1_000 - Double(timeline.dayStartUnixMilliseconds)) / 60_000)
        guard let segment = geometry.axis.segments.last(where: { $0.startMinute <= max(0, nowMinute - 60) }) else { return }
        proxy.scrollTo("segment-\(segment.startMinute)", anchor: .top)
    }
}

private extension TimelineGeometry {
    func blockFrame(_ block: EventBlock, width: CGFloat) -> CGRect { blockFrame(block, totalWidth: width) }
}

// MARK: Pieces

/// One event. A tap opens it in place (or closes it). In edit mode the selected event also shows its two resize
/// handles; otherwise there are none. The two never happen together.
private struct BlockCell: View {
    let block: EventBlock
    let frame: CGRect
    let zoneIdentifier: String
    let editor: TimelineEditor

    var body: some View {
        let selected = editor.isSelected(block)
        let expanded = editor.isExpanded(block)
        Group {
            if expanded {
                ExpandedBlockView(block: block, zoneIdentifier: zoneIdentifier)
            } else {
                EventBlockView(block: block, zoneIdentifier: zoneIdentifier, height: frame.height)
                    .opacity(editor.activeBlockID == block.id ? 0.3 : 1)
                    .overlay { if selected { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2) } }
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .offset(x: frame.minX, y: frame.minY)
        .onTapGesture { editor.toggleExpanded(block) }
        .accessibilityAction(named: "시간 조정") { editor.enterEditMode(for: block, pressMinute: block.startMinute) }
    }
}

/// A start or end handle of the event being edited. Touches on it are handled by the gesture host; this view draws it and
/// gives VoiceOver the same control: the element is a full-size touch target, and swiping up or down moves the edge by 15
/// minutes through the same command a drag uses.
private struct EditHandle: View {
    let kind: TimelineEditPlanner.Kind
    let block: EventBlock
    let center: CGPoint
    let editor: TimelineEditor
    let zoneIdentifier: String

    private static let step = 15

    var body: some View {
        let target = EditHit.touchFrame(around: center)
        let isStart = kind == .resizeStart
        let instant = isStart ? block.startUnixMilliseconds : block.endUnixMilliseconds
        Circle().fill(.white).frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .frame(width: target.width, height: target.height)
            .contentShape(Rectangle())
            .offset(x: target.minX, y: target.minY)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isStart ? "시작 시각" : "종료 시각")
            .accessibilityValue(Formatting.time(instant, zoneIdentifier: zoneIdentifier))
            .accessibilityHint("위로 쓸면 \(Self.step)분 일찍, 아래로 쓸면 \(Self.step)분 늦게")
            .accessibilityAdjustableAction { direction in
                let minutes = direction == .increment ? Self.step : -Self.step
                editor.nudge(kind, block: block, minutes: minutes)
            }
    }
}

/// A stretch of the day drawn small: a dashed rule and an ellipsis in the hour gutter. It carries no duration label.
private struct FoldRow: View {
    let segment: TimelineAxis.Segment
    let geometry: TimelineGeometry
    let width: CGFloat

    var body: some View {
        let top = geometry.axis.top(of: segment)
        ZStack(alignment: .topLeading) {
            Rectangle().stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(width: max(0, width - geometry.gutterWidth), height: 0)
                .offset(x: geometry.gutterWidth, y: segment.height / 2)
            // Only a mark that time is skipped here. How long is not worth saying: the hours around it already tell.
            Image(systemName: "ellipsis").font(.system(size: 10)).rotationEffect(.degrees(90))
                .foregroundStyle(.secondary)
                .frame(width: geometry.gutterWidth - 6, height: segment.height)
        }
        .frame(width: width, height: segment.height, alignment: .topLeading)
        .offset(y: top)
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

/// Transactions that are not wholly accounted for inside an event block: they stay on the time axis as their own markers.
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

/// Quarter-hour ticks beside an opened event: its own time axis, laid open. They appear only when the axis is large
/// enough that a quarter hour is a comfortable distance, and never where an hour label already is.
private struct QuarterMarks: View {
    let block: EventBlock
    let geometry: TimelineGeometry
    let timeline: DayTimeline
    let zone: DisplayTimeZone

    var body: some View {
        let start = block.displayStartMinute
        let end = block.displayEndMinute
        let quarter = geometry.y(minute: min(end, start + 15)) - geometry.y(minute: start)
        if end > start, quarter >= 14 {
            ForEach(Array(marks(start: start, end: end)), id: \.self) { minute in
                Text(label(minute))
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: geometry.gutterWidth - 6, alignment: .trailing)
                    .offset(y: geometry.y(minute: minute) - 6)
                    .accessibilityHidden(true)
            }
        }
    }

    private func clockMinute(_ minute: Int) -> Int {
        zone.minuteOfDay(of: timeline.dayStartUnixMilliseconds + Int64(minute) * 60_000)
    }

    private func marks(start: Int, end: Int) -> [Int] {
        ((start + 1)..<end).filter { clockMinute($0) % 15 == 0 && clockMinute($0) % 60 != 0 }
    }

    private func label(_ minute: Int) -> String {
        let clock = clockMinute(minute)
        return String(format: "%d:%02d", clock / 60, clock % 60)
    }
}
