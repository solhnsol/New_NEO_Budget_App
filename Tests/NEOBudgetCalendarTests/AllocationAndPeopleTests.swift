import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private func activities(_ ids: [String]) -> [LifeChange] {
    ids.enumerated().map { index, id in
        let event = event("e-\(id)", title: "활동 \(id)", from: at(today, 9 + index), to: at(today, 10 + index))
        return .createActivity(Activity.materialized(from: event, id: ActivityID(rawValue: id), at: 1))
    }
}

private func state(_ ids: [String] = ["A", "B", "C"], extra: [LifeChange] = []) throws -> LifeState {
    try LifeState.empty.applying(activities(ids) + extra)
}

private func failure(_ block: () throws -> Void) -> LifeValidationError? {
    do { try block(); return nil } catch let error as LifeValidationError { return error } catch { return nil }
}

private func allocationID(_ transaction: String, _ activity: String?) -> AllocationID {
    AllocationID(rawValue: "alloc-\(transaction)-\(activity ?? "none")")
}

// MARK: One transaction, many activities

@Test func oneTransferCanBeSplitAcrossSeveralActivities() throws {
    // 80,000원 송금: 30,000 → 지난주 술자리, 25,000 → 농구 대관비, 25,000 → 여행 숙박비
    let life = try state(extra: [
        allocation("tx", to: "A", amount: .exact(30_000), of: 80_000),
        allocation("tx", to: "B", amount: .exact(25_000), of: 80_000),
        allocation("tx", to: "C", amount: .exact(25_000), of: 80_000)
    ])
    let set = try #require(life.allocationSet(for: txID("tx")))
    #expect(set.allocations.count == 3)
    #expect(set.transactionTotal == won(80_000))
    #expect(set.isFullyAllocated)
    #expect(set.remainder == AmountBounds(lower: 0, upper: 0))
    #expect(set.knownRemainderMinorUnits == 0)
    #expect(life.allocations(forActivity: ActivityID(rawValue: "A")).map { $0.amount.knowledge } == [.exact(30_000)])
    #expect(life.allocations(forActivity: ActivityID(rawValue: "C")).map { $0.amount.knowledge } == [.exact(25_000)])
}

@Test func oneActivityCanHoldPortionsOfManyTransactions() throws {
    // 데이트: 점심, 카페, 영화, 택시
    let life = try state(["date"], extra: [
        wholeAllocation("lunch", to: "date", total: 9_500),
        wholeAllocation("cafe", to: "date", total: 5_800),
        wholeAllocation("movie", to: "date", total: 14_000, createdAt: 2),
        allocation("taxi", to: "date", amount: .exact(6_000), of: 13_200, createdAt: 3)
    ])
    #expect(life.allocations(forActivity: ActivityID(rawValue: "date")).count == 4)
    #expect(life.allocationSets.count == 4)
}

@Test func aTransactionCanBeOnlyPartlyAllocatedAndTheRestIsRepresentable() throws {
    // 50,000원 거래: 30,000 → Activity A, 20,000 → 아직 배분 안 됨
    let life = try state(extra: [allocation("tx", to: "A", amount: .exact(30_000), of: 50_000)])
    let set = try #require(life.allocationSet(for: txID("tx")))
    #expect(!set.isFullyAllocated)
    #expect(set.knownRemainderMinorUnits == 20_000)
    #expect(set.remainder == AmountBounds(lower: 20_000, upper: 20_000))
}

@Test func theAllocatedAmountsCanNeverExceedTheTransaction() throws {
    let base = try state(extra: [
        allocation("tx", to: "A", amount: .exact(30_000), of: 80_000),
        allocation("tx", to: "B", amount: .exact(25_000), of: 80_000)
    ])
    #expect(failure { _ = try base.applying([allocation("tx", to: "C", amount: .exact(30_000), of: 80_000)]) } == .allocationExceedsTransaction(txID("tx")))
    #expect(try base.applying([allocation("tx", to: "C", amount: .exact(25_000), of: 80_000)]).allocationSet(for: txID("tx"))?.isFullyAllocated == true)
    // Even a range counts at its minimum: it cannot be that little and still fit.
    #expect(failure { _ = try base.applying([allocation("tx", to: "C", amount: amountRange(26_000, 40_000), of: 80_000)]) } == .allocationExceedsTransaction(txID("tx")))
    #expect(try base.applying([allocation("tx", to: "C", amount: amountRange(10_000, 40_000), of: 80_000)]).allocationSet(for: txID("tx")) != nil)
}

