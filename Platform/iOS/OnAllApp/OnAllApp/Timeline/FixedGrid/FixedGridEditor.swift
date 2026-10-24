import Foundation
import NEOBudgetCalendar
import Observation

/// The parts that edit, joined for the fixed-grid Browse (Phase 3A): it is the `editor` end of `FixedGridEditRouter`. A session's event is held as an
/// `EditDraft` (the real range, the original fixed); a handle dragged moves one edge of it (`EditDraft.drag`, 15-minute grid); the precision bubble steps an
/// edge to a time its wheel turned to (`setRange`; VoiceOver steps it by 15 minutes, `EditDraft.stepStart`/`stepEnd`); a tap on the title renames it
/// (`title`, typed with the keyboard); a commit saves the time and the title through `EventSavePipeline` (via `Environment.save`, which reads the days
/// again) and answers the session with `commitFinished` or `commitFailed`.
///
/// What it decides, and the session does not:
/// - a draft that cannot be made (a multi-day, all-day or read-only event): the session is cancelled at once and a message says why;
/// - a recurring event: the save asks for a scope (`scopeQuestion`); no answer is back to editing with the changes kept;
/// - a refusal (the event changed or went away elsewhere, or cannot be written): nothing is written, the draft is dropped and the session ends — the
///   screen then shows what the calendar holds;
/// - a failure: back to editing with the changes kept; another "완료" tries again (the original is checked again first).
///
/// A new event (`Target.isNew`, put down by a long press) is held the same way, as a draft of an event that is not in the calendar yet: its handles, bubble
/// and title work as for any other, its calendar is chosen here (`choose`), and done creates it (`Environment.create`) instead of saving a change; cancel
/// writes nothing. A failure to create is back to editing, the draft kept.
///
/// It never writes by itself and never decides the session's state; it only answers with events.
@MainActor
@Observable
final class FixedGridEditor {
    struct Environment {
        var zone: DisplayTimeZone
        /// The data generation now (`AppModel.dataGeneration`).
        var generation: () -> Int
        /// The target's block as kept now (by block id, else by the calendar's key).
        var block: (FixedGridEditInteraction.Target) -> EventBlock?
        /// Saves, then reads the days again (`AppModel.save`). `nil`: no calendar to save to.
        var save: (EventSaveRequest) async -> EventSaveResult?
        /// A grid step was taken (a haptic).
        var stepped: () -> Void = {}
        /// The calendars there are (a new event goes to one that can be written).
        var calendars: () -> [CalendarDescriptor] = { [] }
        /// Creates an event, then reads the days again (`AppModel.perform`). `nil`: no calendar to save to.
        var create: (CalendarEventDraft) async -> CalendarCommandOutcome? = { _ in nil }
        /// Records who a new event is with and how many people in all, once it is created (`docs/ledger-behavior.md`: settling later needs no typing).
        var meet: (CalendarEventKey, [PersonID], Int?) async -> Void = { _, _, _ in }
    }

    /// What is said to the person after something they did not see happen (a refusal, a failure, a snap).
    struct Message: Equatable, Identifiable {
        let id: Int
        let text: String
        let isProblem: Bool
    }

    struct ScopeQuestion: Equatable, Identifiable {
        let session: Int
        let request: EventSaveRequest
        let options: [RecurrenceScope]
        var id: Int { session }
    }

    private let send: (FixedGridEditInteraction.Event) -> Void
    private let environment: Environment

    private(set) var session: Int?
    private(set) var target: FixedGridEditInteraction.Target?
    private(set) var draft: EditDraft?
    private var original: EventSaveOriginal?
    /// The edge whose bubble is up (chosen, or being dragged).
    private(set) var edge: EditDraft.Edge?
    private(set) var isDragging = false
    private var rangeAtDragStart: TimedRange?
    private var sentDirty = false
    /// The title as typed (the original's until the person types). A blank one is not saved: the original stays.
    var title = "" { didSet { reportDirty() } }
    /// The title is being edited (the keyboard is up).
    private(set) var isRenaming = false
    private(set) var isSaving = false
    /// The session's event is a new one, not in the calendar until done.
    private(set) var isNew = false
    /// The calendar a new event goes to (chosen with the chips; the first writable one at first).
    private(set) var calendarID: CalendarID?
    /// Who a new event is with (chosen with the people chips), saved on its activity once it is created.
    var people: Set<PersonID> = []
    /// How many people in all, the user included, for a new event (`nil`: the people chosen and the user).
    var headcount: Int?
    var scopeQuestion: ScopeQuestion?
    private(set) var message: Message?
    private var messages = 0

