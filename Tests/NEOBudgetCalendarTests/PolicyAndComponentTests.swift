import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private func failure(_ block: () throws -> Void) -> LifeValidationError? {
    do { try block(); return nil } catch let error as LifeValidationError { return error } catch { return nil }
}

private let dinner = ActivityID(rawValue: "dinner")
private let dinnerEvent = event("dinner", title: "회식", from: at(today, 18), to: at(today, 23))
private let dinnerKey = key("life", "dinner")

/// Me, B, C, D, and a dinner activity that B, C and D attend (I am implicitly there too).
private func dinnerLife(participants: [String] = ["b", "c", "d"], extra: [LifeChange] = []) -> LifeState {
    var changes: [LifeChange] = [.createActivity(Activity.materialized(from: dinnerEvent, id: dinner, at: 1))]
    changes += participants.map { .addParticipant(dinner, ParticipantAssignment(personID: pid($0), provenance: userProvenance())) }
    return lifeWithPeople(["b", "c", "d"], extra: changes + extra)
}

private func component(
    _ id: String, _ amount: AmountKnowledge, payer: String = "me", participants: [String]? = nil, excluded: [String] = [],
    policy: SettlementPolicyOverride? = nil, category: CategoryAssignment = .initial, provenance: AssignmentProvenance = userProvenance()
) -> ExpenseComponent {
    ExpenseComponent(
        id: ExpenseComponentID(rawValue: id), activityID: dinner, label: id, amount: entry(amount), payerID: pid(payer),
        participants: participants.map { $0.map { pid($0) } }, excludedParticipants: excluded.map { pid($0) },
        policy: policy, category: category, provenance: provenance, createdAtUnixMilliseconds: 1
    )
}

private func cid(_ value: String) -> ExpenseComponentID { ExpenseComponentID(rawValue: value) }

private func rounding(_ mode: RoundingMode, _ unit: Int64) -> RoundingRule { try! RoundingRule(mode: mode, unitMinorUnits: unit) }

private func owed(_ derivation: ObligationDerivation) -> [String: Int64] {
    var result: [String: Int64] = [:]
    for draft in derivation.drafts { result[draft.counterpartyID.rawValue] = draft.amount.knownValue }
    return result
}

private func userPolicy(_ policy: SettlementPolicyOverride) -> Assigned<SettlementPolicyOverride> {
    Assigned(policy, provenance: userProvenance())
}

// MARK: Rounding and splitting arithmetic

@Test func roundingModesBehaveAsHabitsDo() {
    #expect(rounding(.exact, 1_000).apply(to: 23_700) == 23_700)
    #expect(rounding(.floor, 1_000).apply(to: 23_700) == 23_000)
    #expect(rounding(.ceil, 1_000).apply(to: 23_700) == 24_000)
    #expect(rounding(.nearest, 1_000).apply(to: 23_700) == 24_000)
    #expect(rounding(.nearest, 1_000).apply(to: 23_499) == 23_000)
    #expect(rounding(.nearest, 500).apply(to: 23_250) == 23_500)             // halves go up
    #expect(rounding(.floor, 500).apply(to: 23_700) == 23_500)
    #expect(rounding(.ceil, 100).apply(to: 23_000) == 23_000)                // already a multiple
    #expect(rounding(.floor, 1).apply(to: 23_701) == 23_701)
    #expect(RoundingRule.exact.apply(to: 23_701) == 23_701)
    #expect(throws: SettlementPolicyError.invalidRoundingUnit(0)) { _ = try RoundingRule(mode: .floor, unitMinorUnits: 0) }
}

@Test func anEqualSplitNeverLosesAMinorUnit() throws {
    let people = [pid("a"), pid("b"), pid("c")]
    let shares = try SplitCalculator.rawShares(total: 100_000, participants: people, rule: .equal)
    #expect(shares.values.reduce(0, +) == 100_000)
    #expect(shares[pid("a")] == 33_334 && shares[pid("b")] == 33_333 && shares[pid("c")] == 33_333)   // odd units to the earliest IDs
    #expect(try SplitCalculator.rawShares(total: 90_000, participants: people, rule: .equal).values.allSatisfy { $0 == 30_000 })
    #expect(throws: SettlementPolicyError.noParticipants) { _ = try SplitCalculator.rawShares(total: 1, participants: [], rule: .equal) }
}

