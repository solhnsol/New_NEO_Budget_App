import Testing
import NEOBudgetCalendar
import NEOBudgetInMemoryCalendar

@Test func aCreatedCalendarIsListedAndWritable() async throws {
    let provider = InMemoryCalendarProvider()
    guard case let .success(made) = await provider.createCalendar(title: "운동", colorHex: "#3FA66B") else { Issue.record("not created"); return }
    #expect(made.title == "운동" && made.colorHex == "#3FA66B" && made.isWritable)
    #expect(try await provider.calendars().map(\.id) == [made.id])
}

@Test func deletingACalendarRemovesItsEvents() async throws {
    let provider = InMemoryCalendarProvider(calendars: [CalendarDescriptor(id: CalendarID(rawValue: "c"), title: "일상")])
    let range = try TimedRange(startUnixMilliseconds: 0, endUnixMilliseconds: 3_600_000)
    let draft = CalendarEventDraft(calendarID: CalendarID(rawValue: "c"), title: "x", time: .timed(range))
    guard case let .success(event) = await provider.createEvent(draft) else { Issue.record("no event"); return }
    #expect(await provider.deleteCalendar(CalendarID(rawValue: "c")) == .success(true))
    #expect(try await provider.calendars().isEmpty)
    #expect(try await provider.event(event.key) == nil)
}

@Test func aReadOnlyCalendarCannotBeDeleted() async {
    let id = CalendarID(rawValue: "ro")
    let provider = InMemoryCalendarProvider(calendars: [CalendarDescriptor(id: id, title: "구독", isWritable: false)])
    #expect(await provider.deleteCalendar(id) == .failure(.calendarNotWritable(id)))
}
