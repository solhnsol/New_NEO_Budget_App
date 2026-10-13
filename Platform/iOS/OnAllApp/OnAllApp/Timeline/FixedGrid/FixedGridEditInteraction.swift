import CoreGraphics
import NEOBudgetCalendar
import Observation

/// What an edit session on the fixed grid is doing, as a state machine of small events in and commands out (Phase 3A). Pure, so it is tested; the screen
/// (`FixedGridBrowseView`) feeds it the grid's touches and the selected day, and carries out the commands that are the grid's own (freeze, retarget,
/// unfreeze). The commands for the parts that edit — a draft of the event, the time bubble of a handle, the save — go out through `FixedGridEditRouter`
/// to whoever implements them; nothing here knows their types, and they answer with events (`draftChanged`, `commitFinished`, `commitFailed`).
///
/// One session at a time, on one event:
/// - **enter** (a tap on an editable event): the grid freezes (`freeze`); no handle is chosen.
/// - **rename** (a tap on the chosen event's title): the title is edited with the keyboard (`rename(true)`); a chosen handle is let go. A handle touched
///   or a tap outside ends the renaming first (`rename(false)`), the new title kept; done saves the title with the time.
/// - **handles**: a tap chooses a handle (its time bubble) or lets it go; a drag makes it the dragged one, and lets it go when it ends (no bubble during or
///   after a drag: the card shows the time). The handle last touched is the edge the time is kept at when the session ends (`AnchorRequest`).
/// - **confirm**: with changes, `commit` and wait (still frozen) for `commitFinished` (unfreeze at the edited edge) or `commitFailed` (back to editing, the
///   changes kept); without, the session just ends.
/// - **cancel**: `discard` (when there are changes) and unfreeze at the middle of the screen.
/// - **a tap outside** the event and its handles (empty grid, a transaction, the day header): first ends a renaming, or lets a chosen handle go; then ends the session — without
///   changes as a cancel, with changes as `ExitPolicy.outsideTap` says.
/// - **another event tapped**: without changes the session moves to it and the grid stays frozen (`retarget`); with changes it is a tap outside.
/// - **the selected day changes** (the week strip, "오늘"): the days are going to move, so the grid unfreezes at once; changes are committed or discarded as
///   `ExitPolicy.dayChange` says (a commit then finishes after the grid has let go).
/// - while a commit is under way only its answer and a day change count.
struct FixedGridEditInteraction: Equatable {
    /// The event being edited: the day (column) it is drawn in, its block, its calendar key and its time as the session began (elapsed minutes of `day`).
    struct Target: Equatable {
        let day: LocalDate
        let blockID: BlockID
        let eventKey: CalendarEventKey
        let startMinute: Int
        let endMinute: Int

        init(day: LocalDate, blockID: BlockID, eventKey: CalendarEventKey, startMinute: Int, endMinute: Int) {
            self.day = day; self.blockID = blockID; self.eventKey = eventKey; self.startMinute = startMinute; self.endMinute = endMinute
        }

        init(day: LocalDate, block: EventBlock) {
            self.init(day: day, blockID: block.id, eventKey: block.eventKey, startMinute: block.startMinute, endMinute: block.endMinute)
        }

        var epoch: Int { day.daysSinceUnixEpoch }
    }

    enum Handle: Equatable, Hashable {
        case start, end
        init?(_ hit: EditHit) {
            switch hit {
            case .resizeStart: self = .start
            case .resizeEnd: self = .end
            case .body: return nil
            }
        }
    }

    enum HandleState: Equatable {
        case none
        /// Chosen (by a tap, or the drag that just ended): its time bubble is up.
        case selected(Handle)
        case dragging(Handle)

        var handle: Handle? {
            switch self {
            case .none: nil
            case let .selected(handle), let .dragging(handle): handle
            }
        }
    }

    /// What is done with changes when the session is left without a confirm or a cancel. `ask` leaves the session open and asks (`askExit`); the answer is a
    /// `confirm` or a `cancel`.
    enum DirtyExit: Equatable { case commit, discard, ask }

    struct ExitPolicy: Equatable {
        /// A tap outside the event: the changes are kept, the way a calendar keeps a drag when the finger lifts.
        var outsideTap: DirtyExit = .commit
        /// The selected day changed under the session. `ask` is taken as `commit`: the days are already going (there is nothing to hold them for an answer).
        var dayChange: DirtyExit = .commit
    }

