import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private func failure(_ block: () throws -> Void) -> LifeValidationError? {
    do { try block(); return nil } catch let error as LifeValidationError { return error } catch { return nil }
}

private let gid = AmountGroupID(rawValue: "g")

private func group(_ total: AmountEntry, _ members: [AmountMemberRef], id: String = "g") -> AmountGroup {
    try! AmountGroup(id: AmountGroupID(rawValue: id), total: total, members: members, createdAtUnixMilliseconds: 1)
}

// MARK: Group constraints in state

@Test func aDateSettlementKeepsItsTotalWhileTheSharesAreStillUnknown() throws {
    // 데이트 정산 총액 = 31,000. 점심 / 카페 / 택시 금액은 모두 모른다.
    let life = lifeWithPeople(["friend"], extra: [
        .createObligation(obligation("lunch", .payable, .unknown)),
        .createObligation(obligation("cafe", .payable, .unknown)),
        .createObligation(obligation("taxi", .payable, .unknown)),
        .defineAmountGroup(group(entry(.exact(31_000)), [.obligation(oid("lunch")), .obligation(oid("cafe")), .obligation(oid("taxi"))]))
    ])
    guard case let .underdetermined(analysis) = life.analysis(ofGroup: gid) else {
        Issue.record("expected an unresolved group, not guessed shares")
        return
    }
    #expect(analysis.remainingMinorUnits == 31_000 && analysis.unresolved.count == 3)
    // Nothing has been assigned: the members are exactly as unknown as before.
    #expect(["lunch", "cafe", "taxi"].allSatisfy { life.obligations[oid($0)]?.amount.knowledge == .unknown })
    // New evidence narrows it, step by step, and the last share is finally forced.
    let afterLunch = try life.applying([.setObligationAmount(oid("lunch"), entry(.exact(12_000)))])
    if case .underdetermined(let narrowed) = afterLunch.analysis(ofGroup: gid) { #expect(narrowed.remainingMinorUnits == 19_000) } else { Issue.record("still two unknowns") }
    let afterCafe = try afterLunch.applying([.setObligationAmount(oid("cafe"), entry(.exact(7_000)))])
    #expect(afterCafe.analysis(ofGroup: gid) == .uniqueSolution(member: .obligation(oid("taxi")), minorUnits: 12_000))
}

@Test func theCompositeIsAnUnresolvedStateNeverACategory() {
    #expect(!ActivityTypeDefinition.presets.map(\.displayName).contains { $0.contains("복합") })
    let life = lifeWithPeople(["friend"], extra: [
        .createObligation(obligation("a", .payable, .unknown)),
        .createObligation(obligation("b", .payable, .unknown)),
        .defineAmountGroup(group(entry(.exact(10_000)), [.obligation(oid("a")), .obligation(oid("b"))]))
    ])
    // The group keeps the member references so a UI can say "외식 · 카페 · 택시, 세부 금액 미확인"; there is no category involved.
    #expect(life.amountGroups[gid]?.members.count == 2)
    #expect(CategoryAssignment.initial == .unclassified(.notYetEvaluated))
}

@Test func groupMembersAndTotalsAreValidatedWhenTheGroupIsDefined() throws {
    let base = lifeWithPeople(["friend"], extra: [
        .createObligation(obligation("a", .payable, .unknown)), .createObligation(obligation("b", .payable, .unknown)),
        .createObligation(obligation("usd", .payable, .unknown, currency: "USD")),
        .createObligation(obligation("big", .payable, .exact(40_000)))
    ])
    let members: [AmountMemberRef] = [.obligation(oid("a")), .obligation(oid("b"))]
    #expect(failure { _ = try base.applying([.defineAmountGroup(group(entry(.exact(10_000)), [.obligation(oid("a")), .obligation(oid("ghost"))]))]) } == .unknownGroupMember(.obligation(oid("ghost"))))
    #expect(failure { _ = try base.applying([.defineAmountGroup(group(entry(.exact(10_000)), [.obligation(oid("a")), .obligation(oid("usd"))]))]) } == .groupCurrencyMismatch(.obligation(oid("usd"))))
    // Already-known members that cannot add up to the total make the constraint impossible from the start.
    #expect(failure { _ = try base.applying([.defineAmountGroup(group(entry(.exact(10_000)), [.obligation(oid("big")), .obligation(oid("a"))]))]) } == .amountGroupContradiction(gid, .knownSumExceedsTotal))
    let defined = try base.applying([.defineAmountGroup(group(entry(.exact(10_000)), members))])
    #expect(failure { _ = try defined.applying([.defineAmountGroup(group(entry(.exact(5_000)), members, id: "g2"))]) } == .memberAlreadyInGroup(.obligation(oid("a"))))
    #expect(failure { _ = try defined.applying([.defineAmountGroup(group(entry(.exact(5_000)), members + [], id: "g"))]) } == .duplicateIdentifier(entity: "amountGroup", id: "g"))
}

@Test func aGroupProtectsItsMembersFromChangesThatWouldBreakIt() throws {
    let life = lifeWithPeople(["friend"], extra: [
        .createObligation(obligation("a", .payable, .unknown)), .createObligation(obligation("b", .payable, .unknown)),
        .defineAmountGroup(group(entry(.exact(10_000)), [.obligation(oid("a")), .obligation(oid("b"))]))
    ])
    #expect(failure { _ = try life.applying([.setObligationAmount(oid("a"), entry(.exact(11_000)))]) } == .amountGroupContradiction(gid, .knownSumExceedsTotal))
    #expect(failure { _ = try life.applying([.cancelObligation(oid("a"), by: userProvenance())]) } == .memberOfAmountGroup(.obligation(oid("a"))))
    let ok = try life.applying([.setObligationAmount(oid("a"), entry(.exact(4_000)))])
    #expect(ok.analysis(ofGroup: gid) == .uniqueSolution(member: .obligation(oid("b")), minorUnits: 6_000))
}

@Test func allocationsCanBeGroupedToo() throws {
    // 80,000원 거래를 세 활동에 나누되 각 금액은 아직 모르고, 합계만 80,000임을 안다.
    let events = ["A", "B", "C"].enumerated().map { index, id in
        LifeChange.createActivity(Activity.materialized(from: event("e-\(id)", from: at(today, 9 + index), to: at(today, 10 + index)), id: ActivityID(rawValue: id), at: 1))
    }
    let members = ["A", "B", "C"].map { AmountMemberRef.allocation(AllocationID(rawValue: "alloc-tx-\($0)")) }
    let life = try lifeWithPeople([], extra: events + ["A", "B", "C"].map { allocation("tx", to: $0, amount: .unknown, of: 80_000) } +
                                  [.defineAmountGroup(group(entry(.exact(80_000)), members))])
    guard case .underdetermined = life.analysis(ofGroup: gid) else { Issue.record("expected unresolved"); return }
    let learned = try life.applying([
        .setAllocationAmount(AllocationID(rawValue: "alloc-tx-A"), entry(.exact(30_000))),
        .setAllocationAmount(AllocationID(rawValue: "alloc-tx-B"), entry(.exact(25_000)))
    ])
    #expect(learned.analysis(ofGroup: gid) == .uniqueSolution(member: members[2], minorUnits: 25_000))
    #expect(failure { _ = try life.applying([.removeAllocation(AllocationID(rawValue: "alloc-tx-A"), by: userProvenance())]) } == .memberOfAmountGroup(members[0]))
}

@Test func aGroupCanBeRemovedOnlyByWhoMayReplaceIt() throws {
    let life = lifeWithPeople(["friend"], extra: [
        .createObligation(obligation("a", .payable, .unknown)), .createObligation(obligation("b", .payable, .unknown)),
        .defineAmountGroup(group(entry(.exact(10_000)), [.obligation(oid("a")), .obligation(oid("b"))]))
    ])
    #expect(failure { _ = try life.applying([.removeAmountGroup(gid, by: autoProvenance(0.99))]) } == .userAssignmentProtected)
    #expect(try life.applying([.removeAmountGroup(gid, by: userProvenance())]).amountGroups.isEmpty)
    #expect(failure { _ = try life.applying([.removeAmountGroup(AmountGroupID(rawValue: "ghost"), by: userProvenance())]) } == .unknownAmountGroup(AmountGroupID(rawValue: "ghost")))
}

// MARK: Participant affinity

private let now = at(today, 12)
private let day = 86_400_000 as Int64

/// A gathering `daysAgo` days before `now`, with the user and the given people.
private func gathering(_ id: String, _ people: [String], daysAgo: Int, type: ActivityTypeID? = nil) -> LifeChange {
    let start = now - Int64(daysAgo) * day
    return .createActivity(Activity(
        id: ActivityID(rawValue: id),
        origin: .standalone(StandaloneActivityInfo(title: id, time: .timed(timed(start, start + 3_600_000)))),
        activityType: type.map { Assigned($0, provenance: userProvenance()) },
        participants: (["me"] + people).map { ParticipantAssignment(personID: pid($0), provenance: userProvenance()) },
        createdAtUnixMilliseconds: 1
    ))
}

private func peopleChanges(_ ids: [String]) -> [LifeChange] { ids.map { .upsertPerson(person($0)) } }

@Test func scenarioF_smallRepeatedGroupsOutrankLargeGroupOnlyPeople() throws {
    let large = (1...25).map { "L\($0)" }
    var changes = peopleChanges(["A", "B", "C"] + large)
    changes += (0..<5).map { gathering("abc\($0)", ["A", "B", "C"], daysAgo: 10 + $0 * 10) }      // A + B + C, small group, repeated
    changes += (0..<3).map { gathering("ab\($0)", ["A", "B"], daysAgo: 15 + $0 * 10) }             // A + B, repeated
    changes += (0..<6).map { gathering("big\($0)", ["A"] + large, daysAgo: 5 + $0 * 12) }          // A + 25 others, large group
    let life = lifeWithPeople([], extra: changes)

    let ranked = ParticipantAffinityCalculator.recommend(given: [pid("A")], in: life, now: now, limit: 30)
    #expect(ranked.prefix(2).map(\.personID) == [pid("B"), pid("C")])
    let bScore = try #require(ranked.first { $0.personID == pid("B") }?.score)
    let cScore = try #require(ranked.first { $0.personID == pid("C") }?.score)
    let bestLarge = try #require(ranked.filter { $0.personID.rawValue.hasPrefix("L") }.map(\.score).max())
    #expect(bScore > cScore && cScore > bestLarge * 5)
    #expect(ranked.filter { $0.personID.rawValue.hasPrefix("L") }.count == 25)           // they appear, only far lower
    #expect(ranked.allSatisfy { $0.personID != pid("A") && $0.personID != myself })
}

@Test func threePeopleDiningEightTimesBeatThirtyPeopleInEightLectures() throws {
    var changes = peopleChanges(["X", "Y", "Z", "P", "Q"] + (1...28).map { "S\($0)" })
    changes += (0..<8).map { gathering("dinner\($0)", ["X", "Y", "Z"], daysAgo: 20 + $0, type: .social) }
    changes += (0..<8).map { gathering("lecture\($0)", ["P", "Q"] + (1...28).map { "S\($0)" }, daysAgo: 20 + $0, type: .study) }
    let life = lifeWithPeople([], extra: changes)
    let affinities = ParticipantAffinityCalculator.affinities(in: life, now: now)
    let dinner = try #require(affinities[PersonPair(pid("X"), pid("Y"))])
    let lecture = try #require(affinities[PersonPair(pid("P"), pid("Q"))])
    #expect(dinner.coOccurrenceCount == 8 && lecture.coOccurrenceCount == 8)             // the same raw count...
    #expect(dinner.weightedScore > lecture.weightedScore * 10)                           // ...but very different closeness
    #expect(dinner.commonActivityTypes == [.social: 8] && lecture.commonActivityTypes == [.study: 8])
}

@Test func recentGatheringsCountMoreThanOldOnes() throws {
    let life = lifeWithPeople([], extra: peopleChanges(["A", "B", "C", "D"]) + [
        gathering("recent", ["A", "B"], daysAgo: 1), gathering("old", ["C", "D"], daysAgo: 540)
    ])
    let affinities = ParticipantAffinityCalculator.affinities(in: life, now: now)
    let recent = try #require(affinities[PersonPair(pid("A"), pid("B"))])
    let old = try #require(affinities[PersonPair(pid("C"), pid("D"))])
    #expect(recent.weightedScore > old.weightedScore * 5)             // 540 days is three half-lives
    #expect(recent.lastTogetherUnixMilliseconds > old.lastTogetherUnixMilliseconds)
    let slower = ParticipantAffinityCalculator.affinities(in: life, now: now, configuration: AffinityConfiguration(recencyHalfLifeDays: 100_000))
    #expect(abs((slower[PersonPair(pid("C"), pid("D"))]?.weightedScore ?? 0) - 1.0) < 0.05)   // with almost no decay it is nearly 1
}

@Test func theUserAndLoneCompanionsNeverCreateAffinity() {
    let life = lifeWithPeople([], extra: peopleChanges(["A", "B"]) + [
        gathering("one-on-one", ["A"], daysAgo: 3),       // only me and A: no pair to learn
        gathering("pair", ["A", "B"], daysAgo: 4)
    ])
    let affinities = ParticipantAffinityCalculator.affinities(in: life, now: now)
    #expect(affinities.keys.sorted() == [PersonPair(pid("A"), pid("B"))])
    #expect(affinities.keys.allSatisfy { !$0.contains(myself) })
}

@Test func recommendationsExcludeChosenPeopleAndAreStableAndLimited() {
    let life = lifeWithPeople([], extra: peopleChanges(["A", "B", "C", "D"]) + [
        gathering("g1", ["A", "B", "C", "D"], daysAgo: 5), gathering("g2", ["A", "B", "C", "D"], daysAgo: 9)
    ])
    let all = ParticipantAffinityCalculator.recommend(given: [pid("A")], in: life, now: now)
    #expect(all.map(\.personID.rawValue) == ["B", "C", "D"])             // equal scores: ordered by id, never random
    #expect(ParticipantAffinityCalculator.recommend(given: [pid("A"), pid("B")], in: life, now: now).map(\.personID.rawValue) == ["C", "D"])
    #expect(ParticipantAffinityCalculator.recommend(given: [pid("A")], in: life, now: now, limit: 1).count == 1)
    #expect(ParticipantAffinityCalculator.recommend(given: [], in: life, now: now).isEmpty)
    #expect(ParticipantAffinityCalculator.recommend(given: [pid("A")], in: life, now: now, limit: 0).isEmpty)
    #expect(all.allSatisfy { $0.supportingPairs == 1 })
    let twoChosen = ParticipantAffinityCalculator.recommend(given: [pid("A"), pid("B")], in: life, now: now)
    #expect(twoChosen.allSatisfy { $0.supportingPairs == 2 } && twoChosen[0].score > all[0].score)
}

@Test func someoneNeverSeenWithTheChosenIsNotRecommended() {
    let life = lifeWithPeople([], extra: peopleChanges(["A", "B", "Loner"]) + [gathering("g", ["A", "B"], daysAgo: 2)])
    #expect(ParticipantAffinityCalculator.recommend(given: [pid("A")], in: life, now: now).map(\.personID.rawValue) == ["B"])
    #expect(ParticipantAffinityCalculator.recommend(given: [pid("Loner")], in: life, now: now).isEmpty)
}

@Test func affinityNeverInventsARelationshipLabel() {
    let life = lifeWithPeople([], extra: peopleChanges(["A", "B"]) + (0..<20).map { gathering("g\($0)", ["A", "B"], daysAgo: $0) })
    let affinity = ParticipantAffinityCalculator.affinities(in: life, now: now)[PersonPair(pid("A"), pid("B"))]
    #expect(affinity?.coOccurrenceCount == 20)                           // frequently together, and that is all that is said
    #expect(life.persons[pid("A")]?.relationshipLabel == nil && life.persons[pid("B")]?.relationshipLabel == nil)
}

@Test func affinityIsDeterministic() {
    let life = lifeWithPeople([], extra: peopleChanges(["A", "B", "C"]) + [gathering("g", ["A", "B", "C"], daysAgo: 7)])
    let first = ParticipantAffinityCalculator.recommend(given: [pid("A")], in: life, now: now)
    for _ in 0..<5 { #expect(ParticipantAffinityCalculator.recommend(given: [pid("A")], in: life, now: now) == first) }
}
