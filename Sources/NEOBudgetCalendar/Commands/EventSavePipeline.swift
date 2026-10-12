import Foundation

// The one save path for an edit session's time change (Phase 3A). It does not write by itself: it re-reads the target, checks it is still what the
// session started from, turns the proposal into the same `CalendarCommand` the timeline editor sends (`TimelineEditPlanner.command`), and runs it
// through `CalendarCommandService.perform`. So the calendar write, the recurrence scope check, the revision conflict check and the local follow-up
// are exactly the existing ones; this only adds the checks before and after them and a result an edit session can act on.
//
// It knows nothing about a draft, a gesture or a screen. A draft fills `EventSaveRequest` (see `docs/development/phase3a-save-pipeline.md`).

/// The event as the edit session first saw it, fixed for the whole session. Its real range, never one clipped to a day.
public struct EventSaveOriginal: Hashable, Sendable {
    public let key: CalendarEventKey
    /// The provider's revision when the session began. `nil` means the provider gave none; only the time is then compared.
    public let revisionToken: String?
    public let start: Date
    public let end: Date

    public init(key: CalendarEventKey, revisionToken: String?, start: Date, end: Date) {
        self.key = key
        self.revisionToken = revisionToken
        self.start = start
        self.end = end
    }

    /// From a timeline block: its unclipped range, not the minutes drawn on one day.
    public init(block: EventBlock) {
        self.init(
            key: block.eventKey, revisionToken: block.revisionToken,
            start: EventSaveTime.date(block.startUnixMilliseconds), end: EventSaveTime.date(block.endUnixMilliseconds)
        )
    }

    /// From a provider snapshot. `nil` for an all-day event, which an edit session does not change.
    public init?(event: CalendarEvent) {
        guard case let .timed(range) = event.time else { return nil }
        self.init(
            key: event.key, revisionToken: event.revisionToken,
            start: EventSaveTime.date(range.startUnixMilliseconds), end: EventSaveTime.date(range.endUnixMilliseconds)
        )
    }

    var startMilliseconds: Int64 { EventSaveTime.milliseconds(start) }
    var endMilliseconds: Int64 { EventSaveTime.milliseconds(end) }

    /// Whether `event` is still this original: the same revision (when there is one) and the same real range.
    public func matches(_ event: CalendarEvent) -> Bool {
        guard case let .timed(range) = event.time else { return false }
        if let revisionToken, revisionToken != event.revisionToken { return false }
        return range.startUnixMilliseconds == startMilliseconds && range.endUnixMilliseconds == endMilliseconds
    }
}

/// What an edit session asks to save: the original it was made against and the real range it proposes. A plain value, so it can be built and
/// tested without a draft and saved again unchanged (a retry).
public struct EventSaveRequest: Hashable, Sendable {
    public let original: EventSaveOriginal
    public let proposedStart: Date
    public let proposedEnd: Date
    /// How far a change to a recurring event reaches. `nil` until the user chose (`EventSaveResult.needsScope`); ignored for a single event.
    public let scope: RecurrenceScope?
    /// Keeps an end-only change from running past this instant (the timeline editor passes the selected day's end). `nil` for no limit.
    public let endLimit: Date?

    public init(original: EventSaveOriginal, proposedStart: Date, proposedEnd: Date, scope: RecurrenceScope? = nil, endLimit: Date? = nil) {
        self.original = original
        self.proposedStart = proposedStart
        self.proposedEnd = proposedEnd
        self.scope = scope
        self.endLimit = endLimit
    }

    /// The same request with the scope the user chose.
    public func scoped(_ scope: RecurrenceScope?) -> EventSaveRequest {
        EventSaveRequest(original: original, proposedStart: proposedStart, proposedEnd: proposedEnd, scope: scope, endLimit: endLimit)
    }