    struct Session: Equatable {
        let id: Int
        var target: Target
        var handle: HandleState = .none
        /// The handle last tapped or dragged in this session.
        var lastEdited: Handle?
        /// Whether the draft differs from the original (said by the draft's owner, `draftChanged`).
        var isDirty = false
        /// The title is being edited (the keyboard is up).
        var renaming = false
        var committing = false
        /// The grid has let go already (the days moved on); the session only waits for its commit's answer.
        var released = false
        /// Waiting for the answer to `askExit`.
        var asking: ExitReason?
    }

    enum ExitReason: Equatable { case outsideTap, otherEvent }

    /// Where the time stays put when the grid unfreezes after a session.
    enum AnchorRequest: Equatable {
        /// The time at the middle of the screen (nothing was edited, or what was is let go).
        case middle
        /// The edited edge, at the time it was saved with (elapsed minutes of `day`): it stays where it is on screen while the axis eases to the new plan.
        case edge(Handle, day: LocalDate, minute: Int)
    }

    /// What the save made of the event (elapsed minutes of `day`), from whoever saved it.
    struct Committed: Equatable {
        let day: LocalDate
        let startMinute: Int
        let endMinute: Int
    }

    enum EndReason: Equatable { case committed, cancelled, discarded, dayChanged, commitFailedAfterRelease }

    enum Event: Equatable {
        case enter(Target)
        case handleTap(Handle)
        /// A drag from a handle; `minute`: the elapsed minute of the target's day under the finger, on the frozen axis.
        case handleDrag(GridGestureHooks.Phase, Handle, point: CGPoint, minute: Int?)
        /// The chosen event's title tapped: edit it.
        case tapTitle
        /// The keyboard went away (its return key is a `confirm`).
        case endRename
        case tapOutside
        /// Another event of the grid tapped while editing (the same event's body lets a chosen handle go).
        case tapEvent(Target)
        case selectedDayChanged(LocalDate)
        case cancel
        case confirm
        case draftChanged(session: Int, isDirty: Bool)
        case commitFinished(session: Int, Committed)
        case commitFailed(session: Int)
    }

    enum Command: Equatable {
        // The grid's own (the screen carries them out).
        case freeze(session: Int, Target)
        /// The session moves to another event; the grid stays as it is.
        case retarget(session: Int, Target)
        case unfreeze(session: Int, AnchorRequest)
        // For the parts that edit (draft, time bubble, save).
        case began(session: Int, Target)
        case handle(session: Int, HandleState)
        case dragHandle(session: Int, GridGestureHooks.Phase, Handle, point: CGPoint, minute: Int?)
        /// The title is being edited (`true`) or no longer is.
        case rename(session: Int, Bool)
        case commit(session: Int)
        case discard(session: Int)
        case askExit(session: Int, ExitReason)
        case ended(session: Int, EndReason)

        /// Whether the grid carries it out (otherwise it is for the editing parts).
        var isGrid: Bool {
            switch self {
            case .freeze, .retarget, .unfreeze: true
            default: false
            }
        }
    }

    var policy = ExitPolicy()
    private(set) var session: Session?
    private var sessions = 0

    init(policy: ExitPolicy = ExitPolicy()) { self.policy = policy }

    /// The session the grid is frozen for (`nil` when none, or when the grid has let go and a commit is only finishing).
    var editing: Session? { session.flatMap { $0.released ? nil : $0 } }

    // MARK: Events

    mutating func handle(_ event: Event) -> [Command] {
        switch event {
        case let .enter(target): return enter(target)
        case let .handleTap(handle): return tapHandle(handle)
        case let .handleDrag(phase, handle, point, minute): return drag(phase, handle, point: point, minute: minute)
        case .tapTitle: return tapTitle()
        case .endRename:
            guard var session = active, session.renaming else { return [] }
            return endRename(&session)
        case .tapOutside: return tapOutside()
        case let .tapEvent(target): return tapEvent(target)
        case .selectedDayChanged: return dayChanged()
        case .cancel: return cancel()
        case .confirm: return confirm()
        case let .draftChanged(id, dirty):
            guard var session, session.id == id, !session.committing else { return [] }
            session.isDirty = dirty
            self.session = session
            return []
        case let .commitFinished(id, committed): return commitFinished(id, committed)
        case let .commitFailed(id): return commitFailed(id)
        }
    }