@Test func theTransactionTotalCannotChangeBetweenAllocations() throws {
    let base = try state(extra: [allocation("tx", to: "A", amount: .exact(10_000), of: 80_000)])
    #expect(failure { _ = try base.applying([allocation("tx", to: "B", amount: .exact(10_000), of: 90_000)]) } == .transactionTotalMismatch(txID("tx")))
    #expect(failure { _ = try base.applying([allocation("tx", to: "B", amount: .exact(10_000), of: 80_000, flow: .refund)]) } == .transactionTotalMismatch(txID("tx")))
}

@Test func eachActivityAppearsOnceInATransactionAndNoActivityCanBeExplicit() throws {
    let base = try state(extra: [allocation("tx", to: "A", amount: .exact(10_000), of: 80_000, id: "one")])
    #expect(failure { _ = try base.applying([allocation("tx", to: "A", amount: .exact(5_000), of: 80_000, id: "two")]) } == .duplicateAllocationTarget(txID("tx")))
    let withExplicitNone = try base.applying([allocation("tx", to: nil, amount: .exact(20_000), of: 80_000)])
    let set = try #require(withExplicitNone.allocationSet(for: txID("tx")))
    #expect(set.allocations.contains { $0.activityID == nil })                  // 활동 외 소비 as a decision
    #expect(set.knownRemainderMinorUnits == 50_000)                             // different from the undecided remainder
    #expect(failure { _ = try withExplicitNone.applying([allocation("tx", to: nil, amount: .exact(1_000), of: 80_000, id: "another-none")]) } == .duplicateAllocationTarget(txID("tx")))
}

@Test func allocationsToUnknownActivitiesOrWithBadCurrencyAreRefused() throws {
    let base = try state()
    #expect(failure { _ = try base.applying([wholeAllocation("tx", to: "ghost", total: 1_000)]) } == .unknownActivity(ActivityID(rawValue: "ghost")))
    let usd = TransactionAllocation(
        id: AllocationID(rawValue: "x"), transactionID: txID("tx"), activityID: ActivityID(rawValue: "A"),
        amount: entry(.exact(100), currency: "USD"), provenance: userProvenance(), createdAtUnixMilliseconds: 1
    )
    #expect(failure { _ = try base.applying([.upsertAllocation(usd, transactionTotal: won(1_000), flow: .spend)]) } == .allocationCurrencyMismatch(AllocationID(rawValue: "x")))
}

// MARK: Uncertain portions

@Test func aPortionMayBeUnknownAndTheRemainderWidensAccordingly() throws {
    // 80,000원: A는 금액 미상, B는 25,000 확정
    let life = try state(extra: [
        allocation("tx", to: "A", amount: .unknown, of: 80_000),
        allocation("tx", to: "B", amount: .exact(25_000), of: 80_000)
    ])
    let set = try #require(life.allocationSet(for: txID("tx")))
    #expect(set.remainder == AmountBounds(lower: 0, upper: 55_000))
    #expect(set.knownRemainderMinorUnits == nil)
    #expect(!set.isFullyAllocated)
}

@Test func rangesNarrowTheRemainderFromBothSides() throws {
    let life = try state(extra: [
        allocation("tx", to: "A", amount: amountRange(20_000, 30_000), of: 80_000),
        allocation("tx", to: "B", amount: .exact(25_000), of: 80_000)
    ])
    #expect(life.allocationSet(for: txID("tx"))?.remainder == AmountBounds(lower: 25_000, upper: 35_000))
}

@Test func anAllocationAmountSharpensOverTimeButNeverByOverwritingAUser() throws {
    let id = AllocationID(rawValue: "alloc-tx-A")
    let life = try state(extra: [allocation("tx", to: "A", amount: .unknown, of: 80_000, provenance: userProvenance())])
    // Evidence makes it exact: allowed (a user may always state it).
    let sharpened = try life.applying([.setAllocationAmount(id, entry(.exact(30_000)))])
    #expect(sharpened.allocation(id)?.amount.knowledge == .exact(30_000))
    // Automation cannot overwrite what the user confirmed, even with a different "inference".
    #expect(failure { _ = try sharpened.applying([.setAllocationAmount(id, entry(inferred(31_000), provenance: autoProvenance(1.0)))]) } == .amountUpdateRejected(.rejectedProtectedUserAmount))
    // Automation can promote an unknown portion.
    let promoted = try life.applying([.setAllocationAmount(id, entry(inferred(30_000), provenance: autoProvenance(1.0)))])
    #expect(promoted.allocation(id)?.amount.knowledge == inferred(30_000))
    // ...but not make a settled one less known.
    #expect(failure { _ = try promoted.applying([.setAllocationAmount(id, entry(.unknown, provenance: autoProvenance(1.0)))]) } == .amountUpdateRejected(.rejectedWeakening))
}

