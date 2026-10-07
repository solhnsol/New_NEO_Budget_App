import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private func failure(_ block: () throws -> Void) -> LifeValidationError? {
    do { try block(); return nil } catch let error as LifeValidationError { return error } catch { return nil }
}

private func world(_ obligations: [Obligation], people: [String] = ["friend"], extra: [LifeChange] = []) -> LifeState {
    lifeWithPeople(people, extra: obligations.map { .createObligation($0) } + extra)
}

private func ids(_ values: [ObligationID]) -> [String] { values.map(\.rawValue).sorted() }

// MARK: Obligations are not transactions

@Test func anObligationExistsWithNoTransactionAndNoOnAllAccount() throws {
    // 상대방이 점심을 결제했다. 내 원장에는 거래가 없지만 줄 돈은 존재한다.
    let life = world([obligation("lunch-share", .payable, .unknown)])
    let stored = try #require(life.obligations[oid("lunch-share")])
    #expect(stored.originTransactionID == nil)
    #expect(stored.status == .open && stored.direction == .payable && stored.amount.knowledge == .unknown)
    #expect(life.allocationSets.isEmpty)                                      // nothing in the ledger-facing side
    #expect(life.persons[pid("friend")]?.externalIdentity == nil)
}

@Test func obligationsOnlyStartOpenWithRealCounterpartiesAndNeverWithMyself() throws {
    var settled = obligation("o", .payable, .exact(5_000))
    settled.status = .settled
    #expect(failure { _ = try world([]).applying([.createObligation(settled)]) } == .obligationMustStartOpen(oid("o")))
    #expect(failure { _ = try world([]).applying([.createObligation(obligation("o", with: "ghost", .payable, .exact(1)))]) } == .unknownPerson(pid("ghost")))
    #expect(failure { _ = try world([]).applying([.createObligation(obligation("o", with: "me", .payable, .exact(1)))]) } == .counterpartyIsSelf(myself))
    #expect(failure { _ = try world([obligation("o", .payable, .exact(1))]).applying([.createObligation(obligation("o", .receivable, .exact(2)))]) } == .duplicateIdentifier(entity: "obligation", id: "o"))
}

@Test func anObligationMayNameAnActivityAndOriginTransaction() throws {
    let event = event("e", title: "데이트", from: at(today, 12), to: at(today, 14))
    let activity = Activity.materialized(from: event, id: ActivityID(rawValue: "date"), at: 1)
    var movie = obligation("movie", .receivable, .exact(7_000), activity: "date")
    movie = Obligation(
        id: movie.id, counterpartyID: movie.counterpartyID, activityID: movie.activityID, direction: .receivable, amount: movie.amount,
        provenance: userProvenance(), createdAtUnixMilliseconds: 1, originTransactionID: txID("movie-ticket"), label: "영화"
    )
    let life = try world([], extra: [.createActivity(activity), .createObligation(movie)])
    #expect(life.obligations(forActivity: ActivityID(rawValue: "date")).map(\.label) == ["영화"])
    #expect(failure { _ = try world([]).applying([.createObligation(obligation("x", .payable, .exact(1), activity: "ghost"))]) } == .unknownActivity(ActivityID(rawValue: "ghost")))
}

@Test func anObligationAmountSharpensUnderTheSameKnowledgeRules() throws {
    let life = world([obligation("lunch", .payable, .unknown)])
    let auto = autoProvenance(1.0)
    let promoted = try life.applying([.setObligationAmount(oid("lunch"), entry(inferred(6_000), provenance: auto))])
    #expect(promoted.obligations[oid("lunch")]?.amount.knowledge == inferred(6_000))
    // The user's later word wins and becomes exact.
    let confirmed = try promoted.applying([.setObligationAmount(oid("lunch"), entry(.exact(6_500)))])
    #expect(confirmed.obligations[oid("lunch")]?.amount.knowledge == .exact(6_500))
    // After that, no automatic inference may touch it.
    #expect(failure { _ = try confirmed.applying([.setObligationAmount(oid("lunch"), entry(inferred(9_000), provenance: auto))]) } == .amountUpdateRejected(.rejectedProtectedUserAmount))
    #expect(failure { _ = try promoted.applying([.setObligationAmount(oid("lunch"), entry(.unknown, provenance: auto))]) } == .amountUpdateRejected(.rejectedWeakening))
    #expect(failure { _ = try life.applying([.setObligationAmount(oid("ghost"), entry(.exact(1)))]) } == .unknownObligation(oid("ghost")))
}

