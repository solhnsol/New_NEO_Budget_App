import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetCore

// Money-flow consistency and uncertainty semantics (docs/calendar-domain.md, "머니 플로우 일관성").
//
// Principle: a difference is first evidence about amounts that are not yet known, and becomes a residual only
// when nothing uncertain is left to explain it. One won is in one economic bucket at a time.

private func failure(_ block: () throws -> Void) -> LifeValidationError? {
    do { try block(); return nil } catch let error as LifeValidationError { return error } catch { return nil }
}

private func world(_ obligations: [Obligation] = [], people: [String] = ["friend"], extra: [LifeChange] = []) -> LifeState {
    lifeWithPeople(people, extra: obligations.map { .createObligation($0) } + extra)
}

private func ids(_ values: [ObligationID]) -> [String] { values.map(\.rawValue).sorted() }

private func expectNoViolations(_ life: LifeState, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(life.conservationViolations() == [], sourceLocation: sourceLocation)
}

// MARK: Scenario O — an unknown obligation consumes the difference

@Test func scenarioOUnknownObligationConsumesTheDifferenceAndLeavesNoResidual() throws {
    // 받을 돈 30,000 (확정), 줄 돈 미상, 실제 입금 18,000 → 줄 돈 = 12,000, residual 없음
    let life = world([obligation("recv", .receivable, .exact(30_000)), obligation("pay", .payable, .unknown)])
    let result = SettlementMatcher.match(transfer("t", .incoming, 18_000), in: life)
    guard case let .inferredUniqueSolution(proposal) = result else {
        Issue.record("expected the unknown to be inferred, got \(result)")
        return
    }
    #expect(proposal.residuals.isEmpty)
    #expect(proposal.inferences == [ProposedInference(obligationID: oid("pay"), minorUnits: 12_000)])
    let settled = try settle(life, proposal)
    guard case .inferred(12_000, _) = try #require(settled.obligations[oid("pay")]).amount.knowledge else {
        Issue.record("the unknown must become inferred, never exact")
        return
    }
    #expect(settled.residuals.isEmpty && settled.unresolvedResiduals.isEmpty && settled.residualSummary().isEmpty)
    expectNoViolations(settled)
}

// MARK: Scenario P — several unknowns keep a constraint, never a residual or a question

@Test func scenarioPSeveralUnknownsKeepAConstraintAndNeverCreateAResidualQuestion() throws {
    let life = world([obligation("recv", .receivable, .exact(30_000)), obligation("x", .payable, .unknown), obligation("y", .payable, .unknown)])
    let result = SettlementMatcher.match(transfer("t", .incoming, 18_000), in: life)
    guard case let .ambiguous(report) = result else {
        Issue.record("expected an ambiguity with a constraint, got \(result)")
        return
    }
    let constraint = try #require(report.constraint)
    #expect(constraint.totalMinorUnits == 12_000 && ids(constraint.unknownObligationIDs) == ["x", "y"])
    #expect(result.proposal == nil)                          // no residual proposal of any kind
    #expect(life.residuals.isEmpty && life.unresolvedResiduals.isEmpty)    // nothing for a review to ask about
    #expect(life.obligations[oid("x")]?.amount.knowledge == .unknown)      // the unknowns are still there to explain it
}

@Test func anOpenUnknownNeverLetsADifferenceBecomeAResidualEvenWithARequest() throws {
    // The request names only the known receivable. The unnamed unknown payable with the same person could still
    // be the difference, so the matcher refuses to call it "unexplained".
    let base = world([obligation("recv", .receivable, .exact(30_000)), obligation("pay", .payable, amountRange(1_000, 5_000))])
    let request = try SettlementRequest(
        id: SettlementRequestID(rawValue: "req"), counterpartyID: pid("friend"), obligationIDs: [oid("recv")], createdAtUnixMilliseconds: 1
    )
    let life = try base.applying([.createSettlementRequest(request)])
    // 18,000 against 30,000 (short by 12,000) cannot be absorbed by a payable of at most 5,000, but it can
    // still change the remainder: no shortfall is invented while it is open.
    #expect(SettlementMatcher.match(transfer("t", .incoming, 18_000), in: life, requestID: request.id)
        == .insufficientEvidence(.unknownAmountsMayExplainDifference([oid("pay")])))
    // The same for a surplus: an unknown receivable next to a known one could be what arrived beyond it.
    let surplusWorld = world([obligation("recv", .receivable, .exact(5_000)), obligation("pay", .payable, .unknown)])
    #expect(SettlementMatcher.match(transfer("t", .incoming, 20_000), in: surplusWorld)
        == .insufficientEvidence(.unknownAmountsMayExplainDifference([oid("pay")])))
}

@Test func theStateRefusesAnAutomatedResidualWhileAnUncertainObligationIsOpen() throws {
    // A hand-built automated settlement that records a surplus while an unknown obligation is open.
    let life = world([obligation("recv", .receivable, .exact(18_000)), obligation("unk", .payable, .unknown)])
    let settlementID = SettlementID(rawValue: "s")
    let unresolved = Assigned(ResidualClassification.unresolved, provenance: autoProvenance(1.0))
    let surplus = try SettlementResidual(
        id: ResidualID(rawValue: "r"), settlementID: settlementID, obligationID: nil, amount: won(2_000), direction: .surplus,
        classification: unresolved, createdAtUnixMilliseconds: 1
    )
    func settlement(by provenance: AssignmentProvenance) throws -> Settlement {
        try Settlement(
            id: settlementID, transfer: transfer("t", .incoming, 20_000),
            allocations: [try SettlementAllocation(obligationID: oid("recv"), appliedMinorUnits: 18_000)],
            residuals: [surplus], provenance: provenance, createdAtUnixMilliseconds: 1
        )
    }
    #expect(failure { _ = try life.applying([.recordSettlement(try settlement(by: autoProvenance(1.0)))]) }
        == .residualWhileUncertainObligationsOpen(ResidualID(rawValue: "r")))
    // The user may say so knowingly.
    #expect((try life.applying([.recordSettlement(try settlement(by: userProvenance()))])).residuals.count == 1)
}

