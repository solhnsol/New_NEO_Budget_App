import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private let dinner = ActivityID(rawValue: "dinner")
private let dinnerEvent = event("dinner", title: "저녁", from: at(today, 18), to: at(today, 21))
private let day: Int64 = 86_400_000

private func dinnerLife(extra: [LifeChange] = []) -> LifeState {
    let attendees = ["b", "c"].map { LifeChange.addParticipant(dinner, ParticipantAssignment(personID: pid($0), provenance: userProvenance())) }
    return lifeWithPeople(
        ["b", "c"],
        extra: [.createActivity(Activity.materialized(from: dinnerEvent, id: dinner, at: 1)), allocation("pay", to: "dinner", amount: .exact(60_000), of: 60_000)] + attendees + extra
    )
}

private func dinnerComponent(_ total: Int64) -> ExpenseComponent {
    ExpenseComponent(
        id: ExpenseComponentID(rawValue: "split"), activityID: dinner, label: "정산", amount: entry(.exact(total)), payerID: myself,
        participants: nil, excludedParticipants: [], policy: nil, category: .initial, provenance: userProvenance(), createdAtUnixMilliseconds: 1
    )
}

private func owed(_ id: String, _ person: String, _ amount: Int64, activity: String = "dinner", label: String? = "정산", createdAt: Int64 = 1) -> LifeChange {
    .createObligation(Obligation(
        id: oid(id), counterpartyID: pid(person), activityID: ActivityID(rawValue: activity), direction: .receivable, amount: entry(.exact(amount)),
        provenance: userProvenance(), createdAtUnixMilliseconds: createdAt, label: label
    ))
}

// MARK: Overview and overdue

@Test func summariesCountOpenMoneyPerPersonAndMarkOldRequests() throws {
    let life = lifeWithPeople(["b", "c"], extra: [
        .createObligation(obligation("old", with: "b", .receivable, .exact(30_000), createdAt: 1_000)),
        .createObligation(obligation("owe", with: "b", .payable, .exact(5_000), createdAt: 2_000)),
        .createObligation(obligation("fresh", with: "c", .receivable, .exact(8_000), createdAt: 20 * day)),
        .createObligation(obligation("vague", with: "c", .payable, .unknown, createdAt: 20 * day)),
    ])
    let summaries = life.settlementSummaries(nowUnixMilliseconds: 20 * day, overdueAfterDays: 14)
    #expect(summaries.map(\.personID.rawValue) == ["b", "c"])                       // oldest open first
    let b = try #require(summaries.first), c = try #require(summaries.last)
    #expect(b.receivableMinorUnits == 30_000 && b.payableMinorUnits == 5_000 && b.netMinorUnits == 25_000 && b.isOverdue)
    #expect(c.receivableMinorUnits == 8_000 && c.unknownOpenCount == 1 && !c.isOverdue)
}