    private mutating func enter(_ target: Target) -> [Command] {
        if let session {
            guard !session.released else { return [] }                            // a commit is finishing; the next session waits for it
            return tapEvent(target)
        }
        sessions += 1
        session = Session(id: sessions, target: target)
        return [.freeze(session: sessions, target), .began(session: sessions, target)]
    }

    private mutating func tapHandle(_ handle: Handle) -> [Command] {
        guard var session = active else { return [] }
        let renamed = session.renaming ? endRename(&session) : []
        session.handle = session.handle == .selected(handle) ? .none : .selected(handle)
        session.lastEdited = handle
        self.session = session
        return renamed + [.handle(session: session.id, session.handle)]
    }

    private mutating func tapTitle() -> [Command] {
        guard var session = active, !session.renaming else { return [] }
        var commands: [Command] = []
        if session.handle != .none {                                               // the keyboard and a time bubble are not up together
            session.handle = .none
            commands.append(.handle(session: session.id, .none))
        }
        session.renaming = true
        self.session = session
        return commands + [.rename(session: session.id, true)]
    }

    /// Ends the renaming of `session` (kept here) and says so.
    private mutating func endRename(_ session: inout Session) -> [Command] {
        session.renaming = false
        self.session = session
        return [.rename(session: session.id, false)]
    }

    private mutating func drag(_ phase: GridGestureHooks.Phase, _ handle: Handle, point: CGPoint, minute: Int?) -> [Command] {
        guard var session = active else { return [] }
        var commands: [Command] = []
        switch phase {
        case .began:
            if session.renaming { commands += endRename(&session) }
            session.handle = .dragging(handle)
            session.lastEdited = handle
            commands.append(.handle(session: session.id, session.handle))
        case .moved:
            guard session.handle == .dragging(handle) else { return [] }
        case .ended, .cancelled:
            guard session.handle == .dragging(handle) else { return [] }
            session.handle = .none                                                 // a drag shows its time on the card; the bubble is a tap's
        }
        commands.append(.dragHandle(session: session.id, phase, handle, point: point, minute: minute))
        if phase == .ended || phase == .cancelled { commands.append(.handle(session: session.id, session.handle)) }
        self.session = session
        return commands
    }

    private mutating func tapOutside() -> [Command] {
        guard var session = active else { return [] }
        if session.renaming { return endRename(&session) }                         // the innermost thing goes first
        if session.handle != .none {
            session.handle = .none
            self.session = session
            return [.handle(session: session.id, .none)]
        }
        return leave(session, policy: policy.outsideTap, reason: .outsideTap)
    }

    private mutating func tapEvent(_ target: Target) -> [Command] {
        guard var session = active else { return [] }
        if target.eventKey == session.target.eventKey && target.day == session.target.day {
            if session.renaming { return endRename(&session) }
            guard session.handle != .none else { return [] }
            session.handle = .none
            self.session = session
            return [.handle(session: session.id, .none)]
        }
        guard !session.isDirty else { return leave(session, policy: policy.outsideTap, reason: .otherEvent) }
        session.target = target
        session.handle = .none
        session.lastEdited = nil
        session.renaming = false
        self.session = session
        return [.retarget(session: session.id, target), .began(session: session.id, target)]
    }

    /// Leaves the session without a confirm or a cancel.
    private mutating func leave(_ session: Session, policy: DirtyExit, reason: ExitReason) -> [Command] {
        guard session.isDirty else { return cancel() }
        switch policy {
        case .commit: return confirm()
        case .discard: return cancel()
        case .ask:
            var session = session
            session.asking = reason
            self.session = session
            return [.askExit(session: session.id, reason)]
        }
    }

    private mutating func dayChanged() -> [Command] {
        guard var session, !session.released else { return [] }
        let id = session.id
        if session.committing {                                                    // the commit goes on; the grid lets go now
            session.released = true
            self.session = session
            return [.unfreeze(session: id, .middle)]
        }
        guard session.isDirty else {
            self.session = nil
            return [.unfreeze(session: id, .middle), .ended(session: id, .dayChanged)]
        }
        if policy.dayChange == .discard {
            self.session = nil
            return [.discard(session: id), .unfreeze(session: id, .middle), .ended(session: id, .dayChanged)]
        }
        session.committing = true
        session.released = true
        session.handle = .none
        session.renaming = false
        session.asking = nil
        self.session = session
        return [.commit(session: id), .unfreeze(session: id, .middle)]
    }