    /// Which existing command carries the change, from which edges moved.
    public enum Edit: Hashable, Sendable {
        case none
        /// Both edges by the same amount: `moveEvent` (duration kept, start snapped).
        case move
        /// Only the start: `resizeEvent(.start)`.
        case resizeStart
        /// Only the end: `resizeEvent(.end)`.
        case resizeEnd
        /// Both edges by different amounts: `editEvent` with the new time (validated, not snapped).
        case retime
    }

    var proposedStartMilliseconds: Int64 { EventSaveTime.milliseconds(proposedStart) }
    var proposedEndMilliseconds: Int64 { EventSaveTime.milliseconds(proposedEnd) }

    public var edit: Edit {
        let startDelta = proposedStartMilliseconds - original.startMilliseconds
        let endDelta = proposedEndMilliseconds - original.endMilliseconds
        switch (startDelta == 0, endDelta == 0) {
        case (true, true): return .none
        case (false, true): return .resizeStart
        case (true, false): return .resizeEnd
        case (false, false): return startDelta == endDelta ? .move : .retime
        }
    }

    /// Whether the change moves the event's start to another local day in `zone`. A series cannot take a date change.
    public func changesDate(in zone: DisplayTimeZone) -> Bool {
        zone.localDate(of: original.startMilliseconds) != zone.localDate(of: proposedStartMilliseconds)
    }

    /// The command the timeline editor would send for this change (`TimelineEditPlanner.command`), with the original revision as the expected one.
    /// `nil` when nothing changed or the proposal is not a range.
    public func command(scope: RecurrenceScope?) -> CalendarCommand? {
        let target = EventTarget(key: original.key, expectedRevisionToken: original.revisionToken)
        switch edit {
        case .none:
            return nil
        case .move:
            return .moveEvent(MoveEventInput(target: target, destination: .proposedStart(proposedStartMilliseconds), scope: scope))
        case .resizeStart:
            return .resizeEvent(ResizeEventInput(target: target, edge: .start, proposedInstant: proposedStartMilliseconds, scope: scope))
        case .resizeEnd:
            return .resizeEvent(ResizeEventInput(
                target: target, edge: .end, proposedInstant: proposedEndMilliseconds,
                clampToDayEnd: endLimit.map(EventSaveTime.milliseconds), scope: scope
            ))
        case .retime:
            guard let range = try? TimedRange(startUnixMilliseconds: proposedStartMilliseconds, endUnixMilliseconds: proposedEndMilliseconds) else { return nil }
            return .editEvent(EditEventInput(target: target, update: CalendarEventUpdate(time: .timed(range)), scope: scope))
        }
    }
}

/// What came of a save. `.saved` wrote; `.unchanged`, `.needsScope` and `.refused` wrote nothing; `.failed` says whether the original was
/// confirmed still in place (`originalVerified`).
public enum EventSaveResult: Equatable, Sendable {
    case saved(EventSaveReceipt)
    /// The proposal is the original: nothing to write.
    case unchanged(CalendarEvent)
    /// A recurring event needs a scope first. Save again with `request.scoped(one of these)`. Nothing was written.
    case needsScope([RecurrenceScope])
    /// Refused; trying the same request again cannot help.
    case refused(EventSaveRefusal)
    /// The calendar could not do it. See `EventSaveFailure.retry`.
    case failed(EventSaveFailure)
}

public enum EventSaveRefusal: Equatable, Sendable {
    /// The event no longer exists (deleted elsewhere, or its calendar went away).
    case targetGone
    /// The event is no longer the original (another revision, or another time). `current` is what the calendar holds now.
    case targetChanged(current: CalendarEvent)
    case notEditable
    /// The scope is not one offered for this change (`EventSavePipeline.scopeOptions`).
    case scopeNotOffered(RecurrenceScope, offered: [RecurrenceScope])
    /// The command service refused it before writing (too short, a date change for a whole series, ...).
    case invalid(CommandRejection)
}