@Test func weightedSplitsUseTheLargestRemainder() throws {
    let people = [pid("a"), pid("b")]
    let shares = try SplitCalculator.rawShares(total: 100, participants: people, rule: .weights([pid("a"): 1, pid("b"): 2]))
    #expect(shares[pid("a")] == 33 && shares[pid("b")] == 67)
    #expect(shares.values.reduce(0, +) == 100)
    #expect(throws: SettlementPolicyError.missingWeight(pid("b"))) {
        _ = try SplitCalculator.rawShares(total: 100, participants: people, rule: .weights([pid("a"): 1]))
    }
    #expect(throws: SettlementPolicyError.nonPositiveWeight(pid("a"))) {
        _ = try SplitCalculator.rawShares(total: 100, participants: people, rule: .weights([pid("a"): 0, pid("b"): 1]))
    }
    #expect(throws: SettlementPolicyError.weightForNonParticipant(pid("z"))) {
        _ = try SplitCalculator.rawShares(total: 100, participants: people, rule: .weights([pid("a"): 1, pid("b"): 1, pid("z"): 1]))
    }
}

@Test func fixedAmountsTakeTheirShareAndTheRestIsSplitEqually() throws {
    let people = [pid("a"), pid("b"), pid("c")]
    let shares = try SplitCalculator.rawShares(total: 100_000, participants: people, rule: .fixedAmounts([pid("c"): 20_000]))
    #expect(shares[pid("c")] == 20_000 && shares[pid("a")] == 40_000 && shares[pid("b")] == 40_000)
    #expect(throws: SettlementPolicyError.fixedAmountsExceedTotal) {
        _ = try SplitCalculator.rawShares(total: 10_000, participants: people, rule: .fixedAmounts([pid("c"): 20_000]))
    }
    #expect(throws: SettlementPolicyError.fixedAmountForNonParticipant(pid("z"))) {
        _ = try SplitCalculator.rawShares(total: 10_000, participants: people, rule: .fixedAmounts([pid("z"): 1_000]))
    }
    // When everyone is fixed, the fixed amounts must cover the total exactly.
    #expect(throws: SettlementPolicyError.fixedAmountsDoNotCoverTotal) {
        _ = try SplitCalculator.rawShares(total: 10_000, participants: [pid("a")], rule: .fixedAmounts([pid("a"): 9_000]))
    }
}

// MARK: Scenario J — a person's rounding habit

@Test func scenarioJRawShareAndRequestedShareAreBothKept() throws {
    // 47,400 dinner paid by me, split with my girlfriend: raw 23,700 each. She rounds down to 1,000.
    let life = try dinnerLife(participants: ["b"], extra: [
        .setSettlementPolicy(.person(pid("b")), userPolicy(SettlementPolicyOverride(rounding: rounding(.floor, 1_000)))),
        .upsertExpenseComponent(component("meal", .exact(47_400)))
    ])
    let derivation = try life.deriveObligations(forComponent: cid("meal"))
    let share = try #require(derivation.shares.share(of: pid("b")))
    #expect(share.rawMinorUnits == 23_700 && share.requestedMinorUnits == 23_000)
    #expect(share.roundingAdjustmentMinorUnits == -700)
    #expect(derivation.shares.roundingAbsorbedByPayerMinorUnits == 700)    // I bear the 700
    // My own share is never rounded: I do not ask myself for money.
    #expect(derivation.shares.share(of: myself)?.rawMinorUnits == 23_700 && derivation.shares.share(of: myself)?.requestedMinorUnits == 23_700)

    let draft = try #require(derivation.drafts.first)
    #expect(derivation.drafts.count == 1 && draft.direction == .receivable && draft.counterpartyID == pid("b"))
    #expect(draft.amount == .exact(23_000))
    #expect(draft.share.rawShareMinorUnits == 23_700 && draft.share.rounding == rounding(.floor, 1_000))
}

