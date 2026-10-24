import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private let lunchEvent = event("lunch", title: "점심", from: at(today, 12), to: at(today, 13))
private let activityID = ActivityID(rawValue: "a1")

private func baseState(extra: [LifeChange] = []) throws -> LifeState {
    try LifeState.empty.applying(
        [.createActivity(Activity.materialized(from: lunchEvent, id: activityID, at: 1))] + extra
    )
}

private func tag(_ id: String, _ name: String, archived: Bool = false) -> OnAllTag { OnAllTag(id: TagID(rawValue: id), name: name, isArchived: archived) }
private func area(_ id: String, _ name: String, aliases: [String] = [], broader: String? = nil) -> Area {
    Area(id: AreaID(rawValue: id), displayName: name, aliases: aliases, broaderAreaID: broader.map { AreaID(rawValue: $0) })
}
private func failure(_ block: () throws -> Void) -> LifeValidationError? {
    do { try block(); return nil } catch let error as LifeValidationError { return error } catch { return nil }
}

// MARK: Activity types

@Test func presetActivityTypesExistWithStableIdentifiers() {
    let state = LifeState.empty
    let names = ActivityTypeDefinition.presets.map(\.displayName)
    #expect(names == ["데이트", "친구·사교", "운동", "업무", "학업", "가족", "여가", "볼일", "동아리", "기타"])
    #expect(state.activityTypes.count == 10)
    #expect(state.activityTypes[.date]?.isPreset == true)
    #expect(state.activityTypes.values.allSatisfy { $0.id.rawValue.hasPrefix("preset.") })
}

@Test func usersCanAddRenameAndArchiveTypesButPresetStatusIsFixed() throws {
    let custom = ActivityTypeDefinition(id: ActivityTypeID(rawValue: "user.climbing"), displayName: "클라이밍")
    var state = try LifeState.empty.applying([.upsertActivityType(custom)])
    #expect(state.activityTypes[custom.id]?.displayName == "클라이밍")
    state = try state.applying([.upsertActivityType(ActivityTypeDefinition(id: custom.id, displayName: "볼더링", isArchived: true))])
    #expect(state.activityTypes[custom.id]?.isArchived == true)
    state = try state.applying([.upsertActivityType(ActivityTypeDefinition(id: .date, displayName: "만남", isPreset: true))])
    #expect(state.activityTypes[.date]?.displayName == "만남")
    #expect(failure { _ = try state.applying([.upsertActivityType(ActivityTypeDefinition(id: .date, displayName: "x", isPreset: false))]) } == .presetImmutable(.date))
    #expect(failure { _ = try state.applying([.upsertActivityType(ActivityTypeDefinition(id: ActivityTypeID(rawValue: "u"), displayName: "  "))]) } == .emptyName(entity: "activityType"))
}

@Test func archivedOrUnknownTypesCannotBeAssigned() throws {
    let archived = ActivityTypeDefinition(id: ActivityTypeID(rawValue: "old"), displayName: "옛", isArchived: true)
    let state = try baseState(extra: [.upsertActivityType(archived)])
    let user = userProvenance()
    #expect(failure { _ = try state.applying([.setActivityType(activityID, Assigned(archived.id, provenance: user))]) } == .activityTypeArchived(archived.id))
    #expect(failure { _ = try state.applying([.setActivityType(activityID, Assigned(ActivityTypeID(rawValue: "nope"), provenance: user))]) } == .unknownActivityType(ActivityTypeID(rawValue: "nope")))
}

// MARK: Tags

@Test func tagNamesAreUniqueIgnoringCaseAndSpacingButArchivedOnesFreeTheName() throws {
    let state = try LifeState.empty.applying([.upsertTag(tag("t1", "뒤풀이"))])
    #expect(failure { _ = try state.applying([.upsertTag(tag("t2", "  뒤풀이 "))]) } == .duplicateTagName("뒤풀이"))
    #expect(failure { _ = try LifeState.empty.applying([.upsertTag(tag("a", "Gift")), .upsertTag(tag("b", "gift"))]) } == .duplicateTagName("gift"))
    let freed = try state.applying([.upsertTag(tag("t1", "뒤풀이", archived: true)), .upsertTag(tag("t2", "뒤풀이"))])
    #expect(freed.tags.count == 2)
    #expect(failure { _ = try state.applying([.upsertTag(tag("t3", " "))]) } == .emptyName(entity: "tag"))
}