    init(environment: Environment, send: @escaping (FixedGridEditInteraction.Event) -> Void) {
        self.environment = environment
        self.send = send
    }

    convenience init(router: FixedGridEditRouter, environment: Environment) {
        self.init(environment: environment) { [weak router] in router?.send($0) }
    }

    /// Why an event's time cannot be edited here, or `nil` when it can (the same check a session's start makes).
    static func refusal(for block: EventBlock, zone: DisplayTimeZone) -> EditDraftError? {
        do { _ = try EditDraft(block: block, timeZone: zone); return nil } catch { return error }
    }

    static func text(for refusal: EditDraftError) -> String {
        switch refusal {
        case .allDay: "종일 일정은 여기서 시간을 바꿀 수 없어요"
        case .readOnly: "읽기 전용 캘린더의 일정이에요"
        case .eventMissing: "캘린더에서 사라진 일정이에요"
        case .spansDays: "여러 날에 걸친 일정은 아직 시간을 바꿀 수 없어요"
        case .startNotBeforeEnd, .shorterThanMinimum: "15분보다 짧게 만들 수 없어요"
        case .leavesDay: "하루를 넘어가게 바꿀 수 없어요"
        }
    }

    // MARK: The session's commands

    func perform(_ command: FixedGridEditInteraction.Command) {
        switch command {
        case let .began(id, target): begin(id, target: target)
        case let .handle(id, state):
            guard id == session else { return }
            edge = state.handle.map(Self.edge)
            isDragging = { if case .dragging = state { true } else { false } }()
        case let .dragHandle(id, phase, handle, _, minute):
            guard id == session else { return }
            drag(phase, Self.edge(handle), minute: minute)
        case let .rename(id, on):
            guard id == session else { return }
            isRenaming = on
            if !on, newTitle == nil { title = originalTitle }                    // a blank title goes back to the original
        case let .commit(id):
            guard id == session, let draft else { return }
            if isNew { return create(draft, session: id) }
            guard let original else { return }
            isSaving = true
            save(EventSaveRequest(original: original, proposedStart: draft.startDate, proposedEnd: draft.endDate, proposedTitle: newTitle), session: id)
        case let .discard(id):
            guard id == session else { return }
            draft?.revert()
            title = originalTitle
        case let .askExit(id, _):
            // The default exit policies never ask; a policy that does is answered as a confirm (the changes kept, as a calendar keeps a drag).
            guard id == session else { return }
            send(.confirm)
        case let .ended(id, reason):
            guard id == session else { return }
            if reason == .commitFailedAfterRelease { say("날짜를 옮기기 전에 바꾼 내용을 저장하지 못했어요", problem: true) }
            clear()
        case .freeze, .retarget, .unfreeze:
            break
        }
    }

    private func begin(_ id: Int, target: FixedGridEditInteraction.Target) {
        clear()
        session = id
        self.target = target
        if target.isNew { return beginNew(id, target: target) }
        guard let block = environment.block(target) else { return cancelSoon(id, "일정을 찾지 못했어요") }
        do {
            draft = try EditDraft(block: block, timeZone: environment.zone, generation: environment.generation())
            original = EventSaveOriginal(block: block)
            title = block.title
        } catch {
            cancelSoon(id, Self.text(for: error))
        }
    }

    /// A new event: a draft of an event that is not in the calendar (no title yet, its time where it was put down), for the first calendar that can be written.
    private func beginNew(_ id: Int, target: FixedGridEditInteraction.Target) {
        guard let calendar = environment.calendars().first(where: \.isWritable) else { return cancelSoon(id, "일정을 만들 수 있는 캘린더가 없어요") }
        let start = environment.zone.dayBounds(target.day).start
        guard let range = try? TimedRange(startUnixMilliseconds: start + Int64(target.startMinute) * 60_000, endUnixMilliseconds: start + Int64(target.endMinute) * 60_000)
        else { return cancelSoon(id, Self.text(for: EditDraftError.startNotBeforeEnd)) }
        let snapshot = EditDraft.Snapshot(key: target.eventKey, revisionToken: nil, title: "", time: .timed(range), isEditable: true, isRecurringInstance: false)
        do {
            draft = try EditDraft(original: snapshot, timeZone: environment.zone, generation: environment.generation())
            isNew = true
            calendarID = calendar.id
            sentDirty = true                                                     // the session counts a new event as changed from the start
            title = ""
        } catch {
            cancelSoon(id, Self.text(for: error))
        }
    }

