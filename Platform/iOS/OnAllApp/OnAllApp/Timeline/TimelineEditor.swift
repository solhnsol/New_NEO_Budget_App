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
        let id = UUID()
        let delta: CGFloat
        static func == (lhs: ScrollRequest, rhs: ScrollRequest) -> Bool { lhs.id == rhs.id }
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
    /// While an edge handle is dragged and the finger rests over a compressed stretch, the minute the enlarged zone has
    /// moved to. It is the selected time, so the handle stays exactly where the finger is when the zone appears.
    private(set) var dwellCenter: Int?
    /// The event being edited. `nil` while only a focus exists means a new event is being placed.
    private(set) var selectedKey: CalendarEventKey?
    /// The event opened in place to show what it means and every linked transaction. Only one at a time, and never
    /// together with edit mode: time adjustment and reading details are separate.
    private(set) var expandedKey: CalendarEventKey?
    private(set) var scrollRequest: ScrollRequest?
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

    /// Everything that changes the shape of the axis while editing, for animating it.
    struct AxisShape: Equatable {
        let anchors: [Int]?
        let dwell: Int?
    }
    var axisShape: AxisShape { AxisShape(anchors: editAnchors, dwell: dwellCenter) }

    /// Where the axis is enlarged now: the handles, plus the resting finger's zone while one exists.
    private var allAnchors: [Int]? { editAnchors.map { $0 + (dwellCenter.map { [$0] } ?? []) } }
    /// The enlarged minute windows, for drawing and tests.
    var enlargedZones: [ClosedRange<Int>] { allAnchors.map { browseAxis.handleZones(around: $0, parameters: parameters) } ?? [] }
    var isActive: Bool { mode != .idle }
    var activeBlockID: BlockID? { block?.id }
    /// Whether the picked-up block is being created rather than edited.
    var isCreating: Bool { preview?.kind == .create }

    /// Where to draw the preview, in grid coordinates.
    func previewFrame(totalWidth: CGFloat) -> CGRect? {
        guard let planner, let preview else { return nil }
        return planner.previewFrame(preview.range, column: preview.column, columns: preview.columnCount, totalWidth: totalWidth)
    }

    // MARK: View modes

    /// Browse axis for the current day, or the uniform fallback before a timeline is known.
    private var browseAxis: TimelineAxis {
        guard let timeline else { return .linear(totalMinutes: 1440, pointsPerMinute: 1) }
        return TimelineAxis.browse(for: timeline, parameters: parameters)
    }

    /// The axis for a view shape: the browse axis, with the neighbourhood of each handle enlarged and/or one event opened
    /// over its own range.
    private func axis(anchors: [Int]?, expanded: CalendarEventKey?) -> TimelineAxis {
        var result = browseAxis
        if let anchors { result = result.expandedLocally(around: anchors, parameters: parameters) }
        if let spec = expansion(for: expanded) { result = result.expanded(over: spec.window, scale: spec.scale) }
        return result
    }

    private var currentAxis: TimelineAxis { axis(anchors: allAnchors, expanded: expandedKey) }

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

    /// Switches the axis and, if asked, scrolls so `anchorMinute` stays where it was on screen.
    private func setAnchors(
        _ new: [Int]?, selected: CalendarEventKey?, expanded: CalendarEventKey? = nil, anchorMinute: Int?, from old: TimelineAxis
    ) {
        editAnchors = new
        selectedKey = selected
        expandedKey = expanded
        guard let anchorMinute else { return }
        let delta = currentAxis.y(minute: anchorMinute) - old.y(minute: anchorMinute)
        if abs(delta) > 0.5 { scrollRequest = ScrollRequest(delta: delta) }
    }

    /// First long press on an event: select it and enlarge the neighbourhood of its two handles. Nothing else unfolds, and
    /// `pressMinute`, the time under the finger, keeps its screen position. Returns `false` (and says why) if the event cannot be edited.
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
            settlesAt = Date().addingTimeInterval(0.35)
        }
        return true
    }

    /// Long press on empty time: enlarge the neighbourhood of that minute so the new event can be placed in 15 minute steps.
    @discardableResult
    func focusForCreate(atMinute minute: Int) -> Bool {
        guard mode == .idle, timeline != nil else { return false }
        feedback = nil
        setAnchors([minute], selected: nil, anchorMinute: minute, from: currentAxis)
        settlesAt = Date().addingTimeInterval(0.35)
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
        dwellCenter = minute
        let after = currentAxis
        let delta = after.y(minute: minute) - before.y(minute: minute)
        if abs(delta) > 0.5 { scrollRequest = ScrollRequest(delta: delta) }
        let geometry = TimelineGeometry(axis: after)
        planner = TimelineEditPlanner(policy: environment.policy, zone: environment.zone, geometry: geometry, timeline: timeline)
        // The finger has not moved on screen, so in content coordinates it is `delta` further along, and it is at `minute`.
        let original = preview.kind == .resizeStart ? block.startMinute : block.endMinute
        fingerAnchorY = (lastFingerY + delta) - (after.y(minute: minute) - after.y(minute: original))
        lastFingerY += delta
        settlesAt = Date().addingTimeInterval(Self.settleSeconds)
    }

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

    /// Drops the finger's zone, scrolling so `anchorMinute` stays where it is on screen.
    private func releaseDwell(keeping anchorMinute: Int?) {
        cancelDwell()
        guard dwellCenter != nil else { return }
        let before = currentAxis
        dwellCenter = nil
        guard let anchorMinute else { return }
        let delta = currentAxis.y(minute: anchorMinute) - before.y(minute: anchorMinute)
        if abs(delta) > 0.5 { scrollRequest = ScrollRequest(delta: delta) }
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
        cancelDwell()
        mode = .dragging
        feedback = nil
        preview = Preview(
            kind: kind, range: edit.range, wasClamped: edit.wasClamped, blockID: block.id,
            column: block.layout.column, columnCount: block.layout.columnCount, title: block.title
        )
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
                setAnchors(anchors(for: block, fallback: block.startMinute), selected: key, anchorMinute: anchor, from: before)
            } else {
                setAnchors(nil, selected: nil, anchorMinute: nil, from: before)
            }
        }
    }

    private func rollback() {
        if dwellCenter != nil, let preview, let timeline {
            releaseDwell(keeping: edgeMinute(of: preview, in: timeline) ?? dwellCenter)
        }
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
