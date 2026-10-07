import Testing
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryCalendar

private let dateEvent = event("date", title: "데이트", from: at(today, 19), to: at(today, 22))
private let tripEvent = event("trip", title: "여행", from: at(today.adding(days: 3), 9), to: at(today.adding(days: 3), 18))
private let dateKey = key("life", "date")
private let tripKey = key("life", "trip")

private func harness(extraTransactions: [TransactionMarker] = [], life: LifeState = .empty) -> Harness {
    Harness.make(
        events: [dateEvent, tripEvent],
        transactions: [
            marker("ticket", at: at(today.adding(days: -2), 18), amount: 14_000, title: "영화표"),
            marker("dinner", at: at(today, 20, 30), amount: 42_000, title: "저녁"),
            marker("taxi", at: at(today, 22, 40), amount: 13_200, title: "택시"),
            marker("ktx", at: at(today, 8), amount: 59_800, title: "KTX")
        ] + extraTransactions,
        life: life
    )
}

private func link(_ transaction: String, to target: ActivityTarget, provenance: AssignmentProvenance = userProvenance()) -> CalendarCommand {
    .linkTransaction(LinkTransactionInput(transactionID: txID(transaction), target: target, provenance: provenance))
}

private func activityID(of outcome: CalendarCommandOutcome) -> ActivityID? {
    if case let .applied(applied) = outcome { return applied.activityID }
    return nil
}

// MARK: Linking

