import Testing
import NEOBudgetCalendar

@Test func titleTimeSuggestionReadsKoreanAndClockTimes() {
    let a = TitleTimeSuggestion.find(in: "18시 저녁 약속")
    #expect(a?.minuteOfDay == 18 * 60 && a?.strippedTitle == "저녁 약속" && a?.label == "18:00 – 미정")
    #expect(TitleTimeSuggestion.find(in: "오후 6시 30분 회식")?.minuteOfDay == 18 * 60 + 30)
    #expect(TitleTimeSuggestion.find(in: "저녁 7시 반 모임")?.minuteOfDay == 19 * 60 + 30)
    #expect(TitleTimeSuggestion.find(in: "치과 14:30")?.strippedTitle == "치과")
    #expect(TitleTimeSuggestion.find(in: "오전 12시 점검")?.minuteOfDay == 0)
}

@Test func titleTimeSuggestionIgnoresDurationsAndImpossibleTimes() {
    #expect(TitleTimeSuggestion.find(in: "3시간 공부") == nil)
    #expect(TitleTimeSuggestion.find(in: "25시 모임") == nil)
    #expect(TitleTimeSuggestion.find(in: "스터디") == nil)
}

@Test func newEventWithoutAStartIsAllDay() throws {
    let input = NewEventInput(title: " 저녁 약속 ", calendarID: calendarID("life"), day: today)
    let plan = try input.plan(in: seoul)
    #expect(plan.draft.title == "저녁 약속" && plan.draft.time.isAllDay && !plan.isOpenEnd)
}

@Test func newEventWithAStartAndNoEndIsOpenEndWithAPlaceholder() throws {
    let plan = try NewEventInput(title: "약속", calendarID: calendarID("life"), day: today, startMinute: 18 * 60).plan(in: seoul)
    guard case let .timed(range) = plan.draft.time else { Issue.record("expected timed"); return }
    #expect(plan.isOpenEnd && range.startUnixMilliseconds == at(today, 18) && range.endUnixMilliseconds == at(today, 18, 30))
}

@Test func placeholderEndNeverCrossesMidnight() throws {
    let plan = try NewEventInput(title: "늦은 약속", calendarID: calendarID("life"), day: today, startMinute: 23 * 60 + 45).plan(in: seoul)
    guard case let .timed(range) = plan.draft.time else { Issue.record("expected timed"); return }
    #expect(range.endUnixMilliseconds == at(today, 23, 59))
}

@Test func newEventWithBothTimesIsNormalAndABadEndThrows() throws {
    let ok = try NewEventInput(title: "회의", calendarID: calendarID("life"), day: today, startMinute: 600, endMinute: 660).plan(in: seoul)
    #expect(!ok.isOpenEnd)
    #expect(throws: CalendarValidationError.self) {
        try NewEventInput(title: "회의", calendarID: calendarID("life"), day: today, startMinute: 600, endMinute: 600).plan(in: seoul)
    }
}

@Test func marksSurviveAMoveButNotAnEndTheUserSet() {
    let k = key("life", "e")
    var marks = OpenEndMarks()
    marks.mark(k)
    let half = 30 * 60_000 as Int64
    marks.reconcile([k]) { _ in event("e", from: at(today, 19), to: at(today, 19) + half) }
    #expect(marks.isOpenEnd(k))
    marks.reconcile([k]) { _ in event("e", from: at(today, 19), to: at(today, 21)) }
    #expect(!marks.isOpenEnd(k))
    marks.mark(k)
    marks.reconcile([k]) { _ in nil }
    #expect(marks.count == 0)
    marks.mark(k)
    marks.reconcile([k]) { _ in event("e", from: at(today, 19), to: at(today, 19) + half, recurring: true) }
    #expect(marks.count == 0)
}
