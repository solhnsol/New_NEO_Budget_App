import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private let lunch = event("lunch", title: "점심", from: at(today, 12), to: at(today, 13))
private let workday = event("work", title: "근무", from: at(today, 9), to: at(today, 18))
private let trip = allDayEvent("trip", title: "여행", from: today, to: today)

@Test func spendingDuringAnEventGoesToTheInnermostOne() {
    let proposals = TimeBinding.proposals(
        events: [workday, lunch, trip],
        transactions: [
            marker("meal", at: at(today, 12, 41), amount: 15_000),
            marker("coffee", at: at(today, 15), amount: 4_500),
            marker("night", at: at(today, 21), amount: 8_000),
        ],
        life: .empty
    )
    #expect(proposals == [
        .init(transactionID: txID("meal"), event: lunch.key),     // inside both: the shorter lunch takes it
        .init(transactionID: txID("coffee"), event: workday.key),
    ])                                                             // 21:00 is only in the all-day trip: never bound by time
}

@Test func refundsAndAlreadyDecidedTransactionsAreLeftAlone() throws {
    let decided = try LifeState.empty.applying([
        .upsertAllocation(
            TransactionAllocation(
                id: AllocationID(rawValue: "a"), transactionID: txID("meal"), activityID: nil,
                amount: entry(.exact(15_000)), provenance: userProvenance(), createdAtUnixMilliseconds: 1
            ),
            transactionTotal: won(15_000), flow: .spend
        ),
    ])
    let proposals = TimeBinding.proposals(
        events: [lunch],
        transactions: [marker("meal", at: at(today, 12, 10), amount: 15_000), marker("back", at: at(today, 12, 20), amount: 3_000, flow: .refund)],
        life: decided
    )
    #expect(proposals.isEmpty)
}

@Test func theServiceBindsAsAutomationAndOnlyOnce() async throws {
    let h = Harness.make(events: [lunch], transactions: [marker("meal", at: at(today, 12, 41), amount: 15_000)])
    let bounds = seoul.dayBounds(today)
    let first = try await h.service.bindByTime(from: bounds.start, to: bounds.end)
    #expect(first == 1)
    let life = await h.life()
    let allocation = try #require(life.allocationSet(for: txID("meal"))?.allocations.first)
    #expect(allocation.provenance.source == .automated)
    let activityID = try #require(allocation.activityID)
    #expect(life.activities[activityID]?.association?.lastKnown.title == "점심")
    let again = try await h.service.bindByTime(from: bounds.start, to: bounds.end)
    #expect(again == 0)
}

@Test func aTransactionTheUserTookOutStaysOut() async throws {
    let h = Harness.make(events: [lunch], transactions: [marker("meal", at: at(today, 12, 41), amount: 15_000)])
    let bounds = seoul.dayBounds(today)
    _ = try await h.service.bindByTime(from: bounds.start, to: bounds.end)
    let out = await h.service.perform(.unlinkTransaction(UnlinkTransactionInput(transactionID: txID("meal"), by: userProvenance(), keepOut: true)))
    guard case .applied = out else { Issue.record("expected applied, got \(out)"); return }
    let rebound = try await h.service.bindByTime(from: bounds.start, to: bounds.end)
    #expect(rebound == 0)
    let allocation = try #require((await h.life()).allocationSet(for: txID("meal"))?.allocations.first)
    #expect(allocation.activityID == nil && allocation.provenance.source == .user)
}
