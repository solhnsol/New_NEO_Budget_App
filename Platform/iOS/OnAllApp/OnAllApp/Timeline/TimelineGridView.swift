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
    /// One day either side of the two on screen: `strip[1]` and `strip[2]` are the days shown, the others slide in during a swipe.
    let strip: [StripDay]
    let today: LocalDate
    let zone: DisplayTimeZone
    let editor: TimelineEditor
    let onSelect: (TimelineSelection) -> Void
    var onEditInfo: (EventBlock) -> Void = { _ in }
    /// Called, synchronously, when a swipe has come to rest on another day: the strip must already show it in this frame.
    var onMoveDays: (Int) -> Void = { _ in }
    @State private var reveal: EditGestureHost.RevealRequest?
    /// How far the strip of days is dragged sideways of its resting place, during a swipe and while it settles.
    @State private var swipeOffset: CGFloat = 0
    @State private var settling = false

    private static let transition = Animation.easeInOut(duration: 0.28)
    private static let settleDuration = 0.22
    private static let edgePadding: CGFloat = EditHit.handleRadius
    private static let editScrollRoom: CGFloat = 320
    @State private var probe = ScrollProbe()

    /// The two days on screen; either may still be waiting to be read.
    private var visible: [DayTimeline?] { [strip[safe: 1]?.timeline, strip[safe: 2]?.timeline] }

    var body: some View {
        VStack(spacing: 0) {
            DayHeaderStrip(strip: strip, today: today, swipeOffset: swipeOffset, onSelect: { onSelect(.allDay($0)) })
            Divider()
            scrollingGrid
        }
    }

    private var scrollingGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // While the axis changes shape the clock, not an animation, says how far along it is (`AxisTransition.progress`):
                // every frame is positioned from that one number (see `TimelineGeometry`), so nothing can fall out of step.
                TimelineView(.animation(minimumInterval: nil, paused: editor.transition == nil)) { context in
                    MorphingContent(
                        progress: editor.transition?.progress(at: context.date) ?? 0,
                        transition: editor.transition, base: editor.geometry
                    ) { geometry, shift in
                        grid(geometry: geometry, shift: shift)
                    }
                }
            }
            .scrollDisabled(editor.isActive)
            .onAppear {
                scrollToStart(proxy, geometry: editor.geometry)
                // The editor asks how far the content may be shifted before it plans a change of shape.
                editor.visibleRange = { [probe] in probe.visibleGridRange(gridInset: Self.edgePadding) }
                editor.scrollLimits = { [probe] contentHeight, needsRoom in
                    probe.shiftRange(contentHeight: contentHeight + 2 * Self.edgePadding + (needsRoom ? Self.editScrollRoom : 0))
                }
            }
            .task(id: editor.transition?.id) {
                // The change ends when its time is up: the scroll view takes the whole shift in one step and the content shift is
                // dropped in the same update.
                guard let id = editor.transition?.id else { return }
                try? await Task.sleep(for: .seconds(TimelineEditor.AxisTransition.duration + 0.02))
                editor.completeTransition(id: id)
            }
        }
    }

    private func columns(width: CGFloat, geometry: TimelineGeometry) -> DayColumns {
        DayColumns(count: 2, gutterWidth: geometry.gutterWidth, trailingPadding: geometry.trailingPadding, totalWidth: width)
    }

    /// The hour grid for one frame. `geometry` may be a blend of two shapes; `shift` is how far the content is moved up so the
    /// anchor minute stays put while the scroll view itself stays where it is.
    private func grid(geometry: TimelineGeometry, shift: CGFloat) -> some View {
        let first = visible[0] ?? strip[safe: 1]?.timeline
        let marks = first.map { geometry.hourMarks(dayStartUnixMilliseconds: $0.dayStartUnixMilliseconds, zone: zone) } ?? []
        let badges = editBadges(geometry: geometry)
        let covered = badges.map(\.y)
        return GeometryReader { size in
            let width = size.size.width
            let columns = columns(width: width, geometry: geometry)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { location in
                        if TimelineGestureRouter.tapEndsEditing(on: .emptyTime) {
                            editor.collapseAll(anchorMinute: editor.geometry.minute(atY: location.y))
                        }
                    }
                    .frame(width: width, height: geometry.contentHeight)
                ForEach(marks, id: \.elapsedMinute) { mark in
                    HourRow(mark: mark, geometry: geometry, width: width, coveredBy: covered)
                }
                ForEach(geometry.foldMarks, id: \.startMinute) { fold in
                    FoldRow(fold: fold, geometry: geometry, width: width, coveredBy: covered)
                }
                // Each day is laid out as a lone day would be, in a column of its own, and slid into place. They are keyed by date,
                // so a day that moves one place over in a swipe is the same view, not a new one.
                // The strip is cut at the gutter, so the days that slide in or out never cover the hour labels.
                ZStack(alignment: .topLeading) {
                    ForEach(Array(strip.enumerated()), id: \.element.day) { position, entry in
                        if let timeline = entry.timeline {
                            dayContent(timeline, geometry: geometry, layoutWidth: columns.dayLayoutWidth)
                                .frame(width: columns.dayLayoutWidth, height: geometry.contentHeight, alignment: .topLeading)
                                .offset(x: columns.originX(of: position - 1) + swipeOffset - columns.gutterWidth)
                        }
                    }
                }
                .frame(width: max(0, width - columns.gutterWidth), height: geometry.contentHeight, alignment: .topLeading)
                .clipped()
                .offset(x: columns.gutterWidth)
                // The handles are positioned from the same geometry as the block they belong to, so they move with it.
                ForEach(0..<2, id: \.self) { column in
                    if let timeline = visible[column], let block = selectedBlock(in: timeline), !editor.isExpanded(block), !editor.isActive {
                        let frame = frame(of: block, in: timeline, width: columns.dayLayoutWidth, geometry: geometry)
                        let origin = columns.originX(of: column) + swipeOffset
                        ZStack(alignment: .topLeading) {
                            if !block.continuesFromPreviousDay {
                                EditHandle(kind: .resizeStart, block: block, center: EditHit.startHandle(of: frame), editor: editor, zoneIdentifier: timeline.timeZoneIdentifier)
                            }
                            if !block.continuesToNextDay {
                                EditHandle(kind: .resizeEnd, block: block, center: EditHit.endHandle(of: frame), editor: editor, zoneIdentifier: timeline.timeZoneIdentifier)
                            }
                        }
                        .offset(x: origin)
                    }
                }
                if let preview = editor.preview, let frame = editor.previewFrame(totalWidth: columns.dayLayoutWidth, geometry: geometry),
                   let zoneIdentifier = visible[safe: preview.column]??.timeZoneIdentifier ?? first?.timeZoneIdentifier {
                    PreviewBlockView(preview: preview, zoneIdentifier: zoneIdentifier)
                        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                        .offset(x: frame.minX + columns.originX(of: preview.column), y: frame.minY)
                        .allowsHitTesting(false)
                }
                // The times being set, on the hour axis, where a finger over the block cannot hide them.
                ForEach(badges, id: \.minute) { badge in
                    EditTimeBadge(text: badge.text, y: badge.y, width: geometry.gutterWidth)
                }
            }
            .background { gestureHost(width: width, geometry: geometry) }
            .offset(y: -shift)
            .onChange(of: editor.expandedKey) { _, key in revealWhenOpened(key, width: width, geometry: geometry) }
            // The zone moved to where the finger rested: a small tick says the time can now be set precisely.
            .onChange(of: editor.dwellCenter) { _, center in if center != nil { Haptics.snap() } }
        }
        .frame(height: geometry.contentHeight)
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
        // Room to scroll past the end while a zone is open under a finger, so a short day can still follow it.
        .padding(.bottom, editor.needsScrollRoom ? Self.editScrollRoom : 0)
    }

    /// Everything of one day: events stacked in its column, then its transactions as cards in the same column.
    private func dayContent(_ timeline: DayTimeline, geometry: TimelineGeometry, layoutWidth width: CGFloat) -> some View {
        let layout = DayContentLayout(blocks: timeline.blocks)
        let focus = focusedID(in: timeline)
        let frames = cardFrames(layout: layout, in: timeline, geometry: geometry, width: width)
        let places = titlePlacements(layout: layout, in: timeline, geometry: geometry, frames: frames, width: width, focused: focus)
        let drawOrder = self.drawOrder(layout: layout, in: timeline, focused: focus)
        return ZStack(alignment: .topLeading) {
            // Back to front; the opened event is drawn last so it sits over its neighbours.
            ForEach(drawOrder, id: \.id) { block in
                let frame = frames[block.id] ?? .zero
                if editor.isExpanded(block) { QuarterMarks(block: block, geometry: geometry, timeline: timeline, zone: zone) }
                BlockCell(block: block, frame: frame, title: places[block.id] ?? .init(), zoneIdentifier: timeline.timeZoneIdentifier, editor: editor, onEditInfo: onEditInfo)
            }
            // Titles are drawn over every card, so a card stacked on another never hides the title under it.
            ForEach(drawOrder.filter { !editor.isExpanded($0) }, id: \.id) { block in
                if let frame = frames[block.id], !titleIsCovered(block, frame: frame, place: places[block.id] ?? .init(), frames: frames, focused: focus) {
                    EventTitleLayer(block: block, frame: frame, place: places[block.id] ?? .init(), columnRight: geometry.gutterWidth + geometry.contentWidth(totalWidth: width))
                }
            }
            TransactionCards(timeline: timeline, geometry: geometry, width: width, onSelect: onSelect)
            if timeline.day == today { NowLine(timeline: timeline, geometry: geometry, width: width) }
        }
    }

    /// The time of each edge being changed, and where it is on the axis. A resize shows the edge that moves; a move or a new event shows
    /// both. The hour labels and folds under a badge are hidden while it is there, so nothing is drawn over anything else.
    private struct EditBadge {
        let minute: Int
        let y: CGFloat
        let text: String
    }

    private func editBadges(geometry: TimelineGeometry) -> [EditBadge] {
        guard let preview = editor.preview, let timeline = visible[safe: preview.column] ?? nil else { return [] }
        let instants: [Int64]
        switch preview.kind {
        case .resizeStart: instants = [preview.range.startUnixMilliseconds]
        case .resizeEnd: instants = [preview.range.endUnixMilliseconds]
        case .move, .create: instants = [preview.range.startUnixMilliseconds, preview.range.endUnixMilliseconds]
        }
        return instants.map { instant in
            let minute = min(max(Int((instant - timeline.dayStartUnixMilliseconds) / 60_000), 0), timeline.totalMinutes)
            return EditBadge(minute: minute, y: geometry.y(minute: minute), text: Formatting.time(instant, zoneIdentifier: timeline.timeZoneIdentifier))
        }
    }

    // MARK: Gestures

    private func gestureHost(width: CGFloat, geometry: TimelineGeometry) -> some View {
        let columns = columns(width: width, geometry: geometry)
        return EditGestureHost(
            probe: probe,
            panEnabled: editor.isEditing,
            swipeEnabled: !editor.isEditing && !editor.isActive && !settling,
            scrollCommit: editor.scrollCommit,
            reveal: reveal,
            longPress: { phase, point in longPress(phase, point, columns: columns) },
            panStartsAt: { point in
                TimelineGestureRouter.panBegins(on: touchTarget(at: point, columns: columns), isEditing: editor.isEditing)
            },
            pan: { phase, point in pan(phase, point, columns: columns) },
            swipe: { phase, translation, velocity in swipe(phase, translation, velocity, columnWidth: columns.columnWidth) }
        )
    }

    /// Horizontal swipe: the strip of days follows the finger (never more than one day) and, on release, comes to rest on one
    /// whole day, either the one it was on or the next one over. Vertical movement is scrolling and never reaches this.
    private func swipe(_ phase: EditGestureHost.Phase, _ translation: CGFloat, _ velocity: CGFloat, columnWidth: CGFloat) {
        switch phase {
        case .began:
            break
        case .moved:
            swipeOffset = DaySwipe.liveOffset(translation: translation, columnWidth: columnWidth)
        case .ended:
            let days = DaySwipe.daysToMove(translation: translation, velocity: velocity, columnWidth: columnWidth)
            settling = true
            withAnimation(.easeOut(duration: Self.settleDuration)) {
                swipeOffset = DaySwipe.settledOffset(days: days, columnWidth: columnWidth)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.settleDuration + 0.02))
                // The new first day and the offset go back to rest in one update, so the days do not move on screen.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if days != 0 { onMoveDays(days) }
                    swipeOffset = 0
                    settling = false
                }
                if days != 0 { Haptics.snap() }
            }
        }
    }

    /// Long press. On an event: the first one enters edit mode and nothing moves; once that event is selected, a long press on
    /// it picks it up, and the drag that follows moves it. On a handle: nothing (the handle's own drag does the work). On
    /// empty time: starts a new event there.
    private func longPress(_ phase: EditGestureHost.Phase, _ point: CGPoint, columns: DayColumns) {
        switch phase {
        case .began:
            let pressMinute = editor.geometry.minute(atY: point.y)
            let column = columns.column(atX: point.x)
            let target = touchTarget(at: point, columns: columns)
            let hit = located(at: point, columns: columns)
            switch TimelineGestureRouter.longPress(on: target, isEditing: editor.isEditing) {
            case .ignore:
                return
            case .pickUp:
                // Second long press: pick the selected event up. The axis is already settled, so the finger stays put.
                guard let hit else { return }
                editor.setFingerAnchor(y: point.y)
                if editor.begin(.move, block: hit.block, timeline: hit.timeline, geometry: editor.geometry, column: hit.column) { Haptics.pickUp() }
            case .enterEditMode:
                if let hit, editor.enterEditMode(for: hit.block, pressMinute: pressMinute) { Haptics.enterEdit() }
            case .startNewEvent:
                guard let timeline = visible[column], editor.focusForCreate(atMinute: pressMinute) else { return }
                let after = editor.geometry
                if editor.beginCreate(atY: after.y(minute: pressMinute), timeline: timeline, geometry: after, column: column) { Haptics.pickUp() }
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
    private func pan(_ phase: EditGestureHost.Phase, _ point: CGPoint, columns: DayColumns) {
        switch phase {
        case .began:
            guard let found = editHandle(at: point, columns: columns) else { return }
            editor.setFingerAnchor(y: point.y)
            if editor.begin(found.hit == .resizeStart ? .resizeStart : .resizeEnd, block: found.block, timeline: found.timeline, geometry: editor.geometry, column: found.column) {
                Haptics.pickUp()
            }
        case .moved:
            editor.update(fingerY: point.y)
        case .ended:
            editor.finish()
        }
    }

    private func selectedBlock(in timeline: DayTimeline) -> EventBlock? { timeline.blocks.first { editor.isSelected($0) } }

    /// Classifies a point in grid coordinates for `TimelineGestureRouter`.
    private func touchTarget(at point: CGPoint, columns: DayColumns) -> TimelineTouchTarget {
        if let found = editHandle(at: point, columns: columns) { return .handle(found.hit) }
        guard let hit = located(at: point, columns: columns) else { return .emptyTime }
        return editor.isSelected(hit.block) ? .selectedEvent : .otherEvent
    }

    /// The handle of the selected event under a point (grid coordinates), if any.
    private func editHandle(at point: CGPoint, columns: DayColumns) -> (hit: EditHit, block: EventBlock, timeline: DayTimeline, column: Int)? {
        guard editor.isEditing, editor.mode == .idle else { return nil }
        for column in 0..<2 {
            guard let timeline = visible[column], let block = selectedBlock(in: timeline), !editor.isExpanded(block) else { continue }
            let frame = frame(of: block, in: timeline, width: columns.dayLayoutWidth)
            let local = columns.localPoint(point, column: column)
            if let hit = EditHit.handle(at: local, frame: frame, canResizeStart: !block.continuesFromPreviousDay, canResizeEnd: !block.continuesToNextDay) {
                return (hit, block, timeline, column)
            }
        }
        return nil
    }

    /// The topmost event under a point in grid coordinates, and the day it is on.
    private func located(at point: CGPoint, columns: DayColumns) -> (block: EventBlock, timeline: DayTimeline, column: Int)? {
        let column = columns.column(atX: point.x)
        guard let timeline = visible[column] else { return nil }
        let local = columns.localPoint(point, column: column)
        let layout = DayContentLayout(blocks: timeline.blocks)
        let frames = cardFrames(layout: layout, in: timeline, geometry: editor.geometry, width: columns.dayLayoutWidth)
        let byID = Dictionary(timeline.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let id = layout.topmost(at: local, frames: frames, focused: focusedID(in: timeline)), let block = byID[id] else { return nil }
        return (block, timeline, column)
    }

    /// The block id that is drawn on top of everything in a day: the opened event, else the selected one.
    private func focusedID(in timeline: DayTimeline) -> BlockID? {
        timeline.blocks.first { editor.isExpanded($0) }?.id ?? timeline.blocks.first { editor.isSelected($0) }?.id
    }

    /// Blocks back to front: stacking order, with the focused one last.
    private func drawOrder(layout: DayContentLayout, in timeline: DayTimeline, focused: BlockID?) -> [EventBlock] {
        let byID = Dictionary(timeline.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.hitOrder(focused: focused).reversed().compactMap { byID[$0] }
    }

    /// Where every block of a day is, in `geometry` (a blend while the axis is changing, otherwise the current shape).
    private func cardFrames(layout: DayContentLayout, in timeline: DayTimeline, geometry: TimelineGeometry, width: CGFloat) -> [BlockID: CGRect] {
        let available = geometry.contentWidth(totalWidth: width)
        var result: [BlockID: CGRect] = [:]
        for block in timeline.blocks {
            result[block.id] = geometry.blockFrame(
                block, totalWidth: width, expanded: editor.isExpanded(block),
                insets: DayContentLayout.insets(for: layout.slot(of: block.id), available: available)
            )
        }
        return result
    }

    /// A title is hidden while the opened or selected event, which is drawn over everything, sits on top of it.
    private func titleIsCovered(_ block: EventBlock, frame: CGRect, place: DayContentLayout.TitlePlacement, frames: [BlockID: CGRect], focused: BlockID?) -> Bool {
        guard let focus = focused, focus != block.id, let cover = frames[focus] else { return false }
        return cover.intersects(CGRect(x: frame.minX + place.dx, y: frame.minY + place.dy, width: max(0, frame.width - place.dx), height: DayContentLayout.titleRowHeight))
    }

    /// Where each title is drawn, so overlapping events keep every title readable.
    private func titlePlacements(layout: DayContentLayout, in timeline: DayTimeline, geometry: TimelineGeometry, frames: [BlockID: CGRect], width: CGFloat, focused: BlockID?) -> [BlockID: DayContentLayout.TitlePlacement] {
        let byID = Dictionary(timeline.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.titlePlacements(
            top: { geometry.y(minute: byID[$0]?.displayStartMinute ?? 0) },
            bottom: { geometry.y(minute: byID[$0]?.displayEndMinute ?? 0) },
            left: { (frames[$0]?.minX ?? 0) + EventTitleLayer.horizontalPadding },
            right: { (frames[$0]?.maxX ?? 0) - EventTitleLayer.horizontalPadding },
            width: { DayContentLayout.estimatedTitleWidth(byID[$0]?.title ?? "", extra: 14) },
            columnRight: geometry.gutterWidth + geometry.contentWidth(totalWidth: width) - EventTitleLayer.horizontalPadding,
            minimumHeight: geometry.minimumBlockHeight,
            focused: focused
        )
    }

    /// Where a block is in `geometry`, in its day's own layout.
    private func frame(of block: EventBlock, in timeline: DayTimeline, width: CGFloat, geometry: TimelineGeometry? = nil) -> CGRect {
        let layout = DayContentLayout(blocks: timeline.blocks)
        return cardFrames(layout: layout, in: timeline, geometry: geometry ?? editor.geometry, width: width)[block.id] ?? .zero
    }

    /// After an event opens, bring all of it into view; its content is taller than the block was.
    private func revealWhenOpened(_ key: CalendarEventKey?, width: CGFloat, geometry: TimelineGeometry) {
        guard let key else { return }
        let columns = columns(width: width, geometry: geometry)
        for column in 0..<2 {
            guard let timeline = visible[column], let block = timeline.blocks.first(where: { $0.eventKey == key }) else { continue }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(340))          // after the open animation settles
                guard editor.expandedKey == key else { return }
                let rect = frame(of: block, in: timeline, width: columns.dayLayoutWidth)
                reveal = EditGestureHost.RevealRequest(rect: rect.offsetBy(dx: columns.originX(of: column), dy: 0))
            }
            return
        }
    }

    /// A day that already fits about one screen stays at the top. A taller one opens near the current time (today).
    private func scrollToStart(_ proxy: ScrollViewProxy, geometry: TimelineGeometry) {
        guard let timeline = visible.compactMap({ $0 }).first(where: { $0.day == today }), geometry.contentHeight > 760 else { return }
        let nowMinute = Int((Date().timeIntervalSince1970 * 1_000 - Double(timeline.dayStartUnixMilliseconds)) / 60_000)
        guard let segment = geometry.axis.segments.last(where: { $0.startMinute <= max(0, nowMinute - 60) }) else { return }
        proxy.scrollTo("segment-\(segment.startMinute)", anchor: .top)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: Pieces

/// One event. A tap opens it in place (or closes it). In edit mode the selected event also shows its two resize
/// handles; otherwise there are none. The two never happen together.
private struct BlockCell: View {
    let block: EventBlock
    let frame: CGRect
    let title: DayContentLayout.TitlePlacement
    let zoneIdentifier: String
    let editor: TimelineEditor
    let onEditInfo: (EventBlock) -> Void

    var body: some View {
        let selected = editor.isSelected(block)
        let expanded = editor.isExpanded(block)
        Group {
            if expanded {
                ExpandedBlockView(block: block, zoneIdentifier: zoneIdentifier, onEditInfo: { onEditInfo(block) })
            } else {
                EventBlockView(block: block, zoneIdentifier: zoneIdentifier, height: frame.height, titleOffset: title.dy)
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
    let fold: TimelineGeometry.FoldMark
    let geometry: TimelineGeometry
    let width: CGFloat
    var coveredBy: [CGFloat] = []

    var body: some View {
        let top = geometry.y(minute: fold.startMinute)
        let height = geometry.y(minute: fold.endMinute) - top
        ZStack(alignment: .topLeading) {
            Rectangle().stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(width: max(0, width - geometry.gutterWidth), height: 0)
                .offset(x: geometry.gutterWidth, y: height / 2)
            // Only a mark that time is skipped here. How long is not worth saying: the hours around it already tell.
            Image(systemName: "ellipsis").font(.system(size: 10)).rotationEffect(.degrees(90))
                .foregroundStyle(.secondary)
                .frame(width: geometry.gutterWidth - 6, height: height)
                .opacity(coveredBy.contains { abs($0 - (top + height / 2)) < 17 } ? 0 : 1)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .offset(y: top)
        .opacity(fold.opacity)
        .accessibilityHidden(true)
    }
}

/// Draws its content for one value of `progress`: the blend of the two shapes of a change in progress, or the plain shape. The
/// content is the same view whether or not a change is running. A different structure (an `if` around two branches) would be a
/// different view to SwiftUI: the grid, the gesture recognizers and the scroll view's position would all be torn down and rebuilt
/// as a change starts and ends.
private struct MorphingContent<Content: View>: View {
    let progress: CGFloat
    let transition: TimelineEditor.AxisTransition?
    let base: TimelineGeometry
    let content: (TimelineGeometry, CGFloat) -> Content

    var body: some View {
        let geometry = transition.map { TimelineGeometry(from: $0.from, to: $0.to, progress: progress) } ?? base
        content(geometry, (transition?.delta ?? 0) * progress)
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
        // The edge being dragged keeps its handle, so there is always something under the finger to follow.
        .overlay {
            GeometryReader { size in
                if preview.kind == .resizeStart {
                    DraggedHandleDot().position(x: size.size.width - EditHit.handleInset, y: 0)
                } else if preview.kind == .resizeEnd {
                    DraggedHandleDot().position(x: EditHit.handleInset, y: size.size.height)
                }
            }
        }
    }
}

/// The time an edge is at right now, in the hour gutter. It sits on the axis at the edge's own position, so it is readable
/// when the finger is over the block, and it takes the place of the hour label that would be under it.
private struct EditTimeBadge: View {
    let text: String
    let y: CGFloat
    let width: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 3)
            .frame(width: width - 4, height: 18)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))
            .offset(x: 2, y: y - 9)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct DraggedHandleDot: View {
    var body: some View {
        Circle().fill(Color.accentColor).frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

private struct HourRow: View {
    let mark: TimelineGeometry.HourMark
    let geometry: TimelineGeometry
    let width: CGFloat
    /// Positions of time badges: a label this close to one is hidden for as long as it is there.
    var coveredBy: [CGFloat] = []

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
        .opacity(mark.opacity * (coveredBy.contains { abs($0 - geometry.y(minute: mark.elapsedMinute)) < 17 } ? 0 : 1))
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

/// Transactions that are not wholly accounted for inside an event block, drawn in the same column as the events, each as its
/// own card at its time. A transaction with no event is ordinary, not an exception: it has no special rail or warning colour.
/// One during an event is drawn over that event but is never counted as part of it; only an explicit link does that.
private struct TransactionCards: View {
    let timeline: DayTimeline
    let geometry: TimelineGeometry
    let width: CGFloat
    let onSelect: (TimelineSelection) -> Void

    var body: some View {
        let content = geometry.contentWidth(totalWidth: width)
        let cardWidth = TransactionCardPlan.width(content: content)
        let positions = geometry.stackedYPositions(minutes: timeline.markers.map(\.positionMinute), minimumSpacing: TransactionCardPlan.height + 2)
        ForEach(Array(timeline.markers.enumerated()), id: \.element.transactionID) { index, marker in
            let style = TransactionCardPlan.style(for: marker)
            Button { onSelect(.marker(marker)) } label: {
                TransactionCardView(marker: marker, style: style, showsTitle: TransactionCardPlan.showsTitle(width: cardWidth))
            }
            .buttonStyle(.plain)
            .frame(width: cardWidth, height: TransactionCardPlan.height)
            .offset(x: geometry.gutterWidth + content - cardWidth - geometry.columnSpacing, y: positions[index] - TransactionCardPlan.height / 2)
            .accessibilityLabel(TransactionCardPlan.accessibilityText(marker))
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