@Test func cancellingRequiresNoSettlementsAndRespectsWhoCreatedIt() throws {
    let life = world([obligation("o", .payable, .exact(5_000)), obligation("auto", .payable, .exact(5_000), provenance: autoProvenance(0.9))])
    #expect(failure { _ = try life.applying([.cancelObligation(oid("o"), by: autoProvenance(0.99))]) } == .userAssignmentProtected)
    #expect(settleable(try life.applying([.cancelObligation(oid("o"), by: userProvenance())]), "o") == .cancelled)
    #expect(settleable(try life.applying([.cancelObligation(oid("auto"), by: autoProvenance(0.9))]), "auto") == .cancelled)
    #expect(try life.applying([.cancelObligation(oid("o"), by: userProvenance()), .cancelObligation(oid("o"), by: userProvenance())]).obligations[oid("o")]?.status == .cancelled)
    let settled = try settle(world([obligation("o", .receivable, .exact(5_000))]), try #require(SettlementMatcher.match(transfer("t", .incoming, 5_000), in: world([obligation("o", .receivable, .exact(5_000))])).proposal))
    #expect(failure { _ = try settled.applying([.cancelObligation(oid("o"), by: userProvenance())]) } == .obligationHasSettlements(oid("o")))
}

// MARK: Netting — a different transfer is not a failed settlement

@Test func aTransferEqualToOneObligationIsAnExactMatch() throws {
    let life = world([obligation("r", .receivable, .exact(30_000)), obligation("other-person", with: "friend", .payable, .exact(99))])
    guard case let .exactMatch(proposal) = SettlementMatcher.match(transfer("t", .incoming, 30_000), in: life) else {
        Issue.record("expected exact match")
        return
    }
    // The tiny payable does not matter: only {r} adds up to +30,000.
    #expect(proposal.applications == [ProposedApplication(obligationID: oid("r"), appliedMinorUnits: 30_000)])
    #expect(proposal.inferences.isEmpty && !proposal.isPartial)
}

@Test func scenarioB_aNetTransferSettlesBothDirectionsAtOnce() throws {
    // 내가 받을 돈 +30,000, 내가 줄 돈 -12,000, net +18,000 → 실제 입금 18,000
    let life = world([obligation("recv", .receivable, .exact(30_000)), obligation("pay", .payable, .exact(12_000))])
    let result = SettlementMatcher.match(transfer("t", .incoming, 18_000), in: life)
    guard case let .netMatch(proposal) = result else {
        Issue.record("expected net match, got \(result)")
        return
    }
    #expect(proposal.applications.map(\.obligationID.rawValue) == ["pay", "recv"])
    #expect(proposal.applications.map(\.appliedMinorUnits) == [12_000, 30_000])
    let settled = try settle(life, proposal)
    #expect(settleable(settled, "recv") == .settled && settleable(settled, "pay") == .settled)
    #expect(settled.settlements.count == 1)
}

@Test func theSameNetWorksWhenIPayInstead() throws {
    let life = world([obligation("recv", .receivable, .exact(12_000)), obligation("pay", .payable, .exact(30_000))])
    guard case let .netMatch(proposal) = SettlementMatcher.match(transfer("t", .outgoing, 18_000), in: life) else {
        Issue.record("expected net match")
        return
    }
    #expect(try settle(life, proposal).obligations.values.allSatisfy { $0.status == .settled })
}

@Test func aTransferThatNothingExplainsIsReportedAsNoMatchNotAsFailure() {
    #expect(SettlementMatcher.match(transfer("t", .incoming, 1_000), in: world([])) == .noMatch(.noOpenObligations))
    // Only payables are open, and I received money: nothing in the data explains it.
    let life = world([obligation("pay", .payable, .exact(5_000))])
    #expect(SettlementMatcher.match(transfer("t", .incoming, 1_000), in: life) == .noMatch(.noCombinationExplainsTransfer))
    #expect(SettlementMatcher.match(transfer("t", .incoming, 5_000), in: life) == .noMatch(.noCombinationExplainsTransfer))
}

@Test func onlyTheSameCounterpartyAndCurrencyAreCandidates() {
    let life = world(
        [obligation("friend-usd", with: "friend", .receivable, .exact(5_000), currency: "USD"),
         obligation("other", with: "other", .receivable, .exact(5_000))],
        people: ["friend", "other"]
    )
    #expect(SettlementMatcher.match(transfer("t", "friend", .incoming, 5_000), in: life) == .noMatch(.noOpenObligations))
    #expect(SettlementMatcher.match(transfer("t", "other", .incoming, 5_000), in: life).proposal?.applications.map(\.obligationID) == [oid("other")])
}

@Test func settledAndCancelledObligationsAreNotCandidates() throws {
    let base = world([obligation("a", .receivable, .exact(5_000)), obligation("b", .receivable, .exact(7_000))])
    let cancelled = try base.applying([.cancelObligation(oid("b"), by: userProvenance())])
    #expect(SettlementMatcher.match(transfer("t", .incoming, 7_000), in: cancelled) == .noMatch(.noCombinationExplainsTransfer))
    let first = try settle(cancelled, try #require(SettlementMatcher.match(transfer("t1", .incoming, 5_000), in: cancelled).proposal), id: "s1")
    #expect(SettlementMatcher.match(transfer("t2", .incoming, 5_000), in: first) == .noMatch(.noOpenObligations))
}

@Test func theSameTransferCannotSettleTwice() throws {
    let life = world([obligation("a", .receivable, .exact(5_000)), obligation("b", .receivable, .exact(7_000))])
    let proposal = try #require(SettlementMatcher.match(transfer("t", .incoming, 5_000), in: life).proposal)
    let first = try settle(life, proposal)
    #expect(first.settlements.count == 1)
    #expect(SettlementMatcher.match(transfer("t", .incoming, 5_000), in: first) == .noMatch(.transferAlreadySettled))
    // Recording a second settlement for the same transaction is refused at the state boundary too.
    #expect(failure { _ = try settle(first, proposal, id: "again") } == .transferAlreadySettled(txID("t")))
}

// MARK: Ambiguity is preserved

@Test func twoObligationsOfTheSameAmountAreAmbiguousNotArbitrarilyPicked() {
    let life = world([obligation("a", .receivable, .exact(10_000)), obligation("b", .receivable, .exact(10_000))])
    guard case let .ambiguous(report) = SettlementMatcher.match(transfer("t", .incoming, 10_000), in: life) else {
        Issue.record("expected ambiguous")
        return
    }
    #expect(report.reason == .multipleExplanations && report.alternativeCount == 2 && !report.narrowedByRequest)
    #expect(Set(report.alternatives.map { ids($0.obligationIDs) }) == [["a"], ["b"]])
    #expect(report.constraint == nil)
}

@Test func aSettlementRequestIsEvidenceThatBreaksAnOtherwiseTiedMatch() throws {
    let base = world([obligation("a", .receivable, .exact(10_000)), obligation("b", .receivable, .exact(10_000))])
    let request = try SettlementRequest(id: SettlementRequestID(rawValue: "req"), counterpartyID: pid("friend"), obligationIDs: [oid("b")], createdAtUnixMilliseconds: 1)
    let life = try base.applying([.createSettlementRequest(request)])
    guard case let .exactMatch(proposal) = SettlementMatcher.match(transfer("t", .incoming, 10_000), in: life, requestID: request.id) else {
        Issue.record("expected the request to resolve the tie")
        return
    }
    #expect(proposal.applications.map(\.obligationID) == [oid("b")])
    #expect(proposal.requestID == request.id)
}

@Test func aRequestNeverOverridesWhatTheNumbersSayWhenTheyAreUnambiguous() throws {
    // The request names "a", but only "b" can explain 7,000.
    let base = world([obligation("a", .receivable, .exact(10_000)), obligation("b", .receivable, .exact(7_000))])
    let request = try SettlementRequest(id: SettlementRequestID(rawValue: "req"), counterpartyID: pid("friend"), obligationIDs: [oid("a")], createdAtUnixMilliseconds: 1)
    let life = try base.applying([.createSettlementRequest(request)])
    let proposal = try #require(SettlementMatcher.match(transfer("t", .incoming, 7_000), in: life, requestID: request.id).proposal)
    #expect(proposal.applications.map(\.obligationID) == [oid("b")])
    #expect(proposal.requestID == nil)                                          // it did not actually concern the request
}

// MARK: Unknown amounts — inferred only when the explanation is unique

@Test func scenarioB2_oneUnknownPayableIsInferredFromTheNet() throws {
    // 받을 돈 30,000 (확정), 줄 돈 미상, 실제 입금 18,000 → 줄 돈 = 12,000 (유일한 해)
    let life = world([obligation("recv", .receivable, .exact(30_000)), obligation("pay", .payable, .unknown)])
    let result = SettlementMatcher.match(transfer("t", .incoming, 18_000), in: life)
    guard case let .inferredUniqueSolution(proposal) = result else {
        Issue.record("expected an inferred unique solution, got \(result)")
        return
    }
    #expect(proposal.inferences == [ProposedInference(obligationID: oid("pay"), minorUnits: 12_000)])
    #expect(Set(proposal.applications.map(\.appliedMinorUnits)) == [12_000, 30_000])

    let settled = try settle(life, proposal, id: "s-infer")
    let pay = try #require(settled.obligations[oid("pay")])
    #expect(pay.status == .settled && settleable(settled, "recv") == .settled)
    // The amount is inferred, with its evidence, and is NOT exact.
    guard case let .inferred(value, evidence) = pay.amount.knowledge else {
        Issue.record("expected an inferred amount, got \(pay.amount.knowledge)")
        return
    }
    #expect(value == 12_000)
    #expect(evidence.settlementID == SettlementID(rawValue: "s-infer"))
    #expect(pay.amount.provenance.source == .automated)
    #expect(pay.amount.knowledge != .exact(12_000))
}

@Test func anInferredAmountOnlyFitsInsideAKnownRange() throws {
    let inside = world([obligation("recv", .receivable, .exact(30_000)), obligation("pay", .payable, amountRange(10_000, 15_000))])
    #expect(SettlementMatcher.match(transfer("t", .incoming, 18_000), in: inside).proposal?.inferences == [ProposedInference(obligationID: oid("pay"), minorUnits: 12_000)])
    // 12,000 is outside 1,000...5,000, so that unknown cannot explain the transfer; nothing is forced.
    let outside = world([obligation("recv", .receivable, .exact(30_000)), obligation("pay", .payable, amountRange(1_000, 5_000))])
    #expect(SettlementMatcher.match(transfer("t", .incoming, 18_000), in: outside) == .insufficientEvidence(.possiblePartialSettlement([oid("recv")])))
}

@Test func scenarioC_severalUnknownsOnlyYieldAConstraintNeverAnAutomaticSplit() throws {
    // 받을 돈 30,000, 줄 돈 X (미상), 줄 돈 Y (미상), 실제 입금 18,000 → X + Y = 12,000 까지만 안다
    let life = world([obligation("recv", .receivable, .exact(30_000)), obligation("x", .payable, .unknown), obligation("y", .payable, .unknown)])
    let result = SettlementMatcher.match(transfer("t", .incoming, 18_000), in: life)
    guard case let .ambiguous(report) = result else {
        Issue.record("expected ambiguous, got \(result)")
        return
    }
    #expect(report.alternativeCount == 3)                                       // {recv,x,y}, {recv,x}, {recv,y}
    let constraint = try #require(report.constraint)
    #expect(constraint.totalMinorUnits == 12_000 && constraint.currency == "KRW")
    #expect(ids(constraint.unknownObligationIDs) == ["x", "y"] && ids(constraint.knownObligationIDs) == ["recv"])
    #expect(result.proposal == nil)                                             // nothing is decided automatically
    // Nothing was written: both unknowns are still unknown.
    #expect(life.obligations[oid("x")]?.amount.knowledge == .unknown && life.obligations[oid("y")]?.amount.knowledge == .unknown)
}

@Test func theConstraintFromAnAmbiguousMatchCanBeKeptAndLaterResolvedByNewEvidence() throws {
    let life = world([obligation("recv", .receivable, .exact(30_000)), obligation("x", .payable, .unknown), obligation("y", .payable, .unknown)])
    guard case let .ambiguous(report) = SettlementMatcher.match(transfer("t", .incoming, 18_000), in: life), let constraint = report.constraint else {
        Issue.record("expected a constraint")
        return
    }
    let evidence = InferenceEvidence(summary: "X + Y = 12,000 from the net of an 18,000 transfer")
    let group = try AmountGroup(
        id: AmountGroupID(rawValue: "g"),
        total: entry(.inferred(constraint.totalMinorUnits, evidence), provenance: autoProvenance(1.0)),
        members: constraint.unknownObligationIDs.map { .obligation($0) },
        createdAtUnixMilliseconds: 5
    )
    let kept = try life.applying([.defineAmountGroup(group)])
    guard case .underdetermined = kept.analysis(ofGroup: group.id) else {
        Issue.record("the group must still be underdetermined")
        return
    }
    // The user later learns X = 5,000. Now Y is forced to 7,000.
    let learned = try kept.applying([.setObligationAmount(oid("x"), entry(.exact(5_000)))])
    #expect(learned.analysis(ofGroup: group.id) == .uniqueSolution(member: .obligation(oid("y")), minorUnits: 7_000))
    // A fact that breaks the constraint is refused: X alone cannot exceed the 12,000 the two share.
    #expect(failure { _ = try kept.applying([.setObligationAmount(oid("x"), entry(.exact(13_000)))]) } == .amountGroupContradiction(group.id, .knownSumExceedsTotal))
}

@Test func scenarioA_aDateSettlementInfersTheLunchShareWhenARequestCoversEverything() throws {
    // 점심: 상대 결제, 내 부담금 미상 / 영화: 내가 결제, 상대 부담금 7,000 / 카페: 상대 결제, 내 부담금 6,000
    let life = world([
        obligation("lunch", .payable, .unknown, activity: nil),
        obligation("movie", .receivable, .exact(7_000)),
        obligation("cafe", .payable, .exact(6_000))
    ])
    // I send 5,000. Without more evidence, three different explanations fit.
    let outgoing = transfer("t", .outgoing, 5_000)
    guard case let .ambiguous(report) = SettlementMatcher.match(outgoing, in: life) else {
        Issue.record("expected ambiguity without a request")
        return
    }
    #expect(report.alternativeCount == 3)
    // OnAll created a settlement request that covers all three obligations.
    let request = try SettlementRequest(
        id: SettlementRequestID(rawValue: "date-request"), counterpartyID: pid("friend"),
        obligationIDs: [oid("lunch"), oid("movie"), oid("cafe")], createdAtUnixMilliseconds: 2
    )
    let withRequest = try life.applying([.createSettlementRequest(request)])
    let result = SettlementMatcher.match(outgoing, in: withRequest, requestID: request.id)
    guard case let .inferredUniqueSolution(proposal) = result else {
        Issue.record("expected the request to make the explanation unique, got \(result)")
        return
    }
    // 7,000 - 6,000 - 6,000 = -5,000: the lunch share is forced to 6,000.
    #expect(proposal.inferences == [ProposedInference(obligationID: oid("lunch"), minorUnits: 6_000)])
    #expect(proposal.requestID == request.id)
    let settled = try settle(withRequest, proposal)
    #expect(settled.obligations.values.allSatisfy { $0.status == .settled })
    #expect(settled.settlementRequests[request.id]?.status == .fulfilled)
    #expect(settled.obligations[oid("lunch")]?.amount.knowledge.knownValue == 6_000)
    if case .exact = settled.obligations[oid("lunch")]?.amount.knowledge { Issue.record("an inference must not be recorded as exact") }
}

@Test func theRequestedAmountMinusARelatedPayableExplainsTheDeposit() throws {
    // 30,000원 보내달라고 요청했고, 같은 상대에게 줄 돈 12,000이 있었다. 실제 입금 18,000.
    let base = world([obligation("recv", .receivable, .exact(30_000)), obligation("pay", .payable, .exact(12_000))])
    let request = try SettlementRequest(
        id: SettlementRequestID(rawValue: "req"), counterpartyID: pid("friend"), obligationIDs: [oid("recv")],
        requestedAmount: try Money(minorUnits: 30_000, currency: "KRW"), createdAtUnixMilliseconds: 1
    )
    let life = try base.applying([.createSettlementRequest(request)])
    guard case let .netMatch(proposal) = SettlementMatcher.match(transfer("t", .incoming, 18_000), in: life, requestID: request.id) else {
        Issue.record("expected net match")
        return
    }
    #expect(proposal.requestID == request.id)
    let settled = try settle(life, proposal)
    #expect(settled.settlementRequests[request.id]?.status == .fulfilled)
}

// MARK: Partial settlement and many-to-many

@Test func aSmallerTransferIsPossiblyPartialButNotAssumedWithoutEvidence() {
    let life = world([obligation("recv", .receivable, .exact(30_000))])
    #expect(SettlementMatcher.match(transfer("t", .incoming, 18_000), in: life) == .insufficientEvidence(.possiblePartialSettlement([oid("recv")])))
}

@Test func aRequestForThatAmountMakesAPartialSettlementTheEvidencedExplanation() throws {
    let base = world([obligation("recv", .receivable, .exact(30_000))])
    let request = try SettlementRequest(
        id: SettlementRequestID(rawValue: "req"), counterpartyID: pid("friend"), obligationIDs: [oid("recv")],
        requestedAmount: try Money(minorUnits: 10_000, currency: "KRW"), createdAtUnixMilliseconds: 1
    )
    let life = try base.applying([.createSettlementRequest(request)])
    guard case let .exactMatch(proposal) = SettlementMatcher.match(transfer("t1", .incoming, 10_000), in: life, requestID: request.id) else {
        Issue.record("expected a partial exact match")
        return
    }
    #expect(proposal.isPartial && proposal.applications == [ProposedApplication(obligationID: oid("recv"), appliedMinorUnits: 10_000)])
    let afterFirst = try settle(life, proposal, id: "s1")
    #expect(settleable(afterFirst, "recv") == .partiallySettled)
    #expect(afterFirst.appliedMinorUnits(for: oid("recv")) == 10_000)
    #expect(afterFirst.settlementRequests[request.id]?.status == .open)

    // The remaining 20,000 arrives later, as a second settlement of the same obligation.
    let second = try #require(SettlementMatcher.match(transfer("t2", .incoming, 20_000), in: afterFirst).proposal)
    #expect(second.applications == [ProposedApplication(obligationID: oid("recv"), appliedMinorUnits: 20_000)])
    let done = try settle(afterFirst, second, id: "s2")
    #expect(settleable(done, "recv") == .settled && done.settlements.count == 2)
    #expect(done.settlementRequests[request.id]?.status == .fulfilled)
}

@Test func oneTransferCanResolveSeveralObligations() throws {
    // 실제 17,000원이 A(+20,000), B(-6,000), C(+3,000)을 함께 정리한다.
    let life = world([obligation("a", .receivable, .exact(20_000)), obligation("b", .payable, .exact(6_000)), obligation("c", .receivable, .exact(3_000))])
    guard case let .netMatch(proposal) = SettlementMatcher.match(transfer("t", .incoming, 17_000), in: life) else {
        Issue.record("expected net match")
        return
    }
    #expect(proposal.applications.count == 3)
    #expect(try settle(life, proposal).obligations.values.allSatisfy { $0.status == .settled })
}

@Test func tooManyOpenObligationsAreReportedInsteadOfGuessed() {
    let many = (0..<13).map { obligation("o\($0)", .receivable, .exact(Int64(1_000 + $0))) }
    #expect(SettlementMatcher.match(transfer("t", .incoming, 1_000), in: world(many)) == .insufficientEvidence(.tooManyOpenObligations(13)))
}

// MARK: Settlement invariants at the state boundary

private func manualSettlement(
    _ id: String = "s", transfer: ActualTransfer, applying: [(String, Int64)], promotions: [AppliedPromotion] = [],
    request: String? = nil, provenance: AssignmentProvenance = userProvenance()
) throws -> Settlement {
    try Settlement(
        id: SettlementID(rawValue: id), transfer: transfer,
        allocations: applying.map { try SettlementAllocation(obligationID: oid($0.0), appliedMinorUnits: $0.1) },
        promotions: promotions, requestID: request.map { SettlementRequestID(rawValue: $0) },
        provenance: provenance, createdAtUnixMilliseconds: 10
    )
}

@Test func aSettlementMustNetExactlyToTheTransfer() throws {
    let life = world([obligation("recv", .receivable, .exact(30_000)), obligation("pay", .payable, .exact(12_000))])
    let wrong = try manualSettlement(transfer: transfer("t", .incoming, 17_000), applying: [("recv", 30_000), ("pay", 12_000)])
    #expect(failure { _ = try life.applying([.recordSettlement(wrong)]) } == .settlementNetMismatch)
    let wrongDirection = try manualSettlement(transfer: transfer("t", .outgoing, 18_000), applying: [("recv", 30_000), ("pay", 12_000)])
    #expect(failure { _ = try life.applying([.recordSettlement(wrongDirection)]) } == .settlementNetMismatch)
    let right = try manualSettlement(transfer: transfer("t", .incoming, 18_000), applying: [("recv", 30_000), ("pay", 12_000)])
    #expect(try life.applying([.recordSettlement(right)]).settlements.count == 1)
}

@Test func aSettlementCannotApplyMoreThanAnObligationOrTheWrongPerson() throws {
    let life = world([obligation("recv", .receivable, .exact(5_000))], people: ["friend", "other"])
    let over = try manualSettlement(transfer: transfer("t", .incoming, 6_000), applying: [("recv", 6_000)])
    #expect(failure { _ = try life.applying([.recordSettlement(over)]) } == .appliedExceedsObligation(oid("recv")))
    let wrongPerson = try manualSettlement(transfer: transfer("t", "other", .incoming, 5_000), applying: [("recv", 5_000)])
    #expect(failure { _ = try life.applying([.recordSettlement(wrongPerson)]) } == .obligationCounterpartyMismatch(oid("recv")))
    let ghost = try manualSettlement(transfer: transfer("t", .incoming, 5_000), applying: [("ghost", 5_000)])
    #expect(failure { _ = try life.applying([.recordSettlement(ghost)]) } == .unknownObligation(oid("ghost")))
    let usd = try manualSettlement(transfer: transfer("t", .incoming, 5_000, currency: "USD"), applying: [("recv", 5_000)])
    #expect(failure { _ = try life.applying([.recordSettlement(usd)]) } == .obligationCurrencyMismatch(oid("recv")))
}

@Test func settlementRecordsValidateTheirOwnShape() {
    #expect(throws: SettlementValidationError.emptyAllocations) {
        try Settlement(id: SettlementID(rawValue: "s"), transfer: transfer("t", .incoming, 5), allocations: [], provenance: userProvenance(), createdAtUnixMilliseconds: 1)
    }
    #expect(throws: SettlementValidationError.nonPositiveApplied(oid("a"))) { try SettlementAllocation(obligationID: oid("a"), appliedMinorUnits: 0) }
    #expect(throws: SettlementValidationError.nonPositiveAmount) {
        try ActualTransfer(transactionID: txID("t"), counterpartyID: pid("friend"), direction: .incoming, amount: won(0), occurredAtUnixMilliseconds: 1)
    }
    #expect(throws: SettlementValidationError.emptyObligationList) {
        try SettlementRequest(id: SettlementRequestID(rawValue: "r"), counterpartyID: pid("friend"), obligationIDs: [], createdAtUnixMilliseconds: 1)
    }
    #expect(throws: SettlementValidationError.duplicateObligation(oid("a"))) {
        try SettlementRequest(id: SettlementRequestID(rawValue: "r"), counterpartyID: pid("friend"), obligationIDs: [oid("a"), oid("a")], createdAtUnixMilliseconds: 1)
    }
}