@Test func theObligationRemembersTheRawShareSoAnalysisIsNotDistorted() async throws {
    let life = try dinnerLife(participants: ["b"], extra: [
        .setSettlementPolicy(.person(pid("b")), userPolicy(SettlementPolicyOverride(rounding: rounding(.floor, 1_000)))),
        .upsertExpenseComponent(component("meal", .exact(47_400)))
    ])
    let h = Harness.make(events: [dinnerEvent], life: life)
    let outcome = await h.service.perform(.generateObligations(GenerateObligationsInput(componentID: cid("meal"), provenance: userProvenance())))
    guard case let .applied(applied) = outcome else {
        Issue.record("expected applied, got \(outcome)")
        return
    }
    let state = await h.life()
    let obligationID = try #require(applied.obligationIDs.first)
    let obligation = try #require(state.obligations[obligationID])
    #expect(obligation.amount.knowledge == .exact(23_000))                  // what was asked
    #expect(obligation.share?.rawShareMinorUnits == 23_700)                 // what it really cost her
    #expect(obligation.roundingAdjustmentMinorUnits == -700)
    #expect(obligation.componentID == cid("meal") && obligation.activityID == dinner && obligation.label == "meal")
    let summary = try #require(RoundingSummary.summarize(Array(state.obligations.values)).first)
    #expect(summary.rawShareMinorUnits == 23_700 && summary.requestedMinorUnits == 23_000 && summary.adjustmentMinorUnits == -700)

    // The 23,000 she actually sends settles it exactly; the 700 is not a shortfall because it was never asked.
    guard case let .exactMatch(proposal) = SettlementMatcher.match(transfer("t", "b", .incoming, 23_000), in: state) else {
        Issue.record("expected an exact match on the requested amount")
        return
    }
    let settled = try settle(state, proposal)
    #expect(settled.obligations[obligation.id]?.status == .settled && settled.residuals.isEmpty)
}

@Test func roundingUpAndDownDependOnThePersonNotTheDirection() throws {
    // C paid 30,100 and I owe C half: C's habit (ceil 1,000) applies to the amount I am asked for.
    let life = try dinnerLife(participants: ["c"], extra: [
        .setSettlementPolicy(.person(pid("c")), userPolicy(SettlementPolicyOverride(rounding: rounding(.ceil, 1_000)))),
        .upsertExpenseComponent(component("taxi", .exact(30_100), payer: "c"))
    ])
    let derivation = try life.deriveObligations(forComponent: cid("taxi"))
    let draft = try #require(derivation.drafts.first)
    #expect(draft.direction == .payable && draft.counterpartyID == pid("c"))
    #expect(draft.share.rawShareMinorUnits == 15_050 && draft.amount == .exact(16_000))
}

@Test func aShareThatRoundsToNothingCreatesNoObligationButStaysVisible() throws {
    let life = try dinnerLife(participants: ["b"], extra: [
        .setSettlementPolicy(.person(pid("b")), userPolicy(SettlementPolicyOverride(rounding: rounding(.floor, 1_000)))),
        .upsertExpenseComponent(component("gum", .exact(1_200)))
    ])
    let derivation = try life.deriveObligations(forComponent: cid("gum"))
    #expect(derivation.drafts.isEmpty && derivation.roundedToZero == [pid("b")])
    #expect(derivation.shares.share(of: pid("b"))?.rawMinorUnits == 600)
}

// MARK: Policy precedence

