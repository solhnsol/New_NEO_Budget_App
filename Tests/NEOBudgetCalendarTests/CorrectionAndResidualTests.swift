import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private func failure(_ block: () throws -> Void) -> LifeValidationError? {
    do { try block(); return nil } catch let error as LifeValidationError { return error } catch { return nil }
}

private func world(_ obligations: [Obligation] = [], people: [String] = ["friend"], extra: [LifeChange] = []) -> LifeState {
    lifeWithPeople(people, extra: obligations.map { .createObligation($0) } + extra)
}

private func raw(_ id: String, _ direction: TransferDirection, _ amount: Int64, at time: Int64, with who: String = "friend") -> ActualTransfer {
    try! ActualTransfer(
        transactionID: txID(id), counterpartyID: pid(who), direction: direction,
        amount: won(amount), occurredAtUnixMilliseconds: time
    )
}

private let gid = CorrectionGroupID(rawValue: "fix1")

private func group(_ sources: [ActualTransfer], id: CorrectionGroupID = gid) throws -> TransactionCorrectionGroup {
    try TransactionCorrectionGroup(id: id, sources: sources, provenance: userProvenance(), createdAtUnixMilliseconds: 5)
}

private func settlementStatus(_ life: LifeState, _ id: String) -> ObligationStatus? { life.obligations[oid(id)]?.status }

// MARK: Scenario G — a transfer sent wrong and partly taken back

@Test func scenarioGWrongTransferThenPartialReturnBecomesEffectivePlus8000() throws {
    let sent = raw("in12", .incoming, 12_000, at: 1_000)
    let back = raw("out4", .outgoing, 4_000, at: 2_000)
    let base = world([obligation("lunch", .receivable, .exact(8_000))])

    // Without the user's correction the +12,000 alone is NOT treated as a mistake: it is 4,000 too much.
    guard case let .matchWithResidual(rawProposal) = SettlementMatcher.match(sent, in: base) else {
        Issue.record("the raw transfer should not match exactly")
        return
    }
    #expect(rawProposal.residuals == [ProposedResidual(direction: .surplus, minorUnits: 4_000)])

    // The user says: these two belong together.
    let corrected = try base.applying([.createCorrectionGroup(try group([sent, back]))])
    let created = try #require(corrected.correctionGroups[gid])
    #expect(created.effectiveDirection == .incoming && created.effectiveAmount == won(8_000))
    #expect(created.effectiveSignedMinorUnits == 8_000)
    // The ledger facts are carried as they were: nothing was edited or removed.
    #expect(created.sources == [sent, back])

    // The raw transactions are no longer matched on their own...
    #expect(SettlementMatcher.match(sent, in: corrected) == .noMatch(.partOfCorrectionGroup(gid)))
    #expect(SettlementMatcher.match(back, in: corrected) == .noMatch(.partOfCorrectionGroup(gid)))
    // ...the effective +8,000 settles the 8,000 receivable exactly.
    let effective = try #require(created.effectiveTransfer)
    #expect(effective.coveredTransactionIDs == [txID("in12"), txID("out4")])
    guard case let .exactMatch(proposal) = SettlementMatcher.match(effective, in: corrected) else {
        Issue.record("expected an exact match on the effective transfer")
        return
    }
    #expect(proposal.residuals.isEmpty)
    let settled = try settle(corrected, proposal)
    #expect(settlementStatus(settled, "lunch") == .settled)
    #expect(settled.residuals.isEmpty)
    // Both raw transactions are now accounted for: neither can be settled again.
    #expect(SettlementMatcher.match(effective, in: settled) == .noMatch(.transferAlreadySettled))
}