public struct EventSaveFailure: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        /// Reading the event before the write failed. Nothing was written.
        case verifying
        /// The calendar refused or failed the write.
        case writing
    }

    public let stage: Stage
    public let failure: CalendarProviderFailure
    /// Whether the calendar was read again afterwards and still holds the original (revision and time). Always true when nothing was written.
    public let originalVerified: Bool
    /// The request to save again, when that can help: a retryable failure and the original still in place. `nil` otherwise.
    public let retry: EventSaveRequest?
}

/// A save that reached the calendar.
public struct EventSaveReceipt: Equatable, Sendable {
    /// The event as the calendar holds it now (for a whole-series change, the occurrence that was edited).
    public let event: CalendarEvent
    public let start: Date
    public let end: Date
    /// What it was before.
    public let original: EventSaveOriginal
    /// The scope used: `.thisOccurrence` for a single event.
    public let scope: RecurrenceScope
    /// The command that was sent.
    public let command: CalendarCommand
    /// Set when the event was saved but the local follow-up (the Activity's cached summary) was not (`partiallyApplied`). The event is correct.
    public let localFailure: CommandRejection?
    /// Whether the saved range is exactly the proposed one (the edit policy may snap or clamp it).
    public let matchesProposal: Bool
}

/// Runs `EventSaveRequest`s through the command service. Stateless: a retry is the same request saved again, and it is checked again first.
public struct EventSavePipeline: Sendable {
    public let supportedScopes: Set<RecurrenceScope>
    public let zone: DisplayTimeZone
    private let perform: @Sendable (CalendarCommand) async -> CalendarCommandOutcome
    private let read: @Sendable (CalendarEventKey) async throws -> CalendarEvent?

    public init(
        supportedScopes: Set<RecurrenceScope>,
        zone: DisplayTimeZone,
        perform: @escaping @Sendable (CalendarCommand) async -> CalendarCommandOutcome,
        read: @escaping @Sendable (CalendarEventKey) async throws -> CalendarEvent?
    ) {
        self.supportedScopes = supportedScopes
        self.zone = zone
        self.perform = perform
        self.read = read
    }

    /// Through `service` (writes) and the same provider it reads (`service.event`).
    public init(service: CalendarCommandService, supportedScopes: Set<RecurrenceScope>, zone: DisplayTimeZone) {
        self.init(
            supportedScopes: supportedScopes, zone: zone,
            perform: { await service.perform($0) }, read: { try await service.event($0) }
        )
    }

    /// The scopes the user may choose from for a change to a recurring event, as the timeline editor offers them (`TimelineEditPlanner.scopeOptions`):
    /// this occurrence, and the whole series unless the change moves it to another day. Never `thisAndFuture`, which re-identifies the future occurrences.
    public func scopeOptions(for request: EventSaveRequest) -> [RecurrenceScope] {
        var options: [RecurrenceScope] = []
        if supportedScopes.contains(.thisOccurrence) { options.append(.thisOccurrence) }
        if supportedScopes.contains(.allInSeries), !request.changesDate(in: zone) { options.append(.allInSeries) }
        return options
    }

