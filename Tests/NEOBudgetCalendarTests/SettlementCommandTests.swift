import Testing
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryCalendar

private let dateEvent = event("date", title: "성수 데이트", from: at(today, 12), to: at(today, 20))
private let dateKey = key("life", "date")

/// People known to the user: me (self) and a friend, ready for commands.
private func peopleLife() -> LifeState { lifeWithPeople(["friend", "other"]) }

private func harness(life: LifeState? = nil) -> Harness {
    Harness.make(events: [dateEvent], transactions: [marker("movie-ticket", at: at(today, 13), amount: 14_000, title: "영화")], life: life ?? peopleLife())
}

private func create(
    _ direction: ObligationDirection, _ amount: AmountKnowledge, with person: String = "friend",
    activity: ActivityTarget? = nil, provenance: AssignmentProvenance = userProvenance(), label: String? = nil
) -> CalendarCommand {
    .createObligation(CreateObligationInput(counterpartyID: pid(person), activity: activity, direction: direction, currency: "KRW", amount: amount, label: label, provenance: provenance))
}

private func applied(_ outcome: CalendarCommandOutcome) -> AppliedCommand? {
    if case let .applied(value) = outcome { return value }
    return nil
}

private func obligationID(_ outcome: CalendarCommandOutcome) throws -> ObligationID {
    try #require(applied(outcome)?.obligationID)
}

// MARK: Creating and refining obligations

@Test func anObligationCanBeCreatedForAnActivityWithoutAnyTransaction() async throws {
    let h = harness()
    let id = try obligationID(await h.service.perform(create(.payable, .unknown, activity: .event(dateKey), label: "점심")))
    let life = await h.life()
    let obligation = try #require(life.obligations[id])
    #expect(obligation.label == "점심" && obligation.amount.knowledge == .unknown && obligation.status == .open)
    #expect(life.activity(forEvent: dateKey)?.id == obligation.activityID)           // the activity was created lazily for it
    #expect(life.allocationSets.isEmpty)                                            // still no transaction involved
}

@Test func obligationCommandsRejectBadInput() async {
    let h = harness()
    #expect(await h.service.perform(create(.payable, .exact(5_000), with: "ghost")) == .rejected(.lifeValidation(.unknownPerson(pid("ghost")))))
    #expect(await h.service.perform(create(.payable, .exact(5_000), with: "me")) == .rejected(.lifeValidation(.counterpartyIsSelf(myself))))
    #expect(await h.service.perform(create(.payable, .exact(0))) == .rejected(.invalidAmount(.nonPositiveAmount)))
    #expect(await h.service.perform(create(.payable, .estimated(5_000), provenance: autoProvenance(0.3))) == .rejected(.provenanceRejected))
    #expect(await h.service.perform(create(.payable, .exact(5_000), activity: .event(key("life", "nope")))) == .rejected(.eventNotFound))
}

@Test func anAutomaticInferenceCanPromoteButNeverOverwriteAUserConfirmedAmount() async throws {
    let h = harness()
    let id = try obligationID(await h.service.perform(create(.payable, .unknown)))
    let auto = autoProvenance(1.0)
    let set = { (amount: AmountKnowledge, by: AssignmentProvenance) in
        await h.service.perform(.setObligationAmount(SetObligationAmountInput(obligationID: id, amount: amount, provenance: by)))
    }
    #expect(applied(await set(inferred(6_000), auto)) != nil)
    #expect(applied(await set(.exact(6_500), userProvenance(9))) != nil)              // the user confirms
    #expect(await set(inferred(7_000), auto) == .rejected(.lifeValidation(.amountUpdateRejected(.rejectedProtectedUserAmount))))
    #expect((await h.life()).obligations[id]?.amount.knowledge == .exact(6_500))
    #expect(await h.service.perform(.setObligationAmount(SetObligationAmountInput(obligationID: oid("ghost"), amount: .exact(1), provenance: userProvenance()))) == .rejected(.lifeValidation(.unknownObligation(oid("ghost")))))
}