@Test func aTransactionBoughtDaysBeforeTheEventCanStillBeLinkedToIt() async throws {
    let h = harness()
    let outcome = await h.service.perform(link("ticket", to: .event(dateKey)))
    let id = try #require(activityID(of: outcome))
    do { let life = await h.life(); #expect(life.link(for: txID("ticket"))?.activityID == id) }

    let timeline = try await h.service.dayTimeline(for: today)
    let block = try #require(timeline.blocks.first { $0.title == "데이트" })
    #expect(block.linked.map(\.transactionID) == [txID("ticket")])
    #expect(block.linked.first?.occursOnSelectedDay == false)               // two days earlier, yet part of this activity
    #expect(block.linkedTotals == [won(14_000)])
    #expect(timeline.markers.contains { $0.transactionID == txID("ticket") } == false)
}

@Test func linkingMaterializesTheActivityLazilyAndReusesItAfterwards() async {
    let h = harness()
    do { let life = await h.life(); #expect(life.activities.isEmpty) }
    let first = activityID(of: await h.service.perform(link("dinner", to: .event(dateKey))))
    let second = activityID(of: await h.service.perform(link("taxi", to: .event(dateKey))))
    #expect(first != nil && first == second)
    let life = await h.life()
    #expect(life.activities.count == 1)
    #expect(life.links(forActivity: first!).map(\.transactionID.rawValue) == ["dinner", "taxi"])
}

@Test func linkingByActivityIDWorksOnceTheActivityExists() async throws {
    let h = harness()
    let id = try #require(activityID(of: await h.service.perform(link("dinner", to: .event(dateKey)))))
    let outcome = await h.service.perform(link("ticket", to: .activity(id)))
    #expect(activityID(of: outcome) == id)
    do { let life = await h.life(); #expect(life.links(forActivity: id).count == 2) }
}

@Test func linkingRefusesUnknownTransactionsEventsAndActivities() async {
    let h = harness()
    #expect(await h.service.perform(link("ghost-tx", to: .event(dateKey))) == .rejected(.transactionNotFound))
    #expect(await h.service.perform(link("dinner", to: .event(key("life", "nope")))) == .rejected(.eventNotFound))
    #expect(await h.service.perform(link("dinner", to: .activity(ActivityID(rawValue: "nope")))) == .rejected(.activityNotFound))
    do { let life = await h.life(); #expect(life.activities.isEmpty) }                           // a refused link creates no Activity
}

@Test func relinkingMovesATransactionInsteadOfDuplicatingIt() async throws {
    let h = harness()
    let dateActivity = try #require(activityID(of: await h.service.perform(link("ktx", to: .event(dateKey)))))
    let tripActivity = try #require(activityID(of: await h.service.perform(link("ktx", to: .event(tripKey)))))
    let life = await h.life()
    #expect(dateActivity != tripActivity)
    #expect(life.link(for: txID("ktx"))?.activityID == tripActivity)
    #expect(life.links(forActivity: dateActivity).isEmpty)
    #expect(life.linksByTransaction.count == 1)
}

@Test func linkingToTheSameActivityAgainChangesNothing() async throws {
    let h = harness()
    let id = try #require(activityID(of: await h.service.perform(link("dinner", to: .event(dateKey)))))
    let revision = try await h.service.lifeSnapshot().revision
    #expect(activityID(of: await h.service.perform(link("dinner", to: .activity(id)))) == id)
    let revisionAfter = try await h.service.lifeSnapshot().revision
    #expect(revisionAfter == revision)
}

@Test func aUserCanConfirmAnAutomatedLinkAndThatDecisionThenSticks() async throws {
    let h = harness()
    let id = try #require(activityID(of: await h.service.perform(link("dinner", to: .event(dateKey), provenance: autoProvenance(0.92)))))
    do { let life = await h.life(); #expect(life.link(for: txID("dinner"))?.provenance.source == .automated) }
    _ = await h.service.perform(link("dinner", to: .activity(id)))
    do { let life = await h.life(); #expect(life.link(for: txID("dinner"))?.provenance.source == .user) }
    let attempt = await h.service.perform(link("dinner", to: .event(tripKey), provenance: autoProvenance(0.99)))
    #expect(attempt == .rejected(.userAssignmentProtected))
    do { let life = await h.life(); #expect(life.link(for: txID("dinner"))?.activityID == id) }
    do { let life = await h.life(); #expect(life.activities.count == 1) }                        // the refused attempt created nothing
}

@Test func lowConfidenceAutomationIsNotStored() async {
    let h = harness()
    #expect(await h.service.perform(link("dinner", to: .event(dateKey), provenance: autoProvenance(0.5))) == .rejected(.provenanceRejected))
    #expect(await h.service.perform(link("dinner", to: .event(dateKey), provenance: autoProvenance(nil))) == .rejected(.provenanceRejected))
    do { let life = await h.life(); #expect(life.linksByTransaction.isEmpty && life.activities.isEmpty) }
    #expect(activityID(of: await h.service.perform(link("dinner", to: .event(dateKey), provenance: autoProvenance(0.9)))) != nil)
}

@Test func anActivityWhoseEventIsGoneCannotTakeNewLinks() async throws {
    let h = harness()
    let id = try #require(activityID(of: await h.service.perform(link("dinner", to: .event(dateKey)))))
    _ = await h.service.perform(.deleteEvent(DeleteEventInput(target: EventTarget(key: dateKey))))
    #expect(await h.service.perform(link("taxi", to: .activity(id))) == .rejected(.activityEventMissing))
    #expect(await h.service.perform(link("taxi", to: .event(dateKey))) == .rejected(.activityEventMissing))
    do { let life = await h.life(); #expect(life.link(for: txID("dinner")) != nil) }             // existing links are kept
}

@Test func unlinkingIsIdempotentAndRespectsWhoDecided() async throws {
    let h = harness()
    _ = await h.service.perform(link("dinner", to: .event(dateKey)))
    let byAutomation = await h.service.perform(.unlinkTransaction(UnlinkTransactionInput(transactionID: txID("dinner"), by: autoProvenance(0.99))))
    #expect(byAutomation == .rejected(.userAssignmentProtected))
    let byUser = await h.service.perform(.unlinkTransaction(UnlinkTransactionInput(transactionID: txID("dinner"), by: userProvenance(5))))
    guard case .applied = byUser else { Issue.record("expected applied, got \(byUser)"); return }
    do { let life = await h.life(); #expect(life.link(for: txID("dinner")) == nil) }
    let again = await h.service.perform(.unlinkTransaction(UnlinkTransactionInput(transactionID: txID("dinner"), by: userProvenance(6))))
    guard case .applied = again else { Issue.record("expected applied, got \(again)"); return }
    do { let life = await h.life(); #expect(life.activities.count == 1) }                        // the Activity stays; "no Activity" is not forced
    let unlinkedDay = try await h.service.dayTimeline(for: today)
    #expect(unlinkedDay.markers.contains { $0.transactionID == txID("dinner") && $0.linkState == .unlinked })
}

// MARK: Activity type

@Test func assigningATypeToAnEventCreatesItsActivityOnDemand() async throws {
    let h = harness()
    let outcome = await h.service.perform(.assignActivityType(AssignActivityTypeInput(target: .event(dateKey), typeID: .date, provenance: userProvenance())))
    let id = try #require(activityID(of: outcome))
    do { let life = await h.life(); #expect(life.activities[id]?.activityType?.value == .date) }
    let timeline = try await h.service.dayTimeline(for: today)
    #expect(timeline.blocks.first { $0.title == "데이트" }?.activity?.activityType == .date)
}

@Test func customTypesWorkAndUnknownOrArchivedOnesAreRefused() async throws {
    let climbing = ActivityTypeDefinition(id: ActivityTypeID(rawValue: "user.climbing"), displayName: "클라이밍")
    let archived = ActivityTypeDefinition(id: ActivityTypeID(rawValue: "user.old"), displayName: "옛", isArchived: true)
    let life = try LifeState.empty.applying([.upsertActivityType(climbing), .upsertActivityType(archived)])
    let h = harness(life: life)
    let assign = { (type: ActivityTypeID) in
        await h.service.perform(.assignActivityType(AssignActivityTypeInput(target: .event(dateKey), typeID: type, provenance: userProvenance())))
    }
    #expect(activityID(of: await assign(climbing.id)) != nil)
    #expect(await assign(ActivityTypeID(rawValue: "user.nope")) == .rejected(.lifeValidation(.unknownActivityType(ActivityTypeID(rawValue: "user.nope")))))
    #expect(await assign(archived.id) == .rejected(.lifeValidation(.activityTypeArchived(archived.id))))
}

@Test func clearingATypeNeverCreatesAnActivityJustToClearIt() async throws {
    let h = harness()
    let clear = AssignActivityTypeInput(target: .event(dateKey), typeID: nil, provenance: userProvenance())
    guard case .applied = await h.service.perform(.assignActivityType(clear)) else { Issue.record("expected applied"); return }
    do { let life = await h.life(); #expect(life.activities.isEmpty) }
    _ = await h.service.perform(.assignActivityType(AssignActivityTypeInput(target: .event(dateKey), typeID: .social, provenance: userProvenance())))
    _ = await h.service.perform(.assignActivityType(clear))
    do { let life = await h.life(); #expect(life.activities.values.first?.activityType == nil) }
}

@Test func automatedTypeSuggestionsFollowTheConfidencePolicyAndNeverOverrideTheUser() async throws {
    let h = harness()
    let suggest = { (type: ActivityTypeID, confidence: Double?) in
        await h.service.perform(.assignActivityType(AssignActivityTypeInput(target: .event(dateKey), typeID: type, provenance: autoProvenance(confidence))))
    }
    #expect(await suggest(.date, 0.3) == .rejected(.provenanceRejected))
    do { let life = await h.life(); #expect(life.activities.isEmpty) }
    #expect(activityID(of: await suggest(.date, 0.9)) != nil)
    _ = await h.service.perform(.assignActivityType(AssignActivityTypeInput(target: .event(dateKey), typeID: .family, provenance: userProvenance(5))))
    #expect(await suggest(.date, 0.99) == .rejected(.userAssignmentProtected))
    do { let life = await h.life(); #expect(life.activities.values.first?.activityType?.value == .family) }
}

// MARK: Tags

private func lifeWithTags() throws -> LifeState {
    try LifeState.empty.applying([
        .upsertTag(OnAllTag(id: TagID(rawValue: "sub"), name: "구독")),
        .upsertTag(OnAllTag(id: TagID(rawValue: "afterparty"), name: "뒤풀이")),
        .upsertTag(OnAllTag(id: TagID(rawValue: "old"), name: "옛태그", isArchived: true))
    ])
}

@Test func tagsAreAppliedToActivitiesAndTransactionsFromTheUsersOwnSet() async throws {
    let h = harness(life: try lifeWithTags())
    let onEvent = await h.service.perform(.assignTag(AssignTagInput(tagID: TagID(rawValue: "afterparty"), target: .activity(.event(dateKey)), provenance: userProvenance())))
    let id = try #require(activityID(of: onEvent))
    let onTransaction = await h.service.perform(.assignTag(AssignTagInput(tagID: TagID(rawValue: "sub"), target: .transaction(txID("taxi")), provenance: userProvenance())))
    guard case .applied = onTransaction else { Issue.record("expected applied, got \(onTransaction)"); return }
    let life = await h.life()
    #expect(life.activities[id]?.tags.map(\.tagID.rawValue) == ["afterparty"])
    #expect(life.tags(forTransaction: txID("taxi")).map(\.tagID.rawValue) == ["sub"])
}

@Test func anAutomatedProposalCannotCreateAnUnknownOrArchivedTag() async throws {
    let h = harness(life: try lifeWithTags())
    let propose = { (tag: String) in
        await h.service.perform(.assignTag(AssignTagInput(tagID: TagID(rawValue: tag), target: .transaction(txID("taxi")), provenance: autoProvenance(0.95))))
    }
    #expect(await propose("brand-new-ai-tag") == .rejected(.lifeValidation(.unknownTag(TagID(rawValue: "brand-new-ai-tag")))))
    #expect(await propose("old") == .rejected(.lifeValidation(.tagArchived(TagID(rawValue: "old")))))
    do { let life = await h.life(); #expect(life.tags.count == 3) }                              // the vocabulary never grew
    #expect(activityID(of: await propose("sub")) == nil)                   // an existing tag is accepted (no activity involved)
    do { let life = await h.life(); #expect(life.tags(forTransaction: txID("taxi")).count == 1) }
}

@Test func removingATagRespectsProvenanceAndNeverCreatesActivities() async throws {
    let h = harness(life: try lifeWithTags())
    let sub = TagID(rawValue: "sub")
    let remove = { (by: AssignmentProvenance) in
        await h.service.perform(.unassignTag(AssignTagInput(tagID: sub, target: .transaction(txID("taxi")), provenance: by)))
    }
    _ = await h.service.perform(.assignTag(AssignTagInput(tagID: sub, target: .transaction(txID("taxi")), provenance: userProvenance())))
    #expect(await remove(autoProvenance(0.99)) == .rejected(.userAssignmentProtected))
    guard case .applied = await remove(userProvenance(9)) else { Issue.record("expected applied"); return }
    do { let life = await h.life(); #expect(life.tags(forTransaction: txID("taxi")).isEmpty) }
    let noActivity = AssignTagInput(tagID: sub, target: .activity(.event(dateKey)), provenance: userProvenance())
    guard case .applied = await h.service.perform(.unassignTag(noActivity)) else { Issue.record("expected applied"); return }
    do { let life = await h.life(); #expect(life.activities.isEmpty) }
}

@Test func tagCommandsRefuseUnknownTransactions() async throws {
    let h = harness(life: try lifeWithTags())
    let outcome = await h.service.perform(.assignTag(AssignTagInput(tagID: TagID(rawValue: "sub"), target: .transaction(txID("ghost")), provenance: userProvenance())))
    #expect(outcome == .rejected(.transactionNotFound))
}

// MARK: Reconciliation through the service

@Test func anEventRemovedElsewhereBecomesAGhostAfterReconcileAndKeepsItsSpending() async throws {
    let h = harness()
    _ = await h.service.perform(link("dinner", to: .event(dateKey)))
    await h.provider.removeExternally(dateKey)
    let window = seoul.dayBounds(today)
    let changed = try await h.service.reconcile(from: window.start, to: window.end)
    #expect(changed == 1)
    let timeline = try await h.service.dayTimeline(for: today)
    let ghost = try #require(timeline.blocks.first { $0.title == "데이트" })
    #expect(ghost.state == .eventMissing && !ghost.isEditable)
    #expect(ghost.linkedTotals == [won(42_000)])
    let again = try await h.service.reconcile(from: window.start, to: window.end)
    #expect(again == 0)    // already recorded: nothing more to do
}

@Test func aDeletedCalendarMarksEveryAffectedActivityMissing() async throws {
    let h = harness()
    _ = await h.service.perform(link("dinner", to: .event(dateKey)))
    _ = await h.service.perform(link("ktx", to: .event(tripKey)))
    await h.provider.removeCalendarExternally(calendarID("life"))
    let from = seoul.startOfDay(today)
    let changed = try await h.service.reconcile(from: from, to: seoul.startOfDay(today.adding(days: 7)))
    #expect(changed == 2)
    do { let life = await h.life(); #expect(life.activities.values.allSatisfy({ $0.isEventMissing })) }
    do { let life = await h.life(); #expect(life.linksByTransaction.count == 2) }               // spending links survive the calendar
}

@Test func theServiceBuildsAWeekStripFromProviderAndTransactions() async throws {
    let h = harness()
    let strip = try await h.service.weekStrip(containing: today)
    #expect(strip.count == 7)
    let todayCell = try #require(strip.first { $0.day == today })
    #expect(todayCell.eventCount == 1)
    #expect(todayCell.unlinkedTransactionCount == 3)                       // dinner, taxi, ktx happened today
    #expect(todayCell.netSpend == [won(42_000 + 13_200 + 59_800)])
}
