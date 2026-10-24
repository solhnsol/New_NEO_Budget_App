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
    #expect(plan.items.first?.id.hasPrefix("marker/") == true)
    let titles = plan.items.compactMap { item -> String? in if case let .event(block) = item { block.title } else { nil } }
    #expect(titles == ["점심", "저녁"])
}