// MARK: Scenario Q — range obligations, and uncertainty propagation

private let dinner = ActivityID(rawValue: "dinner")
private let dinnerEvent = event("dinner", title: "회식", from: at(today, 18), to: at(today, 23))

private func dinnerLife(participants: [String] = ["b"], extra: [LifeChange] = []) -> LifeState {
    var changes: [LifeChange] = [.createActivity(Activity.materialized(from: dinnerEvent, id: dinner, at: 1))]
    changes += participants.map { .addParticipant(dinner, ParticipantAssignment(personID: pid($0), provenance: userProvenance())) }
    return lifeWithPeople(["b", "c", "d"], extra: changes + extra)
}

private func component(
    _ id: String, _ amount: AmountKnowledge, payer: String = "me", participants: [String]? = nil,
    policy: SettlementPolicyOverride? = nil, origin: String? = nil
) -> ExpenseComponent {
    ExpenseComponent(
        id: ExpenseComponentID(rawValue: id), activityID: dinner, label: id, amount: entry(amount), payerID: pid(payer),
        participants: participants.map { $0.map { pid($0) } }, policy: policy, originTransactionID: origin.map { txID($0) },
        provenance: userProvenance(), createdAtUnixMilliseconds: 1
    )
}

private func cid(_ value: String) -> ExpenseComponentID { ExpenseComponentID(rawValue: value) }
private func floorRule(_ unit: Int64) -> RoundingRule { try! RoundingRule(mode: .floor, unitMinorUnits: unit) }
private func personRounding(_ person: String, _ rule: RoundingRule) -> LifeChange {
    .setSettlementPolicy(.person(pid(person)), Assigned(SettlementPolicyOverride(rounding: rule), provenance: userProvenance()))
}

@Test func scenarioQARangeTotalGivesARangeObligation() throws {
    // 저녁 총액 50,000 ~ 60,000, 2인 균등 → 상대 obligation 25,000 ~ 30,000
    let life = dinnerLife(extra: [.upsertExpenseComponent(component("meal", amountRange(50_000, 60_000)))])
    let derivation = try life.deriveObligations(forComponent: cid("meal"))
    let draft = try #require(derivation.drafts.first)
    #expect(derivation.drafts.count == 1 && draft.counterpartyID == pid("b") && draft.direction == .receivable)
    #expect(draft.amount == amountRange(25_000, 30_000))
    #expect(draft.share.rawShare == amountRange(25_000, 30_000) && draft.share.total == amountRange(50_000, 60_000))
    #expect(derivation.shares == nil)                           // no single split exists for a range
}

@Test func uncertaintyIsPropagatedFromTheTotalToTheShareAtTheSameLevel() throws {
    func amount(_ total: AmountKnowledge) throws -> AmountKnowledge {
        try #require(try dinnerLife(extra: [.upsertExpenseComponent(component("m", total))]).deriveObligations(forComponent: cid("m")).drafts.first).amount
    }
    #expect(try amount(.exact(50_000)) == .exact(25_000))
    guard case .inferred(25_000, _) = try amount(inferred(50_000)) else {
        Issue.record("an inferred total gives an inferred share")
        return
    }
    #expect(try amount(amountRange(50_000, 60_000)) == amountRange(25_000, 30_000))
    #expect(try amount(.estimated(50_000)) == .estimated(25_000))
    #expect(try amount(.unknown) == .unknown)
}

@Test func aRangeShareBoundsHoldForWeightedAndFixedSplitsAndRounding() throws {
    // Weighted 1:2 of 90,000...100,000 → b (weight 2) between 60,000 and 66,667.
    let weighted = SettlementPolicyOverride(splitRule: .weights([pid("b"): 2, pid("me"): 1]))
    let life = dinnerLife(extra: [.upsertExpenseComponent(component("w", amountRange(90_000, 100_000), policy: weighted))])
    let share = try #require(try life.deriveObligations(forComponent: cid("w")).drafts.first).amount
    guard case let .range(range) = share else {
        Issue.record("expected a range")
        return
    }
    #expect(range.minMinorUnits == 60_000 && range.maxMinorUnits == 66_667)
    // Every possible total in the range lands inside that range for both ends and the middle.
    for total in [90_000, 95_000, 100_000] as [Int64] {
        let exact = try SplitCalculator.rawShares(total: total, participants: [pid("b"), myself], rule: .weights([pid("b"): 2, myself: 1]))
        #expect(range.contains(try #require(exact[pid("b")])))
    }
    // Fixed amount: c pays 20,000 whatever the total is, the rest is split equally.
    let fixed = SettlementPolicyOverride(splitRule: .fixedAmounts([pid("c"): 20_000]))
    let withFixed = dinnerLife(participants: ["b", "c"], extra: [.upsertExpenseComponent(component("f", amountRange(80_000, 100_000), policy: fixed))])
    let drafts = try withFixed.deriveObligations(forComponent: cid("f")).drafts
    #expect(drafts.first { $0.counterpartyID == pid("c") }?.amount == amountRange(20_000, 20_000))
    #expect(drafts.first { $0.counterpartyID == pid("b") }?.amount == amountRange(30_000, 40_000))
    // A rounding habit applies to both ends (floor 1,000 of 25,500...30,500 → 25,000...30,000).
    let rounded = dinnerLife(extra: [personRounding("b", floorRule(1_000)), .upsertExpenseComponent(component("r", amountRange(51_000, 61_000)))])
    #expect(try rounded.deriveObligations(forComponent: cid("r")).drafts.first?.amount == amountRange(25_000, 30_000))
}