@Test func anUpdatedAllocationAmountStillCannotExceedTheTransaction() throws {
    let id = AllocationID(rawValue: "alloc-tx-A")
    let life = try state(extra: [
        allocation("tx", to: "A", amount: .unknown, of: 80_000),
        allocation("tx", to: "B", amount: .exact(60_000), of: 80_000)
    ])
    #expect(failure { _ = try life.applying([.setAllocationAmount(id, entry(.exact(30_000)))]) } == .allocationExceedsTransaction(txID("tx")))
    #expect(try life.applying([.setAllocationAmount(id, entry(.exact(20_000)))]).allocationSet(for: txID("tx"))?.isFullyAllocated == true)
}

@Test func allocationAmountsAreKeptPerEntryWithTheirOwnProvenance() throws {
    let life = try state(extra: [
        allocation("tx", to: "A", amount: .estimated(30_000), of: 80_000, provenance: autoProvenance(0.9))
    ])
    let stored = try #require(life.allocation(allocationID("tx", "A")))
    #expect(stored.amount.provenance.source == .automated)
    #expect(stored.amount.knowledge == .estimated(30_000))
}

// MARK: Provenance and removal

@Test func automationCannotReplaceOrRemoveAUsersAllocation() throws {
    let life = try state(extra: [allocation("tx", to: "A", amount: .exact(30_000), of: 80_000)])
    let auto = autoProvenance(0.99)
    #expect(failure { _ = try life.applying([allocation("tx", to: "A", amount: .exact(30_000), of: 80_000, provenance: auto)]) } == .userAssignmentProtected)
    #expect(failure { _ = try life.applying([.removeAllocation(allocationID("tx", "A"), by: auto)]) } == .userAssignmentProtected)
    let byUser = try life.applying([.removeAllocation(allocationID("tx", "A"), by: userProvenance())])
    #expect(byUser.allocationSet(for: txID("tx")) == nil)                       // an empty set disappears
    #expect(failure { _ = try life.applying([.removeAllocation(AllocationID(rawValue: "ghost"), by: userProvenance())]) } == .unknownAllocation(AllocationID(rawValue: "ghost")))
}

@Test func anAllocationCannotChangeWhichActivityOrTransactionItBelongsTo() throws {
    let life = try state(extra: [allocation("tx", to: "A", amount: .exact(30_000), of: 80_000, id: "same")])
    #expect(failure { _ = try life.applying([allocation("tx", to: "B", amount: .exact(30_000), of: 80_000, id: "same")]) } == .allocationIdentityChanged(AllocationID(rawValue: "same")))
}

@Test func allocationsSurviveACalendarEventDisappearing() throws {
    let life = try state(["A"], extra: [wholeAllocation("tx", to: "A", total: 5_000)])
    let association = try #require(life.activities[ActivityID(rawValue: "A")]?.association)
    let missing = try life.applying([.updateAssociation(ActivityID(rawValue: "A"), association.markedMissing(at: 9))])
    #expect(missing.activities[ActivityID(rawValue: "A")]?.isEventMissing == true)
    #expect(missing.allocationSet(for: txID("tx"))?.allocations.count == 1)
}

// MARK: People and participants

@Test func thereIsAtMostOneSelfPersonAndNamesCannotBeEmpty() throws {
    let life = lifeWithPeople(["friend"])
    #expect(life.persons[myself]?.isSelf == true)
    #expect(failure { _ = try life.applying([.upsertPerson(person("me2", name: "또 나", isSelf: true))]) } == .duplicateSelf)
    #expect(try life.applying([.upsertPerson(person("me", name: "내 이름 변경", isSelf: true))]).persons[myself]?.displayName == "내 이름 변경")
    #expect(failure { _ = try life.applying([.upsertPerson(person("blank", name: "  "))]) } == .emptyName(entity: "person"))
    #expect(failure { _ = try life.applying([.upsertPerson(Person(id: PersonID(rawValue: ""), displayName: "x"))]) } == .emptyIdentifier(entity: "person"))
}

@Test func aPersonNeedsNoOnAllAccount() throws {
    let external = Person(id: pid("g"), displayName: "홍길동", externalIdentity: ExternalIdentity(kind: "contacts", value: "abc"))
    let plain = person("h", name: "홍길순")
    let life = lifeWithPeople([], extra: [.upsertPerson(external), .upsertPerson(plain)])
    #expect(life.persons[pid("g")]?.externalIdentity?.kind == "contacts")
    #expect(life.persons[pid("h")]?.externalIdentity == nil)                    // fully functional without any external identity
    #expect(try JSONDecoder().decode(Person.self, from: JSONEncoder().encode(external)) == external)
}

