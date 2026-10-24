import Testing
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryCalendar

private let eA = event("eA", title: "지난주 술자리", from: at(today.adding(days: -7), 20), to: at(today.adding(days: -7), 23))
private let eB = event("eB", title: "농구 대관", from: at(today, 18), to: at(today, 20))
private let eC = event("eC", title: "여행", from: at(today.adding(days: 3), 9), to: at(today.adding(days: 3), 18))
private let kA = key("life", "eA"), kB = key("life", "eB"), kC = key("life", "eC")

private func harness(life: LifeState = .empty) -> Harness {
    Harness.make(
        events: [eA, eB, eC],
        transactions: [
            marker("tx80", at: at(today, 10), amount: 80_000, title: "송금"),
            marker("tx50", at: at(today, 11), amount: 50_000, title: "결제"),
            marker("tx10", at: at(today, 12), amount: 10_000, title: "작은 결제")
        ],
        life: life
    )
}

private func part(_ key: CalendarEventKey, _ amount: AmountKnowledge) -> AllocationPartInput {
    AllocationPartInput(target: .activity(.event(key)), amount: amount)
}

private func set(_ transaction: String, _ parts: [AllocationPartInput], by provenance: AssignmentProvenance = userProvenance()) -> CalendarCommand {
    .setAllocations(SetAllocationsInput(transactionID: txID(transaction), parts: parts, provenance: provenance))
}

private func applied(_ outcome: CalendarCommandOutcome) -> AppliedCommand? {
    if case let .applied(value) = outcome { return value }
    return nil
}

@Test func scenarioD_oneTransferIsSplitAcrossThreeActivitiesThroughTheService() async throws {
    // 80,000원 송금: 30,000 → 지난주 술자리, 25,000 → 농구 대관비, 25,000 → 여행 숙박비
    let h = harness()
    let outcome = await h.service.perform(set("tx80", [part(kA, .exact(30_000)), part(kB, .exact(25_000)), part(kC, .exact(25_000))]))
    let result = try #require(applied(outcome))
    #expect(result.allocationIDs.count == 3)
    let life = await h.life()
    let allocations = try #require(life.allocationSet(for: txID("tx80")))
    #expect(allocations.isFullyAllocated && allocations.allocations.count == 3)
    #expect(life.activities.count == 3)                                              // each activity was created lazily
    #expect(life.allocations(forActivity: try #require(life.activity(forEvent: kB)?.id)).first?.amount.knowledge == .exact(25_000))
}

@Test func theTransactionTimeNeedNotLieInsideTheActivity() async throws {
    // tx80 happened today at 10:00; "지난주 술자리" was a week ago and "여행" is in three days.
    let h = harness()
    _ = await h.service.perform(set("tx80", [part(kA, .exact(40_000)), part(kC, .exact(40_000))]))
    #expect((await h.life()).allocationSet(for: txID("tx80"))?.allocations.count == 2)
    let timeline = try await h.service.dayTimeline(for: today.adding(days: -7))
    let block = try #require(timeline.blocks.first { $0.title == "지난주 술자리" })
    #expect(block.allocations.first?.occursOnSelectedDay == false)
    #expect(block.allocatedSpend.first?.exactMinorUnits == 40_000)
}

@Test func replacingTheDivisionReusesAllocationsAndReleasesTheOthers() async throws {
    let h = harness()
    let first = try #require(applied(await h.service.perform(set("tx80", [part(kA, .exact(30_000)), part(kB, .exact(25_000)), part(kC, .exact(25_000))]))))
    let beforeLife = await h.life()
    let aID = try #require(beforeLife.activity(forEvent: kA)?.id)
    let originalA = try #require(beforeLife.allocations(forActivity: aID).first?.id)

    _ = await h.service.perform(set("tx80", [part(kA, .exact(50_000)), part(kB, .exact(30_000))]))
    let life = await h.life()
    #expect(life.allocationSet(for: txID("tx80"))?.allocations.count == 2)
    #expect(life.allocations(forActivity: aID).first?.id == originalA)                // same portion, updated
    #expect(life.allocations(forActivity: aID).first?.amount.knowledge == .exact(50_000))
    let cID = try #require(life.activity(forEvent: kC)?.id)
    #expect(life.allocations(forActivity: cID).isEmpty)                               // released, but the activity remains
    #expect(first.allocationIDs.count == 3)
}

@Test func scenarioE_aPartialAllocationLeavesTheRestUnallocated() async throws {
    // 50,000원 거래: 30,000 → Activity A, 20,000 → 아직 배분 안 됨
    let h = harness()
    _ = await h.service.perform(set("tx50", [part(kA, .exact(30_000))]))
    let set = try #require((await h.life()).allocationSet(for: txID("tx50")))
    #expect(set.knownRemainderMinorUnits == 20_000 && !set.isFullyAllocated)
}

@Test func exceedingTheTransactionIsRejectedAndNothingChanges() async throws {
    let h = harness()
    let outcome = await h.service.perform(set("tx80", [part(kA, .exact(30_000)), part(kB, .exact(25_000)), part(kC, .exact(30_000))]))
    #expect(outcome == .rejected(.lifeValidation(.allocationExceedsTransaction(txID("tx80")))))
    let snapshot = try await h.service.lifeSnapshot()
    #expect(snapshot.revision == 0 && snapshot.state.activities.isEmpty && snapshot.state.allocationSets.isEmpty)   // atomic: the lazily created activities are not left behind
}

