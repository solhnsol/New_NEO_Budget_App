import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private let me = PersonID(rawValue: "me")
private let minsu = PersonID(rawValue: "minsu")
private let jiwon = PersonID(rawValue: "jiwon")

@Test func equalSplitOverTheNamedAndMe() throws {
    let plan = try EventSettlementPlan.make(totalMinorUnits: 60_000, currency: "KRW", me: me, others: [(minsu, "민수")], headcount: nil)
    #expect(plan.headcount == 2)
    #expect(plan.others.map(\.minorUnits) == [30_000])
    #expect(plan.myShareMinorUnits == 30_000)
}

@Test func headcountCountsPeopleNotNamedYet() throws {
    // Dinner for four, only 민수 named: everyone's share is 15,000, and the two unnamed shares stay with me until they are named.
    let plan = try EventSettlementPlan.make(totalMinorUnits: 60_000, currency: "KRW", me: me, others: [(minsu, "민수")], headcount: 4)
    #expect(plan.others.map(\.minorUnits) == [15_000])
    #expect(plan.unnamedCount == 2)
    #expect(plan.unnamedShareMinorUnits == 15_000)
    #expect(plan.keptByMeMinorUnits == 45_000)
}

@Test func headcountNeverHidesANamedPerson() throws {
    let plan = try EventSettlementPlan.make(totalMinorUnits: 30_000, currency: "KRW", me: me, others: [(minsu, "민수"), (jiwon, "지원")], headcount: 2)
    #expect(plan.headcount == 3)
    #expect(plan.unnamedCount == 0)
}

@Test func aHandSetShareLeavesTheRestEqual() throws {
    let plan = try EventSettlementPlan.make(
        totalMinorUnits: 60_000, currency: "KRW", me: me, others: [(minsu, "민수"), (jiwon, "지원")], headcount: nil, fixed: [jiwon: 10_000]
    )
    #expect(plan.others.first { $0.personID == jiwon }?.minorUnits == 10_000)
    #expect(plan.others.first { $0.personID == minsu }?.minorUnits == 25_000)
    #expect(plan.myShareMinorUnits == 25_000)
    #expect(throws: EventSettlementPlan.Problem.fixedExceedTotal) {
        try EventSettlementPlan.make(totalMinorUnits: 60_000, currency: "KRW", me: me, others: [(minsu, "민수")], headcount: nil, fixed: [minsu: 70_000])
    }
}

@Test func theSavedComponentAsksEachNamedPersonForTheirShare() throws {
    let plan = try EventSettlementPlan.make(totalMinorUnits: 60_000, currency: "KRW", me: me, others: [(minsu, "민수")], headcount: 4)
    let event = CalendarEventKey(calendarID: CalendarID(rawValue: "c"), eventID: CalendarEventID(rawValue: "dinner"))
    let input = plan.component(for: event, me: me, existing: nil, provenance: .user(at: 1, evidenceVersion: nil))
    #expect(input.payerID == me)
    #expect(Set(input.participants ?? []) == [me, minsu])
    #expect(input.policy?.splitRule == .fixedAmounts([minsu: 15_000]))
    #expect(input.amount == .exact(60_000))
}
