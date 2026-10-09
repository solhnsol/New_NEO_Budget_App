import Foundation
import NEOBudgetCalendar
import Observation

/// What the user is told when a change could not be saved. The preview has already been rolled back.
struct EditFeedback: Equatable, Identifiable {
    enum Tone: Equatable { case error, notice }
    let id = UUID()
    let message: String
    let tone: Tone
    /// Set when trying again can help (a save failure, not a conflict).
    let canRetry: Bool

    static func == (lhs: EditFeedback, rhs: EditFeedback) -> Bool { lhs.id == rhs.id }

    /// Maps a command outcome to a message, or `nil` when it was applied cleanly.
    static func make(for outcome: CalendarCommandOutcome) -> EditFeedback? {
        switch outcome {
        case .applied:
            return nil
        case .partiallyApplied:
            return EditFeedback(message: "일정은 저장됐지만 연결 정보를 갱신하지 못했습니다.", tone: .notice, canRetry: false)
        case .conflict:
            return EditFeedback(message: "다른 곳에서 일정이 바뀌어 저장하지 않았습니다. 최신 내용으로 새로 고쳤어요.", tone: .error, canRetry: false)
        case let .rejected(reason):
            return EditFeedback(message: message(for: reason), tone: .error, canRetry: false)
        case let .providerFailure(failure):
            switch failure {
            case .calendarNotWritable:
                return EditFeedback(message: "읽기 전용 캘린더라 변경할 수 없습니다.", tone: .error, canRetry: false)
            case .accessUnavailable:
                return EditFeedback(message: "캘린더 접근이 꺼져 있어 저장하지 못했습니다.", tone: .error, canRetry: false)
            case .eventMissing:
                return EditFeedback(message: "일정이 삭제되어 저장하지 못했습니다.", tone: .error, canRetry: false)
            case .calendarMissing:
                return EditFeedback(message: "캘린더를 찾을 수 없어 저장하지 못했습니다.", tone: .error, canRetry: false)
            case let .saveFailed(retryable, _):
                return EditFeedback(message: "저장하지 못했습니다. 변경 전 상태로 되돌렸어요.", tone: .error, canRetry: retryable)
            case .unsupported:
                return EditFeedback(message: "이 일정에는 지원하지 않는 변경입니다.", tone: .error, canRetry: false)
            }
        }
    }

    private static func message(for reason: CommandRejection) -> String {
        switch reason {
        case .eventNotEditable: return "읽기 전용 일정이라 변경할 수 없습니다."
        case .eventNotFound: return "일정을 찾을 수 없습니다. 이미 삭제됐을 수 있어요."
        case .dateChangeRequiresThisOccurrence: return "날짜가 바뀌는 변경은 이 일정에만 적용할 수 있습니다."
        case .durationBelowMinimum: return "일정은 최소 15분이어야 합니다."
        case .recurrenceScopeRequired, .recurrenceScopeUnsupported: return "반복 일정의 적용 범위를 지원하지 않습니다."
        default: return "변경할 수 없습니다."
        }
    }
}

/// Runs one timeline edit at a time: pick up, preview locally, decide on release, commit once, roll back on failure.
/// While a gesture is in progress nothing is written anywhere; the preview is only this object's state.
@MainActor
@Observable
final class TimelineEditor {
    struct Environment {
        let perform: @Sendable (CalendarCommand) async -> CalendarCommandOutcome
        let reload: @MainActor () async -> Void
        let supportedScopes: Set<RecurrenceScope>
        let zone: DisplayTimeZone
        let policy: TimelineEditPolicy
        let calendars: @MainActor () -> [CalendarDescriptor]
    }

    enum Mode: Equatable {
        case idle
        case dragging
        case choosingScope
        case namingEvent
        case committing
    }

    struct Preview: Equatable {
        let kind: TimelineEditPlanner.Kind
        let range: TimedRange
        let wasClamped: Bool
        let blockID: BlockID?
        let column: Int
        let columnCount: Int
        let title: String?
    }

    /// Asks the scroll view to move by `delta` points, in step with an axis change, so what is under the finger stays put.
    struct ScrollRequest: Equatable {
        let id: UUID
        let delta: CGFloat
        init(id: UUID = UUID(), delta: CGFloat) {
            self.id = id
            self.delta = delta
        }
        static func == (lhs: ScrollRequest, rhs: ScrollRequest) -> Bool { lhs.id == rhs.id }
    }