@Test func relationshipLabelsExistOnlyWhenTheUserStatesThem() throws {
    let userLabel = Person(id: pid("g"), displayName: "홍길동", relationshipLabel: Assigned("친구", provenance: userProvenance()))
    let autoLabel = Person(id: pid("g"), displayName: "홍길동", relationshipLabel: Assigned("연인", provenance: autoProvenance(0.99)))
    let life = lifeWithPeople([])
    #expect(try life.applying([.upsertPerson(userLabel)]).persons[pid("g")]?.relationshipLabel?.value == "친구")
    #expect(failure { _ = try life.applying([.upsertPerson(autoLabel)]) } == .relationshipLabelRequiresUser)
}

@Test func participantsAttachToActivitiesAndMustBeKnownPeople() throws {
    let life = lifeWithPeople(["friend", "other"], extra: activities(["A"]))
    let a = ActivityID(rawValue: "A")
    let user = userProvenance()
    let with = try life.applying([
        .addParticipant(a, ParticipantAssignment(personID: pid("other"), provenance: user)),
        .addParticipant(a, ParticipantAssignment(personID: myself, provenance: user)),
        .addParticipant(a, ParticipantAssignment(personID: pid("friend"), provenance: user))
    ])
    #expect(with.activities[a]?.participants.map(\.personID.rawValue) == ["friend", "me", "other"])    // stable order
    #expect(failure { _ = try life.applying([.addParticipant(a, ParticipantAssignment(personID: pid("ghost"), provenance: user))]) } == .unknownPerson(pid("ghost")))
    let removed = try with.applying([.removeParticipant(a, pid("other"), by: user)])
    #expect(removed.activities[a]?.participants.count == 2)
    #expect(try removed.applying([.removeParticipant(a, pid("other"), by: user)]) == removed)           // removing again is a no-op
}

@Test func automationCannotRemoveOrReplaceAParticipantTheUserAdded() throws {
    let life = lifeWithPeople(["friend"], extra: activities(["A"]))
    let a = ActivityID(rawValue: "A")
    let added = try life.applying([.addParticipant(a, ParticipantAssignment(personID: pid("friend"), provenance: userProvenance()))])
    let auto = autoProvenance(0.95)
    #expect(failure { _ = try added.applying([.removeParticipant(a, pid("friend"), by: auto)]) } == .userAssignmentProtected)
    #expect(failure { _ = try added.applying([.addParticipant(a, ParticipantAssignment(personID: pid("friend"), provenance: auto))]) } == .userAssignmentProtected)
}

@Test func anActivityCanBeCreatedWithParticipantsButOnlyKnownOnes() throws {
    let life = lifeWithPeople(["friend"])
    let event = event("e", title: "모임", from: at(today, 10), to: at(today, 11))
    var activity = Activity.materialized(from: event, id: ActivityID(rawValue: "A"), at: 1)
    activity.participants = [ParticipantAssignment(personID: pid("friend"), provenance: userProvenance())]
    #expect(try life.applying([.createActivity(activity)]).activities[activity.id]?.participants.count == 1)
    activity.participants = [ParticipantAssignment(personID: pid("ghost"), provenance: userProvenance())]
    #expect(failure { _ = try life.applying([.createActivity(activity)]) } == .unknownPerson(pid("ghost")))
    #expect(Activity.materialized(from: event, id: ActivityID(rawValue: "B"), at: 1).carriesNoMeaning)      // nothing attached yet
    var withPeople = Activity.materialized(from: event, id: ActivityID(rawValue: "C"), at: 1)
    withPeople.participants = [ParticipantAssignment(personID: pid("friend"), provenance: userProvenance())]
    #expect(withPeople.carriesNoMeaning == false)                                // participants are meaning worth keeping
}

@Test func lifeStateWithAllTheNewPiecesRoundTripsThroughCodable() throws {
    let a = ActivityID(rawValue: "A")
    let life = try lifeWithPeople(["friend"], extra: activities(["A"]) + [
        allocation("tx", to: "A", amount: amountRange(10_000, 20_000), of: 50_000),
        allocation("tx", to: nil, amount: .estimated(5_000), of: 50_000),
        .addParticipant(a, ParticipantAssignment(personID: pid("friend"), provenance: userProvenance())),
        .createObligation(obligation("o1", .payable, .unknown, activity: "A")),
        .createObligation(obligation("o2", .receivable, .exact(7_000), activity: "A")),
        .defineAmountGroup(try AmountGroup(
            id: AmountGroupID(rawValue: "g"), total: entry(.exact(20_000)),
            members: [.obligation(oid("o1")), .allocation(allocationID("tx", "A"))], createdAtUnixMilliseconds: 1
        ))
    ])
    let data = try JSONEncoder().encode(LifeSnapshot(revision: 3, state: life))
    #expect(try JSONDecoder().decode(LifeSnapshot.self, from: data).state == life)
}