@Test func anAutomatedPromotionMustBeInferredNeverExact() throws {
    let life = world([obligation("recv", .receivable, .exact(30_000)), obligation("pay", .payable, .unknown)])
    let before = try #require(life.obligations[oid("pay")]).amount
    let sneaky = AppliedPromotion(obligationID: oid("pay"), previous: before, applied: entry(.exact(12_000), provenance: autoProvenance(1.0)))
    let settlement = try manualSettlement(transfer: transfer("t", .incoming, 18_000), applying: [("recv", 30_000), ("pay", 12_000)], promotions: [sneaky], provenance: autoProvenance(1.0))
    #expect(failure { _ = try life.applying([.recordSettlement(settlement)]) } == .automatedPromotionMustBeInferred(oid("pay")))
}

@Test func aStalePromotionIsRefused() throws {
    let life = world([obligation("recv", .receivable, .exact(30_000)), obligation("pay", .payable, .unknown)])
    let outdated = AppliedPromotion(obligationID: oid("pay"), previous: entry(.estimated(1)), applied: entry(inferred(12_000), provenance: autoProvenance(1.0)))
    let settlement = try manualSettlement(transfer: transfer("t", .incoming, 18_000), applying: [("recv", 30_000), ("pay", 12_000)], promotions: [outdated])
    #expect(failure { _ = try life.applying([.recordSettlement(settlement)]) } == .staleAmountPromotion(oid("pay")))
}