    /// The calendar a new event goes to. Only a new event's calendar is chosen here (moving an event to another calendar is not saved yet).
    func choose(_ calendar: CalendarID) {
        guard isNew, !isSaving, environment.calendars().contains(where: { $0.id == calendar && $0.isWritable }) else { return }
        calendarID = calendar
    }

    /// Ends a session that cannot be edited, after the command that opened it has been carried out.
    private func cancelSoon(_ id: Int, _ text: String) {
        say(text, problem: true)
        Task { @MainActor [weak self] in
            guard let self, self.session == id else { return }
            self.send(.cancel)
        }
    }

    private func drag(_ phase: GridGestureHooks.Phase, _ edge: EditDraft.Edge, minute: Int?) {
        guard var draft, let target else { return }
        switch phase {
        case .began:
            rangeAtDragStart = draft.range
        case .moved, .ended:
            guard let minute else { return }
            let instant = environment.zone.dayBounds(target.day).start + Int64(minute) * 60_000
            if draft.drag(edge, to: instant) { environment.stepped() }
            if phase == .ended { rangeAtDragStart = nil }
        case .cancelled:
            if let start = rangeAtDragStart { try? draft.setRange(start) }
            rangeAtDragStart = nil
        }
        self.draft = draft
        reportDirty()
    }

    private func reportDirty() {
        guard let session, draft != nil, isChanged != sentDirty else { return }
        sentDirty = isChanged
        send(.draftChanged(session: session, isDirty: sentDirty))
    }

    private var originalTitle: String { draft?.original.title ?? "" }