@Test func aRangeObligationIsOnlyEverInferredNeverExactBySettlement() throws {
    let life = world([obligation("share", .receivable, amountRange(25_000, 30_000))])
    // A transfer inside the range is compatible: it becomes a candidate whose amount is `inferred`.
    let result = SettlementMatcher.match(transfer("t", .incoming, 27_000), in: life)
    guard case let .inferredUniqueSolution(proposal) = result else {
        Issue.record("expected an inferred candidate, got \(result)")
        return
    }
    let settled = try settle(life, proposal)
    guard case .inferred(27_000, _) = try #require(settled.obligations[oid("share")]).amount.knowledge else {
        Issue.record("a range settles as inferred, never exact")
        return
    }
    // A transfer outside the range is not compatible and is never forced into it.
    #expect(SettlementMatcher.match(transfer("t2", .incoming, 40_000), in: life) != result)
    #expect(SettlementMatcher.match(transfer("t2", .incoming, 40_000), in: life).proposal == nil)
}

@Test func anEstimateIsASoftHintNeverAHardBoundOrAnExactMatch() throws {
    let life = world([obligation("share", .receivable, .estimated(25_000))])
    for amount in [10_000, 25_000, 40_000] as [Int64] {
        guard case let .inferredUniqueSolution(proposal) = SettlementMatcher.match(transfer("t\(amount)", .incoming, amount), in: life) else {
            Issue.record("an estimate must not block or force a match: \(amount)")
            return
        }
        #expect(proposal.inferences == [ProposedInference(obligationID: oid("share"), minorUnits: amount)])
    }
}

@Test func aSharperTotalRefinesRangeObligationsInsteadOfDuplicatingThem() async throws {
    let life = dinnerLife(extra: [.upsertExpenseComponent(component("meal", amountRange(50_000, 60_000)))])
    let h = Harness.make(events: [dinnerEvent], life: life)
    let generate = CalendarCommand.generateObligations(GenerateObligationsInput(componentID: cid("meal"), provenance: userProvenance()))
    guard case let .applied(first) = await h.service.perform(generate), let obligationID = first.obligationIDs.first else {
        Issue.record("expected a range obligation")
        return
    }
    #expect((await h.life()).obligations[obligationID]?.amount.knowledge == amountRange(25_000, 30_000))
    // The receipt arrives: the total is exact. The component may be sharpened even though obligations exist.
    let upsert = CalendarCommand.upsertExpenseComponent(UpsertExpenseComponentInput(
        componentID: cid("meal"), activity: .activity(dinner), label: "meal", currency: "KRW", amount: .exact(56_000),
        payerID: myself, provenance: userProvenance()
    ))
    guard case .applied = await h.service.perform(upsert) else {
        Issue.record("sharpening an uncertain total must be allowed")
        return
    }
    guard case let .applied(refined) = await h.service.perform(generate) else {
        Issue.record("expected the obligation to be refined")
        return
    }
    let state = await h.life()
    #expect(refined.obligationIDs == [obligationID] && state.obligations.count == 1)
    #expect(state.obligations[obligationID]?.amount.knowledge == .exact(28_000))
    // Once the total is settled, changing it underneath existing obligations is still refused.
    var changed = try #require(state.components[cid("meal")])
    changed.amount = entry(.exact(70_000))
    #expect(failure { _ = try state.applying([.upsertExpenseComponent(changed)]) } == .componentHasObligations(cid("meal")))
    expectNoViolations(state)
}

// MARK: Scenario R — a shortfall is one remainder, not two buckets

@Test func scenarioRExactShortfallIsSettledPlusRemainingAndNotCountedTwice() throws {
    let life = world([obligation("recv", .receivable, .exact(18_000))])
    guard case let .matchWithResidual(proposal) = SettlementMatcher.match(transfer("t", .incoming, 17_000), in: life) else {
        Issue.record("expected a partial settlement")
        return
    }
    let settled = try settle(life, proposal)
    let balance = try #require(settled.balance(of: oid("recv")))
    #expect(balance.originalMinorUnits == 18_000 && balance.settledMinorUnits == 17_000 && balance.remainingMinorUnits == 1_000)
    #expect(balance.waivedMinorUnits == 0 && balance.isConserved)
    // The shortfall record only points at the same 1,000; it is metadata, not extra money.
    #expect(balance.openShortfallReferenceMinorUnits == 1_000)
    let summary = try #require(settled.residualSummary().first)
    #expect(summary.unresolvedSurplusMinorUnits == 0)                      // no independent unexplained money
    #expect(summary.openShortfallReferenceMinorUnits == 1_000)
    // What is outstanding counts the 1,000 once.
    let outstanding = try #require(settled.outstanding().first)
    #expect(outstanding.receivableMinorUnits == 1_000 && outstanding.netMinorUnits == 1_000)
    // What actually moved is 17,000: the shortfall is not part of the money that moved.
    let audit = try #require(MoneyFlowAudit.audit(rawTransfers: [transfer("t", .incoming, 17_000)], in: settled).first)
    #expect(audit.appliedToObligationsSignedMinorUnits == 17_000 && audit.surplusSignedMinorUnits == 0 && audit.isConserved)
    expectNoViolations(settled)
}

