import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private func plan(_ count: Int, height: CGFloat) -> InlineAllocationPlan {
    InlineAllocationPlan.make(allocationCount: count, blockHeight: height, showsTime: InlineAllocationPlan.showsTime(blockHeight: height))
}

@Test func aBlockWithoutLinkedTransactionsShowsNothingExtra() {
    #expect(plan(0, height: 200) == InlineAllocationPlan(shown: 0, hidden: 0, showsSummaryRow: false, showsSummaryChip: false))
}

@Test func aCollapsedBlockShowsAtMostTwoTransactionsAndFoldsTheRestIntoPlusN() {
    // Room for three rows: two transactions and, when there are more, the "+N" row. Never a third transaction.
    let two = plan(2, height: 120)
    #expect(two.shown == 2 && two.hidden == 0)
    let three = plan(3, height: 120)
    #expect(three.shown == 2 && three.hidden == 1 && !three.showsSummaryRow)
    let many = plan(5, height: 200)
    #expect(many.shown == 2 && many.hidden == 3 && many.shown + 1 <= InlineAllocationPlan.maximumRows)
    #expect(many.shown <= InlineAllocationPlan.maximumItems)
}

@Test func aShortBlockFoldsWhatDoesNotFit() {
    // 70pt leaves room for two rows after the title and time: one transaction plus "+N".
    let two = plan(4, height: 70)
    #expect(two.shown == 1 && two.hidden == 3)
    // Two rows are enough for exactly two transactions, so there is no "+N".
    let exact = plan(2, height: 70)
    #expect(exact.shown == 2 && exact.hidden == 0)
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

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let ledgerCalendar = CalendarID(rawValue: "life")

struct Spec {
    let id: String
    let amount: AmountKnowledge
    let minuteOfDay: Int
    var flow: TransactionFlow = .spend
}

/// A real block with real allocations, built through the same builder the app uses (read-model types have no public init).
func blockWith(
    _ specs: [Spec], participants: [String] = [], typeID: ActivityTypeID? = nil, areaName: String? = nil, calendarTitle: String = "약속"
) throws -> EventBlock {
    let event = CalendarEvent(
        id: CalendarEventID(rawValue: "e"), calendarID: ledgerCalendar, title: "점심", time: .timed(
            try TimedRange(startUnixMilliseconds: zone.instant(of: day, minuteOfDay: 12 * 60), endUnixMilliseconds: zone.instant(of: day, minuteOfDay: 13 * 60))),
        revisionToken: "r0")
    let activityID = ActivityID(rawValue: "A")
    var changes: [LifeChange] = [.createActivity(Activity.materialized(from: event, id: activityID, at: 1))]
    let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)
    if let typeID { changes.append(.setActivityType(activityID, Assigned(typeID, provenance: provenance))) }
    if let areaName {
        let area = Area(id: AreaID(rawValue: "area"), displayName: areaName)
        changes += [.upsertArea(area), .setActivityArea(activityID, Assigned(area.id, provenance: provenance))]
    }
    for (index, name) in participants.enumerated() {
        let person = Person(id: PersonID(rawValue: "p\(index)"), displayName: name, isSelf: index == 0)
        changes += [.upsertPerson(person), .addParticipant(activityID, ParticipantAssignment(personID: person.id, provenance: provenance))]
    }
    var markers: [TransactionMarker] = []
    let total = try Money(minorUnits: 100_000, currency: "KRW")
    for spec in specs {
        let id = LedgerEntryID(rawValue: spec.id)
        markers.append(TransactionMarker(
            id: id, occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: spec.minuteOfDay), amount: total, flow: spec.flow, title: spec.id))
        changes.append(.upsertAllocation(
            TransactionAllocation(
                id: AllocationID(rawValue: "alloc-\(spec.id)"), transactionID: id, activityID: activityID,
                amount: try AmountEntry(currency: "KRW", knowledge: spec.amount, provenance: provenance),
                provenance: provenance, createdAtUnixMilliseconds: 1),
            transactionTotal: total, flow: spec.flow))
    }
    let life = try LifeState.empty.applying(changes)
    let calendars = [CalendarDescriptor(id: ledgerCalendar, title: calendarTitle)]
    let timeline = DayTimelineBuilder.build(DayTimelineInput(day: day, timeZone: zone, calendars: calendars, events: [event], life: life, transactions: markers))
    return try #require(timeline.blocks.first)
}