@Test func aPortionCanBeUnknownOrDeliberatelyOutsideAnyActivity() async throws {
    let h = harness()
    let outcome = await h.service.perform(set("tx80", [
        part(kA, .unknown),
        AllocationPartInput(target: .nonActivity, amount: .exact(20_000)),
        part(kB, amountRange(10_000, 30_000))
    ]))
    #expect(applied(outcome) != nil)
    let life = await h.life()
    let allocations = try #require(life.allocationSet(for: txID("tx80")))
    #expect(allocations.allocations.contains { $0.activityID == nil && $0.amount.knowledge == .exact(20_000) })
    #expect(allocations.remainder == AmountBounds(lower: 0, upper: 50_000))              // 80,000 minus the settled lowers (20,000 + 10,000); unknown A leaves no floor
    #expect(allocations.knownRemainderMinorUnits == nil)
}

@Test func automationNeverReplacesAUsersDivisionAndWeakSuggestionsAreNotStored() async throws {
    let h = harness()
    _ = await h.service.perform(set("tx80", [part(kA, .exact(30_000)), part(kB, .exact(50_000))]))
    let before = try await h.service.lifeSnapshot()
    let suggestion = set("tx80", [part(kC, .exact(80_000))], by: autoProvenance(0.95))
    #expect(await h.service.perform(suggestion) == .rejected(.userAssignmentProtected))
    #expect(try await h.service.lifeSnapshot() == before)                              // nothing changed, including no new activity for C
    #expect(await h.service.perform(set("tx80", [part(kC, .exact(80_000))], by: autoProvenance(0.4))) == .rejected(.provenanceRejected))
    // For a transaction nobody has divided yet, the same suggestion is allowed.
    #expect(applied(await h.service.perform(set("tx50", [part(kC, .exact(50_000))], by: autoProvenance(0.95)))) != nil)
}

@Test func invalidAmountsAndUnknownTransactionsAreRefused() async {
    let h = harness()
    #expect(await h.service.perform(set("tx80", [part(kA, .exact(0))])) == .rejected(.invalidAmount(.nonPositiveAmount)))
    #expect(await h.service.perform(set("ghost", [part(kA, .exact(1))])) == .rejected(.transactionNotFound))
    #expect(await h.service.perform(set("tx80", [part(key("life", "nope"), .exact(1))])) == .rejected(.eventNotFound))
    #expect(await h.service.perform(set("tx80", [part(kA, .exact(5_000)), part(kA, .exact(5_000))])) == .rejected(.lifeValidation(.duplicateAllocationTarget(txID("tx80")))))
}

@Test func repeatingTheSameDivisionChangesNothing() async throws {
    let h = harness()
    let command = set("tx80", [part(kA, .exact(30_000)), part(kB, .exact(50_000))])
    let first = try #require(applied(await h.service.perform(command)))
    let again = try #require(applied(await h.service.perform(command)))
    #expect(first.allocationIDs.sorted() == again.allocationIDs.sorted())
    #expect(try await h.service.lifeSnapshot().revision == 1)                          // the second call wrote nothing
}

@Test func anExistingPortionMayStayOnAnActivityWhoseEventIsGoneButNewOnesMayNot() async throws {
    let h = harness()
    _ = await h.service.perform(set("tx50", [part(kA, .exact(30_000))]))
    _ = await h.service.perform(.deleteEvent(DeleteEventInput(target: EventTarget(key: kA))))
    // The same single portion stays valid; refreshing it is a no-op.
    #expect(applied(await h.service.perform(set("tx50", [part(kA, .exact(30_000))]))) != nil)
    // But a different transaction cannot be newly assigned to a vanished event.
    #expect(await h.service.perform(set("tx10", [part(kA, .exact(10_000))])) == .rejected(.activityEventMissing))
}

@Test func linkingTheWholeTransactionReplacesASplitAndUnlinkingClearsEverything() async throws {
    let h = harness()
    _ = await h.service.perform(set("tx80", [part(kA, .exact(30_000)), part(kB, .exact(50_000))]))
    _ = await h.service.perform(.linkTransaction(LinkTransactionInput(transactionID: txID("tx80"), target: .event(kC), provenance: userProvenance())))
    var life = await h.life()
    let set = try #require(life.allocationSet(for: txID("tx80")))
    #expect(set.allocations.count == 1 && set.allocations[0].amount.knowledge == .exact(80_000))
    #expect(life.activity(forEvent: kC).map { set.allocations[0].activityID == $0.id } == true)
    _ = await h.service.perform(.unlinkTransaction(UnlinkTransactionInput(transactionID: txID("tx80"), by: userProvenance())))
    life = await h.life()
    #expect(life.allocationSet(for: txID("tx80")) == nil)
}

@Test func allocationsToAnExistingActivityCanBeAddressedByActivityID() async throws {
    let h = harness()
    let id = try #require(applied(await h.service.perform(set("tx50", [part(kA, .exact(10_000))])))?.activityID)
    let outcome = await h.service.perform(set("tx80", [AllocationPartInput(target: .activity(.activity(id)), amount: .exact(80_000))]))
    #expect(applied(outcome)?.activityID == id)
    #expect((await h.life()).allocations(forActivity: id).count == 2)
    #expect(await h.service.perform(set("tx10", [AllocationPartInput(target: .activity(.activity(ActivityID(rawValue: "ghost"))), amount: .exact(1))])) == .rejected(.activityNotFound))
}