@Test func aLaterPaymentRetiresTheShortfallReferenceInsteadOfLeavingStaleMoney() throws {
    let life = world([obligation("recv", .receivable, .exact(18_000))])
    let first = try settle(life, try #require(SettlementMatcher.match(transfer("t1", .incoming, 17_000), in: life).proposal), id: "s1")
    let second = try settle(first, try #require(SettlementMatcher.match(transfer("t2", .incoming, 1_000), in: first).proposal), id: "s2")
    let balance = try #require(second.balance(of: oid("recv")))
    #expect(balance.settledMinorUnits == 18_000 && balance.remainingMinorUnits == 0 && balance.openShortfallReferenceMinorUnits == 0)
    // The old record is still there as history, but it no longer counts as anything open.
    #expect(second.residuals.count == 1)
    #expect(second.residualSummary().first?.openShortfallReferenceMinorUnits == 0)
    #expect(second.outstanding().isEmpty)                  // nothing is outstanding any more
    expectNoViolations(second)
}

@Test func originalEqualsSettledPlusWaivedPlusRemainingAndSurplusIsNotSymmetricWithShortfall() throws {
    let life = world([obligation("recv", .receivable, .exact(18_000))])
    let short = try settle(life, try #require(SettlementMatcher.match(transfer("t", .incoming, 17_000), in: life).proposal))
    let residual = try #require(short.residuals.values.first)
    // The user forgives the 1,000: it moves from remaining to waived, and the total never changes.
    let waived = try short.applying([.classifyResidual(residual.id, .waived, by: userProvenance())])
    let balance = try #require(waived.balance(of: oid("recv")))
    #expect(balance.settledMinorUnits == 17_000 && balance.waivedMinorUnits == 1_000 && balance.remainingMinorUnits == 0 && balance.isConserved)
    #expect(waived.residualSummary().first?.openShortfallReferenceMinorUnits == 0)
    // A surplus is a different thing: money beyond the obligation, with no obligation to be a remainder of.
    let over = world([obligation("recv", .receivable, .exact(18_000))])
    let proposal = try #require(SettlementMatcher.match(transfer("t", .incoming, 20_000), in: over).proposal)
    let settled = try settle(over, proposal)
    let overBalance = try #require(settled.balance(of: oid("recv")))
    #expect(overBalance.settledMinorUnits == 18_000 && overBalance.remainingMinorUnits == 0)
    #expect(settled.residualSummary().first?.unresolvedSurplusMinorUnits == 2_000)
    #expect(settled.residualSummary().first?.openShortfallReferenceMinorUnits == 0)
    expectNoViolations(waived)
    expectNoViolations(settled)
}

@Test func aCancelledObligationKeepsItsAmountAccountedFor() throws {
    let life = try world([obligation("o", .receivable, .exact(5_000))]).applying([.cancelObligation(oid("o"), by: userProvenance())])
    let balance = try #require(life.balance(of: oid("o")))
    #expect(balance.cancelledMinorUnits == 5_000 && balance.remainingMinorUnits == 0 && balance.isConserved)
    #expect(life.outstanding().first?.receivableMinorUnits == 0 || life.outstanding().isEmpty)
}

// MARK: Rounding pipeline — raw → adjustment → requested → actual → residual

/// Me and `b`, a dinner of 47,400 paid by me, and `b` rounding down to 1,000. Returns the state with the
/// generated obligation (23,000 asked, raw 23,700).
private func roundedMeal(extra: [LifeChange] = []) async throws -> (life: LifeState, obligation: ObligationID) {
    let life = dinnerLife(extra: [personRounding("b", floorRule(1_000)), .upsertExpenseComponent(component("meal", .exact(47_400)))] + extra)
    let h = Harness.make(events: [dinnerEvent], life: life)
    guard case let .applied(applied) = await h.service.perform(.generateObligations(GenerateObligationsInput(componentID: cid("meal"), provenance: userProvenance()))),
          let id = applied.obligationIDs.first else {
        throw LifeValidationError.selfNotDefined
    }
    return (await h.life(), id)
}

@Test func scenarioSRoundingPolicyNeverBecomesAResidual() async throws {
    let (life, id) = try await roundedMeal()
    let before = try #require(life.balance(of: id))
    #expect(before.rawShareMinorUnits == 23_700 && before.originalMinorUnits == 23_000 && before.policyAdjustmentMinorUnits == -700)
    let proposal = try #require(SettlementMatcher.match(transfer("t", "b", .incoming, 23_000), in: life).proposal)
    #expect(proposal.residuals.isEmpty)
    let settled = try settle(life, proposal)
    let balance = try #require(settled.balance(of: id))
    #expect(balance.settledMinorUnits == 23_000 && balance.remainingMinorUnits == 0 && balance.policyAdjustmentMinorUnits == -700)
    #expect(settled.residuals.isEmpty && settled.residualSummary().isEmpty && settled.unresolvedResiduals.isEmpty)
    expectNoViolations(settled)
}

@Test func scenarioTRoundingPlusAnActualShortfallLeavesOnlyTheUnexplainedThousand() async throws {
    let (life, id) = try await roundedMeal()
    guard case let .matchWithResidual(proposal) = SettlementMatcher.match(transfer("t", "b", .incoming, 22_000), in: life) else {
        Issue.record("expected a partial settlement")
        return
    }
    // Only the 1,000 between requested (23,000) and actual (22,000); the 700 was policy, not a difference.
    #expect(proposal.residuals == [ProposedResidual(direction: .shortfall, minorUnits: 1_000, obligationID: id)])
    let settled = try settle(life, proposal)
    let balance = try #require(settled.balance(of: id))
    #expect(balance.policyAdjustmentMinorUnits == -700 && balance.remainingMinorUnits == 1_000)
    #expect(settled.residualSummary().first?.openShortfallReferenceMinorUnits == 1_000)
    expectNoViolations(settled)
}

@Test func anActualAboveTheRequestedAmountIsASurplusOfOnlyTheExcess() async throws {
    let (life, id) = try await roundedMeal()
    let proposal = try #require(SettlementMatcher.match(transfer("t", "b", .incoming, 25_000), in: life).proposal)
    // Not 1,300 (25,000 − raw 23,700): the policy adjustment is not part of the comparison.
    #expect(proposal.residuals == [ProposedResidual(direction: .surplus, minorUnits: 2_000)])
    let settled = try settle(life, proposal)
    #expect(settled.balance(of: id)?.settledMinorUnits == 23_000)
    #expect(settled.residualSummary().first?.unresolvedSurplusMinorUnits == 2_000)
    expectNoViolations(settled)
}

@Test func nettingWithPerPersonRoundingLeavesNoResidualEvenThoughRawSharesDiffer() async throws {
    // I paid a 47,400 dinner (b owes 23,000 after rounding), and b paid a 30,100 taxi (I owe b 15,000 after
    // rounding). b sends the net 8,000. The raw shares would net to 8,650, which is not what was asked.
    let life = dinnerLife(extra: [
        personRounding("b", floorRule(1_000)),
        .upsertExpenseComponent(component("meal", .exact(47_400))),
        .upsertExpenseComponent(component("taxi", .exact(30_100), payer: "b"))
    ])
    let h = Harness.make(events: [dinnerEvent], life: life)
    for name in ["meal", "taxi"] {
        guard case .applied = await h.service.perform(.generateObligations(GenerateObligationsInput(componentID: cid(name), provenance: userProvenance()))) else {
            Issue.record("expected obligations for \(name)")
            return
        }
    }
    let state = await h.life()
    let net = try #require(state.balances().reduce(Int64(0)) { total, balance in
        total + (state.obligations[balance.obligationID]?.direction.sign ?? 0) * (balance.originalMinorUnits ?? 0)
    } as Int64?)
    #expect(net == 8_000)
    guard case let .netMatch(proposal) = SettlementMatcher.match(transfer("t", "b", .incoming, 8_000), in: state) else {
        Issue.record("expected a net match on the requested amounts")
        return
    }
    #expect(proposal.residuals.isEmpty)
    let settled = try settle(state, proposal)
    #expect(settled.residuals.isEmpty && settled.balances().allSatisfy { $0.remainingMinorUnits == 0 })
    // The policy adjustments are kept per obligation: -700 on the dinner, -50 on the taxi.
    #expect(Set(settled.balances().compactMap(\.policyAdjustmentMinorUnits)) == [-700, -50])
    expectNoViolations(settled)
}

@Test func componentRoundingAndDifferentPersonPoliciesEachKeepTheirOwnAdjustment() throws {
    // 100,000 shared by me, b and c: raw 33,333 or 33,334. b floors to 1,000, c rounds to the nearest 500.
    let nearest500 = try RoundingRule(mode: .nearest, unitMinorUnits: 500)
    let life = dinnerLife(participants: ["b", "c"], extra: [
        personRounding("b", floorRule(1_000)), personRounding("c", nearest500),
        .upsertExpenseComponent(component("meal", .exact(100_000)))
    ])
    let drafts = try life.deriveObligations(forComponent: cid("meal")).drafts
    let byPerson = Dictionary(uniqueKeysWithValues: drafts.map { ($0.counterpartyID, $0) })
    #expect(byPerson[pid("b")]?.amount == .exact(33_000) && byPerson[pid("b")]?.share.rawShareMinorUnits == 33_334)
    #expect(byPerson[pid("c")]?.amount == .exact(33_500) && byPerson[pid("c")]?.share.rawShareMinorUnits == 33_333)
    // The component's own rounding beats the person's habit.
    let override = SettlementPolicyOverride(rounding: floorRule(100))
    let overridden = dinnerLife(extra: [personRounding("b", floorRule(1_000)), .upsertExpenseComponent(component("meal", .exact(47_400), policy: override))])
    let draft = try #require(try overridden.deriveObligations(forComponent: cid("meal")).drafts.first)
    #expect(draft.amount == .exact(23_700) && draft.share.rawShareMinorUnits == 23_700)
}

// MARK: Scenario U — a parent sends more than was requested

@Test func scenarioUParentOverpaymentSplitsIntoSettlementAndUnresolvedSurplus() throws {
    // 구매액 30,000을 요청했는데 50,000이 입금됐다.
    let incoming = transfer("deposit", "mom", .incoming, 50_000)
    let mom = world([obligation("purchase", with: "mom", .receivable, .exact(30_000))], people: ["mom"])
    guard case let .matchWithResidual(proposal) = SettlementMatcher.match(incoming, in: mom) else {
        Issue.record("expected 30,000 settled and 20,000 left over")
        return
    }
    #expect(proposal.applications == [ProposedApplication(obligationID: oid("purchase"), appliedMinorUnits: 30_000)])
    #expect(proposal.residuals == [ProposedResidual(direction: .surplus, minorUnits: 20_000)])
    let settled = try settle(mom, proposal)
    let surplus = try #require(settled.unresolvedResiduals.first)
    #expect(surplus.amount == won(20_000) && surplus.direction == .surplus && surplus.classification.value == .unresolved)
    #expect(settled.balance(of: oid("purchase"))?.settledMinorUnits == 30_000)
    // The whole 50,000 is NOT reimbursement: no spending was reduced, and automation cannot decide what it was.
    #expect(settled.spendingByNature().isEmpty && SpendingAnalytics.items(unifiedIn: settled).isEmpty)
    #expect(failure { _ = try settled.applying([.classifyResidual(surplus.id, .gift, by: autoProvenance(1.0))]) }
        == .automatedResidualClassification(surplus.id))
    let audit = try #require(MoneyFlowAudit.audit(rawTransfers: [incoming], in: settled).first)
    #expect(audit.appliedToObligationsSignedMinorUnits == 30_000 && audit.unresolvedSurplusSignedMinorUnits == 20_000 && audit.isConserved)
    // The user, and only the user, may later say what the 20,000 was.
    let gifted = try settled.applying([.classifyResidual(surplus.id, .gift, by: userProvenance())])
    #expect(gifted.unresolvedResiduals.isEmpty && gifted.residualSummary().first?.surplusByClassification[.gift] == 20_000)
    expectNoViolations(gifted)
}