@Test func tagsAreChosenFromExistingOnesNeverInvented() throws {
    let state = try baseState(extra: [.upsertTag(tag("t1", "구독"))])
    let user = userProvenance()
    let unknown = TagAssignment(tagID: TagID(rawValue: "ghost"), provenance: user)
    #expect(failure { _ = try state.applying([.setActivityTag(activityID, unknown)]) } == .unknownTag(TagID(rawValue: "ghost")))
    #expect(failure { _ = try state.applying([.setTransactionTag(txID("t"), unknown)]) } == .unknownTag(TagID(rawValue: "ghost")))
    let archivedState = try state.applying([.upsertTag(tag("t1", "구독", archived: true))])
    #expect(failure { _ = try archivedState.applying([.setActivityTag(activityID, TagAssignment(tagID: TagID(rawValue: "t1"), provenance: user))]) } == .tagArchived(TagID(rawValue: "t1")))
}

@Test func tagsAttachToActivitiesAndTransactions() throws {
    let user = userProvenance()
    let state = try baseState(extra: [
        .upsertTag(tag("t1", "구독")), .upsertTag(tag("t2", "선물")),
        .setActivityTag(activityID, TagAssignment(tagID: TagID(rawValue: "t2"), provenance: user)),
        .setActivityTag(activityID, TagAssignment(tagID: TagID(rawValue: "t1"), provenance: user)),
        .setTransactionTag(txID("tx"), TagAssignment(tagID: TagID(rawValue: "t1"), provenance: user))
    ])
    #expect(state.activities[activityID]?.tags.map(\.tagID.rawValue) == ["t1", "t2"])   // stable order
    #expect(state.tags(forTransaction: txID("tx")).map(\.tagID.rawValue) == ["t1"])
    let removed = try state.applying([.removeTransactionTag(txID("tx"), TagID(rawValue: "t1"), by: user)])
    #expect(removed.tags(forTransaction: txID("tx")).isEmpty)
    #expect(removed.transactionTags[txID("tx")] == nil)
}

// MARK: Areas

private func seoulAreas() throws -> AreaCatalog {
    var catalog = AreaCatalog()
    catalog = try catalog.inserting(area("hongdae", "홍대권", aliases: ["홍대"]))
    catalog = try catalog.inserting(area("yeonnam", "연남", aliases: ["연남동"], broader: "hongdae"))
    catalog = try catalog.inserting(area("hapjeong", "합정", broader: "hongdae"))
    catalog = try catalog.inserting(area("sinchon", "신촌", aliases: ["이대"]))
    catalog = try catalog.inserting(area("seongsu", "성수"))
    catalog = try catalog.inserting(area("gangnam", "강남"))
    catalog = try catalog.inserting(area("jamsil", "잠실"))
    catalog = try catalog.inserting(area("sharosu", "샤로수길"))
    return catalog
}

@Test func areasResolveByNameOrAliasAndNeverByGuessing() throws {
    let catalog = try seoulAreas()
    #expect(catalog.resolve(alias: "연남")?.id == AreaID(rawValue: "yeonnam"))
    #expect(catalog.resolve(alias: " 연남동 ")?.id == AreaID(rawValue: "yeonnam"))
    #expect(catalog.resolve(alias: "이대")?.id == AreaID(rawValue: "sinchon"))
    #expect(catalog.resolve(alias: "홍대")?.id == AreaID(rawValue: "hongdae"))
    #expect(catalog.resolve(alias: "연남동 맛집") == nil)       // only exact (normalized) matches resolve
    #expect(catalog.resolve(alias: "") == nil)
}