@Test func cancellingAnObligationThroughTheService() async throws {
    let h = harness()
    let id = try obligationID(await h.service.perform(create(.receivable, .exact(5_000))))
    #expect(await h.service.perform(.cancelObligation(CancelObligationInput(obligationID: id, by: autoProvenance(0.99)))) == .rejected(.userAssignmentProtected))
    #expect(applied(await h.service.perform(.cancelObligation(CancelObligationInput(obligationID: id, by: userProvenance())))) != nil)
    #expect((await h.life()).obligations[id]?.status == .cancelled)
}

// MARK: Group constraints through the service

@Test func aGroupIsResolvedAutomaticallyOnlyWhenOneMemberIsLeft() async throws {
    let h = harness()
    var ids: [ObligationID] = []
    for label in ["lunch", "cafe", "taxi"] { ids.append(try obligationID(await h.service.perform(create(.payable, .unknown, label: label)))) }
    let defined = await h.service.perform(.defineAmountGroup(DefineAmountGroupInput(
        members: ids.map { .obligation($0) }, currency: "KRW", total: .exact(31_000), provenance: userProvenance()
    )))
    let groupID = try #require(applied(defined)?.amountGroupID)

    // Three unknown shares: the constraint stays, nothing is guessed.
    #expect(await h.service.perform(.resolveAmountGroup(groupID)) == .rejected(.amountGroupNotUniquelySolvable))
    #expect((await h.life()).obligations.values.allSatisfy { $0.amount.knowledge == .unknown })

    for (id, amount) in [(ids[0], Int64(12_000)), (ids[1], 7_000)] {
        _ = await h.service.perform(.setObligationAmount(SetObligationAmountInput(obligationID: id, amount: .exact(amount), provenance: userProvenance())))
    }
    #expect(applied(await h.service.perform(.resolveAmountGroup(groupID))) != nil)
    let taxi = try #require((await h.life()).obligations[ids[2]])
    guard case let .inferred(value, evidence) = taxi.amount.knowledge else {
        Issue.record("expected an inferred amount, got \(taxi.amount.knowledge)")
        return
    }
    #expect(value == 12_000 && evidence.amountGroupID == groupID)
    #expect(taxi.amount.provenance.source == .automated && taxi.amount.knowledge != .exact(12_000))
    #expect(applied(await h.service.perform(.resolveAmountGroup(groupID))) != nil)    // already satisfied: nothing more to do
}

@Test func aGroupResolutionNeverOverridesAUserSetMember() async throws {
    let h = harness()
    let a = try obligationID(await h.service.perform(create(.payable, .unknown)))
    let b = try obligationID(await h.service.perform(create(.payable, .exact(4_000))))
    let groupID = try #require(applied(await h.service.perform(.defineAmountGroup(DefineAmountGroupInput(
        members: [.obligation(a), .obligation(b)], currency: "KRW", total: .exact(10_000), provenance: userProvenance()
    ))))?.amountGroupID)
    _ = await h.service.perform(.resolveAmountGroup(groupID))
    #expect((await h.life()).obligations[b]?.amount.knowledge == .exact(4_000))           // the user's exact member is untouched
    #expect((await h.life()).obligations[a]?.amount.knowledge.knownValue == 6_000)
}

@Test func groupCommandsRejectInvalidGroups() async throws {
    let h = harness()
    let a = try obligationID(await h.service.perform(create(.payable, .unknown)))
    let b = try obligationID(await h.service.perform(create(.payable, .unknown)))
    let define = { (members: [AmountMemberRef], total: AmountKnowledge) in
        await h.service.perform(.defineAmountGroup(DefineAmountGroupInput(members: members, currency: "KRW", total: total, provenance: userProvenance())))
    }
    #expect(await define([.obligation(a)], .exact(1_000)) == .rejected(.invalidAmountGroup(.tooFewMembers)))
    #expect(await define([.obligation(a), .obligation(b)], .unknown) == .rejected(.invalidAmountGroup(.totalNotKnown)))
    #expect(await define([.obligation(a), .obligation(b)], .estimated(5_000)) == .rejected(.invalidAmountGroup(.totalNotKnown)))
    #expect(await define([.obligation(a), .obligation(oid("ghost"))], .exact(1_000)) == .rejected(.lifeValidation(.unknownGroupMember(.obligation(oid("ghost"))))))
    #expect(await h.service.perform(.resolveAmountGroup(AmountGroupID(rawValue: "ghost"))) == .rejected(.lifeValidation(.unknownAmountGroup(AmountGroupID(rawValue: "ghost")))))
}