@Test func policiesResolveFromGlobalThroughPersonAndActivityToTheComponent() throws {
    let base = try dinnerLife(participants: ["b"], extra: [.upsertExpenseComponent(component("meal", .exact(10_000)))])
    let meal = try #require(base.components[cid("meal")])

    // Nothing stated: equal split, no rounding.
    #expect(base.effectivePolicy(for: meal, counterparty: pid("b")) == SettlementPolicy.default)

    // 1) global
    let globalOnly = try base.applying([.setSettlementPolicy(.global, userPolicy(SettlementPolicyOverride(rounding: rounding(.nearest, 500))))])
    #expect(globalOnly.effectivePolicy(for: meal, counterparty: pid("b")).rounding == rounding(.nearest, 500))
    // 2) person beats global (and only for that person)
    let withPerson = try globalOnly.applying([.setSettlementPolicy(.person(pid("b")), userPolicy(SettlementPolicyOverride(rounding: rounding(.floor, 1_000))))])
    #expect(withPerson.effectivePolicy(for: meal, counterparty: pid("b")).rounding == rounding(.floor, 1_000))
    #expect(withPerson.effectivePolicy(for: meal, counterparty: pid("c")).rounding == rounding(.nearest, 500))
    // 3) activity beats person
    let withActivity = try withPerson.applying([.setSettlementPolicy(.activity(dinner), userPolicy(SettlementPolicyOverride(splitRule: .weights([pid("b"): 1, myself: 3]), rounding: rounding(.ceil, 100))))])
    let activityPolicy = withActivity.effectivePolicy(for: meal, counterparty: pid("b"))
    #expect(activityPolicy.rounding == rounding(.ceil, 100))
    #expect(activityPolicy.splitRule == .weights([pid("b"): 1, myself: 3]))
    // 4) the component beats the activity, field by field: it states a split but inherits the rounding
    var override = meal
    override.policy = SettlementPolicyOverride(splitRule: .equal)
    let withComponent = try withActivity.applying([.upsertExpenseComponent(override)])
    let componentPolicy = withComponent.effectivePolicy(for: try #require(withComponent.components[cid("meal")]), counterparty: pid("b"))
    #expect(componentPolicy.splitRule == .equal && componentPolicy.rounding == rounding(.ceil, 100))
}

@Test func aPersonPolicyCarriesRoundingOnlyAndEverythingElseIsTheUsersDecision() throws {
    let life = dinnerLife()
    #expect(failure { _ = try life.applying([.setSettlementPolicy(.person(pid("b")), userPolicy(SettlementPolicyOverride(splitRule: .equal)))]) }
        == .personPolicyCannotSetSplitRule(pid("b")))
    let automated = Assigned(SettlementPolicyOverride(rounding: rounding(.floor, 1_000)), provenance: autoProvenance(1.0))
    #expect(failure { _ = try life.applying([.setSettlementPolicy(.person(pid("b")), automated)]) } == .policyRequiresUser)
    #expect(failure { _ = try life.applying([.setSettlementPolicy(.global, automated)]) } == .policyRequiresUser)
    #expect(failure { _ = try life.applying([.setSettlementPolicy(.person(pid("ghost")), userPolicy(SettlementPolicyOverride()))]) } == .unknownPerson(pid("ghost")))
    #expect(failure { _ = try life.applying([.setSettlementPolicy(.activity(ActivityID(rawValue: "ghost")), userPolicy(SettlementPolicyOverride()))]) } == .unknownActivity(ActivityID(rawValue: "ghost")))
    #expect(failure { _ = try life.applying([.setSettlementPolicy(.global, userPolicy(SettlementPolicyOverride(splitRule: .weights([pid("b"): 0]))))]) }
        == .invalidPolicy(.nonPositiveWeight(pid("b"))))
    // Clearing is the user's too.
    let set = try life.applying([.setSettlementPolicy(.global, userPolicy(SettlementPolicyOverride(rounding: rounding(.floor, 1_000))))])
    #expect(failure { _ = try set.applying([.clearSettlementPolicy(.global, by: autoProvenance(1.0))]) } == .policyRequiresUser)
    #expect((try set.applying([.clearSettlementPolicy(.global, by: userProvenance())])).policyOverrides.isEmpty)
}

// MARK: Scenario K — someone joined late

@Test func scenarioKTheLateComerOwesNothingForTheSecondRound() async throws {
    // 1차 (everybody, 120,000) and 2차 (A B C only, 60,000). I am A and paid both.
    let life = dinnerLife(extra: [
        .upsertExpenseComponent(component("round1", .exact(120_000))),
        .upsertExpenseComponent(component("round2", .exact(60_000), participants: ["me", "b", "c"]))
    ])
    let first = try life.deriveObligations(forComponent: cid("round1"))
    #expect(owed(first) == ["b": 30_000, "c": 30_000, "d": 30_000])
    let second = try life.deriveObligations(forComponent: cid("round2"))
    #expect(owed(second) == ["b": 20_000, "c": 20_000])                    // D has no second-round obligation
    #expect(second.shares.share(of: pid("d")) == nil)

    // Through the service, one obligation per counterparty per component is created and traced back.
    let h = Harness.make(events: [dinnerEvent], life: life)
    for id in ["round1", "round2"] {
        guard case .applied = await h.service.perform(.generateObligations(GenerateObligationsInput(componentID: cid(id), provenance: userProvenance()))) else {
            Issue.record("expected applied for \(id)")
            return
        }
    }
    let state = await h.life()
    let ofD = state.obligations.values.filter { $0.counterpartyID == pid("d") }
    #expect(ofD.count == 1 && ofD.first?.componentID == cid("round1"))
    let ofB = state.obligations.values.filter { $0.counterpartyID == pid("b") }
    #expect(Set(ofB.compactMap(\.componentID)) == [cid("round1"), cid("round2")])
    #expect(ofB.reduce(Int64(0)) { $0 + ($1.amount.knowledge.knownValue ?? 0) } == 50_000)
    // The obligations feed straight into netting: B's 50,000 settles both at once.
    guard case let .netMatch(proposal) = SettlementMatcher.match(transfer("t", "b", .incoming, 50_000), in: state) else {
        Issue.record("expected a net match for both rounds")
        return
    }
    #expect(proposal.applications.count == 2)
}