@Test func areasHaveAnOptionalBroaderAreaChain() throws {
    let catalog = try seoulAreas()
    #expect(catalog.ancestors(of: AreaID(rawValue: "yeonnam")).map(\.displayName) == ["홍대권"])
    #expect(catalog.ancestors(of: AreaID(rawValue: "sinchon")).isEmpty)
    #expect(catalog.isWithin(AreaID(rawValue: "hapjeong"), ancestor: AreaID(rawValue: "hongdae")))
    #expect(catalog.isWithin(AreaID(rawValue: "hongdae"), ancestor: AreaID(rawValue: "hongdae")))
    #expect(!catalog.isWithin(AreaID(rawValue: "sinchon"), ancestor: AreaID(rawValue: "hongdae")))
    #expect(!catalog.isWithin(AreaID(rawValue: "hongdae"), ancestor: AreaID(rawValue: "yeonnam")))
}

@Test func areaCatalogRejectsDuplicatesCyclesAndMissingParents() throws {
    let catalog = try seoulAreas()
    #expect(failure { _ = try catalog.inserting(area("other", "다른", aliases: ["연남"])) } == .duplicateAreaAlias("연남"))
    #expect(failure { _ = try catalog.inserting(area("other", "연남동")) } == .duplicateAreaAlias("연남동"))
    #expect(failure { _ = try catalog.inserting(area("x", "엑스", broader: "missing")) } == .unknownBroaderArea(AreaID(rawValue: "missing")))
    #expect(failure { _ = try catalog.inserting(area("hongdae", "홍대권", broader: "yeonnam")) } == .areaCycle(AreaID(rawValue: "hongdae")))
    #expect(failure { _ = try catalog.inserting(area("self", "셀프", broader: "self")) } == .areaCycle(AreaID(rawValue: "self")))
    #expect(failure { _ = try catalog.inserting(area("blank", " ")) } == .emptyName(entity: "area"))
}

@Test func replacingAnAreaReleasesItsOldAliases() throws {
    var catalog = try seoulAreas()
    catalog = try catalog.inserting(area("yeonnam", "연남", aliases: ["연트럴파크"], broader: "hongdae"))
    #expect(catalog.resolve(alias: "연남동") == nil)
    #expect(catalog.resolve(alias: "연트럴파크")?.id == AreaID(rawValue: "yeonnam"))
    catalog = try catalog.inserting(area("new", "새곳", aliases: ["연남동"]))
    #expect(catalog.resolve(alias: "연남동")?.id == AreaID(rawValue: "new"))
}