@Test func theEffectiveViewReplacesRawTransfersAndRemovingTheCorrectionRestoresThem() throws {
    let sent = raw("in12", .incoming, 12_000, at: 1_000)
    let back = raw("out4", .outgoing, 4_000, at: 2_000)
    let unrelated = raw("other", .incoming, 3_000, at: 3_000)
    let life = world(extra: [.createCorrectionGroup(try group([sent, back]))])

    let view = EffectiveTransfers.resolve(raw: [unrelated, back, sent], in: life)
    #expect(view.count == 2)
    #expect(view.first?.signedMinorUnits == 8_000 && view.first?.correctionGroupID == gid)
    #expect(view.last == unrelated)
    #expect(EffectiveTransfers.netMinorUnits(of: [sent, back, unrelated], in: life) == 11_000)

    // Undo: the raw meaning comes straight back.
    let undone = try life.applying([.removeCorrectionGroup(gid, by: userProvenance())])
    #expect(undone.correctionGroups.isEmpty)
    #expect(EffectiveTransfers.resolve(raw: [unrelated, back, sent], in: undone) == [sent, back, unrelated])
    #expect(EffectiveTransfers.netMinorUnits(of: [sent, back, unrelated], in: undone) == 11_000)
}

@Test func aCorrectionCanOnlyBeMadeByTheUser() throws {
    let sources = [raw("a", .incoming, 12_000, at: 1), raw("b", .outgoing, 4_000, at: 2)]
    #expect(throws: CorrectionError.requiresUser) {
        _ = try TransactionCorrectionGroup(id: gid, sources: sources, provenance: autoProvenance(1.0), createdAtUnixMilliseconds: 5)
    }
    // Nor can automation take one apart.
    let life = world(extra: [.createCorrectionGroup(try group(sources))])
    #expect(failure { _ = try life.applying([.removeCorrectionGroup(gid, by: autoProvenance(1.0))]) } == .userAssignmentProtected)
}

@Test func aCorrectionNeedsTwoOrMoreTransfersWithOnePersonInOneCurrency() throws {
    let a = raw("a", .incoming, 12_000, at: 1)
    #expect(throws: CorrectionError.tooFewTransactions) { _ = try group([a]) }
    #expect(throws: CorrectionError.duplicateTransaction(txID("a"))) { _ = try group([a, a]) }
    #expect(throws: CorrectionError.mixedCounterparties) { _ = try group([a, raw("b", .outgoing, 1_000, at: 2, with: "other")]) }
    let usd = try ActualTransfer(
        transactionID: txID("usd"), counterpartyID: pid("friend"), direction: .outgoing,
        amount: try Money(minorUnits: 100, currency: "USD"), occurredAtUnixMilliseconds: 3
    )
    #expect(throws: CorrectionError.mixedCurrencies) { _ = try group([a, usd]) }
}

@Test func aTransactionCannotBelongToTwoCorrectionGroups() throws {
    let a = raw("a", .incoming, 12_000, at: 1), b = raw("b", .outgoing, 4_000, at: 2), c = raw("c", .outgoing, 1_000, at: 3)
    let life = world(extra: [.createCorrectionGroup(try group([a, b]))])
    let second = try group([b, c], id: CorrectionGroupID(rawValue: "fix2"))
    #expect(failure { _ = try life.applying([.createCorrectionGroup(second)]) } == .transactionAlreadyCorrected(txID("b")))
    #expect(failure { _ = try life.applying([.createCorrectionGroup(try group([a, c]))]) } == .duplicateIdentifier(entity: "correctionGroup", id: "fix1"))
    // Another person is fine, and an effective transfer cannot itself be a source of a new group.
    let effective = try #require(life.correctionGroups[gid]?.effectiveTransfer)
    let nested = try group([effective, c], id: CorrectionGroupID(rawValue: "fix3"))
    #expect(failure { _ = try life.applying([.createCorrectionGroup(nested)]) } == .correctionSourceNotRaw(effective.transactionID))
}