@Test func collapsedBlocksLeadWithTheLargestAndExpandedBlocksFollowTheDay() throws {
    let block = try blockWith([
        Spec(id: "small", amount: .exact(1_000), minuteOfDay: 12 * 60 + 10),
        Spec(id: "big", amount: .exact(50_000), minuteOfDay: 12 * 60 + 30),
        Spec(id: "unknown", amount: .unknown, minuteOfDay: 12 * 60 + 5),
        Spec(id: "estimate", amount: .estimated(8_000), minuteOfDay: 12 * 60 + 20),
    ])
    // An estimate still has a size (8,000 outranks a settled 1,000); only a transaction with no amount at all ranks last.
    #expect(AllocationOrdering.byAmountDescending(block.allocations).map(\.title) == ["big", "estimate", "small", "unknown"])
    #expect(AllocationOrdering.byTime(block.allocations).map(\.title) == ["unknown", "small", "estimate", "big"])
    // Equal amounts fall back to time, so the order is the same on every redraw.
    let tied = try blockWith([
        Spec(id: "later", amount: .exact(5_000), minuteOfDay: 12 * 60 + 20),
        Spec(id: "earlier", amount: .exact(5_000), minuteOfDay: 12 * 60 + 10),
    ])
    #expect(AllocationOrdering.byAmountDescending(tied.allocations).map(\.title) == ["earlier", "later"])
}

@Test func theLinkedTotalNeverMixesCurrenciesAndSaysWhatIsUnsettled() {
    func aggregate(_ currency: String, _ components: [AmountKnowledge]) -> AmountAggregate {
        AmountAggregate.summarize(components.map { (currency, $0) })[0]
    }
    #expect(LinkedTotal.text(spend: [aggregate("KRW", [.exact(10_000), .exact(2_000)])], refunds: []) == "12,000원")
    #expect(LinkedTotal.text(spend: [aggregate("KRW", [.exact(10_000)])], refunds: [aggregate("KRW", [.exact(3_000)])]) == "7,000원")
    #expect(LinkedTotal.text(spend: [aggregate("KRW", [.exact(10_000), .unknown])], refunds: []) == "10,000원 외 미정 1건")
    #expect(LinkedTotal.text(spend: [aggregate("KRW", [.unknown])], refunds: []) == "금액 미정 1건")
    let mixed = LinkedTotal.text(spend: [aggregate("KRW", [.exact(5_000)]), aggregate("USD", [.exact(1_250)])], refunds: [])
    #expect(mixed == "12.50 USD · 5,000원" || mixed == "5,000원 · 12.50 USD")
    #expect(LinkedTotal.text(spend: [], refunds: []) == nil)
}

// MARK: Expanded block

@Test func anExpandedBlockShowsWhatTheActivityHasAndSaysSoWhenItHasNothing() throws {
    let full = try blockWith(
        [], participants: ["나", "가영", "지은", "민수"], typeID: .social, areaName: "성수")
    let rows = ExpandedBlockPlan.metaRows(for: full)
    #expect(rows.map(\.label) == ["캘린더", "유형", "장소", "참여자"])
    #expect(rows.first { $0.label == "캘린더" }?.value == "약속")
    #expect(rows.first { $0.label == "유형" }?.value == "친구·사교" && rows.first { $0.label == "장소" }?.value == "성수")
    // The user first, then others by name; a long list stays on one line.
    #expect(rows.first { $0.label == "참여자" }?.value == "나, 가영 외 2명")

    let bare = try blockWith([])
    #expect(ExpandedBlockPlan.metaRows(for: bare).map(\.label) == ["캘린더", "활동"])
    #expect(ExpandedBlockPlan.metaRows(for: bare).last?.value == "아직 정보가 없습니다")
}

@Test func anExpandedBlockIsTallEnoughForItsContentAndGrowsOnlyWithWhatItShows() throws {
    let none = try blockWith([], participants: ["나"], typeID: .study)
    let two = try blockWith([Spec(id: "a", amount: .exact(1_000), minuteOfDay: 12 * 60 + 5), Spec(id: "b", amount: .exact(2_000), minuteOfDay: 12 * 60 + 9)],
                            participants: ["나"], typeID: .study)
    let five = try blockWith((0..<5).map { Spec(id: "t\($0)", amount: .exact(1_000), minuteOfDay: 12 * 60 + $0) }, participants: ["나"], typeID: .study)
    let base = ExpandedBlockPlan.height(for: none)
    #expect(ExpandedBlockPlan.height(for: two) == base + ExpandedBlockPlan.sectionGap + ExpandedBlockPlan.transactionHeaderHeight + 2 * ExpandedBlockPlan.transactionRowHeight)
    #expect(ExpandedBlockPlan.height(for: five) - ExpandedBlockPlan.height(for: two) == 3 * ExpandedBlockPlan.transactionRowHeight)
    // Every row fits: title, time, the meta rows, and the transaction section, plus padding both sides.
    #expect(base >= ExpandedBlockPlan.padding * 2 + ExpandedBlockPlan.titleHeight + ExpandedBlockPlan.timeHeight)
}

@Test func participantNamesShortenToTwoPlusTheCount() {
    #expect(ExpandedBlockPlan.participants(["나"]) == "나")
    #expect(ExpandedBlockPlan.participants(["나", "가영"]) == "나, 가영")
    #expect(ExpandedBlockPlan.participants(["나", "가영", "지은"]) == "나, 가영 외 1명")
}