    /// The title to save: the typed one, trimmed, when it is not blank and differs from the original's.
    var newTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == originalTitle ? nil : trimmed
    }

    /// The title the card shows now: the typed one (the original's while it is blank; a new event's placeholder).
    var shownTitle: String {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return title }
        return isNew ? Self.newTitle : originalTitle
    }

    /// What a new event is called when no name is typed.
    static let newTitle = "새 일정"

    /// Whether anything would be saved: the time or the title (a new event: the event itself).
    var isChanged: Bool { isNew || draft?.isChanged == true || newTitle != nil }

    // MARK: The precision bubble

    /// What the bubble shows now: the chosen edge's time, the times its wheel offers and which steps may be taken. `nil` while no edge is chosen, a handle is
    /// dragged (the card shows the time) or a save is under way.
    var bubbleInput: PrecisionBubbleInput? {
        guard let edge, let draft, !isSaving, !isDragging, let zone = TimeZone(identifier: environment.zone.identifier) else { return nil }
        return PrecisionBubbleInput(
            edge: edge == .start ? .start : .end, instant: edge == .start ? draft.startDate : draft.endDate, timeZone: zone,
            canDecrement: !isDragging && draft.canStep(edge, by: -1), canIncrement: !isDragging && draft.canStep(edge, by: 1),
            choices: Self.choices(for: edge, of: draft)
        )
    }

    /// The times an edge may be set to: the 15-minute lines of the draft's day that keep the event inside it and at least the minimum long against the other
    /// edge, and the edge's original time when it is off the grid.
    static func choices(for edge: EditDraft.Edge, of draft: EditDraft) -> [Date] {
        guard let day = draft.days.first else { return [] }
        let bounds = draft.timeZone.dayBounds(day)
        let minimum = Int64(EditDraft.minimumDurationMinutes) * 60_000
        let range = draft.range, original = draft.originalRange
        let (low, high, keep) = edge == .start
            ? (bounds.start, range.endUnixMilliseconds - minimum, original.startUnixMilliseconds)
            : (range.startUnixMilliseconds + minimum, bounds.end, original.endUnixMilliseconds)
        return PrecisionWheelChoices.make(
            low: EventSaveTime.date(low), high: EventSaveTime.date(high), dayStart: EventSaveTime.date(bounds.start), keep: [EventSaveTime.date(keep)],
            stepMinutes: EditDraft.stepMinutes
        )
    }

    func bubble(_ action: PrecisionBubbleAction) {
        guard let edge, var draft, !isSaving else { return }
        switch action {
        case .decrement15, .increment15:
            let steps = action == .increment15 ? 1 : -1
            do {
                switch edge {
                case .start: try draft.stepStart(by: steps)
                case .end: try draft.stepEnd(by: steps)
                }
                environment.stepped()
            } catch {
                say(Self.text(for: error), problem: true)
            }
            self.draft = draft
            reportDirty()
        case let .set(instant):
            let milliseconds = EventSaveTime.milliseconds(instant)
            let start = edge == .start ? milliseconds : draft.range.startUnixMilliseconds
            let end = edge == .end ? milliseconds : draft.range.endUnixMilliseconds
            guard let range = try? TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: end) else {
                return say(Self.text(for: EditDraftError.startNotBeforeEnd), problem: true)
            }
            guard range != draft.range else { return }
            do throws(EditDraftError) {
                try draft.setRange(range)
                environment.stepped()
            } catch {
                say(Self.text(for: error), problem: true)
            }
            self.draft = draft
            reportDirty()
        case .dismiss:
            send(.handleTap(edge == .start ? .start : .end))         // the chosen handle tapped again lets it go
        }
    }

    // MARK: Saving

    /// Creates the new event as the draft has it: the typed name (else "새 일정"), the chosen calendar, the draft's time.
    private func create(_ draft: EditDraft, session id: Int) {
        guard let calendarID else {
            say("일정을 만들 수 있는 캘린더가 없어요", problem: true)
            send(.commitFailed(session: id))
            return
        }
        isSaving = true
        let event = CalendarEventDraft(calendarID: calendarID, title: newTitle ?? Self.newTitle, time: .timed(draft.range), timeZoneIdentifier: environment.zone.identifier)
        let people = people.sorted(), headcount = headcount
        Task { @MainActor [weak self, environment] in
            let outcome = await environment.create(event)
            if case let .applied(applied)? = outcome, let created = applied.event, !people.isEmpty || headcount != nil {
                await environment.meet(CalendarEventKey(calendarID: created.calendarID, eventID: created.id), people, headcount)
            }
            self?.finishCreate(outcome, draft: draft, session: id)
        }
    }

    func finishCreate(_ outcome: CalendarCommandOutcome?, draft: EditDraft, session id: Int) {
        guard id == session, let target else { return }
        isSaving = false
        switch outcome {
        case .applied?:
            send(.commitFinished(session: id, committed(start: draft.startDate, end: draft.endDate, day: target.day)))
        case let .partiallyApplied(_, failure)?:
            say("일정은 만들었지만 연결된 정보를 저장하지 못했어요 (\(failure))", problem: true)
            send(.commitFinished(session: id, committed(start: draft.startDate, end: draft.endDate, day: target.day)))
        case .rejected?, .conflict?, .providerFailure?:
            say("일정을 만들지 못했어요. 완료를 눌러 다시 시도해 주세요", problem: true)
            send(.commitFailed(session: id))
        case nil:
            say("캘린더에 연결되지 않아 저장할 수 없어요", problem: true)
            send(.commitFailed(session: id))
        }
    }

    func answer(_ scope: RecurrenceScope?) {
        guard let question = scopeQuestion else { return }
        scopeQuestion = nil
        guard let scope else {
            isSaving = false
            send(.commitFailed(session: question.session))             // no answer: back to editing, the changes kept
            return
        }
        save(question.request.scoped(scope), session: question.session)
    }

    private func save(_ request: EventSaveRequest, session id: Int) {
        Task { @MainActor [weak self, environment] in
            let result = await environment.save(request)
            self?.finish(result, request: request, session: id)
        }
    }

    /// The minutes of the target's day a saved range is drawn at.
    private func committed(start: Date, end: Date, day: LocalDate) -> FixedGridEditInteraction.Committed {
        let dayStart = environment.zone.dayBounds(day).start
        let startMs = EventSaveTime.milliseconds(start), endMs = EventSaveTime.milliseconds(end)
        return .init(day: day, startMinute: Int((startMs - dayStart) / 60_000), endMinute: Int((endMs - dayStart + 59_999) / 60_000))
    }

    func finish(_ result: EventSaveResult?, request: EventSaveRequest, session id: Int) {
        guard id == session, let target else { return }
        switch result {
        case let .saved(receipt)?:
            isSaving = false
            if let failure = receipt.localFailure { say("일정은 저장했지만 연결된 정보를 고치지 못했어요 (\(failure))", problem: true) }
            else if !receipt.matchesProposal { say("저장하면서 시간이 조금 바뀌었어요", problem: false) }
            send(.commitFinished(session: id, committed(start: receipt.start, end: receipt.end, day: target.day)))
        case .unchanged?:
            isSaving = false
            send(.commitFinished(session: id, committed(start: request.original.start, end: request.original.end, day: target.day)))
        case let .needsScope(options)?:
            scopeQuestion = ScopeQuestion(session: id, request: request, options: options)
        case let .refused(refusal)?:
            isSaving = false
            say(Self.text(for: refusal), problem: true)
            send(.commitFailed(session: id))
            send(.cancel)                                               // saving it again cannot help: the draft goes, the calendar is shown
        case let .failed(failure)?:
            isSaving = false
            say(failure.retry != nil ? "저장하지 못했어요. 완료를 눌러 다시 시도해 주세요" : "저장하지 못했어요. 캘린더를 다시 불러온 뒤 시도해 주세요", problem: true)
            send(.commitFailed(session: id))
        case nil:
            isSaving = false
            say("캘린더에 연결되지 않아 저장할 수 없어요", problem: true)
            send(.commitFailed(session: id))
        }
    }

    static func text(for refusal: EventSaveRefusal) -> String {
        switch refusal {
        case .targetGone: "다른 곳에서 지운 일정이라 저장하지 않았어요"
        case .targetChanged: "다른 곳에서 바뀐 일정이라 저장하지 않았어요. 지금 시간을 보여 드려요"
        case .notEditable: "이 일정은 바꿀 수 없어요"
        case .scopeNotOffered, .invalid(.dateChangeRequiresThisOccurrence): "반복 일정 전체에는 이 변경을 적용할 수 없어요"
        case .invalid(.durationBelowMinimum): "15분보다 짧게 만들 수 없어요"
        case .invalid: "저장할 수 없는 변경이에요"
        }
    }

    static func label(for scope: RecurrenceScope) -> String {
        switch scope {
        case .thisOccurrence: "이 일정만"
        case .thisAndFuture: "이 일정과 이후 일정"
        case .allInSeries: "모든 반복 일정"
        }
    }

    // MARK: Changes outside the session

    /// The calendar was read again while editing: the draft's original is checked against what is kept now.
    func dataChanged(generation: Int, timelines: [DayTimeline]) {
        guard var draft, !isNew else { return }                                  // a new event is in no calendar to change elsewhere
        draft.noteReload(generation: generation)
        draft.observe(.lookup(draft.key, in: timelines), readGeneration: generation)
        self.draft = draft
    }

    /// Said while editing when the original is known to have changed elsewhere (a save would be refused).
    var conflictNote: String? {
        guard !isSaving else { return nil }
        switch draft?.conflict {
        case .changed?: return "다른 곳에서 바뀐 일정이에요. 지금 저장하면 반영되지 않아요"
        case .deleted?: return "다른 곳에서 지운 일정이에요"
        default: return nil
        }
    }

    // MARK: Helpers

    /// Says something outside a session (an event that cannot be edited here).
    func tell(_ text: String) { say(text, problem: true) }

    func dismissMessage(_ id: Int) { if message?.id == id { message = nil } }

    private func say(_ text: String, problem: Bool) {
        messages += 1
        message = Message(id: messages, text: text, isProblem: problem)
    }

    private func clear() {
        session = nil; target = nil; draft = nil; original = nil; edge = nil; isDragging = false; rangeAtDragStart = nil
        sentDirty = false; isSaving = false; scopeQuestion = nil; isRenaming = false; isNew = false; calendarID = nil; title = ""
        people = []; headcount = nil
    }

    private static func edge(_ handle: FixedGridEditInteraction.Handle) -> EditDraft.Edge { handle == .start ? .start : .end }
}

/// The edit bar's words for how far an edge moved: "+15분", "−1시간 30분".
enum EditSessionBarText {
    static func minutes(_ milliseconds: Int64) -> String {
        let total = Int(milliseconds / 60_000)
        let sign = total < 0 ? "−" : "+"
        let hours = abs(total) / 60, minutes = abs(total) % 60
        return sign + (hours > 0 ? "\(hours)시간" + (minutes > 0 ? " \(minutes)분" : "") : "\(minutes)분")
    }
}
