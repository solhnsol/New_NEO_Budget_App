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
    private let makeID: @Sendable (IDKind) -> String
    private let now: @Sendable () -> Int64

    public init(
        provider: any CalendarProvider,
        repository: any LifeRepository,
        transactions: any TransactionSource,
        configuration: CalendarServiceConfiguration,
        makeID: @escaping @Sendable (IDKind) -> String,
        now: @escaping @Sendable () -> Int64
    ) {
        self.provider = provider
        self.repository = repository
        self.transactions = transactions
        self.configuration = configuration
        self.makeID = makeID
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
        let linkedIDs = Set(life.allocationSets.values.filter { set in
            set.allocations.contains { $0.activityID.map(relevantActivityIDs.contains) ?? false }
        }.compactMap { $0.allocations.first?.transactionID })

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

    /// Explains an actual transfer with the counterparty's open obligations (a read; nothing is recorded).
    public func matchSettlement(_ transfer: ActualTransfer, requestID: SettlementRequestID? = nil) throws -> SettlementMatchResult {
        SettlementMatcher.match(transfer, in: try repository.snapshot().state, requestID: requestID)
    }

    /// Explains the effective transfer of a user-made correction group. `nil` when the group does not exist or
    /// its transfers cancel out (nothing is left to settle).
    public func matchEffectiveTransfer(of groupID: CorrectionGroupID, requestID: SettlementRequestID? = nil) throws -> SettlementMatchResult? {
        let state = try repository.snapshot().state
        guard let transfer = state.correctionGroups[groupID]?.effectiveTransfer else { return nil }
        return SettlementMatcher.match(transfer, in: state, requestID: requestID)
    }

    /// What a component asks of me, computed but not recorded.
    public func previewObligations(forComponent id: ExpenseComponentID) throws -> ObligationDerivation {
        try repository.snapshot().state.deriveObligations(forComponent: id)
    }

    /// Spending split by budget nature, and by how well its category is known (read-only).
    public func spendingBreakdown(flow: TransactionFlow = .spend) throws -> (nature: [NatureBreakdown], category: [CategoryStateBreakdown]) {
        let items = SpendingAnalytics.items(in: try repository.snapshot().state, flow: flow)
        return (SpendingAnalytics.byNature(items), SpendingAnalytics.byCategoryState(items))
    }

    /// Unexplained settlement differences, kept out of spending (read-only).
    public func residualSummary() throws -> [ResidualSummary] {
        try repository.snapshot().state.residualSummary()
    }

    /// People most likely to join an activity, given who is already on it.
    public func recommendParticipants(given chosen: [PersonID], limit: Int = 5) throws -> [ParticipantRecommendation] {
        ParticipantAffinityCalculator.recommend(given: chosen, in: try repository.snapshot().state, now: now(), limit: limit)
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
        case let .setAllocations(input): return await setAllocations(input)
        case let .upsertPerson(person): return applyLocal([.upsertPerson(person)], activityID: nil)
        case let .addParticipant(input): return await participant(input, remove: false)
        case let .removeParticipant(input): return await participant(input, remove: true)
        case let .createObligation(input): return await createObligation(input)
        case let .setObligationAmount(input): return setObligationAmount(input)
        case let .cancelObligation(input): return cancelObligation(input)
        case let .defineAmountGroup(input): return defineAmountGroup(input)
        case let .removeAmountGroup(input): return removeAmountGroup(input)
        case let .resolveAmountGroup(id): return resolveAmountGroup(id)
        case let .createSettlementRequest(input): return createSettlementRequest(input)
        case let .applySettlement(input): return applySettlement(input)
        case let .recordManualSettlement(input): return recordManualSettlement(input)
        case let .removeSettlement(input): return removeSettlement(input)
        case let .createCorrection(input): return createCorrection(input)
        case let .removeCorrection(input): return removeCorrection(input)
        case let .classifyResidual(input): return classifyResidual(input)
        case let .setSettlementPolicy(input): return setSettlementPolicy(input)
        case let .upsertExpenseComponent(input): return await upsertExpenseComponent(input)
        case let .removeExpenseComponent(input): return removeExpenseComponent(input)
        case let .generateObligations(input): return generateObligations(input)
        case let .setSpendingNature(input): return setSpendingNature(input)
        case let .setCategory(input): return setCategory(input)
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

        let activity = Activity.materialized(from: event, id: ActivityID(rawValue: makeID(.activity)), at: now())
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
            for allocation in state.allocations(forActivity: activity.id) { changes.append(.removeAllocation(allocation.id, by: by)) }
            let removable = activity.carriesNoMeaning && state.obligations(forActivity: activity.id).isEmpty
            changes.append(removable ? .removeActivity(activity.id) : .updateAssociation(activity.id, association.markedMissing(at: now())))
        }
        switch commit(changes) {
        case let .success(revision):
            return .applied(AppliedCommand(activityID: activity.id, lifeRevision: revision))
        case let .failure(rejection):
            return .partiallyApplied(AppliedCommand(activityID: activity.id), localFailure: rejection)
        }
    }

    // MARK: Meaning commands

    /// Assigns the whole transaction to one activity (replacing any other division). A convenience over
    /// `setAllocations`.
    private func linkTransaction(_ input: LinkTransactionInput) async -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        guard let marker = transactions.transaction(input.transactionID) else { return .rejected(.transactionNotFound) }
        return await setAllocations(SetAllocationsInput(
            transactionID: input.transactionID,
            parts: [AllocationPartInput(target: .activity(input.target), amount: .exact(marker.amount.minorUnits))],
            provenance: input.provenance
        ))
    }

    /// Removes every allocation of the transaction, returning it to unallocated.
    private func unlinkTransaction(_ input: UnlinkTransactionInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.by) else { return .rejected(.provenanceRejected) }
        guard let state = try? repository.snapshot().state else { return .rejected(.storageUnavailable) }
        let existing = state.allocationSet(for: input.transactionID)?.allocations ?? []
        guard !existing.isEmpty else { return .applied(AppliedCommand()) }
        return applyLocal(existing.map { .removeAllocation($0.id, by: input.by) }, activityID: nil)
    }

    /// Divides a transaction among activities (or deliberately none). The ledger entry is never touched, the
    /// transaction need not lie inside any activity's time range, and the portions may cover only part of it.
    private func setAllocations(_ input: SetAllocationsInput) async -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        guard let marker = transactions.transaction(input.transactionID) else { return .rejected(.transactionNotFound) }
        guard let state = try? repository.snapshot().state else { return .rejected(.storageUnavailable) }
        let existing = state.allocationSet(for: input.transactionID)?.allocations ?? []

        var creation: [LifeChange] = []
        var desired: [(activityID: ActivityID?, knowledge: AmountKnowledge)] = []
        // The same event named twice in one command resolves to one activity, created at most once.
        var resolvedByEvent: [CalendarEventKey: ResolvedActivity] = [:]
        for part in input.parts {
            switch part.target {
            case .nonActivity:
                desired.append((nil, part.amount))
            case let .activity(target):
                var resolved: ResolvedActivity
                if case let .event(key) = target, let known = resolvedByEvent[key] {
                    resolved = ResolvedActivity(id: known.id, isEventMissing: known.isEventMissing, creation: [])
                } else {
                    switch await resolveActivity(target) {
                    case let .success(value): resolved = value
                    case let .failure(outcome): return outcome
                    }
                    if case let .event(key) = target { resolvedByEvent[key] = resolved }
                }
                // A new portion cannot go to an activity whose event is gone; an existing one may stay.
                if resolved.isEventMissing, !existing.contains(where: { $0.activityID == resolved.id }) {
                    return .rejected(.activityEventMissing)
                }
                creation += resolved.creation
                desired.append((resolved.id, part.amount))
            }
        }

        var changes = creation
        // Removals first, so that replacing a division can never momentarily exceed the transaction.
        for old in existing where !desired.contains(where: { $0.activityID == old.activityID }) {
            changes.append(.removeAllocation(old.id, by: input.provenance))
        }
        var touched: [AllocationID] = []
        for item in desired {
            let entry: AmountEntry
            do {
                entry = try AmountEntry(currency: marker.amount.currency, knowledge: item.knowledge, provenance: input.provenance)
            } catch let error as AmountValidationError {
                return .rejected(.invalidAmount(error))
            } catch {
                return .rejected(.storageUnavailable)
            }
            if let old = existing.first(where: { $0.activityID == item.activityID }) {
                touched.append(old.id)
                // Asking for what is already there changes nothing, unless a user decision confirms an automated one.
                let upgrade = old.provenance.source == .automated && input.provenance.source == .user
                if old.amount.knowledge == item.knowledge && !upgrade { continue }
                changes.append(.upsertAllocation(
                    TransactionAllocation(
                        id: old.id, transactionID: old.transactionID, activityID: old.activityID, amount: entry,
                        provenance: input.provenance, createdAtUnixMilliseconds: old.createdAtUnixMilliseconds
                    ),
                    transactionTotal: marker.amount, flow: marker.flow
                ))
            } else {
                let id = AllocationID(rawValue: makeID(.allocation))
                touched.append(id)
                changes.append(.upsertAllocation(
                    TransactionAllocation(
                        id: id, transactionID: input.transactionID, activityID: item.activityID, amount: entry,
                        provenance: input.provenance, createdAtUnixMilliseconds: now()
                    ),
                    transactionTotal: marker.amount, flow: marker.flow
                ))
            }
        }
        let primary = desired.compactMap(\.activityID).first
        guard !changes.isEmpty else { return .applied(AppliedCommand(activityID: primary, allocationIDs: touched)) }
        return applyLocal(changes, activityID: primary, allocationIDs: touched)
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

    // MARK: People

    private func participant(_ input: ParticipantInput, remove: Bool) async -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        if remove {
            guard let id = await existingActivity(input.activity) else { return .applied(AppliedCommand()) }
            return applyLocal([.removeParticipant(id, input.personID, by: input.provenance)], activityID: id)
        }
        let resolved: ResolvedActivity
        switch await resolveActivity(input.activity) {
        case let .success(value): resolved = value
        case let .failure(outcome): return outcome
        }
        return applyLocal(
            resolved.creation + [.addParticipant(resolved.id, ParticipantAssignment(personID: input.personID, provenance: input.provenance))],
            activityID: resolved.id
        )
    }

    // MARK: Obligations and amounts

    private func createObligation(_ input: CreateObligationInput) async -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        let entry: AmountEntry
        do {
            entry = try AmountEntry(currency: input.currency, knowledge: input.amount, provenance: input.provenance)
        } catch let error as AmountValidationError {
            return .rejected(.invalidAmount(error))
        } catch {
            return .rejected(.storageUnavailable)
        }
        var creation: [LifeChange] = []
        var activityID: ActivityID?
        if let target = input.activity {
            switch await resolveActivity(target) {
            case let .success(resolved):
                creation = resolved.creation
                activityID = resolved.id
            case let .failure(outcome):
                return outcome
            }
        }
        let id = ObligationID(rawValue: makeID(.obligation))
        let obligation = Obligation(
            id: id, counterpartyID: input.counterpartyID, activityID: activityID, direction: input.direction, amount: entry,
            provenance: input.provenance, createdAtUnixMilliseconds: now(),
            originTransactionID: input.originTransactionID, label: input.label
        )
        return applyLocal(creation + [.createObligation(obligation)], activityID: activityID, obligationID: id)
    }

    private func setObligationAmount(_ input: SetObligationAmountInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        guard let obligation = (try? repository.snapshot().state)?.obligations[input.obligationID] else {
            return .rejected(.lifeValidation(.unknownObligation(input.obligationID)))
        }
        let entry: AmountEntry
        do {
            entry = try AmountEntry(currency: obligation.currency, knowledge: input.amount, provenance: input.provenance)
        } catch let error as AmountValidationError {
            return .rejected(.invalidAmount(error))
        } catch {
            return .rejected(.storageUnavailable)
        }
        return applyLocal([.setObligationAmount(input.obligationID, entry)], activityID: nil, obligationID: input.obligationID)
    }

    private func cancelObligation(_ input: CancelObligationInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.by) else { return .rejected(.provenanceRejected) }
        return applyLocal([.cancelObligation(input.obligationID, by: input.by)], activityID: nil, obligationID: input.obligationID)
    }

    private func defineAmountGroup(_ input: DefineAmountGroupInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        do {
            let total = try AmountEntry(currency: input.currency, knowledge: input.total, provenance: input.provenance)
            let id = AmountGroupID(rawValue: makeID(.amountGroup))
            let group = try AmountGroup(id: id, total: total, members: input.members, createdAtUnixMilliseconds: now())
            return applyLocal([.defineAmountGroup(group)], activityID: nil, amountGroupID: id)
        } catch let error as AmountValidationError {
            return .rejected(.invalidAmount(error))
        } catch let error as AmountGroupError {
            return .rejected(.invalidAmountGroup(error))
        } catch {
            return .rejected(.storageUnavailable)
        }
    }

    private func removeAmountGroup(_ input: RemoveAmountGroupInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.by) else { return .rejected(.provenanceRejected) }
        return applyLocal([.removeAmountGroup(input.groupID, by: input.by)], activityID: nil, amountGroupID: input.groupID)
    }

    /// Promotes a group's last unresolved member to `inferred` when the constraint forces exactly one value.
    /// With several unresolved members nothing is chosen: the constraint stays and the caller is told.
    private func resolveAmountGroup(_ id: AmountGroupID) -> CalendarCommandOutcome {
        guard let state = try? repository.snapshot().state else { return .rejected(.storageUnavailable) }
        guard let group = state.amountGroups[id], let analysis = state.analysis(ofGroup: id) else {
            return .rejected(.lifeValidation(.unknownAmountGroup(id)))
        }
        switch analysis {
        case .satisfied:
            return .applied(AppliedCommand(amountGroupID: id))
        case .underdetermined:
            return .rejected(.amountGroupNotUniquelySolvable)
        case let .contradiction(reason):
            return .rejected(.lifeValidation(.amountGroupContradiction(id, reason)))
        case let .uniqueSolution(member, minorUnits):
            let evidence = InferenceEvidence(
                amountGroupID: id,
                summary: "The group total leaves exactly this amount for the only unresolved member."
            )
            do {
                let entry = try AmountEntry(
                    currency: group.currency,
                    knowledge: .inferred(minorUnits, evidence),
                    provenance: .automated(origin: "amount-group-solver", confidence: 1.0, at: now())
                )
                let change: LifeChange
                switch member {
                case let .obligation(obligationID): change = .setObligationAmount(obligationID, entry)
                case let .allocation(allocationID): change = .setAllocationAmount(allocationID, entry)
                }
                return applyLocal([change], activityID: nil, amountGroupID: id)
            } catch {
                return .rejected(.storageUnavailable)
            }
        }
    }

    // MARK: Settlement

    private func createSettlementRequest(_ input: CreateSettlementRequestInput) -> CalendarCommandOutcome {
        do {
            let id = SettlementRequestID(rawValue: makeID(.settlementRequest))
            let request = try SettlementRequest(
                id: id, counterpartyID: input.counterpartyID, obligationIDs: input.obligationIDs,
                requestedAmount: input.requestedAmount, createdAtUnixMilliseconds: now()
            )
            return applyLocal([.createSettlementRequest(request)], activityID: nil, settlementRequestID: id)
        } catch let error as SettlementValidationError {
            return .rejected(.invalidSettlement(error))
        } catch {
            return .rejected(.storageUnavailable)
        }
    }

    private func applySettlement(_ input: ApplySettlementInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        guard let state = try? repository.snapshot().state else { return .rejected(.storageUnavailable) }
        do {
            let id = SettlementID(rawValue: makeID(.settlement))
            let settlement = try input.proposal.makeSettlement(
                id: id, life: state, provenance: input.provenance, createdAtUnixMilliseconds: now()
            )
            return applyLocal([.recordSettlement(settlement)], activityID: nil, settlementID: id)
        } catch let error as SettlementValidationError {
            return .rejected(.invalidSettlement(error))
        } catch let error as AmountValidationError {
            return .rejected(.invalidAmount(error))
        } catch {
            return .rejected(.storageUnavailable)
        }
    }

    private func recordManualSettlement(_ input: ManualSettlementInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        guard let state = try? repository.snapshot().state else { return .rejected(.storageUnavailable) }
        do {
            var promotions: [AppliedPromotion] = []
            for (obligationID, minorUnits) in input.confirmedAmounts.sorted(by: { $0.key < $1.key }) {
                guard let obligation = state.obligations[obligationID] else {
                    return .rejected(.lifeValidation(.unknownObligation(obligationID)))
                }
                let applied = try AmountEntry(
                    currency: obligation.currency, knowledge: .exact(minorUnits), provenance: input.provenance
                )
                promotions.append(AppliedPromotion(obligationID: obligationID, previous: obligation.amount, applied: applied))
            }
            let id = SettlementID(rawValue: makeID(.settlement))
            let settlement = try Settlement(
                id: id,
                transfer: input.transfer,
                allocations: input.applications.map { try SettlementAllocation(obligationID: $0.obligationID, appliedMinorUnits: $0.appliedMinorUnits) },
                promotions: promotions,
                requestID: input.requestID,
                provenance: input.provenance,
                createdAtUnixMilliseconds: now()
            )
            return applyLocal([.recordSettlement(settlement)], activityID: nil, settlementID: id)
        } catch let error as SettlementValidationError {
            return .rejected(.invalidSettlement(error))
        } catch let error as AmountValidationError {
            return .rejected(.invalidAmount(error))
        } catch {
            return .rejected(.storageUnavailable)
        }
    }

    private func removeSettlement(_ input: RemoveSettlementInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.by) else { return .rejected(.provenanceRejected) }
        return applyLocal([.removeSettlement(input.settlementID, by: input.by)], activityID: nil, settlementID: input.settlementID)
    }

    // MARK: Corrections, residuals, policies, components, nature

    private func createCorrection(_ input: CreateCorrectionInput) -> CalendarCommandOutcome {
        do {
            let id = CorrectionGroupID(rawValue: makeID(.correctionGroup))
            let group = try TransactionCorrectionGroup(
                id: id, sources: input.sources, provenance: input.provenance, createdAtUnixMilliseconds: now()
            )
            return applyLocal([.createCorrectionGroup(group)], activityID: nil, correctionGroupID: id)
        } catch let error as CorrectionError {
            return .rejected(.invalidCorrection(error))
        } catch {
            return .rejected(.storageUnavailable)
        }
    }

    private func removeCorrection(_ input: RemoveCorrectionInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.by) else { return .rejected(.provenanceRejected) }
        return applyLocal([.removeCorrectionGroup(input.groupID, by: input.by)], activityID: nil, correctionGroupID: input.groupID)
    }

    private func classifyResidual(_ input: ClassifyResidualInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        return applyLocal([.classifyResidual(input.residualID, input.classification, by: input.provenance)], activityID: nil)
    }

    private func setSettlementPolicy(_ input: SetSettlementPolicyInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        if let policy = input.policy {
            return applyLocal([.setSettlementPolicy(input.target, Assigned(policy, provenance: input.provenance))], activityID: nil)
        }
        return applyLocal([.clearSettlementPolicy(input.target, by: input.provenance)], activityID: nil)
    }

    private func upsertExpenseComponent(_ input: UpsertExpenseComponentInput) async -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        if let provenance = input.category.provenance, !configuration.assignmentPolicy.accepts(provenance) {
            return .rejected(.provenanceRejected)
        }
        let entry: AmountEntry
        do {
            entry = try AmountEntry(currency: input.currency, knowledge: input.amount, provenance: input.provenance)
        } catch let error as AmountValidationError {
            return .rejected(.invalidAmount(error))
        } catch {
            return .rejected(.storageUnavailable)
        }
        let resolved: ResolvedActivity
        switch await resolveActivity(input.activity) {
        case let .success(value): resolved = value
        case let .failure(outcome): return outcome
        }
        let id = input.componentID ?? ExpenseComponentID(rawValue: makeID(.expenseComponent))
        let existing = (try? repository.snapshot().state)?.components[id]
        let component = ExpenseComponent(
            id: id, activityID: resolved.id, label: input.label, amount: entry, payerID: input.payerID,
            participants: input.participants, excludedParticipants: input.excludedParticipants, policy: input.policy,
            category: input.category, originTransactionID: input.originTransactionID, provenance: input.provenance,
            createdAtUnixMilliseconds: existing?.createdAtUnixMilliseconds ?? now()
        )
        return applyLocal(resolved.creation + [.upsertExpenseComponent(component)], activityID: resolved.id, componentID: id)
    }

    private func removeExpenseComponent(_ input: RemoveExpenseComponentInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.by) else { return .rejected(.provenanceRejected) }
        return applyLocal([.removeExpenseComponent(input.componentID, by: input.by)], activityID: nil, componentID: input.componentID)
    }

    /// Creates my obligations from a component's computed shares. Nothing is created from an amount that is
    /// not settled, and nothing is created twice for the same counterparty.
    private func generateObligations(_ input: GenerateObligationsInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        guard let state = try? repository.snapshot().state else { return .rejected(.storageUnavailable) }
        let derivation: ObligationDerivation
        do {
            derivation = try state.deriveObligations(forComponent: input.componentID)
        } catch let error as SettlementPolicyError {
            return .rejected(.invalidPolicy(error))
        } catch let error as LifeValidationError {
            return .rejected(.lifeValidation(error))
        } catch {
            return .rejected(.storageUnavailable)
        }
        guard let component = state.components[input.componentID] else {
            return .rejected(.lifeValidation(.unknownComponent(input.componentID)))
        }
        var changes: [LifeChange] = []
        var ids: [ObligationID] = []
        for draft in derivation.drafts {
            do {
                let id = ObligationID(rawValue: makeID(.obligation))
                let amount = try AmountEntry(currency: draft.currency, knowledge: draft.amount, provenance: input.provenance)
                changes.append(.createObligation(Obligation(
                    id: id, counterpartyID: draft.counterpartyID, activityID: component.activityID, direction: draft.direction,
                    amount: amount, provenance: input.provenance, createdAtUnixMilliseconds: now(),
                    originTransactionID: component.originTransactionID, label: component.label,
                    componentID: component.id, share: draft.share
                )))
                ids.append(id)
            } catch let error as AmountValidationError {
                return .rejected(.invalidAmount(error))
            } catch {
                return .rejected(.storageUnavailable)
            }
        }
        guard !changes.isEmpty else { return .applied(AppliedCommand(componentID: component.id)) }
        return applyLocal(changes, activityID: component.activityID, componentID: component.id, obligationIDs: ids)
    }

    private func setSpendingNature(_ input: SetSpendingNatureInput) -> CalendarCommandOutcome {
        guard configuration.assignmentPolicy.accepts(input.provenance) else { return .rejected(.provenanceRejected) }
        if let nature = input.nature {
            return applyLocal([.setSpendingNature(input.target, Assigned(nature, provenance: input.provenance))], activityID: nil)
        }
        return applyLocal([.clearSpendingNature(input.target, by: input.provenance)], activityID: nil)
    }

    private func setCategory(_ input: SetCategoryInput) -> CalendarCommandOutcome {
        if let provenance = input.assignment.provenance, !configuration.assignmentPolicy.accepts(provenance) {
            return .rejected(.provenanceRejected)
        }
        switch input.target {
        case let .allocation(id): return applyLocal([.setAllocationCategory(id, input.assignment)], activityID: nil, allocationIDs: [id])
        case let .component(id): return applyLocal([.setComponentCategory(id, input.assignment)], activityID: nil, componentID: id)
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
            let activity = Activity.materialized(from: event, id: ActivityID(rawValue: makeID(.activity)), at: now())
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

    private func applyLocal(
        _ changes: [LifeChange],
        activityID: ActivityID?,
        allocationIDs: [AllocationID] = [],
        obligationID: ObligationID? = nil,
        amountGroupID: AmountGroupID? = nil,
        settlementID: SettlementID? = nil,
        settlementRequestID: SettlementRequestID? = nil,
        correctionGroupID: CorrectionGroupID? = nil,
        componentID: ExpenseComponentID? = nil,
        obligationIDs: [ObligationID] = []
    ) -> CalendarCommandOutcome {
        switch commit(changes) {
        case let .success(revision):
            return .applied(AppliedCommand(
                activityID: activityID, lifeRevision: revision, allocationIDs: allocationIDs, obligationID: obligationID,
                amountGroupID: amountGroupID, settlementID: settlementID, settlementRequestID: settlementRequestID,
                correctionGroupID: correctionGroupID, componentID: componentID, obligationIDs: obligationIDs
            ))
        case let .failure(rejection):
            return .rejected(rejection)
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
