import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()

private func event(_ id: String, _ title: String, _ from: Int, _ to: Int) throws -> CalendarEvent {
    let range = try TimedRange(startUnixMilliseconds: zone.instant(of: day, minuteOfDay: from), endUnixMilliseconds: zone.instant(of: day, minuteOfDay: to))
    return CalendarEvent(id: CalendarEventID(rawValue: id), calendarID: CalendarID(rawValue: "c"), title: title, time: .timed(range), revisionToken: "r")
}

private func marker(_ id: String, minute: Int) throws -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: minute),
        amount: try Money(minorUnits: 3_000, currency: "KRW"), flow: .spend, title: "상점 \(id)"
    )
}

@Test func theListHasEventsAndLooseTransactionsInTheOrderTheyHappen() throws {
    let timeline = DayTimelineBuilder.build(DayTimelineInput(
        day: day, timeZone: zone, events: [try event("late", "저녁", 1_080, 1_140), try event("early", "점심", 720, 780)],
        life: .empty, transactions: [try marker("m", minute: 600)]
    ))
    let plan = DayListPlan.make(timeline)
    #expect(plan.items.count == 3)
    #expect(plan.items.first?.id.hasPrefix("daily/") == true)
    let titles = plan.items.compactMap { item -> String? in if case let .event(block) = item { block.title } else { nil } }
    #expect(titles == ["점심", "저녁"])
}

@Test func transactionsBetweenTheSameTwoEventsShareOneDailyGroupWithThatStretch() throws {
    let timeline = DayTimelineBuilder.build(DayTimelineInput(
        day: day, timeZone: zone, events: [try event("a", "회의", 540, 600), try event("b", "저녁", 1_080, 1_140)],
        life: .empty, transactions: [try marker("m1", minute: 700), try marker("m2", minute: 800), try marker("m3", minute: 1_200)]
    ))
    let groups = DayListPlan.make(timeline).items.compactMap { item -> DayListPlan.DailyGroup? in if case let .daily(group) = item { group } else { nil } }
    #expect(groups.count == 2)
    #expect(groups[0].markers.count == 2 && groups[0].fromMinute == 600 && groups[0].toMinute == 1_080)
    #expect(groups[1].markers.count == 1 && groups[1].fromMinute == 1_140 && groups[1].toMinute == timeline.totalMinutes)
}