// MARK: Double counting — one transaction, one economic role

@Test func aSettlementTransferCannotAlsoBeAllocatedAsSpendingOrARefund() throws {
    let life = world([obligation("recv", .receivable, .exact(30_000))])
    let settled = try settle(life, try #require(SettlementMatcher.match(transfer("deposit", .incoming, 30_000), in: life).proposal))
    // Allocating the same money as a refund (or as spending) would count the same 30,000 twice.
    for flow in [TransactionFlow.refund, .spend] {
        #expect(failure { _ = try settled.applying([allocation("deposit", to: nil, amount: .exact(30_000), of: 30_000, flow: flow)]) }
            == .allocationOnSettlementTransfer(txID("deposit")))
    }
    // The other order: a transaction that is already spending cannot be taken up as a settlement transfer.
    let spent = world([obligation("recv", .receivable, .exact(30_000))], extra: [allocation("deposit", to: nil, amount: .exact(30_000), of: 30_000, flow: .refund)])
    let proposal = try #require(SettlementMatcher.match(transfer("deposit", .incoming, 30_000), in: spent).proposal)
    #expect(failure { _ = try settle(spent, proposal) } == .settlementTransferIsAllocated(txID("deposit")))
}

@Test func aCorrectedRawTransferCannotBeAllocatedAsSpendingEither() throws {
    let sent = try ActualTransfer(transactionID: txID("in12"), counterpartyID: pid("friend"), direction: .incoming, amount: won(12_000), occurredAtUnixMilliseconds: 1_000)
    let back = try ActualTransfer(transactionID: txID("out4"), counterpartyID: pid("friend"), direction: .outgoing, amount: won(4_000), occurredAtUnixMilliseconds: 2_000)
    let group = try TransactionCorrectionGroup(id: CorrectionGroupID(rawValue: "fix"), sources: [sent, back], provenance: userProvenance(), createdAtUnixMilliseconds: 5)
    let life = try world([obligation("lunch", .receivable, .exact(8_000))]).applying([.createCorrectionGroup(group)])
    #expect(failure { _ = try life.applying([allocation("in12", to: nil, amount: .exact(12_000), of: 12_000, flow: .refund)]) }
        == .allocationOnSettlementTransfer(txID("in12")))
}