@Test func theParticipantListIsInheritedUntilTheComponentStatesItsOwn() throws {
    let life = dinnerLife(participants: ["b", "c"], extra: [
        .upsertExpenseComponent(component("inherit", .exact(90_000))),
        .upsertExpenseComponent(component("own", .exact(90_000), participants: ["me", "d"])),
        .upsertExpenseComponent(component("minus", .exact(90_000), excluded: ["c"]))
    ])
    #expect(life.participants(of: try #require(life.components[cid("inherit")])) == [pid("b"), pid("c"), myself])
    #expect(life.participants(of: try #require(life.components[cid("own")])) == [pid("d"), myself])
    #expect(life.participants(of: try #require(life.components[cid("minus")])) == [pid("b"), myself])
    #expect(owed(try life.deriveObligations(forComponent: cid("own"))) == ["d": 45_000])
}

// MARK: Scenario L — someone did not drink

@Test func scenarioLTheNonDrinkerHasNoAlcoholObligation() throws {
    let life = dinnerLife(participants: ["b", "c"], extra: [
        .upsertExpenseComponent(component("food", .exact(60_000))),
        .upsertExpenseComponent(component("alcohol", .exact(40_000), participants: ["me", "b"]))
    ])
    #expect(owed(try life.deriveObligations(forComponent: cid("food"))) == ["b": 20_000, "c": 20_000])
    let alcohol = try life.deriveObligations(forComponent: cid("alcohol"))
    #expect(owed(alcohol) == ["b": 20_000])
    #expect(alcohol.shares.share(of: pid("c")) == nil)
    #expect(alcohol.drafts.allSatisfy { $0.counterpartyID != pid("c") })
}

@Test func scenarioLAlternativeAFixedAmountForTheOneWhoDidNotDrink() throws {
    // C only pays 20,000 of the 100,000 second round; A and B split the other 80,000.
    let life = dinnerLife(participants: ["b", "c"], extra: [
        .upsertExpenseComponent(component("round2", .exact(100_000), participants: ["me", "b", "c"], policy: SettlementPolicyOverride(splitRule: .fixedAmounts([pid("c"): 20_000]))))
    ])
    let derivation = try life.deriveObligations(forComponent: cid("round2"))
    #expect(owed(derivation) == ["b": 40_000, "c": 20_000])
    #expect(derivation.shares.share(of: myself)?.rawMinorUnits == 40_000)
    #expect(derivation.shares.shares.reduce(Int64(0)) { $0 + $1.rawMinorUnits } == 100_000)   // the parts add up
}

@Test func anInvalidFixedAmountIsReportedWhenSharesAreComputedNotGuessed() throws {
    let life = dinnerLife(extra: [
        .upsertExpenseComponent(component("round2", .exact(10_000), participants: ["me", "b"], policy: SettlementPolicyOverride(splitRule: .fixedAmounts([pid("c"): 20_000]))))
    ])
    #expect(throws: SettlementPolicyError.fixedAmountForNonParticipant(pid("c"))) { _ = try life.deriveObligations(forComponent: cid("round2")) }
}

// MARK: Obligations from components

@Test func whenSomeoneElsePaidIOweThemMyShareOnly() throws {
    let life = dinnerLife(extra: [.upsertExpenseComponent(component("round1", .exact(120_000), payer: "b"))])
    let derivation = try life.deriveObligations(forComponent: cid("round1"))
    #expect(derivation.drafts.count == 1)
    let draft = try #require(derivation.drafts.first)
    #expect(draft.direction == .payable && draft.counterpartyID == pid("b") && draft.amount == .exact(30_000))
}