    /// The axis changing from one shape to another. The grid draws it as one animation of a single number (`GeometryBlend`),
    /// and the scroll view stays where it is while that runs: the content is moved by `delta * progress` instead, so the
    /// anchor minute is held still on screen by the same arithmetic that moves everything else. When it ends (`completeTransition`)
    /// the scroll view is moved by the whole `delta` in one step, the content shift is dropped in the same update, and the
    /// two cancel exactly.
    struct AxisTransition: Equatable {
        let id: UUID
        let from: TimelineAxis
        let to: TimelineAxis
        /// How far the anchor minute moved in content coordinates (`to.y - from.y`).
        let delta: CGFloat
        let startedAt: Date

        static let duration: TimeInterval = 0.25

        /// How far along the change is at `date`, from the clock alone: 0 before it starts, 1 once it is over, eased in between.
        /// Nothing animates this number, so a change that replaces another cannot blend with it.
        func progress(at date: Date) -> CGFloat {
            let t = min(max(date.timeIntervalSince(startedAt) / Self.duration, 0), 1)
            return CGFloat(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
        }
    }

    /// The scroll view moving by `delta` at once, because a transition has ended.
    struct ScrollCommit: Equatable {
        let id = UUID()
        let delta: CGFloat
        static func == (lhs: ScrollCommit, rhs: ScrollCommit) -> Bool { lhs.id == rhs.id }
    }

    private(set) var mode: Mode = .idle
    private(set) var preview: Preview?
    private(set) var scopeOptions: [RecurrenceScope] = []
    var feedback: EditFeedback?

    // MARK: Browse and edit modes

    /// The minutes of the edge handles being edited (or of the slot a new event is placed at). Only the neighbourhood of
    /// each is drawn enlarged; the rest of the day, including the middle of a long event, keeps its browse shape.
    /// `nil` is browse mode.
    private(set) var editAnchors: [Int]?
    /// The minute a new event is being placed at. Only a new event enlarges the axis from the start; an event being edited
    /// does not, so entering and leaving edit mode never moves anything on screen.
    private(set) var createFocus: Int?
    /// While an edge handle is dragged and the finger rests over a compressed stretch, the minute the enlarged zone has
    /// moved to. It is the selected time, so the handle stays exactly where the finger is when the zone appears.
    private(set) var dwellCenter: Int?
    /// The event being edited. `nil` while only a focus exists means a new event is being placed.
    private(set) var selectedKey: CalendarEventKey?
    /// The event opened in place to show what it means and every linked transaction. Only one at a time, and never
    /// together with edit mode: time adjustment and reading details are separate.
    private(set) var expandedKey: CalendarEventKey?
    /// How far the scroll view can shift the content for a layout `contentHeight` tall (with or without the extra room): the
    /// change of shape is planned inside this, because a shift the scroll view refuses would show as a jump when the change ends.
    /// Set by the grid; `nil` (tests, before it appears) means no limit.
    var scrollLimits: ((_ contentHeight: CGFloat, _ needsRoom: Bool) -> ClosedRange<CGFloat>?)?
    /// The part of the grid on screen now (grid coordinates). Set by the grid; `nil` means no constraint.
    var visibleRange: (() -> ClosedRange<CGFloat>?)?
    private(set) var transition: AxisTransition?
    private(set) var scrollCommit: ScrollCommit?
    /// The scroll the current transition will need, for callers and tests that ask what was requested.
    var scrollRequest: ScrollRequest? {
        guard let transition, abs(transition.delta) > 0.5 else { return nil }
        return ScrollRequest(id: transition.id, delta: transition.delta)
    }
    private(set) var timeline: DayTimeline?
    private let parameters = TimelineAxis.Parameters.standard
    private var fingerAnchorY: CGFloat = 0
    private var settlesAt: Date = .distantPast
    /// How long the axis takes to change shape, during which finger readings are not real drags.
    private static let settleSeconds = 0.35

    // MARK: Zoom while a handle rests

