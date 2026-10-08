import CoreGraphics
import Testing
@testable import OnAllApp

private func plan(_ count: Int, height: CGFloat) -> InlineAllocationPlan {
    InlineAllocationPlan.make(allocationCount: count, blockHeight: height, showsTime: InlineAllocationPlan.showsTime(blockHeight: height))
}

@Test func aBlockWithoutLinkedTransactionsShowsNothingExtra() {
    #expect(plan(0, height: 200) == InlineAllocationPlan(shown: 0, hidden: 0, showsSummaryRow: false, showsSummaryChip: false))
}

@Test func upToThreeTransactionsAreShownWhenThereIsRoomAndTheBlockNeverGrowsForThem() {
    let tall = plan(3, height: 120)
    #expect(tall.shown == 3 && tall.hidden == 0 && !tall.showsSummaryRow && !tall.showsSummaryChip)
    // Four or more fold: two real rows and "+2건"; never more than three rows in the block.
    let many = plan(5, height: 200)
    #expect(many.shown == 2 && many.hidden == 3 && many.shown + 1 <= InlineAllocationPlan.maximumInline)
}

@Test func aShortBlockFoldsWhatDoesNotFit() {
    // 70pt leaves room for two rows after the title and time: one transaction plus "+N".
    let two = plan(4, height: 70)
    #expect(two.shown == 1 && two.hidden == 3)
}

@Test func withRoomForOnlyOneRowSeveralTransactionsBecomeASummaryRowNotALoneCount() {
    let one = plan(4, height: 52)
    #expect(one.shown == 0 && one.showsSummaryRow && one.hidden == 4)
    // A single transaction is simply shown.
    #expect(plan(1, height: 52).shown == 1)
}

@Test func aBlockTooSmallForAnyRowShowsOnlyASummaryChip() {
    let small = plan(2, height: 30)
    #expect(small.shown == 0 && small.hidden == 0 && small.showsSummaryChip && !small.showsSummaryRow)
}
