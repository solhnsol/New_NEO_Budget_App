import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private let eventA = event("eA", title: "농구", from: at(today, 10), to: at(today, 11))
private let eventA2 = event("eA2", title: "점심", from: at(today, 12), to: at(today, 13))
private let eventB = event("eB", title: "내일 여행", from: at(today.adding(days: 1), 9), to: at(today.adding(days: 1), 18))

private func life(_ changes: [LifeChange]) -> LifeState {
    let base: [LifeChange] = [("A", eventA), ("A2", eventA2), ("B", eventB)].map {
        .createActivity(Activity.materialized(from: $0.1, id: ActivityID(rawValue: $0.0), at: 1))
    }
    return try! LifeState.empty.applying(base + changes)
}

private func timeline(_ life: LifeState, _ transactions: [TransactionMarker]) -> DayTimeline {
    DayTimelineBuilder.build(DayTimelineInput(
        day: today, timeZone: seoul, calendars: defaultCalendars, events: [eventA, eventA2], life: life, transactions: transactions
    ))
}

@Test func aSplitTransactionShowsItsPortionInsideTheBlockAndKeepsAMarkerForTheRest() throws {
    // 80,000원: 30,000 → 오늘 농구, 25,000 → 내일 여행, 나머지 25,000은 아직 배분 안 됨
    let state = life([
        allocation("tx", to: "A", amount: .exact(30_000), of: 80_000),
        allocation("tx", to: "B", amount: .exact(25_000), of: 80_000)
    ])
    let result = timeline(state, [marker("tx", at: at(today, 9), amount: 80_000, title: "송금")])

    let block = try #require(result.blocks.first { $0.title == "농구" })
    let item = try #require(block.allocations.first)
    #expect(item.allocatedAmount == .exact(30_000) && item.isPartOfTransaction)
    #expect(item.transactionAmount == won(80_000) && item.occursOnSelectedDay)
    #expect(block.allocatedSpend.first?.exactMinorUnits == 30_000)                    // the block shows its portion, not the whole payment

    let stray = try #require(result.markers.first)
    #expect(stray.allocations.count == 2 && !stray.isFullyAllocated)
    #expect(stray.remainder == AmountBounds(lower: 25_000, upper: 25_000))
    let toA = try #require(stray.allocations.first { $0.activityID == ActivityID(rawValue: "A") })
    let toB = try #require(stray.allocations.first { $0.activityID == ActivityID(rawValue: "B") })
    #expect(toA.isShownToday && !toB.isShownToday && toB.activityTitle == "내일 여행")

    let totals = try #require(result.summary.totals.first)
    #expect(totals.linkedNetMinorUnits == 55_000 && totals.unlinkedNetMinorUnits == 25_000 && totals.uncertainNetMinorUnits == 0)
    #expect(result.summary.partiallyAllocatedTransactionCount == 1 && result.summary.unlinkedTransactionCount == 0)
}

@Test func anUnknownPortionIsReportedAsUncertainNotAsAGuess() throws {
    // 50,000원: A에 속하지만 금액 미상, 10,000은 활동 외로 확정
    let state = life([
        allocation("tx", to: "A", amount: .unknown, of: 50_000),
        allocation("tx", to: nil, amount: .exact(10_000), of: 50_000)
    ])
    let result = timeline(state, [marker("tx", at: at(today, 10, 30), amount: 50_000)])
    let totals = try #require(result.summary.totals.first)
    #expect(totals.linkedNetMinorUnits == 0)                       // nothing about A is settled
    #expect(totals.unlinkedNetMinorUnits == 10_000)
    #expect(totals.uncertainNetMinorUnits == 40_000)               // the rest is not forced into either bucket
    let aggregate = try #require(result.blocks.first { $0.title == "농구" }?.allocatedSpend.first)
    #expect(aggregate.unresolvedCount == 1 && aggregate.upperBoundMinorUnits == nil && aggregate.exactMinorUnits == 0)
    #expect(result.markers.count == 1)                             // not wholly accounted for, so the marker remains
}

@Test func aRangePortionKeepsBothBoundsInTheBlock() throws {
    let state = life([allocation("tx", to: "A", amount: amountRange(20_000, 30_000), of: 80_000)])
    let result = timeline(state, [marker("tx", at: at(today, 9), amount: 80_000)])
    let aggregate = try #require(result.blocks.first { $0.title == "농구" }?.allocatedSpend.first)
    #expect(aggregate.lowerBoundMinorUnits == 20_000 && aggregate.upperBoundMinorUnits == 30_000)
    #expect(result.markers.first?.remainder == AmountBounds(lower: 50_000, upper: 60_000))
}