    /// How long the finger must rest over a compressed stretch before the enlarged zone moves to it.
    var dwellInterval: Duration = .milliseconds(400)
    /// Waits `dwellInterval`. Replaceable so tests need no real time.
    var dwellWait: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// A move smaller than this (points) is hand tremor, not movement, and does not restart the wait.
    private static let restTolerance: CGFloat = 4
    private(set) var dwellArmCount = 0
    private var dwellTask: Task<Void, Never>?
    private var dwellAnchorY: CGFloat = 0
    private var lastFingerY: CGFloat = 0
    private var draggedKind: TimelineEditPlanner.Kind?
    /// How far the content was shifted to keep a finger on its handle while zones opened during this drag. Letting go gives it all
    /// back, so the view returns to where it was when the handle was grabbed instead of staying scrolled by what the drag needed.
    private var dragShift: CGFloat = 0

    private let environment: Environment
    private var planner: TimelineEditPlanner?
    private var block: EventBlock?
    private var lastCommand: CalendarCommand?
    private var createAnchorY: CGFloat = 0
    private var inflight: Task<Void, Never>?

    init(environment: Environment) {
        self.environment = environment
    }

    var isEditing: Bool { editAnchors != nil }

    /// Where the axis is enlarged now: the place a new event is being put, and the resting finger's zone. Never the handles of
    /// an event that is merely selected.
    private var zoomWindows: [ClosedRange<Int>] {
        var windows = browseAxis.handleZones(around: [createFocus].compactMap { $0 }, parameters: parameters)
        if let dwellCenter {
            windows.append(max(0, dwellCenter - dwellRadii.before)...min(timeline?.totalMinutes ?? 1440, dwellCenter + dwellRadii.after))
        }
        return windows
    }
    /// How far the resting finger's zone reaches each way. Smaller on the side that faces the event's other edge when a full zone
    /// would push that edge off the screen.
    private var dwellRadii: (before: Int, after: Int) = (45, 45)
    /// The enlarged minute windows, for drawing and tests.
    var enlargedZones: [ClosedRange<Int>] { zoomWindows }

    /// Whether the scroll view needs room beyond the end of the day. A zone opening under a resting finger moves the content by
    /// as much as it grew, which a short day could not do without it. Held until the zone is gone and the scroll has settled.
    var needsScrollRoom: Bool { mode != .idle || dwellCenter != nil || createFocus != nil || transition != nil }
    var isActive: Bool { mode != .idle }
    var activeBlockID: BlockID? { block?.id }
    /// Whether the picked-up block is being created rather than edited.
    var isCreating: Bool { preview?.kind == .create }

    /// Where to draw the preview, in grid coordinates.
    func previewFrame(totalWidth: CGFloat, geometry: TimelineGeometry? = nil) -> CGRect? {
        guard let planner, let preview else { return nil }
        return planner.previewFrame(preview.range, column: preview.column, columns: preview.columnCount, totalWidth: totalWidth, geometry: geometry)
    }

    // MARK: View modes

    /// Browse axis for the current day, or the uniform fallback before a timeline is known.
    private var browseAxis: TimelineAxis {
        guard let timeline else { return .linear(totalMinutes: 1440, pointsPerMinute: 1) }
        return TimelineAxis.browse(for: timeline, parameters: parameters)
    }

    /// The axis for a view shape: the browse axis, with the neighbourhood of each handle enlarged and/or one event opened
    /// over its own range.
    private func axis(windows: [ClosedRange<Int>], expanded: CalendarEventKey?) -> TimelineAxis {
        var result = browseAxis
        if !windows.isEmpty { result = result.expandedLocally(windows: windows, parameters: parameters) }
        if let spec = expansion(for: expanded) { result = result.expanded(over: spec.window, scale: spec.scale) }
        return result
    }

    private var currentAxis: TimelineAxis { axis(windows: zoomWindows, expanded: expandedKey) }

    /// The minutes an expanded event occupies and how large they are drawn: large enough that the block is as tall as its
    /// content needs, but never smaller than browse scale.
    private func expansion(for key: CalendarEventKey?) -> (window: ClosedRange<Int>, scale: CGFloat)? {
        guard let key, let block = timeline?.blocks.first(where: { $0.eventKey == key }) else { return nil }
        let lower = block.displayStartMinute
        let upper = max(block.displayEndMinute, lower + 1)
        let needed = ExpandedBlockPlan.height(for: block)
        return (lower...upper, max(parameters.browseScale, needed / CGFloat(upper - lower)))
    }