// MARK: Settlement through the service

private func upsertPerson(_ h: Harness, _ person: Person) async { _ = await h.service.perform(.upsertPerson(person)) }

@Test func aNetTransferWithOneUnknownIsInferredAndSettledEndToEnd() async throws {
    let h = harness()
    let receivable = try obligationID(await h.service.perform(create(.receivable, .exact(30_000))))
    let payable = try obligationID(await h.service.perform(create(.payable, .unknown)))

    let incoming = transfer("deposit", .incoming, 18_000)
    let match = try await h.service.matchSettlement(incoming)
    guard case let .inferredUniqueSolution(proposal) = match else {
        Issue.record("expected an inferred unique solution, got \(match)")
        return
    }
    let outcome = await h.service.perform(.applySettlement(ApplySettlementInput(proposal: proposal, provenance: userProvenance())))
    let settlementID = try #require(applied(outcome)?.settlementID)
    let life = await h.life()
    #expect(life.obligations[receivable]?.status == .settled && life.obligations[payable]?.status == .settled)
    guard case let .inferred(value, evidence) = life.obligations[payable]?.amount.knowledge else {
        Issue.record("expected inferred")
        return
    }
    #expect(value == 12_000 && evidence.settlementID == settlementID)
    // Applying the same proposal again is refused: that transfer is already used.
    #expect(await h.service.perform(.applySettlement(ApplySettlementInput(proposal: proposal, provenance: userProvenance()))) .isRejected)
    #expect(try await h.service.matchSettlement(incoming) == .noMatch(.transferAlreadySettled))
}

@Test func anAmbiguousMatchIsNeverAppliedAutomaticallyButTheUserCanDecide() async throws {
    // Scenario C: 받을 돈 30,000, 줄 돈 X와 Y는 미상, 실제 입금 18,000.
    let h = harness()
    let recv = try obligationID(await h.service.perform(create(.receivable, .exact(30_000))))
    let x = try obligationID(await h.service.perform(create(.payable, .unknown, label: "X")))
    let y = try obligationID(await h.service.perform(create(.payable, .unknown, label: "Y")))
    let incoming = transfer("deposit", .incoming, 18_000)

    let match = try await h.service.matchSettlement(incoming)
    guard case let .ambiguous(report) = match else {
        Issue.record("expected ambiguous, got \(match)")
        return
    }
    #expect(report.constraint?.totalMinorUnits == 12_000)
    #expect(match.proposal == nil)                                                   // there is nothing to apply automatically
    #expect((await h.life()).obligations.values.allSatisfy { $0.status == .open })

    // A wrong manual split that does not net to the transfer is refused.
    let wrong = ManualSettlementInput(
        transfer: incoming,
        applications: [ProposedApplication(obligationID: recv, appliedMinorUnits: 30_000), ProposedApplication(obligationID: x, appliedMinorUnits: 5_000)],
        confirmedAmounts: [x: 5_000], provenance: userProvenance()
    )
    #expect(await h.service.perform(.recordManualSettlement(wrong)) == .rejected(.lifeValidation(.settlementNetMismatch)))

    // The user states X = 5,000 and Y = 7,000 exactly.
    let manual = ManualSettlementInput(
        transfer: incoming,
        applications: [
            ProposedApplication(obligationID: recv, appliedMinorUnits: 30_000),
            ProposedApplication(obligationID: x, appliedMinorUnits: 5_000),
            ProposedApplication(obligationID: y, appliedMinorUnits: 7_000)
        ],
        confirmedAmounts: [x: 5_000, y: 7_000], provenance: userProvenance()
    )
    #expect(applied(await h.service.perform(.recordManualSettlement(manual)))?.settlementID != nil)
    let life = await h.life()
    #expect(life.obligations.values.allSatisfy { $0.status == .settled })
    #expect(life.obligations[x]?.amount.knowledge == .exact(5_000) && life.obligations[y]?.amount.knowledge == .exact(7_000))   // the user's word is exact
}