    private mutating func cancel() -> [Command] {
        guard let session, !session.committing else { return [] }
        self.session = nil
        let reason: EndReason = session.isDirty ? .discarded : .cancelled
        return (session.isDirty ? [.discard(session: session.id)] : []) + [.unfreeze(session: session.id, .middle), .ended(session: session.id, reason)]
    }

    private mutating func confirm() -> [Command] {
        guard var session, !session.committing else { return [] }
        guard session.isDirty else { return cancel() }
        let renamed: [Command] = session.renaming ? [.rename(session: session.id, false)] : []
        session.committing = true
        session.handle = .none
        session.renaming = false
        session.asking = nil
        self.session = session
        return renamed + [.handle(session: session.id, .none), .commit(session: session.id)]
    }

    private mutating func commitFinished(_ id: Int, _ committed: Committed) -> [Command] {
        guard let session, session.id == id, session.committing else { return [] }
        self.session = nil
        let end: [Command] = [.ended(session: id, .committed)]
        guard !session.released else { return end }
        return [.unfreeze(session: id, Self.anchor(for: session, committed: committed))] + end
    }

    private mutating func commitFailed(_ id: Int) -> [Command] {
        guard var session, session.id == id, session.committing else { return [] }
        guard !session.released else { self.session = nil; return [.ended(session: id, .commitFailedAfterRelease)] }
        session.committing = false                                                 // back to editing, the changes kept
        self.session = session
        return []
    }

    /// The session that takes touches and actions: open, not committing, not waiting for an answer to `askExit` (that answer is a confirm or a cancel).
    private var active: Session? { session.flatMap { $0.committing || $0.released || $0.asking != nil ? nil : $0 } }

    // MARK: The anchor

    /// The edge kept in place when the grid unfreezes after a commit: the handle last touched; with none, the end when only the end moved, else the start.
    static func anchor(for session: Session, committed: Committed) -> AnchorRequest {
        let edge = session.lastEdited ?? (committed.startMinute == session.target.startMinute && committed.endMinute != session.target.endMinute ? .end : .start)
        return .edge(edge, day: committed.day, minute: edge == .start ? committed.startMinute : committed.endMinute)
    }

    // MARK: The grid's mode

    /// The gesture mode while this is the state: editing as long as the grid is frozen for a session, even when the target cannot be placed now (its day not
    /// kept, its block gone after a reload) — then there are no handles, but the days still do not move.
    func gestureMode(place: (Target) -> FixedGridGestures.EditTarget?) -> FixedGridGestures.Mode {
        guard let session = editing else { return .browse }
        if let placed = place(session.target) { return .editing(placed) }
        return .editing(FixedGridGestures.EditTarget(epoch: session.target.epoch, blockID: session.target.blockID, frame: .null, canResizeStart: false, canResizeEnd: false))
    }
}

/// Where the edit session lives for the screen and for the parts that edit. The screen sends the grid's events and carries out the grid's commands (`grid`);
/// the parts that edit receive the rest (`editor`) and answer through `send`. Nothing else is shared between them.
@MainActor
@Observable
final class FixedGridEditRouter {
    private(set) var state: FixedGridEditInteraction
    /// The grid's own commands (`Command.isGrid`), for the screen.
    @ObservationIgnored var grid: (FixedGridEditInteraction.Command) -> Void = { _ in }
    /// The commands for the parts that edit (draft, time bubble, save). None in this phase but the DEBUG probe's.
    @ObservationIgnored var editor: (FixedGridEditInteraction.Command) -> Void = { _ in }
    /// The commands sent so far (DEBUG probe and tests), the latest last, at most 32.
    @ObservationIgnored private(set) var log: [FixedGridEditInteraction.Command] = []

    init(policy: FixedGridEditInteraction.ExitPolicy = .init()) { state = FixedGridEditInteraction(policy: policy) }

    var session: FixedGridEditInteraction.Session? { state.session }

    func send(_ event: FixedGridEditInteraction.Event) {
        let commands = state.handle(event)
        log.append(contentsOf: commands)
        if log.count > 32 { log.removeFirst(log.count - 32) }
        for command in commands {
            if command.isGrid { grid(command) } else { editor(command) }
        }
    }
}