    /// What the grid draws right now: folded in browse mode, enlarged around the focus in edit mode, with at most one
    /// event opened in place.
    var geometry: TimelineGeometry { TimelineGeometry(axis: currentAxis) }

    /// The model reports the timeline it now shows. A selected event is followed to wherever it is now; if it is gone
    /// (deleted elsewhere) edit mode ends quietly. Nothing re-centres under a gesture or a pending decision.
    func timelineDidChange(_ new: DayTimeline) {
        let before = currentAxis
        timeline = new
        if let key = expandedKey, !new.blocks.contains(where: { $0.eventKey == key }) { expandedKey = nil }      // it is gone
        guard let key = selectedKey else { return }
        guard let block = new.blocks.first(where: { $0.eventKey == key }) else {
            setAnchors(nil, selected: nil, anchorMinute: nil, from: before)
            return
        }
        guard mode == .idle else { return }
        setAnchors(anchors(for: block, fallback: block.startMinute), selected: key, anchorMinute: block.startMinute, from: before)
    }

    /// Where the axis is enlarged for `block`: its start and end handles, whichever of them it has. An event that fills the
    /// day has none, so the minute that was pressed is enlarged instead and can still be moved in 15 minute steps.
    private func anchors(for block: EventBlock, fallback minute: Int) -> [Int] {
        var result: [Int] = []
        if !block.continuesFromPreviousDay { result.append(block.startMinute) }
        if !block.continuesToNextDay { result.append(block.endMinute) }
        return result.isEmpty ? [minute] : result
    }

    /// Switches the editing state and, if the axis changes shape because of it, makes the change a transition that holds
    /// `anchorMinute` still on screen.
    private func setAnchors(
        _ new: [Int]?, selected: CalendarEventKey?, expanded: CalendarEventKey? = nil, anchorMinute: Int?, from old: TimelineAxis,
        forcedDelta: CGFloat? = nil
    ) {
        editAnchors = new
        if new == nil { createFocus = nil }
        selectedKey = selected
        expandedKey = expanded
        publishAxisChange(from: old, anchorMinute: anchorMinute, forcedDelta: forcedDelta)
    }

    /// Starts the transition from `old` to the axis as it is now (nothing if they are the same). `old` is the axis before the
    /// change that was just made, which is also where a transition still running would be heading, so finishing that one
    /// first loses nothing.
    private func publishAxisChange(from old: TimelineAxis, anchorMinute: Int?, roomAfter: Bool? = nil, forcedDelta: CGFloat? = nil) {
        completeTransition()
        let new = currentAxis
        guard new != old else { return }
        var delta = forcedDelta ?? anchorMinute.map { new.y(minute: $0) - old.y(minute: $0) } ?? 0
        // Hold the anchor as far as the scroll view can follow; past that it drifts smoothly instead of jumping at the end.
        // The limit is the one the content will have when the change is over: if the extra room goes away with it, a shift that
        // needs that room cannot be kept, and holding it until the end would make UIKit take it back all at once.
        if let range = scrollLimits?(new.height, roomAfter ?? needsScrollRoom) { delta = min(max(delta, range.lowerBound), range.upperBound) }
        transition = AxisTransition(id: UUID(), from: old, to: new, delta: delta, startedAt: Date())
    }

    /// The grid has finished drawing the change: the axis is now simply the new shape and the scroll view takes the whole shift.
    func completeTransition(id: UUID? = nil) {
        guard let finished = transition, id == nil || id == finished.id else { return }
        transition = nil
        if abs(finished.delta) > 0.5 { scrollCommit = ScrollCommit(delta: finished.delta) }
    }

