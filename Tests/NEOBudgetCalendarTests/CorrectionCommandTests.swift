import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private func raw(_ id: String, _ direction: TransferDirection, _ amount: Int64, at time: Int64) -> ActualTransfer {
    try! ActualTransfer(
        transactionID: txID(id), counterpartyID: pid("friend"), direction: direction,
        amount: won(amount), occurredAtUnixMilliseconds: time
    )
}

private func harness(obligations: [Obligation]) -> Harness {
    Harness.make(life: lifeWithPeople(["friend"], extra: obligations.map { .createObligation($0) }))
}

private func applied(_ outcome: CalendarCommandOutcome) -> AppliedCommand? {
    if case let .applied(value) = outcome { return value }
    return nil
}

// MARK: Scenario G through the service

@Test func scenarioGEndToEndThroughTheService() async throws {
    let sent = raw("in12", .incoming, 12_000, at: 1_000)
    let back = raw("out4", .outgoing, 4_000, at: 2_000)
    let h = harness(obligations: [obligation("lunch", .receivable, .exact(8_000))])

    // Before the user speaks, +12,000 is just a transfer that is 4,000 larger than what was owed.
    let before = try await h.service.matchSettlement(sent)
    guard case .matchWithResidual = before else {
        Issue.record("expected a residual before any correction: \(before)")
        return
    }

    // Automation cannot decide it was a mistake.
    #expect(await h.service.perform(.createCorrection(CreateCorrectionInput(sources: [sent, back], provenance: autoProvenance(0.99))))
        == .rejected(.invalidCorrection(.requiresUser)))
    #expect((await h.life()).correctionGroups.isEmpty)

    let created = await h.service.perform(.createCorrection(CreateCorrectionInput(sources: [sent, back], provenance: userProvenance())))
    let groupID = try #require(applied(created)?.correctionGroupID)
    let rawAfter = try await h.service.matchSettlement(sent)
    #expect(rawAfter == .noMatch(.partOfCorrectionGroup(groupID)))

    // The effective +8,000 settles the 8,000 exactly.
    let effectiveMatch = try await h.service.matchEffectiveTransfer(of: groupID)
    let match = try #require(effectiveMatch)
    guard case let .exactMatch(proposal) = match else {
        Issue.record("expected an exact match: \(match)")
        return
    }
    let settlement = await h.service.perform(.applySettlement(ApplySettlementInput(proposal: proposal, provenance: userProvenance())))
    #expect(applied(settlement)?.settlementID != nil)
    let state = await h.life()
    #expect(state.obligations[oid("lunch")]?.status == .settled)
    #expect(state.residuals.isEmpty)
    #expect(state.correctionGroups[groupID]?.sources == [sent, back])          // the raw facts are still there, unchanged

    // It cannot be quietly undone while a settlement stands on it.
    #expect(await h.service.perform(.removeCorrection(RemoveCorrectionInput(groupID: groupID, by: userProvenance())))
        == .rejected(.lifeValidation(.correctionHasSettlement(groupID))))
    let ghost = try await h.service.matchEffectiveTransfer(of: CorrectionGroupID(rawValue: "ghost"))
    #expect(ghost == nil)
}

@Test func removingACorrectionThroughTheServiceBringsTheRawMeaningBack() async throws {
    let sent = raw("in12", .incoming, 12_000, at: 1_000)
    let back = raw("out4", .outgoing, 4_000, at: 2_000)
    let h = harness(obligations: [obligation("lunch", .receivable, .exact(8_000))])
    let groupID = try #require(applied(await h.service.perform(.createCorrection(CreateCorrectionInput(sources: [sent, back], provenance: userProvenance()))))?.correctionGroupID)
    #expect(await h.service.perform(.removeCorrection(RemoveCorrectionInput(groupID: groupID, by: autoProvenance(0.99)))) == .rejected(.userAssignmentProtected))
    guard case .applied = await h.service.perform(.removeCorrection(RemoveCorrectionInput(groupID: groupID, by: userProvenance()))) else {
        Issue.record("expected the user to be able to remove the correction")
        return
    }
    let rawAgain = try await h.service.matchSettlement(sent)
    guard case .matchWithResidual = rawAgain else {
        Issue.record("the raw +12,000 should be a raw transfer again")
        return
    }
    #expect(await h.service.perform(.removeCorrection(RemoveCorrectionInput(groupID: groupID, by: userProvenance())))
        == .rejected(.lifeValidation(.unknownCorrectionGroup(groupID))))
}

@Test func correctionInputsAreCheckedBeforeAnythingIsWritten() async throws {
    let h = harness(obligations: [])
    let a = raw("a", .incoming, 5_000, at: 1)
    #expect(await h.service.perform(.createCorrection(CreateCorrectionInput(sources: [a], provenance: userProvenance()))) == .rejected(.invalidCorrection(.tooFewTransactions)))
    let stranger = try ActualTransfer(
        transactionID: txID("s"), counterpartyID: pid("ghost"), direction: .outgoing, amount: won(1), occurredAtUnixMilliseconds: 2
    )
    #expect(await h.service.perform(.createCorrection(CreateCorrectionInput(sources: [a, stranger], provenance: userProvenance()))) == .rejected(.invalidCorrection(.mixedCounterparties)))
    let toUnknownPerson = try ActualTransfer(
        transactionID: txID("g2"), counterpartyID: pid("ghost"), direction: .outgoing, amount: won(1), occurredAtUnixMilliseconds: 3
    )
    let ghostA = try ActualTransfer(
        transactionID: txID("g1"), counterpartyID: pid("ghost"), direction: .incoming, amount: won(5), occurredAtUnixMilliseconds: 2
    )
    #expect(await h.service.perform(.createCorrection(CreateCorrectionInput(sources: [ghostA, toUnknownPerson], provenance: userProvenance())))
        == .rejected(.lifeValidation(.unknownPerson(pid("ghost")))))
}

