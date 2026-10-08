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

    private(set) var mode: Mode = .idle
    private(set) var preview: Preview?
    private(set) var scopeOptions: [RecurrenceScope] = []
    var feedback: EditFeedback?

    private let environment: Environment
    private var planner: TimelineEditPlanner?
    private var block: EventBlock?
    private var lastCommand: CalendarCommand?
    private var createAnchorY: CGFloat = 0
    private var inflight: Task<Void, Never>?

    init(environment: Environment) {
        self.environment = environment
    }

    var isActive: Bool { mode != .idle }
    var activeBlockID: BlockID? { block?.id }
    /// Whether the picked-up block is being created rather than edited.
    var isCreating: Bool { preview?.kind == .create }

    /// Where to draw the preview, in grid coordinates.
    func previewFrame(totalWidth: CGFloat) -> CGRect? {
        guard let planner, let preview else { return nil }
        return planner.previewFrame(preview.range, column: preview.column, columns: preview.columnCount, totalWidth: totalWidth)
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
        let outcome = await environment.perform(command)
        // Whatever happened, show the calendar's truth: the preview goes away only after the fresh read.
        await environment.reload()
        feedback = EditFeedback.make(for: outcome)
        if case .applied = outcome { lastCommand = nil }
        clear()
    }

    private func rollback() { clear() }

    private func clear() {
        mode = .idle
        preview = nil
        planner = nil
        block = nil
        scopeOptions = []
    }
}