    /// First long press on an event: select it, so its two handles show. **Nothing on screen moves**: the axis is not changed,
    /// so no time, block or handle shifts. (An opened event does close, which is a change of shape anchored at the pressed
    /// minute.) The neighbourhood of a handle is enlarged only once that handle is dragged and rests (`zoomAtFinger`).
    /// Returns `false` (and says why) if the event cannot be edited.
    @discardableResult
    func enterEditMode(for block: EventBlock, pressMinute: Int) -> Bool {
        guard mode == .idle, timeline != nil else { return false }
        guard block.isEditable, block.state == .normal else {
            feedback = EditFeedback.make(for: .rejected(.eventNotEditable))
            return false
        }
        feedback = nil
        if selectedKey != block.eventKey || editAnchors == nil {
            setAnchors(anchors(for: block, fallback: pressMinute), selected: block.eventKey, anchorMinute: pressMinute, from: currentAxis)
            if transition != nil { settlesAt = Date().addingTimeInterval(Self.settleSeconds) }
        }
        return true
    }

    /// Long press on empty time: enlarge the neighbourhood of that minute so the new event can be placed in 15 minute steps.
    @discardableResult
    func focusForCreate(atMinute minute: Int) -> Bool {
        guard mode == .idle, timeline != nil else { return false }
        feedback = nil
        let old = currentAxis
        createFocus = minute
        setAnchors([minute], selected: nil, anchorMinute: minute, from: old)
        if transition != nil { settlesAt = Date().addingTimeInterval(Self.settleSeconds) }
        return true
    }

    /// Back to browse mode, keeping `anchorMinute` (the time that was tapped, else the event's start or the new slot) where
    /// it is on screen.
    func exitEditMode(anchorMinute: Int? = nil) {
        guard mode == .idle, editAnchors != nil else { return }
        let anchor = anchorMinute
            ?? selectedKey.flatMap { key in timeline?.blocks.first { $0.eventKey == key }?.startMinute }
            ?? editAnchors?.first
        setAnchors(nil, selected: nil, anchorMinute: anchor, from: currentAxis)
    }

    /// Tap on an event: open it in place (closing any other, and leaving edit mode), or close it if it is already open.
    /// The block's top stays where it is on screen. Ignored while a gesture or a decision is in progress.
    func toggleExpanded(_ block: EventBlock) {
        guard mode == .idle, timeline != nil else { return }
        feedback = nil
        let before = currentAxis
        if expandedKey == block.eventKey {
            setAnchors(nil, selected: nil, expanded: nil, anchorMinute: block.displayStartMinute, from: before)
        } else {
            setAnchors(nil, selected: nil, expanded: block.eventKey, anchorMinute: block.displayStartMinute, from: before)
        }
    }

    /// Back to the plain folded day: closes the opened event and leaves edit mode. A tap outside any event passes the time
    /// it landed on, so that spot stays under the finger.
    func collapseAll(anchorMinute: Int? = nil) {
        guard mode == .idle, editAnchors != nil || expandedKey != nil else { return }
        let anchor = anchorMinute
            ?? expandedKey.flatMap { key in timeline?.blocks.first { $0.eventKey == key }?.displayStartMinute }
            ?? selectedKey.flatMap { key in timeline?.blocks.first { $0.eventKey == key }?.startMinute }
            ?? editAnchors?.first
        setAnchors(nil, selected: nil, expanded: nil, anchorMinute: anchor, from: currentAxis)
    }

    func isExpanded(_ block: EventBlock) -> Bool { expandedKey == block.eventKey }

    /// Whether `block` is the one being edited, so its handles are shown.
    func isSelected(_ block: EventBlock) -> Bool { selectedKey == block.eventKey }

    /// The finger's content position now, relative to where this drag began. Ignored while the axis is still settling.
    func update(fingerY y: CGFloat) {
        guard Date() >= settlesAt else { return }
        lastFingerY = y
        update(translationY: y - fingerAnchorY)
        armDwell(at: y)
    }

    /// The finger position that corresponds to "no movement yet".
    func setFingerAnchor(y: CGFloat) {
        fingerAnchorY = y
        lastFingerY = y
        dwellAnchorY = y
    }

    // MARK: Zoom while a handle rests

    /// Starts (or restarts) the wait for the finger to rest. Only an edge handle zooms: a move or a new event is placed
    /// by distance, not by a precise time, and must not change the axis under the finger.
    private func armDwell(at y: CGFloat) {
        guard mode == .dragging, let kind = preview?.kind, kind == .resizeStart || kind == .resizeEnd else { return }
        if dwellTask != nil, abs(y - dwellAnchorY) <= Self.restTolerance { return }
        dwellAnchorY = y
        dwellTask?.cancel()
        dwellArmCount += 1
        let interval = dwellInterval
        dwellTask = Task { [weak self] in
            guard let self else { return }
            do { try await dwellWait(interval) } catch { return }
            guard !Task.isCancelled else { return }
            zoomAtFinger()
        }
    }