@Test func expensesBetweenOtherPeopleCreateNothingForMe() throws {
    // D paid and I was not there: whatever B and C owe D is not my obligation.
    let life = dinnerLife(extra: [.upsertExpenseComponent(component("theirs", .exact(60_000), payer: "d", participants: ["b", "c", "d"]))])
    let derivation = try life.deriveObligations(forComponent: cid("theirs"))
    #expect(derivation.drafts.isEmpty)
    #expect(derivation.shares.shares.count == 3)                           // the split itself is still computed
}

@Test func anAmountThatIsNotSettledNeverBecomesObligations() throws {
    let unknown = dinnerLife(extra: [.upsertExpenseComponent(component("a", .unknown))])
    #expect(throws: SettlementPolicyError.totalNotKnown) { _ = try unknown.deriveObligations(forComponent: cid("a")) }
    let range = dinnerLife(extra: [.upsertExpenseComponent(component("a", amountRange(50_000, 60_000)))])
    #expect(throws: SettlementPolicyError.totalNotKnown) { _ = try range.deriveObligations(forComponent: cid("a")) }
    let estimated = dinnerLife(extra: [.upsertExpenseComponent(component("a", .estimated(55_000)))])
    #expect(throws: SettlementPolicyError.totalNotKnown) { _ = try estimated.deriveObligations(forComponent: cid("a")) }
}

@Test func sharesOfAnInferredTotalAreInferredNotExact() throws {
    let life = dinnerLife(participants: ["b"], extra: [.upsertExpenseComponent(component("a", inferred(40_000)))])
    let draft = try #require(try life.deriveObligations(forComponent: cid("a")).drafts.first)
    guard case let .inferred(value, _) = draft.amount else {
        Issue.record("an inferred total cannot yield an exact share")
        return
    }
    #expect(value == 20_000)
}

@Test func obligationsAreCreatedOncePerComponentAndCounterparty() async throws {
    let life = dinnerLife(participants: ["b"], extra: [.upsertExpenseComponent(component("meal", .exact(40_000)))])
    let h = Harness.make(events: [dinnerEvent], life: life)
    let generate = CalendarCommand.generateObligations(GenerateObligationsInput(componentID: cid("meal"), provenance: userProvenance()))
    guard case let .applied(first) = await h.service.perform(generate) else {
        Issue.record("expected applied")
        return
    }
    #expect(await h.service.perform(generate) == .rejected(.lifeValidation(.duplicateComponentObligation(cid("meal"), pid("b")))))

    // While obligations exist, who pays what cannot change underneath them; a label or category still can.
    let state = await h.life()
    var changed = try #require(state.components[cid("meal")])
    changed.amount = entry(.exact(50_000))
    #expect(failure { _ = try state.applying([.upsertExpenseComponent(changed)]) } == .componentHasObligations(cid("meal")))
    var relabeled = try #require(state.components[cid("meal")])
    relabeled.label = "고기집"
    relabeled.category = .classified(CanonicalCategoryID(rawValue: "food"), userProvenance())
    #expect((try state.applying([.upsertExpenseComponent(relabeled)])).components[cid("meal")]?.label == "고기집")
    #expect(failure { _ = try state.applying([.removeExpenseComponent(cid("meal"), by: userProvenance())]) } == .componentHasObligations(cid("meal")))
    #expect(failure { _ = try state.applying([.removeActivity(dinner)]) } == .activityHasObligations(dinner))

    // Cancelling the obligation frees the component again.
    let firstObligation = try #require(first.obligationIDs.first)
    let cancelled = try state.applying([.cancelObligation(firstObligation, by: userProvenance())])
    #expect((try cancelled.applying([.upsertExpenseComponent(changed)])).components[cid("meal")]?.amount.knowledge == .exact(50_000))
}