@Test func aTransactionFullyAccountedForInsideTodaysBlocksNeedsNoMarker() throws {
    let state = life([
        allocation("tx", to: "A", amount: .exact(6_000), of: 10_000),
        allocation("tx", to: "A2", amount: .exact(4_000), of: 10_000)
    ])
    let result = timeline(state, [marker("tx", at: at(today, 9), amount: 10_000)])
    #expect(result.markers.isEmpty)
    #expect(result.blocks.flatMap(\.allocations).map(\.allocatedAmount).sorted { ($0.knownValue ?? 0) < ($1.knownValue ?? 0) } == [.exact(4_000), .exact(6_000)])
    #expect(result.summary.partiallyAllocatedTransactionCount == 1)     // split, though complete
    #expect(result.summary.totals.first?.linkedNetMinorUnits == 10_000)
}

@Test func aWholeTransactionLinkedToOneVisibleActivityIsNotPartial() throws {
    let state = life([wholeAllocation("tx", to: "A", total: 14_000)])
    let result = timeline(state, [marker("tx", at: at(today, 9), amount: 14_000)])
    #expect(result.markers.isEmpty && result.summary.partiallyAllocatedTransactionCount == 0)
    #expect(result.blocks.first { $0.title == "농구" }?.allocations.first?.isPartOfTransaction == false)
}

@Test func aDeliberateNoActivityPortionIsNonActivitySpendingNotUnallocated() throws {
    let state = life([allocation("tx", to: nil, amount: .exact(14_000), of: 14_000)])
    let result = timeline(state, [marker("tx", at: at(today, 9), amount: 14_000)])
    #expect(result.summary.unlinkedTransactionCount == 1)
    #expect(result.summary.totals.first?.unlinkedNetMinorUnits == 14_000)
    let stray = try #require(result.markers.first)
    #expect(stray.isFullyAllocated && stray.allocations.first?.activityID == nil)       // decided, and shown as such
}

@Test func refundsAreAllocatedSeparatelyAndSubtractFromTheDay() throws {
    let state = life([
        wholeAllocation("spend", to: "A", total: 10_000),
        allocation("refund", to: "A", amount: .exact(3_000), of: 3_000, flow: .refund)
    ])
    let result = timeline(state, [
        marker("spend", at: at(today, 9), amount: 10_000),
        marker("refund", at: at(today, 9, 30), amount: 3_000, flow: .refund)
    ])
    let block = try #require(result.blocks.first { $0.title == "농구" })
    #expect(block.allocatedSpend.first?.exactMinorUnits == 10_000)
    #expect(block.allocatedRefunds.first?.exactMinorUnits == 3_000)
    #expect(result.summary.totals.first?.linkedNetMinorUnits == 7_000)
}

@Test func anInferredAllocationKeepsItsEvidenceLevelInTheReadModel() throws {
    let state = life([allocation("tx", to: "A", amount: inferred(12_000), of: 12_000, provenance: autoProvenance(1.0))])
    let result = timeline(state, [marker("tx", at: at(today, 9), amount: 12_000)])
    let item = try #require(result.blocks.first { $0.title == "농구" }?.allocations.first)
    #expect(item.allocatedAmount == inferred(12_000) && item.source == .automated)
    let aggregate = try #require(result.blocks.first { $0.title == "농구" }?.allocatedSpend.first)
    #expect(aggregate.inferredMinorUnits == 12_000 && aggregate.exactMinorUnits == 0)   // inferred is not folded into exact
}

@Test func theBadgeShowsParticipantsAndOpenObligations() throws {
    let state = try lifeWithPeople(["friend"], extra: [
        .createActivity(Activity.materialized(from: eventA, id: ActivityID(rawValue: "A"), at: 1)),
        .addParticipant(ActivityID(rawValue: "A"), ParticipantAssignment(personID: pid("friend"), provenance: userProvenance())),
        .addParticipant(ActivityID(rawValue: "A"), ParticipantAssignment(personID: myself, provenance: userProvenance())),
        .createObligation(obligation("open", .payable, .unknown, activity: "A")),
        .createObligation(obligation("done", .receivable, .exact(5_000), activity: "A"))
    ]).applying([.cancelObligation(oid("done"), by: userProvenance())])
    let result = timeline(state, [])
    let badge = try #require(result.blocks.first { $0.title == "농구" }?.activity)
    #expect(badge.participantIDs == [pid("friend"), myself])
    #expect(badge.openObligationCount == 1)                                             // a cancelled obligation is not open
}

@Test func theWeekStripCountsTransactionsWithNoActivityPortion() throws {
    let state = life([
        wholeAllocation("linked", to: "A", total: 5_000),
        allocation("outside", to: nil, amount: .exact(3_000), of: 3_000)
    ])
    let strip = WeekStripBuilder.build(
        containing: today, timeZone: seoul, events: [], life: state,
        transactions: [
            marker("linked", at: at(today, 9), amount: 5_000),
            marker("outside", at: at(today, 10), amount: 3_000),
            marker("none", at: at(today, 11), amount: 1_000)
        ]
    )
    let cell = try #require(strip.first { $0.day == today })
    #expect(cell.unlinkedTransactionCount == 2)                       // the explicit "no activity" one and the never-allocated one
    #expect(cell.netSpend == [won(9_000)])
}