    /// Moves the enlarged zone to the minute the handle is at, if that stretch is compressed. Nothing the user can see in
    /// numbers changes: the selected time stays, and the content scrolls by exactly how far that time moved, so the handle
    /// stays under the resting finger. The drag is re-based to the new axis so the next movement continues from there.
    func zoomAtFinger() {
        dwellTask = nil
        guard mode == .dragging, let preview, let timeline, let block,
              let minute = edgeMinute(of: preview, in: timeline) else { return }
        let before = currentAxis
        guard before.pointsPerMinute(atMinute: minute) < parameters.editScale - 0.001, dwellCenter != minute else { return }
        dwellRadii = radii(forZoomAt: minute, before: before, keepingInView: preview.kind == .resizeStart ? block.endMinute : block.startMinute)
        dwellCenter = minute
        publishAxisChange(from: before, anchorMinute: minute)
        let after = currentAxis
        let delta = transition?.delta ?? 0
        dragShift += delta
        let geometry = TimelineGeometry(axis: after)
        planner = TimelineEditPlanner(policy: environment.policy, zone: environment.zone, geometry: geometry, timeline: timeline)
        // The finger has not moved on screen, so in content coordinates it is `delta` further along, and it is at `minute`.
        let original = preview.kind == .resizeStart ? block.startMinute : block.endMinute
        fingerAnchorY = (lastFingerY + delta) - (after.y(minute: minute) - after.y(minute: original))
        lastFingerY += delta
        settlesAt = Date().addingTimeInterval(Self.settleSeconds)
    }

    /// Where the finger is, in content coordinates, as far as the editor knows. For scripts and tests that stand in for a finger.
    var fingerContentY: CGFloat { lastFingerY }

    /// How far a new zone at `minute` may reach each way. A full zone grows the stretch between the finger and the event's other
    /// edge, and the content is scrolled to hold the finger, so repeated zones push the other edge off the screen and the event can
    /// no longer be seen. So the side facing that edge is shortened, as far as needed, to keep it where it is on screen.
    private func radii(forZoomAt minute: Int, before: TimelineAxis, keepingInView other: Int) -> (before: Int, after: Int) {
        let full = parameters.handleRadius
        guard let visible = visibleRange?() else { return (full, full) }
        let margin: CGFloat = 24
        let fingerY = before.y(minute: minute)
        func inView(_ y: CGFloat) -> Bool { y >= visible.lowerBound + margin && y <= visible.upperBound - margin }
        guard inView(before.y(minute: other)) else { return (full, full) }            // already out of view: not made worse here
        let facingUp = other < minute
        for reach in stride(from: full, through: 0, by: -15) {
            let candidate = facingUp ? (before: reach, after: full) : (before: full, after: reach)
            let window = max(0, minute - candidate.before)...min(timeline?.totalMinutes ?? 1440, minute + candidate.after)
            let axis = self.axis(windows: zoomWindowsExcludingDwell + [window], expanded: expandedKey)
            // The finger stays at `fingerY` on screen, so the other edge lands at its distance from the finger in the new shape.
            let edgeY = fingerY + (axis.y(minute: other) - axis.y(minute: minute))
            if inView(edgeY) { return candidate }
        }
        return facingUp ? (0, full) : (full, 0)
    }

    private var zoomWindowsExcludingDwell: [ClosedRange<Int>] { browseAxis.handleZones(around: [createFocus].compactMap { $0 }, parameters: parameters) }

    /// Ends the wait for the axis to settle. For tests, which have no animation to wait for.
    func endSettling() { settlesAt = .distantPast }