@Test func aPartPaymentLeavesOnlyTheRestOpenAndASettledOneDisappears() throws {
    let base = lifeWithPeople(["b"], extra: [.createObligation(obligation("o", with: "b", .receivable, .exact(30_000)))])
    let part = try settle(base, try #require(SettlementMatcher.match(transfer("t", "b", .incoming, 20_000), in: base).proposal))
    #expect(part.settlementSummaries(nowUnixMilliseconds: 2).first?.receivableMinorUnits == 10_000)
    let full = try settle(base, try #require(SettlementMatcher.match(transfer("t", "b", .incoming, 30_000), in: base).proposal))
    #expect(full.settlementSummaries(nowUnixMilliseconds: 2).isEmpty)
}

// MARK: Deposits are asked about only when something is waiting

@Test func aDepositWithNothingWaitingIsLeftAlone() {
    #expect(lifeWithPeople(["b"]).depositReview(from: pid("b"), currency: "KRW") == .leave)
}

@Test func anOpenRequestMakesADepositWorthAQuestionSenderFirstAndNeverLinks() {
    let life = lifeWithPeople(["b", "c"], extra: [
        .createObligation(obligation("c-old", with: "c", .receivable, .exact(1_000), createdAt: 1)),
        .createObligation(obligation("b-new", with: "b", .receivable, .exact(2_000), createdAt: 9)),
    ])
    #expect(life.depositReview(from: pid("b"), currency: "KRW") == .askToConfirm(obligations: [oid("b-new"), oid("c-old")], gatherings: []))
    #expect(life.depositReview(from: nil, currency: "KRW") == .askToConfirm(obligations: [oid("c-old"), oid("b-new")], gatherings: []))
    #expect(life.depositReview(from: pid("b"), currency: "USD") == .leave)
    #expect(life.settlements.isEmpty)
}

@Test func aGatheringWithPeopleButNoRequestYetIsAskedAbout() {
    let life = dinnerLife()
    #expect(life.depositReview(from: pid("b"), currency: "KRW") == .askToConfirm(obligations: [], gatherings: [dinner]))
    #expect(life.depositReview(from: pid("b"), currency: "KRW", recentActivities: []) == .leave)
    let asked = dinnerLife(extra: [owed("r", "b", 20_000)])
    #expect(asked.depositReview(from: pid("b"), currency: "KRW") == .askToConfirm(obligations: [oid("r")], gatherings: []))
}

@Test func oneDepositCanSettleSeveralDaysOfRequestsAtOnce() throws {
    let life = lifeWithPeople(["b"], extra: [
        .createObligation(obligation("mon", with: "b", .receivable, .exact(30_000), createdAt: 1)),
        .createObligation(obligation("tue", with: "b", .receivable, .exact(6_000), createdAt: 2)),
    ])
    guard case let .netMatch(proposal) = SettlementMatcher.match(transfer("t", "b", .incoming, 36_000), in: life) else {
        Issue.record("expected the deposit to cover both")
        return
    }
    let settled = try settle(life, proposal)
    #expect(settled.obligations[oid("mon")]?.status == .settled && settled.obligations[oid("tue")]?.status == .settled)
}

// MARK: Short and surplus deposits

@Test func aShortDepositIsClosedOrLeftOpenAsTheUserChooses() throws {
    let base = lifeWithPeople(["b"], extra: [.createObligation(obligation("o", with: "b", .receivable, .exact(30_000)))])
    guard case let .matchWithResidual(proposal) = SettlementMatcher.match(transfer("t", "b", .incoming, 25_000), in: base) else {
        Issue.record("expected a shortfall")
        return
    }
    let open = try settle(base, proposal)
    #expect(open.obligations[oid("o")]?.status == .partiallySettled)
    #expect(open.settlementSummaries(nowUnixMilliseconds: 2).first?.receivableMinorUnits == 5_000)     // kept open: 5,000 still to get
    let residual = try #require(open.unresolvedResiduals.first)
    let closed = try open.applying([.classifyResidual(residual.id, .waived, by: userProvenance())])
    #expect(closed.settlementSummaries(nowUnixMilliseconds: 2).isEmpty)                               // closed: nothing left to get
}

@Test func aSurplusIsIncomeByDefaultAndReducesTheEventWhenTheSettingSaysSo() throws {
    let base = lifeWithPeople(["b"], extra: [.createObligation(obligation("o", with: "b", .receivable, .exact(30_000)))])
    guard case let .matchWithResidual(proposal) = SettlementMatcher.match(transfer("t", "b", .incoming, 35_000), in: base) else {
        Issue.record("expected a surplus")
        return
    }
    let life = try settle(base, proposal)
    #expect(life.surplusIncomeMinorUnits(currency: "KRW") == 5_000)
    #expect(life.surplusIncomeMinorUnits(currency: "KRW", treatment: .reduceSpending) == 0)
    #expect(life.surplusIncomeMinorUnits(currency: "USD") == 0)
    let offset = try life.applying([.classifyResidual(try #require(life.unresolvedResiduals.first).id, .otherObligation, by: userProvenance())])
    #expect(offset.surplusIncomeMinorUnits(currency: "KRW") == 0)
}

@Test func withTheSettingASurplusComesOffTheCostOfItsEvent() throws {
    var life = dinnerLife(extra: [owed("b1", "b", 20_000), owed("c1", "c", 20_000)])
    guard case let .matchWithResidual(proposal) = SettlementMatcher.match(transfer("t", "b", .incoming, 25_000), in: life) else {
        Issue.record("expected a surplus")
        return
    }
    life = try settle(life, proposal)
    let normal = try #require(life.activityShares().first), reduced = try #require(life.activityShares(surplus: .reduceSpending).first)
    #expect(normal.myShareMinorUnits == 20_000 && reduced.surplusMinorUnits == 5_000 && reduced.myShareMinorUnits == 15_000)
    #expect(life.surplusIncomeMinorUnits(currency: "KRW", treatment: .reduceSpending) == 0)
}

// MARK: A changed total asks for the difference only

@Test func aLargerTotalAddsOnlyTheDifferenceAndLeavesTheFirstRequestAlone() throws {
    var life = dinnerLife(extra: [.upsertExpenseComponent(dinnerComponent(60_000))])
    life = try life.applying([owed("b1", "b", 20_000), owed("c1", "c", 20_000)])
    #expect(try life.additionalRequests(forComponent: ExpenseComponentID(rawValue: "split")).isEmpty)
    // A 6,000 won taxi joins the dinner: 66,000 over three people.
    life = try life.applying([.upsertExpenseComponent(dinnerComponent(66_000))])
    let drafts = try life.additionalRequests(forComponent: ExpenseComponentID(rawValue: "split"))
    #expect(drafts.map(\.counterpartyID.rawValue) == ["b", "c"] && drafts.allSatisfy { $0.deltaMinorUnits == 2_000 })
    let created = try life.applying([.createObligation(Obligation(
        id: oid("extra-b"), counterpartyID: pid("b"), activityID: dinner, direction: .receivable, amount: entry(.exact(2_000)),
        provenance: userProvenance(), createdAtUnixMilliseconds: 5, label: SettlementLabel.additional
    ))])
    #expect(try created.additionalRequests(forComponent: ExpenseComponentID(rawValue: "split")).map(\.counterpartyID.rawValue) == ["c"])
    #expect(created.obligations[oid("b1")]?.amount.knowledge == .exact(20_000))
}

@Test func aSmallerTotalAsksForNothingAndCancelledRequestsDoNotCount() throws {
    var life = dinnerLife(extra: [.upsertExpenseComponent(dinnerComponent(60_000)), owed("b1", "b", 20_000), owed("c1", "c", 20_000)])
    life = try life.applying([.upsertExpenseComponent(dinnerComponent(45_000))])
    #expect(try life.additionalRequests(forComponent: ExpenseComponentID(rawValue: "split")).isEmpty)
    life = try life.applying([.cancelObligation(oid("c1"), by: userProvenance())])
    #expect(try life.additionalRequests(forComponent: ExpenseComponentID(rawValue: "split")).map(\.counterpartyID.rawValue) == ["c"])
}

// MARK: Money I will send, registered ahead

@Test func aRegisteredPaymentLinksItselfWhenIsendTheMoneyAndNothingElseDoes() throws {
    let life = lifeWithPeople(["b"], extra: [.createObligation(obligation("cafe", with: "b", .payable, .exact(20_000)))])
    let proposal = try #require(ExpectedPaymentLink.autoProposal(for: transfer("t", "b", .outgoing, 20_000), in: life))
    #expect(proposal.applications.map(\.obligationID) == [oid("cafe")])
    #expect(ExpectedPaymentLink.autoProposal(for: transfer("t", "b", .outgoing, 15_000), in: life) == nil)     // a different amount is not guessed
    #expect(ExpectedPaymentLink.autoProposal(for: transfer("t", "b", .incoming, 20_000), in: life) == nil)
    let owedToMe = lifeWithPeople(["b"], extra: [.createObligation(obligation("r", with: "b", .receivable, .exact(20_000)))])
    #expect(ExpectedPaymentLink.autoProposal(for: transfer("t", "b", .incoming, 20_000), in: owedToMe) == nil) // deposits are never auto-linked
}

@Test func aRegisteredPaymentWithNoAmountTakesTheValueOfTheTransfer() throws {
    let life = lifeWithPeople(["b"], extra: [.createObligation(obligation("cafe", with: "b", .payable, .unknown))])
    let proposal = try #require(ExpectedPaymentLink.autoProposal(for: transfer("t", "b", .outgoing, 18_000), in: life))
    #expect(proposal.inferences.map(\.minorUnits) == [18_000])
}

// MARK: How much of an event is mine

@Test func myShareTakesOffWhatCameBackAndWhatIsStillPending() throws {
    var life = dinnerLife(extra: [owed("b1", "b", 20_000), owed("c1", "c", 20_000)])
    var share = try #require(life.activityShares().first)
    #expect(share.spentMinorUnits == 60_000 && share.pendingMinorUnits == 40_000 && share.myShareMinorUnits == 20_000 && share.isPending)
    life = try settle(life, try #require(SettlementMatcher.match(transfer("t", "b", .incoming, 20_000), in: life).proposal))
    share = try #require(life.activityShares().first)
    #expect(share.receivedMinorUnits == 20_000 && share.pendingMinorUnits == 20_000 && share.myShareMinorUnits == 20_000)
}

@Test func aWaivedShortfallStaysInMyShare() throws {
    var life = dinnerLife(extra: [owed("b1", "b", 30_000)])
    guard case let .matchWithResidual(proposal) = SettlementMatcher.match(transfer("t", "b", .incoming, 25_000), in: life) else {
        Issue.record("expected a shortfall")
        return
    }
    life = try settle(life, proposal)
    life = try life.applying([.classifyResidual(try #require(life.unresolvedResiduals.first).id, .waived, by: userProvenance())])
    let share = try #require(life.activityShares().first)
    #expect(share.pendingMinorUnits == 0 && share.receivedMinorUnits == 25_000 && share.myShareMinorUnits == 35_000 && !share.isPending)
}

// MARK: Names

@Test func aPersonAnswersToRememberedAliasesAndOldDataStillReads() throws {
    let minsu = person("minsu", name: "민수").remembering(alias: " 김 민수 ")
    #expect(minsu.matches(name: "민수") && minsu.matches(name: "김민수") && !minsu.matches(name: "민수야") && !minsu.matches(name: " "))
    #expect(minsu.remembering(alias: "김민수").aliases == ["김 민수"])
    let old = #"{"id":"p","displayName":"민수","isSelf":false}"#
    #expect(try JSONDecoder().decode(Person.self, from: Data(old.utf8)).aliases.isEmpty)
    #expect(try JSONDecoder().decode(Person.self, from: JSONEncoder().encode(minsu)) == minsu)
}