@Test func aTransferAlreadySettledOnItsOwnCannotBeFoldedIntoACorrectionAfterwards() throws {
    let a = raw("a", .incoming, 8_000, at: 1), b = raw("b", .outgoing, 1_000, at: 2)
    let base = world([obligation("o", .receivable, .exact(8_000))])
    let settled = try settle(base, try #require(SettlementMatcher.match(a, in: base).proposal))
    #expect(failure { _ = try settled.applying([.createCorrectionGroup(try group([a, b]))]) } == .correctionSourceAlreadySettled(txID("a")))
}

@Test func aCorrectionThatAlreadySettledSomethingCannotBeRemovedSilently() throws {
    let a = raw("a", .incoming, 12_000, at: 1), b = raw("b", .outgoing, 4_000, at: 2)
    let base = world([obligation("o", .receivable, .exact(8_000))], extra: [.createCorrectionGroup(try group([a, b]))])
    let effective = try #require(base.correctionGroups[gid]?.effectiveTransfer)
    let settled = try settle(base, try #require(SettlementMatcher.match(effective, in: base).proposal))
    #expect(failure { _ = try settled.applying([.removeCorrectionGroup(gid, by: userProvenance())]) } == .correctionHasSettlement(gid))
    // Undo the settlement first, then the correction; the obligation is open again.
    let reopened = try settled.applying([.removeSettlement(SettlementID(rawValue: "s1"), by: userProvenance())])
    #expect(settlementStatus(reopened, "o") == .open)
    #expect((try reopened.applying([.removeCorrectionGroup(gid, by: userProvenance())])).correctionGroups.isEmpty)
}

@Test func theStateEnforcesTheCorrectionRulesEvenForHandBuiltSettlements() throws {
    let a = raw("a", .incoming, 12_000, at: 1), b = raw("b", .outgoing, 4_000, at: 2)
    let base = world([obligation("o", .receivable, .exact(8_000))], extra: [.createCorrectionGroup(try group([a, b]))])
    let allocation = try SettlementAllocation(obligationID: oid("o"), appliedMinorUnits: 8_000)

    // A raw member cannot be settled on its own.
    let rawSettlement = try Settlement(
        id: SettlementID(rawValue: "s"), transfer: raw("a", .incoming, 8_000, at: 1), allocations: [allocation],
        provenance: userProvenance(), createdAtUnixMilliseconds: 9
    )
    #expect(failure { _ = try base.applying([.recordSettlement(rawSettlement)]) } == .transferInCorrectionGroup(txID("a")))

    // A transfer that claims to be the group's effective transfer must be exactly it.
    let forged = try ActualTransfer(
        transactionID: txID("b"), counterpartyID: pid("friend"), direction: .incoming, amount: won(8_000),
        occurredAtUnixMilliseconds: 2, coveredTransactionIDs: [txID("a"), txID("b")], correctionGroupID: gid
    )
    let truthful = try #require(base.correctionGroups[gid]?.effectiveTransfer)
    #expect(forged == truthful)                                           // same facts: accepted
    let lying = try ActualTransfer(
        transactionID: txID("b"), counterpartyID: pid("friend"), direction: .incoming, amount: won(9_000),
        occurredAtUnixMilliseconds: 2, coveredTransactionIDs: [txID("a"), txID("b")], correctionGroupID: gid
    )
    let lyingSettlement = try Settlement(
        id: SettlementID(rawValue: "s2"), transfer: lying, allocations: [try SettlementAllocation(obligationID: oid("o"), appliedMinorUnits: 8_000)],
        residuals: [try SettlementResidual(
            id: ResidualID(rawValue: "r"), settlementID: SettlementID(rawValue: "s2"), obligationID: nil, amount: won(1_000), direction: .surplus,
            classification: Assigned(.unresolved, provenance: autoProvenance(1.0)), createdAtUnixMilliseconds: 9
        )],
        provenance: userProvenance(), createdAtUnixMilliseconds: 9
    )
    #expect(failure { _ = try base.applying([.recordSettlement(lyingSettlement)]) } == .correctionTransferMismatch(gid))
}

@Test func aCorrectionThatNetsToZeroLeavesNothingToSettle() throws {
    let a = raw("a", .incoming, 5_000, at: 1), b = raw("b", .outgoing, 5_000, at: 2)
    let zero = try group([a, b])
    #expect(zero.effectiveAmount == won(0) && zero.effectiveTransfer == nil)
    let life = world([obligation("o", .receivable, .exact(5_000))], extra: [.createCorrectionGroup(zero)])
    #expect(EffectiveTransfers.resolve(raw: [a, b], in: life).isEmpty)
    #expect(EffectiveTransfers.netMinorUnits(of: [a, b], in: life) == 0)
}

@Test func correctionGroupsSurviveSerialization() throws {
    let a = raw("a", .incoming, 12_000, at: 1), b = raw("b", .outgoing, 4_000, at: 2)
    let life = world(extra: [.createCorrectionGroup(try group([a, b]))])
    let decoded = try JSONDecoder().decode(LifeState.self, from: try JSONEncoder().encode(life))
    #expect(decoded == life)
    #expect(decoded.correctionGroups[gid]?.effectiveSignedMinorUnits == 8_000)
}

// MARK: Scenario H — more was paid than was owed

@Test func scenarioHOverpaymentSettlesTheObligationAndKeepsAnUnresolvedSurplus() throws {
    let life = world([obligation("recv", .receivable, .exact(18_000))])
    guard case let .matchWithResidual(proposal) = SettlementMatcher.match(transfer("t", .incoming, 20_000), in: life) else {
        Issue.record("expected a settlement with a residual")
        return
    }
    #expect(proposal.applications == [ProposedApplication(obligationID: oid("recv"), appliedMinorUnits: 18_000)])
    #expect(proposal.residuals == [ProposedResidual(direction: .surplus, minorUnits: 2_000)])
    #expect(!proposal.isPartial)

    let settled = try settle(life, proposal)
    #expect(settlementStatus(settled, "recv") == .settled)                // 18,000 settled
    let residual = try #require(settled.unresolvedResiduals.first)
    #expect(residual.amount == won(2_000) && residual.direction == .surplus)
    // Nothing decided what the 2,000 was: not a gift, not a waiver, not income.
    #expect(residual.classification.value == .unresolved)
    #expect(residual.classification.provenance.source == .automated)
    #expect(settled.residualSummary().first?.unresolvedSurplusMinorUnits == 2_000)
    #expect(settled.spendingByNature().isEmpty)                           // and it does not touch spending analysis
}

@Test func automationCanNeverClassifyAResidualButTheUserCan() throws {
    let life = world([obligation("recv", .receivable, .exact(18_000))])
    let settled = try settle(life, try #require(SettlementMatcher.match(transfer("t", .incoming, 20_000), in: life).proposal))
    let id = try #require(settled.unresolvedResiduals.first?.id)

    #expect(failure { _ = try settled.applying([.classifyResidual(id, .gift, by: autoProvenance(1.0))]) } == .automatedResidualClassification(id))
    #expect(failure { _ = try settled.applying([.classifyResidual(id, .waived, by: userProvenance())]) } == .residualClassificationNotApplicable(id))

    let gifted = try settled.applying([.classifyResidual(id, .gift, by: userProvenance(7))])
    #expect(gifted.residuals[id]?.classification.value == .gift)
    #expect(gifted.unresolvedResiduals.isEmpty)
    #expect(gifted.residualSummary().first?.byClassification[.gift] == 2_000)
    // Automation cannot reopen or change the user's decision, the user can.
    #expect(failure { _ = try gifted.applying([.classifyResidual(id, .unresolved, by: autoProvenance(1.0))]) } == .userAssignmentProtected)
    let reopened = try gifted.applying([.classifyResidual(id, .unresolved, by: userProvenance(8))])
    #expect(reopened.unresolvedResiduals.count == 1)
    #expect(failure { _ = try settled.applying([.classifyResidual(ResidualID(rawValue: "ghost"), .other, by: userProvenance())]) } == .unknownResidual(ResidualID(rawValue: "ghost")))
}

@Test func anOverpaymentAfterNettingKeepsBothDirectionsAndTheSurplus() throws {
    // 받을 돈 30,000, 줄 돈 12,000 → net 18,000. 20,000 came in.
    let life = world([obligation("recv", .receivable, .exact(30_000)), obligation("pay", .payable, .exact(12_000))])
    guard case let .matchWithResidual(proposal) = SettlementMatcher.match(transfer("t", .incoming, 20_000), in: life) else {
        Issue.record("expected a netted settlement with a residual")
        return
    }
    #expect(Set(proposal.applications.map(\.obligationID)) == [oid("recv"), oid("pay")])
    #expect(proposal.residuals == [ProposedResidual(direction: .surplus, minorUnits: 2_000)])
    let settled = try settle(life, proposal)
    #expect(settlementStatus(settled, "recv") == .settled && settlementStatus(settled, "pay") == .settled)
}

@Test func anOutgoingOverpaymentIsASurplusToo() throws {
    let life = world([obligation("pay", .payable, .exact(10_000))])
    guard case let .matchWithResidual(proposal) = SettlementMatcher.match(transfer("t", .outgoing, 12_500), in: life) else {
        Issue.record("expected a residual")
        return
    }
    #expect(proposal.residuals == [ProposedResidual(direction: .surplus, minorUnits: 2_500)])
    #expect((try settle(life, proposal)).unresolvedResiduals.first?.amount == won(2_500))
}

@Test func aSurplusIsNotProposedWhenAnUnknownObligationCouldAbsorbIt() throws {
    // With an unknown amount around, the transfer might be that amount (or part of it). That is the existing
    // ambiguity, and no residual is invented to paper over it.
    let life = world([obligation("known", .receivable, .exact(5_000)), obligation("unk", .receivable, .unknown)])
    let result = SettlementMatcher.match(transfer("t", .incoming, 20_000), in: life)
    guard case let .ambiguous(report) = result else {
        Issue.record("expected an ambiguous result, not a residual: \(result)")
        return
    }
    #expect(report.reason == .multipleExplanations)
}

// MARK: Scenario I — less was paid than was owed

@Test func scenarioIShortPaymentIsAPartialSettlementWithAnUnresolvedRemainder() throws {
    let life = world([obligation("recv", .receivable, .exact(18_000))])
    guard case let .matchWithResidual(proposal) = SettlementMatcher.match(transfer("t", .incoming, 17_000), in: life) else {
        Issue.record("expected a partial settlement")
        return
    }
    #expect(proposal.isPartial)
    #expect(proposal.applications == [ProposedApplication(obligationID: oid("recv"), appliedMinorUnits: 17_000)])
    #expect(proposal.residuals == [ProposedResidual(direction: .shortfall, minorUnits: 1_000, obligationID: oid("recv"))])

    let settled = try settle(life, proposal)
    #expect(settlementStatus(settled, "recv") == .partiallySettled)       // 17,000 settled, not 18,000
    #expect(settled.appliedMinorUnits(for: oid("recv")) == 17_000)
    let residual = try #require(settled.unresolvedResiduals.first)
    #expect(residual.direction == .shortfall && residual.amount == won(1_000) && residual.obligationID == oid("recv"))
    #expect(residual.classification.value == .unresolved)                // nothing was waived on its own
    #expect(settled.closedMinorUnits(for: oid("recv")) == 17_000)
}

@Test func onlyTheUserCanWaiveOrRoundAwayAShortfall() throws {
    let life = world([obligation("recv", .receivable, .exact(18_000))])
    let settled = try settle(life, try #require(SettlementMatcher.match(transfer("t", .incoming, 17_000), in: life).proposal))
    let id = try #require(settled.unresolvedResiduals.first?.id)

    #expect(failure { _ = try settled.applying([.classifyResidual(id, .waived, by: autoProvenance(1.0))]) } == .automatedResidualClassification(id))
    #expect(failure { _ = try settled.applying([.classifyResidual(id, .gift, by: userProvenance())]) } == .residualClassificationNotApplicable(id))

    let waived = try settled.applying([.classifyResidual(id, .waived, by: userProvenance())])
    #expect(settlementStatus(waived, "recv") == .settled)                // the user forgave the last 1,000
    #expect(waived.closedMinorUnits(for: oid("recv")) == 18_000 && waived.appliedMinorUnits(for: oid("recv")) == 17_000)
    #expect(waived.unresolvedResiduals.isEmpty)
    let rounded = try settled.applying([.classifyResidual(id, .roundingAdjustment, by: userProvenance())])
    #expect(settlementStatus(rounded, "recv") == .settled)

    // Other meanings do not close it; and reopening brings the remainder back.
    let other = try settled.applying([.classifyResidual(id, .other, by: userProvenance())])
    #expect(settlementStatus(other, "recv") == .partiallySettled)
    let reopened = try waived.applying([.classifyResidual(id, .unresolved, by: userProvenance(9))])
    #expect(settlementStatus(reopened, "recv") == .partiallySettled)
}

@Test func aLaterPaymentOfTheRemainderSettlesItAndRetiresTheShortfallQuestion() throws {
    let life = world([obligation("recv", .receivable, .exact(18_000))])
    let first = try settle(life, try #require(SettlementMatcher.match(transfer("t1", .incoming, 17_000), in: life).proposal), id: "s1")
    // The remaining 1,000 is itself an exact match.
    guard case let .exactMatch(rest) = SettlementMatcher.match(transfer("t2", .incoming, 1_000), in: first) else {
        Issue.record("expected the remainder to match exactly")
        return
    }
    let second = try settle(first, rest, id: "s2")
    #expect(settlementStatus(second, "recv") == .settled)
    #expect(second.unresolvedResiduals.isEmpty)                          // nothing left to ask about
    #expect(second.residuals.count == 1)                                 // the history is kept
}

@Test func aWaivedShortfallDoesNotCountAsOwedForMatchingEither() throws {
    let life = world([obligation("recv", .receivable, .exact(18_000))])
    let settled = try settle(life, try #require(SettlementMatcher.match(transfer("t", .incoming, 17_000), in: life).proposal))
    let id = try #require(settled.unresolvedResiduals.first?.id)
    let waived = try settled.applying([.classifyResidual(id, .waived, by: userProvenance())])
    #expect(SettlementMatcher.match(transfer("t2", .incoming, 1_000), in: waived) == .noMatch(.noOpenObligations))
}

@Test func removingTheSettlementRemovesItsResidualsAndReopensTheObligation() throws {
    let life = world([obligation("recv", .receivable, .exact(18_000))])
    let settled = try settle(life, try #require(SettlementMatcher.match(transfer("t", .incoming, 17_000), in: life).proposal))
    let id = try #require(settled.unresolvedResiduals.first?.id)
    let waived = try settled.applying([.classifyResidual(id, .waived, by: userProvenance())])
    let undone = try waived.applying([.removeSettlement(SettlementID(rawValue: "s1"), by: userProvenance())])
    #expect(undone.residuals.isEmpty && settlementStatus(undone, "recv") == .open)
    #expect(undone.closedMinorUnits(for: oid("recv")) == 0)
}

@Test func theSettlementRecordRefusesResidualsThatDoNotAddUp() throws {
    let base = world([obligation("recv", .receivable, .exact(18_000))])
    let sid = SettlementID(rawValue: "s")
    func residual(_ direction: ResidualDirection, _ amount: Int64, obligation: String? = nil, _ classification: ResidualClassification = .unresolved,
                  by provenance: AssignmentProvenance = autoProvenance(1.0)) throws -> SettlementResidual {
        try SettlementResidual(
            id: ResidualID(rawValue: "r-\(direction.rawValue)"), settlementID: sid, obligationID: obligation.map { oid($0) }, amount: won(amount),
            direction: direction, classification: Assigned(classification, provenance: provenance), createdAtUnixMilliseconds: 9
        )
    }
    func record(_ transferAmount: Int64, applied: Int64, residuals: [SettlementResidual]) throws {
        let settlement = try Settlement(
            id: sid, transfer: transfer("t", .incoming, transferAmount),
            allocations: [try SettlementAllocation(obligationID: oid("recv"), appliedMinorUnits: applied)],
            residuals: residuals, provenance: userProvenance(), createdAtUnixMilliseconds: 9
        )
        _ = try base.applying([.recordSettlement(settlement)])
    }
    // A surplus must account for the money that moved beyond the obligations: 20,000 - 18,000 = 2,000.
    #expect(failure { try record(20_000, applied: 18_000, residuals: [try residual(.surplus, 1_000)]) } == .settlementNetMismatch)
    #expect(failure { try record(20_000, applied: 18_000, residuals: []) } == .settlementNetMismatch)
    #expect(failure { try record(20_000, applied: 18_000, residuals: [try residual(.surplus, 2_000)]) } == nil)
    // A shortfall must be exactly what the obligation still needs: 18,000 - 17,000 = 1,000.
    #expect(failure { try record(17_000, applied: 17_000, residuals: [try residual(.shortfall, 500, obligation: "recv")]) } == .residualMismatch(ResidualID(rawValue: "r-shortfall")))
    #expect(failure { try record(17_000, applied: 17_000, residuals: [try residual(.shortfall, 1_000, obligation: "recv")]) } == nil)
    // Automation cannot arrive with an opinion about what a residual means; a user can.
    #expect(failure { try record(20_000, applied: 18_000, residuals: [try residual(.surplus, 2_000, .gift)]) } == .automatedResidualClassification(ResidualID(rawValue: "r-surplus")))
    #expect(failure { try record(20_000, applied: 18_000, residuals: [try residual(.surplus, 2_000, .gift, by: userProvenance())]) } == nil)
}

@Test func residualRecordsValidateTheirOwnShape() throws {
    let sid = SettlementID(rawValue: "s")
    let unresolved = Assigned(ResidualClassification.unresolved, provenance: autoProvenance(1.0))
    #expect(throws: SettlementValidationError.nonPositiveResidual) {
        _ = try SettlementResidual(id: ResidualID(rawValue: "r"), settlementID: sid, obligationID: nil, amount: won(0), direction: .surplus, classification: unresolved, createdAtUnixMilliseconds: 1)
    }
    #expect(throws: SettlementValidationError.invalidResidualTarget) {
        _ = try SettlementResidual(id: ResidualID(rawValue: "r"), settlementID: sid, obligationID: oid("o"), amount: won(1), direction: .surplus, classification: unresolved, createdAtUnixMilliseconds: 1)
    }
    #expect(throws: SettlementValidationError.invalidResidualTarget) {
        _ = try SettlementResidual(id: ResidualID(rawValue: "r"), settlementID: sid, obligationID: nil, amount: won(1), direction: .shortfall, classification: unresolved, createdAtUnixMilliseconds: 1)
    }
    #expect(throws: SettlementValidationError.residualClassificationNotApplicable) {
        _ = try SettlementResidual(
            id: ResidualID(rawValue: "r"), settlementID: sid, obligationID: nil, amount: won(1), direction: .surplus,
            classification: Assigned(.waived, provenance: userProvenance()), createdAtUnixMilliseconds: 1
        )
    }
}

@Test func residualsAreNotCorrections() throws {
    // 18,000 owed, 20,000 received, 4,000 sent back later: the matcher does not pair these on its own.
    let life = world([obligation("recv", .receivable, .exact(18_000))])
    let first = SettlementMatcher.match(raw("in20", .incoming, 20_000, at: 1), in: life)
    guard case let .matchWithResidual(proposal) = first else {
        Issue.record("expected a residual, not a correction")
        return
    }
    #expect(proposal.residuals.first?.direction == .surplus)
    #expect(life.correctionGroups.isEmpty)                               // nothing was grouped or netted on its own
    let settled = try settle(life, proposal)
    #expect(settled.correctionGroups.isEmpty && settled.unresolvedResiduals.count == 1)
}

@Test func settlementsWithResidualsSurviveSerialization() throws {
    let life = world([obligation("recv", .receivable, .exact(18_000))])
    let settled = try settle(life, try #require(SettlementMatcher.match(transfer("t", .incoming, 20_000), in: life).proposal))
    let decoded = try JSONDecoder().decode(LifeState.self, from: try JSONEncoder().encode(settled))
    #expect(decoded == settled)
    #expect(decoded.unresolvedResiduals.count == 1)
}

// MARK: Residuals and requests

@Test func aRequestNamesWhatTheTransferIsAboutSoTheSurplusIsUnambiguous() throws {
    // Two receivables. Without a request, 35,000 cannot be tied to one of them; with a request it can.
    let base = world([obligation("big", .receivable, .exact(30_000)), obligation("small", .receivable, .exact(10_000))])
    #expect(SettlementMatcher.match(transfer("t", .incoming, 35_000), in: base) == .noMatch(.noCombinationExplainsTransfer))

    let request = try SettlementRequest(
        id: SettlementRequestID(rawValue: "req"), counterpartyID: pid("friend"), obligationIDs: [oid("big")], createdAtUnixMilliseconds: 1
    )
    let life = try base.applying([.createSettlementRequest(request)])
    guard case let .matchWithResidual(proposal) = SettlementMatcher.match(transfer("t", .incoming, 35_000), in: life, requestID: request.id) else {
        Issue.record("expected the request to name the subject")
        return
    }
    #expect(proposal.applications == [ProposedApplication(obligationID: oid("big"), appliedMinorUnits: 30_000)])
    #expect(proposal.residuals == [ProposedResidual(direction: .surplus, minorUnits: 5_000)])
    #expect(proposal.requestID == request.id)
    let settled = try settle(life, proposal)
    #expect(settlementStatus(settled, "big") == .settled && settlementStatus(settled, "small") == .open)
    #expect(settled.settlementRequests[request.id]?.status == .fulfilled)
}

@Test func aShortTransferForSeveralNamedObligationsDoesNotGuessWhichIsShort() throws {
    let base = world([obligation("a", .receivable, .exact(30_000)), obligation("b", .receivable, .exact(10_000))])
    let request = try SettlementRequest(
        id: SettlementRequestID(rawValue: "req"), counterpartyID: pid("friend"), obligationIDs: [oid("a"), oid("b")], createdAtUnixMilliseconds: 1
    )
    let life = try base.applying([.createSettlementRequest(request)])
    // 35,000 is less than the 40,000 named, and either could be the one left short: nothing is proposed.
    #expect(SettlementMatcher.match(transfer("t", .incoming, 35_000), in: life, requestID: request.id) == .noMatch(.noCombinationExplainsTransfer))
    // A smaller transfer that fits inside only the larger obligation is reported as a possible partial payment.
    #expect(SettlementMatcher.match(transfer("t2", .incoming, 20_000), in: life, requestID: request.id)
        == .insufficientEvidence(.possiblePartialSettlement([oid("a")])))
}

@Test func anObligationCannotPointAtAComponentThatDoesNotExist() {
    let ghost = ExpenseComponentID(rawValue: "ghost")
    let orphan = Obligation(
        id: oid("o"), counterpartyID: pid("friend"), direction: .receivable, amount: entry(.exact(5_000)),
        provenance: userProvenance(), createdAtUnixMilliseconds: 1, componentID: ghost
    )
    #expect(failure { _ = try lifeWithPeople(["friend"]).applying([.createObligation(orphan)]) } == .unknownComponent(ghost))
}