    /// The minute the previewed edge is at.
    private func edgeMinute(of preview: Preview, in timeline: DayTimeline) -> Int? {
        guard preview.kind == .resizeStart || preview.kind == .resizeEnd else { return nil }
        let milliseconds = preview.kind == .resizeStart ? preview.range.startUnixMilliseconds : preview.range.endUnixMilliseconds
        return min(max(Int((milliseconds - timeline.dayStartUnixMilliseconds) / 60_000), 0), timeline.totalMinutes)
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    /// Drops the finger's zone and gives back the shift the drag needed, so the view is where it was before the drag.
    private func releaseDwell(roomAfter: Bool? = nil) {
        cancelDwell()
        guard dwellCenter != nil else { return }
        let before = currentAxis
        dwellCenter = nil
        dwellRadii = (parameters.handleRadius, parameters.handleRadius)
        publishAxisChange(from: before, anchorMinute: nil, roomAfter: roomAfter, forcedDelta: -dragShift)
        dragShift = 0
    }

    // MARK: Gesture phases

    /// Picks up a block. Returns `false` (and says why) if it cannot be edited.
    @discardableResult
    func begin(_ kind: TimelineEditPlanner.Kind, block: EventBlock, timeline: DayTimeline, geometry: TimelineGeometry) -> Bool {
        guard mode == .idle, kind != .create else { return false }
        guard block.isEditable, block.state == .normal else {
            feedback = EditFeedback.make(for: .rejected(.eventNotEditable))
            return false
        }
        let planner = TimelineEditPlanner(policy: environment.policy, zone: environment.zone, geometry: geometry, timeline: timeline)
        guard let edit = planner.preview(kind, block: block, translationY: 0) else { return false }
        self.planner = planner
        self.block = block
        draggedKind = kind
        dragShift = 0
        cancelDwell()
        mode = .dragging
        feedback = nil
        preview = Preview(
            kind: kind, range: edit.range, wasClamped: edit.wasClamped, blockID: block.id,
            column: block.layout.column, columnCount: block.layout.columnCount, title: block.title
        )
        armDwell(at: lastFingerY)          // a handle held still, without moving, also opens a precise zone
        return true
    }

    func update(translationY: CGFloat) {
        guard mode == .dragging, let planner, let block, let current = preview, current.kind != .create,
              let edit = planner.preview(current.kind, block: block, translationY: translationY) else { return }
        let next = Preview(
            kind: current.kind, range: edit.range, wasClamped: edit.wasClamped, blockID: current.blockID,
            column: current.column, columnCount: current.columnCount, title: current.title
        )
        if next != current { preview = next }
    }

    /// Starts a new event from a drag across empty space at `y`.
    @discardableResult
    func beginCreate(atY y: CGFloat, timeline: DayTimeline, geometry: TimelineGeometry) -> Bool {
        guard mode == .idle else { return false }
        let planner = TimelineEditPlanner(policy: environment.policy, zone: environment.zone, geometry: geometry, timeline: timeline)
        self.planner = planner
        block = nil
        createAnchorY = y
        mode = .dragging
        feedback = nil
        let edit = planner.createPreview(fromY: y, toY: y)
        preview = Preview(kind: .create, range: edit.range, wasClamped: edit.wasClamped, blockID: nil, column: 0, columnCount: 1, title: nil)
        return true
    }

    func updateCreate(toY y: CGFloat) {
        guard mode == .dragging, let planner, preview?.kind == .create else { return }
        let edit = planner.createPreview(fromY: createAnchorY, toY: y)
        let next = Preview(kind: .create, range: edit.range, wasClamped: edit.wasClamped, blockID: nil, column: 0, columnCount: 1, title: nil)
        if next != preview { preview = next }
    }

    /// Gesture ended. Decides what happens next; commits once if nothing more is needed from the user.
    /// State changes happen synchronously, so a dialog dismissing right after this call sees the new mode.
    func finish() {
        guard mode == .dragging, let preview, let planner else { return }
        cancelDwell()                    // the finger is up: nothing is resting any more
        if preview.kind == .create {
            guard environment.calendars().contains(where: \.isWritable) else {
                rollback()
                feedback = EditFeedback(message: "일정을 만들 수 있는 캘린더가 없습니다.", tone: .error, canRetry: false)
                return
            }
            mode = .namingEvent
            return
        }
        guard let block, planner.range(of: block) != preview.range else {
            rollback()          // dropped where it started: nothing to do
            return
        }
        if block.isRecurringInstance {
            let options = planner.scopeOptions(for: block, newRange: preview.range, supported: environment.supportedScopes)
            guard !options.isEmpty else {
                rollback()
                feedback = EditFeedback.make(for: .providerFailure(.unsupported("recurrence")))
                return
            }
            scopeOptions = options
            mode = .choosingScope
            return
        }
        startCommit(scope: nil)
    }

    /// The user chose how far a change to a recurring event reaches. `nil` cancels.
    func chooseScope(_ scope: RecurrenceScope?) {
        guard mode == .choosingScope else { return }
        guard let scope, scopeOptions.contains(scope) else {
            rollback()
            return
        }
        startCommit(scope: scope)
    }

    func confirmCreate(title: String, calendarID: CalendarID) {
        guard mode == .namingEvent, let planner, let preview else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = planner.createCommand(title: trimmed.isEmpty ? "새 일정" : trimmed, calendarID: calendarID, range: preview.range)
        start(command)
    }

    /// Moves one edge of `block` by `minutes` without a drag, for assistive technologies (VoiceOver's adjustable action). It
    /// goes through the same preview, policy and command as a drag, so snapping, the minimum length, the recurring scope
    /// question and rollback are all the same.
    func nudge(_ kind: TimelineEditPlanner.Kind, block: EventBlock, minutes: Int) {
        guard mode == .idle, let timeline, kind == .resizeStart || kind == .resizeEnd else { return }
        let geometry = self.geometry
        guard begin(kind, block: block, timeline: timeline, geometry: geometry) else { return }
        let edge = kind == .resizeStart ? block.startMinute : block.endMinute
        update(translationY: geometry.y(minute: edge + minutes) - geometry.y(minute: edge))
        finish()
    }

    /// Abandons whatever is in progress and removes the preview.
    func cancel() { rollback() }

    func retry() {
        guard mode == .idle, let lastCommand else { return }
        feedback = nil
        start(lastCommand)
    }

    /// Resolves when the commit in flight (if any) has finished and the calendar was re-read. For tests and callers
    /// that must sequence after a gesture.
    func waitUntilSettled() async { await inflight?.value }

    // MARK: Internals

    private func startCommit(scope: RecurrenceScope?) {
        guard let planner, let block, let preview,
              let command = planner.command(preview.kind, block: block, newRange: preview.range, scope: scope) else {
            rollback()
            return
        }
        start(command)
    }

    /// Flips to `committing` before returning, then performs the one write.
    private func start(_ command: CalendarCommand) {
        mode = .committing
        lastCommand = command
        inflight = Task { await run(command) }
    }

    private func run(_ command: CalendarCommand) async {
        let before = currentAxis               // what the user was looking at, to keep the event still when the axis re-centres
        let kind = draggedKind
        let outcome = await environment.perform(command)
        // Whatever happened, show the calendar's truth: the preview goes away only after the fresh read.
        await environment.reload()
        feedback = EditFeedback.make(for: outcome)
        let wasCreate: Bool
        if case .createEvent = command { wasCreate = true } else { wasCreate = false }
        if case .applied = outcome { lastCommand = nil }
        clear()
        if wasCreate {
            exitEditMode()                      // a new event was placed: fold the day back up
        } else if let key = selectedKey {
            // An edited event stays selected so it can be adjusted again; the enlarged region follows it.
            if let block = timeline?.blocks.first(where: { $0.eventKey == key }) {
                // Keep the edge that was just moved where it was on screen.
                let anchor = kind == .resizeEnd ? block.endMinute : block.startMinute
                // The view goes back to where it was when the handle was grabbed; the new edge is wherever the new time puts it.
                setAnchors(anchors(for: block, fallback: block.startMinute), selected: key, anchorMinute: anchor, from: before,
                           forcedDelta: dragShift == 0 ? nil : -dragShift)
                dragShift = 0
            } else {
                setAnchors(nil, selected: nil, anchorMinute: nil, from: before)
            }
        }
    }

    private func rollback() {
        if dwellCenter != nil { releaseDwell(roomAfter: false) }                                           // the drag is over
        clear()
        if selectedKey == nil { exitEditMode() }       // a cancelled placement folds the day back up
    }

    private func clear() {
        cancelDwell()
        dwellCenter = nil
        mode = .idle
        preview = nil
        planner = nil
        block = nil
        scopeOptions = []
    }
}