@Test func scenarioA_aDateIsSettledAndTheLunchShareIsInferredFromTheRequest() async throws {
    // 성수 데이트: 나, 상대방. 점심은 상대가 결제(내 부담금 미상), 영화는 내가 결제(상대 7,000), 카페는 상대가 결제(내 부담금 6,000).
    let h = harness()
    for target in [ParticipantInput(activity: .event(dateKey), personID: myself, provenance: userProvenance()),
                   ParticipantInput(activity: .event(dateKey), personID: pid("friend"), provenance: userProvenance())] {
        #expect(applied(await h.service.perform(.addParticipant(target))) != nil)
    }
    let date: ActivityTarget = .event(dateKey)
    let lunch = try obligationID(await h.service.perform(create(.payable, .unknown, activity: date, label: "점심")))
    let movie = try obligationID(await h.service.perform(create(.receivable, .exact(7_000), activity: date, label: "영화")))
    let cafe = try obligationID(await h.service.perform(create(.payable, .exact(6_000), activity: date, label: "카페")))

    var timeline = try await h.service.dayTimeline(for: today)
    #expect(timeline.blocks.first?.activity?.openObligationCount == 3)
    #expect(timeline.blocks.first?.activity?.participantIDs == [pid("friend"), myself])

    let outgoing = transfer("my-payment", .outgoing, 5_000)
    guard case .ambiguous = try await h.service.matchSettlement(outgoing) else {
        Issue.record("without a request the data fit several explanations")
        return
    }
    let requested = applied(await h.service.perform(.createSettlementRequest(CreateSettlementRequestInput(counterpartyID: pid("friend"), obligationIDs: [lunch, movie, cafe]))))
    let requestID = try #require(requested?.settlementRequestID)
    let match = try await h.service.matchSettlement(outgoing, requestID: requestID)
    guard case let .inferredUniqueSolution(proposal) = match else {
        Issue.record("expected the request to make it unique, got \(match)")
        return
    }
    #expect(proposal.inferences == [ProposedInference(obligationID: lunch, minorUnits: 6_000)])
    #expect(applied(await h.service.perform(.applySettlement(ApplySettlementInput(proposal: proposal, provenance: userProvenance())))) != nil)

    let life = await h.life()
    #expect(life.obligations.values.allSatisfy { $0.status == .settled })
    #expect(life.settlementRequests[requestID]?.status == .fulfilled)
    #expect(life.obligations[lunch]?.amount.knowledge.knownValue == 6_000)
    timeline = try await h.service.dayTimeline(for: today)
    #expect(timeline.blocks.first?.activity?.openObligationCount == 0)
}

@Test func requestsAreCheckedAgainstTheirCounterpartyAndObligations() async throws {
    let h = harness()
    let mine = try obligationID(await h.service.perform(create(.receivable, .exact(5_000), with: "friend")))
    let theirs = try obligationID(await h.service.perform(create(.receivable, .exact(5_000), with: "other")))
    let wrong = await h.service.perform(.createSettlementRequest(CreateSettlementRequestInput(counterpartyID: pid("friend"), obligationIDs: [mine, theirs])))
    #expect(wrong == .rejected(.lifeValidation(.obligationCounterpartyMismatch(theirs))))
    #expect(await h.service.perform(.createSettlementRequest(CreateSettlementRequestInput(counterpartyID: pid("friend"), obligationIDs: []))) == .rejected(.invalidSettlement(.emptyObligationList)))
}

@Test func aStaleProposalIsRefusedWhenTheObligationsChangedAfterMatching() async throws {
    let h = harness()
    let id = try obligationID(await h.service.perform(create(.receivable, .exact(5_000))))
    let proposal = try #require(try await h.service.matchSettlement(transfer("t", .incoming, 5_000)).proposal)
    _ = await h.service.perform(.cancelObligation(CancelObligationInput(obligationID: id, by: userProvenance())))
    #expect(await h.service.perform(.applySettlement(ApplySettlementInput(proposal: proposal, provenance: userProvenance()))) == .rejected(.lifeValidation(.obligationNotSettleable(id))))
}