@Test func aUserCanSettleManuallyAndStateExactAmountsThemselves() throws {
    // The matcher called Scenario C ambiguous; the user decides X = 5,000 and Y = 7,000, as exact amounts.
    let life = world([obligation("recv", .receivable, .exact(30_000)), obligation("x", .payable, .unknown), obligation("y", .payable, .unknown)])
    let promotions = [
        AppliedPromotion(obligationID: oid("x"), previous: try #require(life.obligations[oid("x")]).amount, applied: entry(.exact(5_000))),
        AppliedPromotion(obligationID: oid("y"), previous: try #require(life.obligations[oid("y")]).amount, applied: entry(.exact(7_000)))
    ]
    let settlement = try manualSettlement(transfer: transfer("t", .incoming, 18_000), applying: [("recv", 30_000), ("x", 5_000), ("y", 7_000)], promotions: promotions)
    let settled = try life.applying([.recordSettlement(settlement)])
    #expect(settled.obligations.values.allSatisfy { $0.status == .settled })
    #expect(settled.obligations[oid("x")]?.amount.knowledge == .exact(5_000))
}

@Test func removingASettlementUndoesItsStatusesInferencesAndRequest() throws {
    let base = world([obligation("recv", .receivable, .exact(30_000)), obligation("pay", .payable, .unknown)])
    let request = try SettlementRequest(id: SettlementRequestID(rawValue: "req"), counterpartyID: pid("friend"), obligationIDs: [oid("recv")], createdAtUnixMilliseconds: 1)
    let life = try base.applying([.createSettlementRequest(request)])
    let proposal = try #require(SettlementMatcher.match(transfer("t", .incoming, 18_000), in: life, requestID: request.id).proposal)
    let settled = try settle(life, proposal, id: "s1")
    #expect(settled.settlementRequests[request.id]?.status == .fulfilled)

    let undone = try settled.applying([.removeSettlement(SettlementID(rawValue: "s1"), by: userProvenance())])
    #expect(settleable(undone, "recv") == .open && settleable(undone, "pay") == .open)
    #expect(undone.obligations[oid("pay")]?.amount.knowledge == .unknown)            // the inference rested on the settlement
    #expect(undone.settlementRequests[request.id]?.status == .open)
    #expect(undone.settlements.isEmpty)
    #expect(SettlementMatcher.match(transfer("t", .incoming, 18_000), in: undone).proposal != nil)   // the transfer can be matched again
}

@Test func automationCannotRemoveAUsersSettlement() throws {
    let life = world([obligation("recv", .receivable, .exact(5_000))])
    let settled = try settle(life, try #require(SettlementMatcher.match(transfer("t", .incoming, 5_000), in: life).proposal), provenance: userProvenance())
    #expect(failure { _ = try settled.applying([.removeSettlement(SettlementID(rawValue: "s1"), by: autoProvenance(0.99))]) } == .userAssignmentProtected)
    #expect(failure { _ = try settled.applying([.removeSettlement(SettlementID(rawValue: "nope"), by: userProvenance())]) } == .unknownSettlement(SettlementID(rawValue: "nope")))
}

@Test func settleableObligationsKeepAFixedOrder() {
    let life = world([obligation("b", .payable, .exact(1)), obligation("a", .payable, .exact(1)), obligation("c", .payable, .exact(1))])
    #expect(life.settleableObligations(with: pid("friend")).map(\.id.rawValue) == ["a", "b", "c"])
}

@Test func matchingIsDeterministic() {
    let life = world([obligation("recv", .receivable, .exact(30_000)), obligation("x", .payable, .unknown), obligation("y", .payable, .unknown)])
    let first = SettlementMatcher.match(transfer("t", .incoming, 18_000), in: life)
    for _ in 0..<5 { #expect(SettlementMatcher.match(transfer("t", .incoming, 18_000), in: life) == first) }
}
