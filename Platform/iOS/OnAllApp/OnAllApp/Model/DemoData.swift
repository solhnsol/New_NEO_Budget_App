import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryCalendar

/// Synthetic calendar events around "today" for UI checks. Transactions come from `SampleLedger`. Nothing here is real data.
enum DemoData {
    struct Bundle {
        let provider: InMemoryCalendarProvider
        let seed: @Sendable () async -> Void
    }

    static func make(today: LocalDate, zone: DisplayTimeZone) -> Bundle {
        let life = CalendarID(rawValue: "demo-life")
        let appointments = CalendarID(rawValue: "demo-appt")
        let school = CalendarID(rawValue: "demo-school")
        let provider = InMemoryCalendarProvider(
            calendars: [
                CalendarDescriptor(id: life, title: "일상", colorHex: "#4C8DF6"),
                CalendarDescriptor(id: appointments, title: "약속", colorHex: "#F28B30"),
                CalendarDescriptor(id: school, title: "학교", colorHex: "#3FA66B"),
            ],
            supportedRecurrenceScopes: [.thisOccurrence, .allInSeries],
            dayZone: zone
        )

        func at(_ day: LocalDate, _ hour: Int, _ minute: Int = 0) -> Int64 { zone.instant(of: day, minuteOfDay: hour * 60 + minute) }
        func draft(_ calendar: CalendarID, _ title: String, _ day: LocalDate, _ from: (Int, Int), _ to: (Int, Int), location: String? = nil) -> CalendarEventDraft {
            let range = try? TimedRange(startUnixMilliseconds: at(day, from.0, from.1), endUnixMilliseconds: at(day, to.0, to.1))
            return CalendarEventDraft(calendarID: calendar, title: title, time: .timed(range ?? TimedRange.placeholder), location: location)
        }

        let tomorrow = today.adding(days: 1)
        let yesterday = today.adding(days: -1)
        let drafts: [CalendarEventDraft] = [
            draft(school, "알고리즘 수업", today, (9, 0), (10, 30), location: "공학관 302"),
            draft(appointments, "점심 약속", today, (12, 0), (13, 0), location: "성수"),
            draft(life, "스터디", today, (12, 30), (14, 30)),
            draft(life, "저녁 운동", today, (19, 0), (20, 30)),
            draft(school, "팀 회의", tomorrow, (15, 0), (16, 0)),
            draft(appointments, "영화", yesterday, (20, 0), (22, 10)),
        ]
        let weekRange = try? DayRange(firstDay: today, lastDay: tomorrow)
        let seriesStart = at(today.adding(days: -7), 16, 0)

        let seed: @Sendable () async -> Void = {
            for item in drafts { _ = await provider.createEvent(item) }
            if let weekRange {
                _ = await provider.createEvent(CalendarEventDraft(calendarID: life, title: "기말 준비 주간", time: .allDay(weekRange)))
            }
            await provider.seedSeries(
                calendarID: school, title: "영어 회화",
                firstStartUnixMilliseconds: seriesStart, durationMilliseconds: 3_600_000, count: 4
            )
        }

        return Bundle(provider: provider, seed: seed)
    }
}

private extension TimedRange {
    /// Only used if a demo range fails to construct, which cannot happen for the fixed values above.
    static var placeholder: TimedRange {
        (try? TimedRange(startUnixMilliseconds: 0, endUnixMilliseconds: 60_000)) ?? { fatalError("unreachable") }()
    }
}