// MARK: Scenarios H and I through the service

@Test func scenarioHEndToEndOverpaymentStaysUnresolvedUntilTheUserSaysWhat() async throws {
    let h = harness(obligations: [obligation("recv", .receivable, .exact(18_000))])
    let match = try await h.service.matchSettlement(transfer("t", .incoming, 20_000))
    guard case let .matchWithResidual(proposal) = match else {
        Issue.record("expected a residual: \(match)")
        return
    }
    let settled = await h.service.perform(.applySettlement(ApplySettlementInput(proposal: proposal, provenance: userProvenance())))
    let settlementID = try #require(applied(settled)?.settlementID)
    let state = await h.life()
    let residual = try #require(state.residuals.values.first)
    #expect(state.obligations[oid("recv")]?.status == .settled)
    #expect(residual.settlementID == settlementID && residual.classification.value == .unresolved)
    let summaryBefore = try await h.service.residualSummary()
    #expect(summaryBefore.first?.unresolvedSurplusMinorUnits == 2_000)

    // Not even a confident automated source can call it a gift.
    #expect(await h.service.perform(.classifyResidual(ClassifyResidualInput(residualID: residual.id, classification: .gift, provenance: autoProvenance(0.99))))
        == .rejected(.lifeValidation(.automatedResidualClassification(residual.id))))
    #expect(await h.service.perform(.classifyResidual(ClassifyResidualInput(residualID: residual.id, classification: .gift, provenance: autoProvenance(0.2))))
        == .rejected(.provenanceRejected))
    guard case .applied = await h.service.perform(.classifyResidual(ClassifyResidualInput(residualID: residual.id, classification: .gift, provenance: userProvenance()))) else {
        Issue.record("expected the user's classification to be stored")
        return
    }
    let summaries = try await h.service.residualSummary()
    let summary = try #require(summaries.first)
    #expect(summary.unresolvedSurplusMinorUnits == 0 && summary.byClassification[.gift] == 2_000)
    // Whatever it was, it never became spending.
    let breakdown = try await h.service.spendingBreakdown()
    #expect(breakdown.nature.isEmpty)
}

@Test func scenarioIEndToEndAShortfallKeepsTheRequestOpenUntilTheUserWaivesIt() async throws {
    let h = harness(obligations: [obligation("recv", .receivable, .exact(18_000))])
    let request = await h.service.perform(.createSettlementRequest(CreateSettlementRequestInput(counterpartyID: pid("friend"), obligationIDs: [oid("recv")])))
    let requestID = try #require(applied(request)?.settlementRequestID)

    let match = try await h.service.matchSettlement(transfer("t", .incoming, 17_000), requestID: requestID)
    guard case let .matchWithResidual(proposal) = match else {
        Issue.record("expected a partial settlement: \(match)")
        return
    }
    #expect(proposal.requestID == requestID && proposal.isPartial)
    _ = await h.service.perform(.applySettlement(ApplySettlementInput(proposal: proposal, provenance: userProvenance())))
    var state = await h.life()
    #expect(state.obligations[oid("recv")]?.status == .partiallySettled)
    #expect(state.settlementRequests[requestID]?.status == .open)             // 1,000 is still unexplained
    let residual = try #require(state.unresolvedResiduals.first)
    #expect(residual.amount == won(1_000) && residual.direction == .shortfall)

    #expect(await h.service.perform(.classifyResidual(ClassifyResidualInput(residualID: residual.id, classification: .waived, provenance: autoProvenance(0.99))))
        == .rejected(.lifeValidation(.automatedResidualClassification(residual.id))))
    _ = await h.service.perform(.classifyResidual(ClassifyResidualInput(residualID: residual.id, classification: .waived, provenance: userProvenance())))
    state = await h.life()
    #expect(state.obligations[oid("recv")]?.status == .settled)
    #expect(state.settlementRequests[requestID]?.status == .fulfilled)
}

@Test func aSettlementWithResidualsCanBeRemovedAsOneUnit() async throws {
    let h = harness(obligations: [obligation("recv", .receivable, .exact(18_000))])
    let match = try await h.service.matchSettlement(transfer("t", .incoming, 20_000))
    let proposal = try #require(match.proposal)
    let settlementID = try #require(applied(await h.service.perform(.applySettlement(ApplySettlementInput(proposal: proposal, provenance: userProvenance()))))?.settlementID)
    #expect(await h.service.perform(.removeSettlement(RemoveSettlementInput(settlementID: settlementID, by: autoProvenance(0.99)))) == .rejected(.userAssignmentProtected))
    _ = await h.service.perform(.removeSettlement(RemoveSettlementInput(settlementID: settlementID, by: userProvenance())))
    let state = await h.life()
    #expect(state.residuals.isEmpty && state.obligations[oid("recv")]?.status == .open)
}