@Test func aComponentThatMirrorsAnAllocatedTransactionIsCountedOnlyOnce() throws {
    // The same dinner is both an allocated transaction (60,000) and a shared-expense component of that
    // activity. Summing both views would be 120,000; the unified view counts the 60,000 once.
    let life = dinnerLife(extra: [
        allocation("card", to: "dinner", amount: .exact(60_000), of: 60_000),
        .upsertExpenseComponent(component("meal", .exact(60_000), origin: "card")),
        .upsertExpenseComponent(component("snack", .exact(5_000)))          // no ledger transaction: a different cost
    ])
    let separate = SpendingAnalytics.items(in: life) + SpendingAnalytics.items(fromComponentsIn: life)
    #expect(separate.count == 3)                                              // the naive sum double counts
    let unified = SpendingAnalytics.items(unifiedIn: life)
    #expect(unified.count == 2)
    #expect(unified.compactMap(\.amount.knowledge.knownValue).reduce(0, +) == 65_000)
    // An allocation to a *different* activity is not the same cost as the component.
    let other = dinnerLife(extra: [
        allocation("card", to: nil, amount: .exact(60_000), of: 60_000),
        .upsertExpenseComponent(component("meal", .exact(60_000), origin: "card"))
    ])
    #expect(SpendingAnalytics.items(unifiedIn: other).count == 2)
}

