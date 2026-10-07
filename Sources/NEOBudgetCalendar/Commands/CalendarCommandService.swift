import NEOBudgetCore

public struct CalendarServiceConfiguration: Sendable {
    public let displayTimeZone: DisplayTimeZone
    public let editPolicy: TimelineEditPolicy
    public let assignmentPolicy: AssignmentPolicy
    public let displayPolicy: TimelineDisplayPolicy

    public init(
        displayTimeZone: DisplayTimeZone,
        editPolicy: TimelineEditPolicy = .standard,
        assignmentPolicy: AssignmentPolicy = AssignmentPolicy(),
        displayPolicy: TimelineDisplayPolicy = .standard
    ) {
        self.displayTimeZone = displayTimeZone
        self.editPolicy = editPolicy
        self.assignmentPolicy = assignmentPolicy
        self.displayPolicy = displayPolicy
    }
}

/// The single contract a UI or platform adapter talks to. It orchestrates a calendar provider (source of
/// truth for event fields), the local life store (source of truth for meaning), and a read-only transaction
/// source, and exposes commands in and read models out. It knows no platform type.
///
/// Write ordering follows one rule: the calendar provider is written first, then local state. A calendar
/// write that fails changes nothing locally. A local write that fails after a calendar write succeeded is
/// reported as `partiallyApplied`; the event is correct and the local part is retryable.
public actor CalendarCommandService {
    private let provider: any CalendarProvider
    private var repository: any LifeRepository
    private let transactions: any TransactionSource
    private let configuration: CalendarServiceConfiguration
    private let makeActivityID: @Sendable () -> ActivityID
    private let now: @Sendable () -> Int64

    public init(
        provider: any CalendarProvider,
        repository: any LifeRepository,
        transactions: any TransactionSource,
        configuration: CalendarServiceConfiguration,
        makeActivityID: @escaping @Sendable () -> ActivityID,
        now: @escaping @Sendable () -> Int64
    ) {
        self.provider = provider
        self.repository = repository
        self.transactions = transactions
        self.configuration = configuration
        self.makeActivityID = makeActivityID
        self.now = now
    }

    // MARK: Read models

    public func lifeSnapshot() throws -> LifeSnapshot { try repository.snapshot() }

    /// The timeline for one day. Fetches the day's events and transactions plus any transaction linked to an
    /// activity that can appear, so spending bought earlier still shows inside its activity.
    public func dayTimeline(for day: LocalDate, visibleCalendarIDs: Set<CalendarID>? = nil) async throws -> DayTimeline {
        let timeZone = configuration.displayTimeZone
        let bounds = timeZone.dayBounds(day)
        let events = try await provider.events(from: bounds.start, to: bounds.end, calendarIDs: visibleCalendarIDs)
        let calendars = try await provider.calendars()
        let life = try repository.snapshot().state

        let byEvent = life.activitiesByEvent()
        var relevantActivityIDs = Set(events.compactMap { byEvent[$0.key]?.id })
        for activity in life.activities.values where activity.isEventMissing { relevantActivityIDs.insert(activity.id) }
        let linkedIDs = Set(life.linksByTransaction.values.filter { relevantActivityIDs.contains($0.activityID) }.map(\.transactionID))

        var markers = Dictionary(
            transactions.transactions(occurringFrom: bounds.start, to: bounds.end).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for marker in transactions.transactions(withIDs: linkedIDs) { markers[marker.id] = marker }

        return DayTimelineBuilder.build(DayTimelineInput(
            day: day,
            timeZone: timeZone,
            calendars: calendars,
            events: events,
            life: life,
            transactions: Array(markers.values),
            policy: configuration.displayPolicy
        ))
    }

    public func weekStrip(containing day: LocalDate, firstWeekday: Int = 0, visibleCalendarIDs: Set<CalendarID>? = nil) async throws -> [WeekStripDay] {
        let timeZone = configuration.displayTimeZone
        let offset = ((day.weekday - firstWeekday) % 7 + 7) % 7
        let first = day.adding(days: -offset)
        let from = timeZone.startOfDay(first)
        let to = timeZone.startOfDay(first.adding(days: 7))
        let events = try await provider.events(from: from, to: to, calendarIDs: visibleCalendarIDs)
        return WeekStripBuilder.build(
            containing: day,
            firstWeekday: firstWeekday,
            timeZone: timeZone,
            events: events,
            life: try repository.snapshot().state,
            transactions: transactions.transactions(occurringFrom: from, to: to)
        )
    }

    /// Refreshes Activities from the provider for a window. Returns how many Activities changed.
    @discardableResult
    public func reconcile(from: Int64, to: Int64, calendarIDs: Set<CalendarID>? = nil) async throws -> Int {
        let events = try await provider.events(from: from, to: to, calendarIDs: calendarIDs)
        let life = try repository.snapshot().state
        let changes = CalendarReconciler.reconcile(
            life: life,
            fetched: events,
            window: (from, to),
            queriedCalendarIDs: calendarIDs,
            timeZone: configuration.displayTimeZone,
            now: now()
        )
        guard !changes.isEmpty else { return 0 }
        if case let .failure(rejection) = commit(changes) { throw ReconcileError.commitFailed(rejection) }
        return changes.count
    }

    public enum ReconcileError: Error, Equatable, Sendable {
        case commitFailed(CommandRejection)
    }

    // MARK: Commands

    public func perform(_ command: CalendarCommand) async -> CalendarCommandOutcome {
        switch command {
        case let .createEvent(input): return await createEvent(input)
        case let .moveEvent(input): return await moveEvent(input)
        case let .resizeEvent(input): return await resizeEvent(input)
        case let .changeAllDay(input): return await changeAllDay(input)
        case let .editEvent(input): return await editEvent(input)
        case let .deleteEvent(input): return await deleteEvent(input)
        case let .linkTransaction(input): return await linkTransaction(input)
        case let .unlinkTransaction(input): return unlinkTransaction(input)
        case let .assignActivityType(input): return await assignActivityType(input)
        case let .assignTag(input): return await assignTag(input, remove: false)
        case let .unassignTag(input): return await assignTag(input, remove: true)
        }
    }

    // MARK: Event commands

    private func createEvent(_ input: CreateEventInput) async -> CalendarCommandOutcome {
        if let identifier = input.draft.timeZoneIdentifier, (try? DisplayTimeZone(identifier: identifier)) == nil {
            return .rejected(.invalidTimeZone(identifier))
        }
        if case let .timed(range) = input.draft.time, range.durationMilliseconds < minimumDurationMilliseconds {
            return .rejected(.durationBelowMinimum)
        }
        let event: CalendarEvent
        switch await provider.createEvent(input.draft) {
        case let .success(created): event = created
        case let .conflict(current): return .conflict(current: current)
        case let .failure(failure): return .providerFailure(failure)
        }
        guard let typeID = input.initialActivityType else { return .applied(AppliedCommand(event: event)) }

        let activity = Activity.materialized(from: event, id: makeActivityID(), at: now())
        let provenance = AssignmentProvenance.user(at: now())
        let changes: [LifeChange] = [.createActivity(activity), .setActivityType(activity.id, Assigned(typeID, provenance: provenance))]
        switch commit(changes) {
        case let .success(revision):
            return .applied(AppliedCommand(event: event, activityID: activity.id, lifeRevision: revision))
        case let .failure(rejection):
            return .partiallyApplied(AppliedCommand(event: event), localFailure: rejection)
        }
    }

    private func moveEvent(_ input: MoveEventInput) async -> CalendarCommandOutcome {
        let event: CalendarEvent
        switch await loadEditableEvent(input.target) {
        case let .success(loaded): event = loaded
        case let .failure(outcome): return outcome
        }
        let timeZone = configuration.displayTimeZone
        let policy = configuration.editPolicy
        let newTime: EventTimeRange
        switch (event.time, input.destination) {
        case let (.timed(range), .proposedStart(start)):
            newTime = .timed(policy.move(range, toProposedStart: start, in: timeZone))
        case let (.timed(range), .day(day)):
            newTime = .timed(policy.move(range, toDay: day, in: timeZone))
        case let (.allDay(range), .day(day)):
            newTime = .allDay(policy.move(range, toFirstDay: day))
        case (.allDay, .proposedStart):
            return .rejected(.destinationKindMismatch)
        }
        return await writeTimeChange(event: event, target: input.target, newTime: newTime, requestedScope: input.scope)
    }

    private func resizeEvent(_ input: ResizeEventInput) async -> CalendarCommandOutcome {
        let event: CalendarEvent
        switch await loadEditableEvent(input.target) {
        case let .success(loaded): event = loaded
        case let .failure(outcome): return outcome
        }
        guard case let .timed(range) = event.time else { return .rejected(.allDayEventCannotResize) }
        let timeZone = configuration.displayTimeZone
        let edit: TimedEdit
        switch input.edge {
        case .start:
            edit = configuration.editPolicy.resizeStart(range, toProposedStart: input.proposedInstant, in: timeZone)
        case .end:
            edit = configuration.editPolicy.resizeEnd(
                range, toProposedEnd: input.proposedInstant, in: timeZone, clampingToDayEnd: input.clampToDayEnd
            )
        }
        return await writeTimeChange(event: event, target: input.target, newTime: .timed(edit.range), requestedScope: input.scope)
    }

    private func changeAllDay(_ input: ChangeAllDayInput) async -> CalendarCommandOutcome {
        let event: CalendarEvent
        switch await loadEditableEvent(input.target) {
        case let .success(loaded): event = loaded
        case let .failure(outcome): return outcome
        }
        let timeZone = configuration.displayTimeZone
        let newTime: EventTimeRange
        switch (event.time, input.toAllDay) {
        case let (.timed(range), true):
            newTime = .allDay(configuration.editPolicy.timedToAllDay(range, in: timeZone))
        case (.allDay, false):
            guard let start = input.proposedStart else { return .rejected(.missingProposedStart) }
            newTime = .timed(configuration.editPolicy.allDayToTimed(atProposedStart: start, in: timeZone))
        default:
            return .applied(AppliedCommand(event: event, activityID: existingActivityID(for: event.key)))
        }
        return await writeTimeChange(event: event, target: input.target, newTime: newTime, requestedScope: input.scope)
    }

    private func editEvent(_ input: EditEventInput) async -> CalendarCommandOutcome {
        guard !input.update.isEmpty else { return .rejected(.emptyUpdate) }
        if case let .set(identifier) = input.update.timeZoneIdentifier, (try? DisplayTimeZone(identifier: identifier)) == nil {
            return .rejected(.invalidTimeZone(identifier))
        }
        if case let .timed(range)? = input.update.time, range.durationMilliseconds < minimumDurationMilliseconds {
            return .rejected(.durationBelowMinimum)
        }
        let event: CalendarEvent
        switch await loadEditableEvent(input.target) {
        case let .success(loaded): event = loaded
        case let .failure(outcome): return outcome
        }
        let scope: RecurrenceScope
        switch resolveScope(event: event, requested: input.scope, changesDate: changesDate(from: event.time, to: input.update.time)) {
        case let .success(resolved): scope = resolved
        case let .failure(rejection): return .rejected(rejection)
        }
        return await write(event: event, target: input.target, update: input.update, scope: scope)
    }

    private func deleteEvent(_ input: DeleteEventInput) async -> CalendarCommandOutcome {
        let event: CalendarEvent
        switch await loadEditableEvent(input.target) {
        case let .success(loaded): event = loaded
        case let .failure(outcome): return outcome
        }
        let scope: RecurrenceScope
        switch resolveScope(event: event, requested: input.scope, changesDate: false) {
        case let .success(resolved): scope = resolved
        case let .failure(rejection): return .rejected(rejection)
        }
        switch await provider.deleteEvent(input.target.key, scope: scope, expectedRevision: input.target.expectedRevisionToken ?? event.revisionToken) {
        case .success: break
        case let .conflict(current): return .conflict(current: current)
        case let .failure(failure): return .providerFailure(failure)
        }

        guard let state = try? repository.snapshot().state, let activity = state.activity(forEvent: event.key), let association = activity.association else {
            return .applied(AppliedCommand())
        }
        var changes: [LifeChange] = []
        switch input.linkDisposition {
        case .keepLinks:
            changes.append(.updateAssociation(activity.id, association.markedMissing(at: now())))
        case .removeLinks:
            let by = AssignmentProvenance.user(at: now())
            for link in state.links(forActivity: activity.id) { changes.append(.removeLink(link.transactionID, by: by)) }
            changes.append(activity.carriesNoMeaning ? .removeActivity(activity.id) : .updateAssociation(activity.id, association.markedMissing(at: now())))
        }
        switch commit(changes) {
        case let .success(revision):
            return .applied(AppliedCommand(activityID: activity.id, lifeRevision: revision))
        case let .failure(rejection):
            return .partiallyApplied(AppliedCommand(activityID: activity.id), localFailure: rejection)
        }
    }

    // MARK: Meaning commands

    private func linkTransaction(_ input: LinkTransactionInput) async -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        guard transactions.transaction(input.transactionID) != nil else { return .rejected(.transactionNotFound) }
        let resolved: ResolvedActivity
        switch await resolveActivity(input.target) {
        case let .success(value): resolved = value
        case let .failure(outcome): return outcome
        }
        if resolved.isEventMissing { return .rejected(.activityEventMissing) }

        // Re-linking to the same activity is a no-op, unless a user decision replaces an automated one.
        if let state = try? repository.snapshot().state,
           let existing = state.link(for: input.transactionID),
           existing.activityID == resolved.id,
           !(existing.provenance.source == .automated && input.provenance.source == .user) {
            return .applied(AppliedCommand(activityID: resolved.id))
        }
        // No time-containment check on purpose: a link is meaning, not a time window.
        let link = TransactionActivityLink(
            transactionID: input.transactionID,
            activityID: resolved.id,
            createdAtUnixMilliseconds: now(),
            provenance: input.provenance
        )
        return applyLocal(resolved.creation + [.setLink(link)], activityID: resolved.id)
    }

    private func unlinkTransaction(_ input: UnlinkTransactionInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.by) else { return .rejected(.provenanceRejected) }
        return applyLocal([.removeLink(input.transactionID, by: input.by)], activityID: nil)
    }

    private func assignActivityType(_ input: AssignActivityTypeInput) async -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        guard let typeID = input.typeID else {
            // Clearing never creates an Activity just to clear nothing.
            guard let resolved = await existingActivity(input.target) else { return .applied(AppliedCommand()) }
            return applyLocal([.clearActivityType(resolved, by: input.provenance)], activityID: resolved)
        }
        let resolved: ResolvedActivity
        switch await resolveActivity(input.target) {
        case let .success(value): resolved = value
        case let .failure(outcome): return outcome
        }
        return applyLocal(
            resolved.creation + [.setActivityType(resolved.id, Assigned(typeID, provenance: input.provenance))],
            activityID: resolved.id
        )
    }

    private func assignTag(_ input: AssignTagInput, remove: Bool) async -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        switch input.target {
        case let .transaction(transactionID):
            guard transactions.transaction(transactionID) != nil else { return .rejected(.transactionNotFound) }
            let change: LifeChange = remove
                ? .removeTransactionTag(transactionID, input.tagID, by: input.provenance)
                : .setTransactionTag(transactionID, TagAssignment(tagID: input.tagID, provenance: input.provenance))
            return applyLocal([change], activityID: nil)
        case let .activity(target):
            if remove {
                guard let id = await existingActivity(target) else { return .applied(AppliedCommand()) }
                return applyLocal([.removeActivityTag(id, input.tagID, by: input.provenance)], activityID: id)
            }
            let resolved: ResolvedActivity
            switch await resolveActivity(target) {
            case let .success(value): resolved = value
            case let .failure(outcome): return outcome
            }
            return applyLocal(
                resolved.creation + [.setActivityTag(resolved.id, TagAssignment(tagID: input.tagID, provenance: input.provenance))],
                activityID: resolved.id
            )
        }
    }

    // MARK: Shared helpers

    /// A step that either yields a value or ends the command with a final outcome.
    private enum Gate<Value> {
        case success(Value)
        case failure(CalendarCommandOutcome)
    }

    private var minimumDurationMilliseconds: Int64 { Int64(configuration.editPolicy.minimumDurationMinutes) * 60_000 }

    private func loadEditableEvent(_ target: EventTarget) async -> Gate<CalendarEvent> {
        let event: CalendarEvent?
        do {
            event = try await provider.event(target.key)
        } catch let failure as CalendarProviderFailure {
            return .failure(.providerFailure(failure))
        } catch {
            return .failure(.providerFailure(.saveFailed(retryable: true, reason: "\(error)")))
        }
        guard let event else { return .failure(.rejected(.eventNotFound)) }
        guard event.isEditable else { return .failure(.rejected(.eventNotEditable)) }
        if let expected = target.expectedRevisionToken, expected != event.revisionToken {
            return .failure(.conflict(current: event))
        }
        return .success(event)
    }

    /// Decides which recurrence scope a change uses. Non-recurring events always use `thisOccurrence`.
    private func resolveScope(event: CalendarEvent, requested: RecurrenceScope?, changesDate: Bool) -> Result<RecurrenceScope, CommandRejection> {
        guard event.isRecurringInstance else { return .success(.thisOccurrence) }
        guard let requested else { return .failure(.recurrenceScopeRequired) }
        guard provider.supportedRecurrenceScopes.contains(requested) else { return .failure(.recurrenceScopeUnsupported(requested)) }
        if changesDate && requested != .thisOccurrence { return .failure(.dateChangeRequiresThisOccurrence) }
        return .success(requested)
    }

    private func changesDate(from old: EventTimeRange, to new: EventTimeRange?) -> Bool {
        guard let new else { return false }
        let timeZone = configuration.displayTimeZone
        switch (old, new) {
        case let (.timed(before), .timed(after)):
            return timeZone.localDate(of: before.startUnixMilliseconds) != timeZone.localDate(of: after.startUnixMilliseconds)
        case let (.allDay(before), .allDay(after)):
            return before.firstDay != after.firstDay
        default:
            return false
        }
    }

    private func writeTimeChange(
        event: CalendarEvent,
        target: EventTarget,
        newTime: EventTimeRange,
        requestedScope: RecurrenceScope?
    ) async -> CalendarCommandOutcome {
        if newTime == event.time {
            return .applied(AppliedCommand(event: event, activityID: existingActivityID(for: event.key)))
        }
        let scope: RecurrenceScope
        switch resolveScope(event: event, requested: requestedScope, changesDate: changesDate(from: event.time, to: newTime)) {
        case let .success(resolved): scope = resolved
        case let .failure(rejection): return .rejected(rejection)
        }
        return await write(event: event, target: target, update: CalendarEventUpdate(time: newTime), scope: scope)
    }

    private func write(event: CalendarEvent, target: EventTarget, update: CalendarEventUpdate, scope: RecurrenceScope) async -> CalendarCommandOutcome {
        let updated: CalendarEvent
        switch await provider.updateEvent(
            target.key, update: update, scope: scope, expectedRevision: target.expectedRevisionToken ?? event.revisionToken
        ) {
        case let .success(value): updated = value
        case let .conflict(current): return .conflict(current: current)
        case let .failure(failure): return .providerFailure(failure)
        }
        // Keep the Activity's last-known summary current. It is a cache: if this fails, a later reconcile fixes it.
        var activityID: ActivityID?
        var revision: UInt64?
        if let state = try? repository.snapshot().state,
           let activity = state.activity(forEvent: updated.key),
           let association = activity.association {
            activityID = activity.id
            if case let .success(value) = commit([.updateAssociation(activity.id, association.refreshed(from: updated))]) { revision = value }
        }
        return .applied(AppliedCommand(event: updated, activityID: activityID, lifeRevision: revision))
    }

    private func existingActivityID(for key: CalendarEventKey) -> ActivityID? {
        (try? repository.snapshot().state)?.activity(forEvent: key)?.id
    }

    private struct ResolvedActivity {
        let id: ActivityID
        let isEventMissing: Bool
        /// Changes that create the Activity when it did not exist yet (empty otherwise).
        let creation: [LifeChange]
    }

    private func resolveActivity(_ target: ActivityTarget) async -> Gate<ResolvedActivity> {
        guard let state = try? repository.snapshot().state else { return .failure(.rejected(.storageUnavailable)) }
        switch target {
        case let .activity(id):
            guard let activity = state.activities[id] else { return .failure(.rejected(.activityNotFound)) }
            return .success(ResolvedActivity(id: id, isEventMissing: activity.isEventMissing, creation: []))
        case let .event(key):
            if let activity = state.activity(forEvent: key) {
                return .success(ResolvedActivity(id: activity.id, isEventMissing: activity.isEventMissing, creation: []))
            }
            let event: CalendarEvent?
            do {
                event = try await provider.event(key)
            } catch let failure as CalendarProviderFailure {
                return .failure(.providerFailure(failure))
            } catch {
                return .failure(.providerFailure(.saveFailed(retryable: true, reason: "\(error)")))
            }
            guard let event else { return .failure(.rejected(.eventNotFound)) }
            let activity = Activity.materialized(from: event, id: makeActivityID(), at: now())
            return .success(ResolvedActivity(id: activity.id, isEventMissing: false, creation: [.createActivity(activity)]))
        }
    }

    private func existingActivity(_ target: ActivityTarget) async -> ActivityID? {
        guard let state = try? repository.snapshot().state else { return nil }
        switch target {
        case let .activity(id): return state.activities[id] == nil ? nil : id
        case let .event(key): return state.activity(forEvent: key)?.id
        }
    }

    private func applyLocal(_ changes: [LifeChange], activityID: ActivityID?) -> CalendarCommandOutcome {
        switch commit(changes) {
        case let .success(revision): return .applied(AppliedCommand(activityID: activityID, lifeRevision: revision))
        case let .failure(rejection): return .rejected(rejection)
        }
    }

    /// Commits to the local store, retrying once if the revision moved underneath this call.
    private func commit(_ changes: [LifeChange]) -> Result<UInt64, CommandRejection> {
        for _ in 0..<2 {
            do {
                let snapshot = try repository.snapshot()
                switch try repository.commit(changes, expectedRevision: snapshot.revision) {
                case let .committed(revision): return .success(revision)
                }
            } catch LifeStorageError.staleRevision {
                continue
            } catch LifeStorageError.invalid(.userAssignmentProtected) {
                return .failure(.userAssignmentProtected)
            } catch let LifeStorageError.invalid(error) {
                return .failure(.lifeValidation(error))
            } catch {
                return .failure(.storageUnavailable)
            }
        }
        return .failure(.storageUnavailable)
    }
}