@Test func removingASettlementReopensEverythingItClosed() async throws {
    let h = harness()
    let recv = try obligationID(await h.service.perform(create(.receivable, .exact(30_000))))
    let pay = try obligationID(await h.service.perform(create(.payable, .unknown)))
    let proposal = try #require(try await h.service.matchSettlement(transfer("t", .incoming, 18_000)).proposal)
    let settlementID = try #require(applied(await h.service.perform(.applySettlement(ApplySettlementInput(proposal: proposal, provenance: userProvenance()))))?.settlementID)
    #expect(await h.service.perform(.removeSettlement(RemoveSettlementInput(settlementID: settlementID, by: autoProvenance(0.99)))) == .rejected(.userAssignmentProtected))
    #expect(applied(await h.service.perform(.removeSettlement(RemoveSettlementInput(settlementID: settlementID, by: userProvenance())))) != nil)
    let life = await h.life()
    #expect(life.obligations[recv]?.status == .open && life.obligations[pay]?.status == .open)
    #expect(life.obligations[pay]?.amount.knowledge == .unknown)
    #expect(life.settlements.isEmpty)
}

// MARK: People

@Test func peopleAndRelationshipLabelsThroughTheService() async throws {
    let h = Harness.make(life: .empty)
    let friend = Person(id: pid("g"), displayName: "홍길동", relationshipLabel: Assigned("친구", provenance: userProvenance()))
    #expect(applied(await h.service.perform(.upsertPerson(friend))) != nil)
    let guessed = Person(id: pid("h"), displayName: "홍길순", relationshipLabel: Assigned("연인", provenance: autoProvenance(0.99)))
    #expect(await h.service.perform(.upsertPerson(guessed)) == .rejected(.lifeValidation(.relationshipLabelRequiresUser)))
    #expect((await h.life()).persons[pid("g")]?.relationshipLabel?.value == "친구")
    #expect((await h.life()).persons[pid("h")] == nil)
}

@Test func participantsAreAddedRemovedAndProtectedLikeEveryOtherAssignment() async throws {
    let h = harness()
    let add = { (person: String, by: AssignmentProvenance) in
        await h.service.perform(.addParticipant(ParticipantInput(activity: .event(dateKey), personID: pid(person), provenance: by)))
    }
    #expect(applied(await add("friend", userProvenance())) != nil)
    #expect(await add("ghost", userProvenance()) == .rejected(.lifeValidation(.unknownPerson(pid("ghost")))))
    #expect(await add("friend", autoProvenance(0.95)) == .rejected(.userAssignmentProtected))
    #expect(await add("other", autoProvenance(0.2)) == .rejected(.provenanceRejected))
    let remove = { (by: AssignmentProvenance) in
        await h.service.perform(.removeParticipant(ParticipantInput(activity: .event(dateKey), personID: pid("friend"), provenance: by)))
    }
    #expect(await remove(autoProvenance(0.99)) == .rejected(.userAssignmentProtected))
    #expect(applied(await remove(userProvenance())) != nil)
    #expect((await h.life()).activities.values.first?.participants.isEmpty == true)
}

@Test func theServiceRecommendsParticipantsFromPastGatherings() async throws {
    var changes: [LifeChange] = [.upsertPerson(person("A")), .upsertPerson(person("B")), .upsertPerson(person("C")), .upsertPerson(person("D"))]
    for index in 0..<3 {
        let start = at(today, 12) - Int64(index + 2) * 86_400_000
        changes.append(.createActivity(Activity(
            id: ActivityID(rawValue: "g\(index)"),
            origin: .standalone(StandaloneActivityInfo(title: "g\(index)", time: .timed(timed(start, start + 3_600_000)))),
            participants: ["me", "A", "B", "C"].map { ParticipantAssignment(personID: pid($0), provenance: userProvenance()) },
            createdAtUnixMilliseconds: 1
        )))
    }
    let h = Harness.make(life: lifeWithPeople([], extra: changes))
    let recommended = try await h.service.recommendParticipants(given: [pid("A")])
    #expect(Set(recommended.map(\.personID)) == [pid("B"), pid("C")])
    #expect(!recommended.contains { $0.personID == pid("D") })
}

private extension CalendarCommandOutcome {
    var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }
}