@Test func componentCommandsRejectBadInputAndKeepTheUsersWork() async throws {
    let h = Harness.make(events: [dinnerEvent], life: dinnerLife())
    func upsert(_ amount: AmountKnowledge, payer: String = "me", provenance: AssignmentProvenance = userProvenance(), id: ExpenseComponentID? = nil) -> CalendarCommand {
        .upsertExpenseComponent(UpsertExpenseComponentInput(
            componentID: id, activity: .activity(dinner), label: "x", currency: "KRW", amount: amount, payerID: pid(payer), provenance: provenance
        ))
    }
    #expect(await h.service.perform(upsert(.exact(0))) == .rejected(.invalidAmount(.nonPositiveAmount)))
    #expect(await h.service.perform(upsert(.exact(5_000), payer: "ghost")) == .rejected(.lifeValidation(.unknownPerson(pid("ghost")))))
    #expect(await h.service.perform(upsert(.exact(5_000), provenance: autoProvenance(0.3))) == .rejected(.provenanceRejected))
    guard case let .applied(created) = await h.service.perform(upsert(.exact(5_000))), let id = created.componentID else {
        Issue.record("expected the component to be created")
        return
    }
    // Automation cannot overwrite what the user entered.
    #expect(await h.service.perform(upsert(.exact(6_000), provenance: autoProvenance(0.95), id: id)) == .rejected(.userAssignmentProtected))
    #expect((await h.life()).components[id]?.amount.knowledge == .exact(5_000))
    #expect(await h.service.perform(.generateObligations(GenerateObligationsInput(componentID: cid("ghost"), provenance: userProvenance())))
        == .rejected(.lifeValidation(.unknownComponent(cid("ghost")))))
}

@Test func generatingObligationsWithoutAnAmountOrWithoutMeIsRefusedNotGuessed() async throws {
    let unknownLife = dinnerLife(extra: [.upsertExpenseComponent(component("a", .unknown))])
    let h = Harness.make(events: [dinnerEvent], life: unknownLife)
    #expect(await h.service.perform(.generateObligations(GenerateObligationsInput(componentID: cid("a"), provenance: userProvenance())))
        == .rejected(.invalidPolicy(.totalNotKnown)))

    let selfless = try LifeState.empty.applying([
        .upsertPerson(person("b")), .createActivity(Activity.materialized(from: dinnerEvent, id: dinner, at: 1)),
        .upsertExpenseComponent(component("a", .exact(10_000), payer: "b"))
    ])
    #expect(failure { _ = try selfless.deriveObligations(forComponent: cid("a")) } == .selfNotDefined)
}

@Test func theServiceCanPreviewWhatAComponentWouldAsk() async throws {
    let life = dinnerLife(extra: [.upsertExpenseComponent(component("round1", .exact(120_000)))])
    let h = Harness.make(events: [dinnerEvent], life: life)
    let preview = try await h.service.previewObligations(forComponent: cid("round1"))
    #expect(owed(preview) == ["b": 30_000, "c": 30_000, "d": 30_000])
    #expect((await h.life()).obligations.isEmpty)                          // a preview records nothing
}

@Test func policiesAndComponentsRoundTripThroughTheService() async throws {
    let h = Harness.make(events: [dinnerEvent], life: dinnerLife())
    let set = await h.service.perform(.setSettlementPolicy(SetSettlementPolicyInput(
        target: .person(pid("b")), policy: SettlementPolicyOverride(rounding: rounding(.floor, 1_000)), provenance: userProvenance()
    )))
    guard case .applied = set else {
        Issue.record("expected the user's policy to be stored: \(set)")
        return
    }
    // A confident automated source still cannot set a preference.
    #expect(await h.service.perform(.setSettlementPolicy(SetSettlementPolicyInput(
        target: .person(pid("c")), policy: SettlementPolicyOverride(rounding: rounding(.floor, 1_000)), provenance: autoProvenance(1.0)
    ))) == .rejected(.lifeValidation(.policyRequiresUser)))
    #expect(await h.service.perform(.setSettlementPolicy(SetSettlementPolicyInput(
        target: .person(pid("c")), policy: SettlementPolicyOverride(rounding: rounding(.floor, 1_000)), provenance: autoProvenance(0.2)
    ))) == .rejected(.provenanceRejected))
    let state = await h.life()
    #expect(state.policyOverrides[.person(pid("b"))]?.value.rounding == rounding(.floor, 1_000))
    let decoded = try JSONDecoder().decode(LifeState.self, from: try JSONEncoder().encode(state))
    #expect(decoded == state)
}