    public func save(_ request: EventSaveRequest) async -> EventSaveResult {
        // 1. The event as the calendar holds it now must still be the original.
        let current: CalendarEvent
        switch await readNow(request.original.key) {
        case let .failure(failure):
            return .failed(EventSaveFailure(stage: .verifying, failure: failure, originalVerified: true, retry: Self.isRetryable(failure) ? request : nil))
        case .success(nil):
            return .refused(.targetGone)
        case let .success(event?):
            current = event
        }
        guard request.original.matches(current) else { return .refused(.targetChanged(current: current)) }
        guard current.isEditable else { return .refused(.notEditable) }

        // 2. What to send.
        guard request.edit != .none else { return .unchanged(current) }
        guard request.proposedStartMilliseconds < request.proposedEndMilliseconds else { return .refused(.invalid(.durationBelowMinimum)) }
        var scope: RecurrenceScope?
        if current.isRecurringInstance {
            let options = scopeOptions(for: request)
            guard let requested = request.scope else {
                return options.isEmpty ? .refused(.invalid(.recurrenceScopeRequired)) : .needsScope(options)
            }
            guard options.contains(requested) else { return .refused(.scopeNotOffered(requested, offered: options)) }
            scope = requested
        }
        guard let command = request.command(scope: scope) else { return .refused(.invalid(.durationBelowMinimum)) }

        // 3. The one write, through the existing path.
        switch await perform(command) {
        case let .applied(applied):
            return await receipt(applied.event, request: request, scope: scope, command: command, localFailure: nil)
        case let .partiallyApplied(applied, localFailure):
            return await receipt(applied.event, request: request, scope: scope, command: command, localFailure: localFailure)
        case let .conflict(current):
            if let current { return .refused(.targetChanged(current: current)) }
            return await afterFailure(.eventMissing, request: request)
        case let .rejected(rejection):
            switch rejection {
            case .eventNotFound: return .refused(.targetGone)
            case .eventNotEditable: return .refused(.notEditable)
            default: return .refused(.invalid(rejection))
            }
        case let .providerFailure(failure):
            return await afterFailure(failure, request: request)
        }
    }

    // MARK: Internals

    private func readNow(_ key: CalendarEventKey) async -> Result<CalendarEvent?, CalendarProviderFailure> {
        do {
            return .success(try await read(key))
        } catch let failure as CalendarProviderFailure {
            return .failure(failure)
        } catch {
            return .failure(.saveFailed(retryable: true, reason: "\(error)"))           // as `CalendarCommandService.loadEditableEvent` maps it
        }
    }

    /// After a failed write the calendar is read again: the event gone or changed is a refusal; the original still there is a failure that keeps it.
    private func afterFailure(_ failure: CalendarProviderFailure, request: EventSaveRequest) async -> EventSaveResult {
        switch await readNow(request.original.key) {
        case .success(nil):
            return .refused(.targetGone)
        case let .success(event?) where !request.original.matches(event):
            return .refused(.targetChanged(current: event))
        case .success:
            return .failed(EventSaveFailure(stage: .writing, failure: failure, originalVerified: true, retry: Self.isRetryable(failure) ? request : nil))
        case .failure:
            // Not known whether the original is intact, so saving again is not offered; a fresh read decides.
            return .failed(EventSaveFailure(stage: .writing, failure: failure, originalVerified: false, retry: nil))
        }
    }

    private func receipt(
        _ event: CalendarEvent?, request: EventSaveRequest, scope: RecurrenceScope?, command: CalendarCommand, localFailure: CommandRejection?
    ) async -> EventSaveResult {
        var saved = event
        if saved == nil, case let .success(read) = await readNow(request.original.key) { saved = read }
        guard let saved, case let .timed(range) = saved.time else {
            // Written, but not readable back as a timed event (as `EventKitCalendarProvider.savedResult` reports it). The caller reloads.
            return .failed(EventSaveFailure(
                stage: .writing, failure: .saveFailed(retryable: false, reason: "the saved event could not be read back"), originalVerified: false, retry: nil
            ))
        }
        return .saved(EventSaveReceipt(
            event: saved,
            start: EventSaveTime.date(range.startUnixMilliseconds),
            end: EventSaveTime.date(range.endUnixMilliseconds),
            original: request.original,
            scope: scope ?? .thisOccurrence,
            command: command,
            localFailure: localFailure,
            matchesProposal: range.startUnixMilliseconds == request.proposedStartMilliseconds && range.endUnixMilliseconds == request.proposedEndMilliseconds
        ))
    }

    /// The failures where trying again can help, as the timeline editor tells the user (`EditFeedback.canRetry`).
    static func isRetryable(_ failure: CalendarProviderFailure) -> Bool {
        if case let .saveFailed(retryable, _) = failure { return retryable }
        return false
    }
}

/// `Date` and the domain's unix milliseconds. A `Date` is rounded to the nearest millisecond.
public enum EventSaveTime {
    public static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }
    public static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }
}