@Test func reimbursementObligationsNeverReduceTheOriginalSpending() throws {
    // I paid 60,000 and b owes me 30,000. The spending stays 60,000; the receivable is a separate fact that
    // settlement later closes. Neither the obligation nor its settlement transfer appears as spending.
    let life = dinnerLife(extra: [
        allocation("card", to: "dinner", amount: .exact(60_000), of: 60_000),
        .createObligation(obligation("b-share", with: "b", .receivable, .exact(30_000), activity: "dinner"))
    ])
    let settled = try settle(life, try #require(SettlementMatcher.match(transfer("back", "b", .incoming, 30_000), in: life).proposal))
    let spend = SpendingAnalytics.items(unifiedIn: settled)
    #expect(spend.count == 1 && spend.first?.amount.knowledge == .exact(60_000))
    expectNoViolations(settled)
}

// MARK: Conservation invariants

@Test func aCorrectionsEffectiveAmountIsTheSignedSumOfItsRawMembersAndConservesMoney() throws {
    let sent = try ActualTransfer(transactionID: txID("in12"), counterpartyID: pid("friend"), direction: .incoming, amount: won(12_000), occurredAtUnixMilliseconds: 1_000)
    let back = try ActualTransfer(transactionID: txID("out4"), counterpartyID: pid("friend"), direction: .outgoing, amount: won(4_000), occurredAtUnixMilliseconds: 2_000)
    let group = try TransactionCorrectionGroup(id: CorrectionGroupID(rawValue: "fix"), sources: [sent, back], provenance: userProvenance(), createdAtUnixMilliseconds: 5)
    #expect(group.effectiveSignedMinorUnits == sent.signedMinorUnits + back.signedMinorUnits)
    let base = world([obligation("lunch", .receivable, .exact(8_000))])
    let corrected = try base.applying([.createCorrectionGroup(group)])
    // Raw and effective are never both counted: they are the same 8,000 seen two ways.
    let unsettled = try #require(MoneyFlowAudit.audit(rawTransfers: [sent, back], in: corrected).first)
    #expect(unsettled.rawSignedMinorUnits == 8_000 && unsettled.effectiveSignedMinorUnits == 8_000 && unsettled.unsettledSignedMinorUnits == 8_000)
    #expect(unsettled.isConserved)
    let effective = try #require(group.effectiveTransfer)
    let settled = try settle(corrected, try #require(SettlementMatcher.match(effective, in: corrected).proposal))
    let audit = try #require(MoneyFlowAudit.audit(rawTransfers: [sent, back], in: settled).first)
    #expect(audit.appliedToObligationsSignedMinorUnits == 8_000 && audit.unsettledSignedMinorUnits == 0 && audit.isConserved)
    // Money that nets to nothing contributes nothing.
    let cancelling = try TransactionCorrectionGroup(
        id: CorrectionGroupID(rawValue: "zero"),
        sources: [try ActualTransfer(transactionID: txID("a"), counterpartyID: pid("friend"), direction: .incoming, amount: won(5_000), occurredAtUnixMilliseconds: 1),
                  try ActualTransfer(transactionID: txID("b"), counterpartyID: pid("friend"), direction: .outgoing, amount: won(5_000), occurredAtUnixMilliseconds: 2)],
        provenance: userProvenance(), createdAtUnixMilliseconds: 5
    )
    let zeroLife = try world().applying([.createCorrectionGroup(cancelling)])
    let zero = try #require(MoneyFlowAudit.audit(rawTransfers: cancelling.sources, in: zeroLife).first)
    #expect(zero.rawSignedMinorUnits == 0 && zero.effectiveSignedMinorUnits == 0 && zero.isConserved)
}

@Test func everySettlementKeepsTheTransferAndTheObligationBooksBalancedAcrossManyShapes() throws {
    // Deterministic property-style sweep: many obligation sets and transfer amounts. Whatever the matcher
    // proposes, accepting it must leave both conservation identities intact:
    //   transfer = applied (receivable +, payable −) + surplus          (shortfall is not money that moved)
    //   original = settled + waived + cancelled + remaining
    var seed: UInt64 = 0x5EED
    func next(_ bound: Int64) -> Int64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int64((seed >> 33) % UInt64(bound))
    }
    var accepted = 0, residualCases = 0
    for round in 0..<300 {
        var obligations: [Obligation] = []
        for index in 0..<Int(1 + next(4)) {
            let direction: ObligationDirection = next(3) == 0 ? .payable : .receivable
            let knowledge: AmountKnowledge
            switch next(6) {
            case 0: knowledge = .unknown
            case 1: knowledge = amountRange(1_000 * (1 + next(5)), 6_000 + 1_000 * next(5))
            case 2: knowledge = .estimated(1_000 * (1 + next(9)))
            default: knowledge = .exact(500 * (1 + next(40)))
            }
            obligations.append(obligation("o\(round)-\(index)", direction, knowledge))
        }
        let life = world(obligations)
        let direction: TransferDirection = next(4) == 0 ? .outgoing : .incoming
        let transferOut = transfer("t\(round)", direction, 500 * (1 + next(60)))
        guard let proposal = SettlementMatcher.match(transferOut, in: life).proposal else { continue }
        let settled = try settle(life, proposal, id: "s\(round)")
        accepted += 1
        if !proposal.residuals.isEmpty { residualCases += 1 }
        // The matcher's own rule: a residual is never proposed while an uncertain obligation is open.
        if !proposal.residuals.isEmpty {
            #expect(obligations.allSatisfy { $0.amount.knowledge.isKnown }, "round \(round): residual with an uncertain obligation open")
        }
        #expect(settled.conservationViolations() == [], "round \(round)")
        let audit = try #require(MoneyFlowAudit.audit(rawTransfers: [transferOut], in: settled).first)
        #expect(audit.isConserved && audit.unsettledSignedMinorUnits == 0, "round \(round)")
        #expect(settled.balances().allSatisfy { $0.isConserved }, "round \(round)")
        // The outstanding total counts a remainder once, whatever shortfall records exist.
        let remaining = settled.balances().compactMap(\.remainingMinorUnits).reduce(0, +)
        let outstanding = settled.outstanding().first
        #expect((outstanding?.receivableMinorUnits ?? 0) + (outstanding?.payableMinorUnits ?? 0) <= remaining, "round \(round)")
    }
    #expect(accepted > 50 && residualCases > 0)        // the sweep actually exercised matches and residuals
}

// MARK: Scenarios V and W — unresolved, confirmedUnknown, and new evidence

private let foodDining = CanonicalCategoryID(rawValue: "food.dining")

private func spendItem(_ transaction: String, category: CategoryAssignment, amount: Int64 = 10_000) -> LifeChange {
    .upsertAllocation(
        TransactionAllocation(
            id: AllocationID(rawValue: "alloc-\(transaction)"), transactionID: txID(transaction), activityID: nil, amount: entry(.exact(amount)),
            category: category, provenance: userProvenance(), createdAtUnixMilliseconds: 1
        ),
        transactionTotal: won(amount), flow: .spend
    )
}

@Test func scenarioVUnresolvedBecomesConfirmedUnknownAndLeavesTheDefaultReview() throws {
    // 정보가 없는 송금: 처음엔 unresolved, 사용자가 "모름"이라고 답하면 confirmedUnknown.
    let life = lifeWithPeople([], extra: [spendItem("who-is-this", category: .unresolved)])
    let id = AllocationID(rawValue: "alloc-who-is-this")
    #expect(SpendingAnalytics.userQuestions(SpendingAnalytics.items(in: life)).map(\.id) == ["alloc-who-is-this"])
    let confirmed = try life.applying([.setAllocationCategory(id, .confirmedUnknown(userProvenance(10, evidenceVersion: 100)))])
    let items = SpendingAnalytics.items(in: confirmed)
    #expect(SpendingAnalytics.reviewQueue(items).isEmpty)                    // not asked again
    #expect(SpendingAnalytics.userQuestions(items, evidenceVersions: ["alloc-who-is-this": 100]).isEmpty)   // same evidence
    #expect(confirmed.allocation(id)?.category.kind == .confirmedUnknown)
    let breakdown = try #require(SpendingAnalytics.byCategoryState(items).first)
    #expect(breakdown.confirmedUnknown?.exactMinorUnits == 10_000 && breakdown.unresolved == nil)
    // Only the user can confirm "I do not know".
    #expect(failure { _ = try life.applying([.setAllocationCategory(id, .confirmedUnknown(autoProvenance(1.0)))]) } == .confirmedUnknownRequiresUser)
    // The classifier backlog and the user's questions are different lists.
    let mixed = lifeWithPeople([], extra: [spendItem("a", category: .unresolved), spendItem("b", category: .unclassified(.notYetEvaluated))])
    let mixedItems = SpendingAnalytics.items(in: mixed)
    #expect(SpendingAnalytics.userQuestions(mixedItems).map(\.id) == ["alloc-a"])
    #expect(SpendingAnalytics.classifierBacklog(mixedItems).map(\.id) == ["alloc-b"])
}

@Test func scenarioWConfirmedUnknownIsReopenedOnlyByNewEvidence() throws {
    let confirmedAt = userProvenance(10, evidenceVersion: 100)
    let life = lifeWithPeople([], extra: [spendItem("x", category: .confirmedUnknown(confirmedAt))])
    let id = AllocationID(rawValue: "alloc-x")
    let policy = AssignmentPolicy()
    func proposal(evidence: Int64?) -> AssignmentProvenance {
        .automated(origin: "merchant-resolver", confidence: 0.97, at: 20, evidenceVersion: evidence)
    }
    // The same evidence (or none stated) can never overwrite the user's "I do not know".
    for evidence in [nil, 50, 100] as [Int64?] {
        #expect(failure { _ = try life.applying([.setAllocationCategory(id, .classified(foodDining, proposal(evidence: evidence)))]) } == .userAssignmentProtected)
        #expect(policy.classification(proposing: foodDining, provenance: proposal(evidence: evidence), replacing: .confirmedUnknown(confirmedAt)).kind == .confirmedUnknown)
    }
    // New merchant/receipt evidence makes it a candidate again, and reclassification is allowed.
    let items = SpendingAnalytics.items(in: life)
    #expect(SpendingAnalytics.userQuestions(items, evidenceVersions: ["alloc-x": 101]).map(\.id) == ["alloc-x"])
    let reclassified = try life.applying([.setAllocationCategory(id, .classified(foodDining, proposal(evidence: 101)))])
    #expect(reclassified.allocation(id)?.category.categoryID == foodDining)
    // A low-confidence proposal still does not become a category, evidence or not.
    let weak = AssignmentProvenance.automated(origin: "merchant-resolver", confidence: 0.3, at: 20, evidenceVersion: 101)
    #expect(policy.classification(proposing: foodDining, provenance: weak, replacing: .confirmedUnknown(confirmedAt)).kind == .confirmedUnknown)
    // The user can always change their mind without any evidence.
    #expect((try life.applying([.setAllocationCategory(id, .classified(foodDining, userProvenance(30)))])).allocation(id)?.category.categoryID == foodDining)
}

@Test func unresolvedAndConfirmedUnknownAreDistinctFromUnclassifiedAndOther() throws {
    #expect(CategoryAssignment.unresolved.needsUserQuestion && !CategoryAssignment.unresolved.needsAutomatedRetry)
    #expect(CategoryAssignment.unclassified(.notYetEvaluated).needsAutomatedRetry && !CategoryAssignment.unclassified(.ambiguous).needsUserQuestion)
    #expect(!CategoryAssignment.confirmedUnknown(userProvenance()).needsUserQuestion)
    #expect(CategoryAssignment.other(userProvenance()).reviewPriority == 0)
    #expect(CategoryAssignment.confirmedUnknown(userProvenance()).reviewPriority == 0)
    // Without a stated evidence version, the time of the user's answer stands in for it.
    let answered = CategoryAssignment.confirmedUnknown(userProvenance(10))
    #expect(answered.confirmedEvidenceVersion == 10 && !answered.isWorthAskingAbout(latestEvidenceVersion: 10) && answered.isWorthAskingAbout(latestEvidenceVersion: 11))
    // Serialization keeps the evidence version.
    let data = try JSONEncoder().encode(CategoryAssignment.confirmedUnknown(userProvenance(10, evidenceVersion: 100)))
    #expect(try JSONDecoder().decode(CategoryAssignment.self, from: data).confirmedEvidenceVersion == 100)
}