@Test func areaCatalogRoundTripsEvenWhenAChildIsStoredBeforeItsParent() throws {
    let catalog = try seoulAreas()
    let data = try JSONEncoder().encode(catalog)
    #expect(try JSONDecoder().decode(AreaCatalog.self, from: data) == catalog)
    let reversed = Data(#"{"areas":[{"id":"c","displayName":"자식","aliases":[],"broaderAreaID":"p"},{"id":"p","displayName":"부모","aliases":[]}]}"#.utf8)
    let decoded = try JSONDecoder().decode(AreaCatalog.self, from: reversed)
    #expect(decoded.ancestors(of: AreaID(rawValue: "c")).map(\.displayName) == ["부모"])
    let orphan = Data(#"{"areas":[{"id":"c","displayName":"자식","aliases":[],"broaderAreaID":"zzz"}]}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(AreaCatalog.self, from: orphan) }
}

@Test func anActivityCanCarryAnAreaButOnlyOneThatExists() throws {
    let state = try baseState(extra: [.upsertArea(area("yeonnam", "연남"))])
    let assigned = try state.applying([.setActivityArea(activityID, Assigned(AreaID(rawValue: "yeonnam"), provenance: userProvenance()))])
    #expect(assigned.activities[activityID]?.area?.value == AreaID(rawValue: "yeonnam"))
    #expect(failure { _ = try state.applying([.setActivityArea(activityID, Assigned(AreaID(rawValue: "nowhere"), provenance: userProvenance()))]) } == .unknownArea(AreaID(rawValue: "nowhere")))
}

// MARK: Activities

@Test func anActivityIsAnOnAllRecordSeparateFromItsCalendarEvent() throws {
    let state = try baseState()
    let activity = try #require(state.activities[activityID])
    #expect(activity.association?.key == lunchEvent.key)
    #expect(activity.displayTitle == "점심")
    #expect(!activity.isEventMissing)
    #expect(activity.carriesNoMeaning)
    #expect(state.activity(forEvent: lunchEvent.key)?.id == activityID)
    #expect(state.activity(forEvent: key("life", "other")) == nil)        // lazy: no Activity until needed
}

@Test func oneEventCanOnlyBelongToOneActivity() throws {
    let state = try baseState()
    let second = Activity.materialized(from: lunchEvent, id: ActivityID(rawValue: "a2"), at: 2)
    #expect(failure { _ = try state.applying([.createActivity(second)]) } == .eventAlreadyAssociated(lunchEvent.key))
    #expect(failure { _ = try state.applying([.createActivity(Activity.materialized(from: lunchEvent, id: activityID, at: 2))]) } == .duplicateIdentifier(entity: "activity", id: "a1"))
}

@Test func anEventDisappearingKeepsTheActivityAndItsAllocations() throws {
    let user = userProvenance()
    let state = try baseState(extra: [
        wholeAllocation("t", to: "a1", total: 8_000),
        .setActivityType(activityID, Assigned(.social, provenance: user))
    ])
    let association = try #require(state.activities[activityID]?.association)
    let missing = try state.applying([.updateAssociation(activityID, association.markedMissing(at: 99))])
    let activity = try #require(missing.activities[activityID])
    #expect(activity.isEventMissing)
    #expect(activity.displayTitle == "점심")
    #expect(activity.activityType?.value == .social)
    #expect(missing.activityID(of: txID("t")) == activityID)
    #expect(association.markedMissing(at: 99).markedMissing(at: 200).status == .missing(sinceUnixMilliseconds: 99))   // first sighting wins
    let back = try missing.applying([.updateAssociation(activityID, association.refreshed(from: lunchEvent))])
    #expect(!(back.activities[activityID]?.isEventMissing ?? true))
}

@Test func anActivityWithAllocationsOrObligationsCannotBeRemoved() throws {
    let state = try baseState(extra: [wholeAllocation("t", to: "a1", total: 8_000)])
    #expect(failure { _ = try state.applying([.removeActivity(activityID)]) } == .activityHasAllocations(activityID))
    let released = try state.applying([.removeAllocation(AllocationID(rawValue: "alloc-t-a1"), by: userProvenance())])
    #expect(try released.applying([.removeActivity(activityID)]).activities.isEmpty)

    let withObligation = try baseState(extra: [
        .upsertPerson(Person(id: PersonID(rawValue: "p"), displayName: "상대")),
        .createObligation(Obligation(
            id: ObligationID(rawValue: "o"), counterpartyID: PersonID(rawValue: "p"), activityID: activityID, direction: .payable,
            amount: try! AmountEntry(currency: "KRW", knowledge: .unknown, provenance: userProvenance()),
            provenance: userProvenance(), createdAtUnixMilliseconds: 1
        ))
    ])
    #expect(failure { _ = try withObligation.applying([.removeActivity(activityID)]) } == .activityHasObligations(activityID))
}

@Test func anActivityNeedsNoCalendarAtAll() throws {
    let info = StandaloneActivityInfo(title: "산책", time: .timed(timed(at(today, 7), at(today, 8))))
    let standalone = Activity(id: ActivityID(rawValue: "walk"), origin: .standalone(info), createdAtUnixMilliseconds: 1)
    let state = try LifeState.empty.applying([.createActivity(standalone)])
    #expect(state.activities[standalone.id]?.association == nil)
    #expect(state.activities[standalone.id]?.displayTitle == "산책")
    #expect(failure { _ = try state.applying([.updateAssociation(standalone.id, CalendarEventAssociation(event: lunchEvent))]) } == .notCalendarActivity(standalone.id))
    let blank = Activity(id: ActivityID(rawValue: "b"), origin: .standalone(StandaloneActivityInfo(title: " ", time: info.time)), createdAtUnixMilliseconds: 1)
    #expect(failure { _ = try LifeState.empty.applying([.createActivity(blank)]) } == .emptyName(entity: "activity"))
}

@Test func reassociatingToAnEventAnotherActivityOwnsIsRefused() throws {
    let other = event("other", title: "다른", from: at(today, 15), to: at(today, 16))
    let state = try baseState(extra: [.createActivity(Activity.materialized(from: other, id: ActivityID(rawValue: "a2"), at: 1))])
    #expect(failure { _ = try state.applying([.updateAssociation(activityID, CalendarEventAssociation(event: other))]) } == .eventAlreadyAssociated(other.key))
}

// MARK: Allocations and provenance

@Test func anAllocationNeedsNoTimeContainmentAndTheTotalCannotBeExceeded() throws {
    let other = event("other", title: "다른", from: at(today, 15), to: at(today, 16))
    let state = try baseState(extra: [.createActivity(Activity.materialized(from: other, id: ActivityID(rawValue: "a2"), at: 1))])
    // Nothing about the transaction's time is known to the state, so nothing can be required of it.
    let first = try state.applying([wholeAllocation("t", to: "a1", total: 8_000, createdAt: 5)])
    #expect(first.activityID(of: txID("t")) == activityID)
    // The same money cannot be assigned in full to a second activity at the same time.
    #expect(failure { _ = try first.applying([wholeAllocation("t", to: "a2", total: 8_000)]) } == .allocationExceedsTransaction(txID("t")))
    // Moving means releasing first.
    let moved = try first.applying([.removeAllocation(AllocationID(rawValue: "alloc-t-a1"), by: userProvenance()), wholeAllocation("t", to: "a2", total: 8_000, createdAt: 6)])
    #expect(moved.activityID(of: txID("t")) == ActivityID(rawValue: "a2"))
    #expect(moved.allocations(forActivity: activityID).isEmpty)
    #expect(failure { _ = try state.applying([wholeAllocation("t", to: "ghost", total: 8_000)]) } == .unknownActivity(ActivityID(rawValue: "ghost")))
}

@Test func allocationsOfAnActivityAreOrderedByCreationThenID() throws {
    let state = try baseState(extra: [
        wholeAllocation("b", to: "a1", total: 100, createdAt: 2),
        wholeAllocation("c", to: "a1", total: 100, createdAt: 1),
        wholeAllocation("a", to: "a1", total: 100, createdAt: 2)
    ])
    #expect(state.allocations(forActivity: activityID).map { $0.transactionID.rawValue } == ["c", "a", "b"])
}

@Test func automationCannotOverwriteOrRemoveAUserDecision() throws {
    let user = userProvenance()
    let auto = autoProvenance(0.95)
    let state = try baseState(extra: [
        .upsertTag(tag("t1", "구독")),
        .upsertArea(area("yeonnam", "연남")), .upsertArea(area("seongsu", "성수")),
        .setActivityType(activityID, Assigned(.date, provenance: user)),
        .setActivityArea(activityID, Assigned(AreaID(rawValue: "yeonnam"), provenance: user)),
        .setActivityTag(activityID, TagAssignment(tagID: TagID(rawValue: "t1"), provenance: user)),
        wholeAllocation("t", to: "a1", total: 8_000),
        .setTransactionTag(txID("t"), TagAssignment(tagID: TagID(rawValue: "t1"), provenance: user))
    ])
    let protected = LifeValidationError.userAssignmentProtected
    #expect(failure { _ = try state.applying([.setActivityType(activityID, Assigned(.social, provenance: auto))]) } == protected)
    #expect(failure { _ = try state.applying([.clearActivityType(activityID, by: auto)]) } == protected)
    #expect(failure { _ = try state.applying([.setActivityArea(activityID, Assigned(AreaID(rawValue: "seongsu"), provenance: auto))]) } == protected)
    #expect(failure { _ = try state.applying([.clearActivityArea(activityID, by: auto)]) } == protected)
    #expect(failure { _ = try state.applying([.setActivityTag(activityID, TagAssignment(tagID: TagID(rawValue: "t1"), provenance: auto))]) } == protected)
    #expect(failure { _ = try state.applying([.removeActivityTag(activityID, TagID(rawValue: "t1"), by: auto)]) } == protected)
    #expect(failure { _ = try state.applying([wholeAllocation("t", to: "a1", total: 8_000, provenance: auto)]) } == protected)
    #expect(failure { _ = try state.applying([.removeAllocation(AllocationID(rawValue: "alloc-t-a1"), by: auto)]) } == protected)
    #expect(failure { _ = try state.applying([.setTransactionTag(txID("t"), TagAssignment(tagID: TagID(rawValue: "t1"), provenance: auto))]) } == protected)
    #expect(failure { _ = try state.applying([.removeTransactionTag(txID("t"), TagID(rawValue: "t1"), by: auto)]) } == protected)
    // The user can still change their own mind.
    let changed = try state.applying([.setActivityType(activityID, Assigned(.social, provenance: user)), .removeAllocation(AllocationID(rawValue: "alloc-t-a1"), by: user)])
    #expect(changed.activities[activityID]?.activityType?.value == .social)
    #expect(changed.activityID(of: txID("t")) == nil)
}

@Test func automationMayRefineItsOwnEarlierGuessAndUsersMayOverrideIt() throws {
    let state = try baseState(extra: [.setActivityType(activityID, Assigned(.social, provenance: autoProvenance(0.9)))])
    let refined = try state.applying([.setActivityType(activityID, Assigned(.date, provenance: autoProvenance(0.97, 2)))])
    #expect(refined.activities[activityID]?.activityType?.value == .date)
    let overridden = try refined.applying([.setActivityType(activityID, Assigned(.family, provenance: userProvenance(3)))])
    #expect(overridden.activities[activityID]?.activityType?.provenance.source == .user)
    let cleared = try refined.applying([.clearActivityType(activityID, by: autoProvenance(0.9, 4))])
    #expect(cleared.activities[activityID]?.activityType == nil)
}

@Test func confidenceOutsideZeroToOneIsRejected() throws {
    let state = try baseState()
    for bad in [-0.1, 1.5, Double.nan, Double.infinity] {
        let provenance = AssignmentProvenance(source: .automated, origin: "x", confidence: bad, assignedAtUnixMilliseconds: 1)
        #expect(failure { _ = try state.applying([.setActivityType(activityID, Assigned(.social, provenance: provenance))]) } == .invalidConfidence)
    }
}

@Test func applyingChangesIsAllOrNothing() throws {
    let state = try baseState()
    let user = userProvenance()
    let before = state
    let result = failure {
        _ = try state.applying([
            .setActivityType(activityID, Assigned(.social, provenance: user)),     // valid
            .setActivityType(activityID, Assigned(ActivityTypeID(rawValue: "nope"), provenance: user))   // invalid
        ])
    }
    #expect(result == .unknownActivityType(ActivityTypeID(rawValue: "nope")))
    #expect(state == before)                      // value semantics: the receiver is untouched
    #expect(state.activities[activityID]?.activityType == nil)
}

@Test func lifeStateRoundTripsThroughCodable() throws {
    let user = userProvenance(10)
    let state = try baseState(extra: [
        .upsertTag(tag("t1", "선물")), .upsertArea(area("sinchon", "신촌", aliases: ["이대"])),
        .setActivityType(activityID, Assigned(.date, provenance: user)),
        .setActivityArea(activityID, Assigned(AreaID(rawValue: "sinchon"), provenance: user)),
        .setActivityTag(activityID, TagAssignment(tagID: TagID(rawValue: "t1"), provenance: autoProvenance(0.9, 11))),
        wholeAllocation("tx", to: "a1", total: 8_000, createdAt: 12),
        .setTransactionTag(txID("tx"), TagAssignment(tagID: TagID(rawValue: "t1"), provenance: user))
    ])
    let data = try JSONEncoder().encode(LifeSnapshot(revision: 7, state: state))
    let decoded = try JSONDecoder().decode(LifeSnapshot.self, from: data)
    #expect(decoded.revision == 7)
    #expect(decoded.state == state)
}
