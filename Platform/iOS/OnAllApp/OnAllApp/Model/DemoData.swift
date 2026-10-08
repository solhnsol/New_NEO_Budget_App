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
        let holidays = CalendarID(rawValue: "demo-holidays")

        func at(_ day: LocalDate, _ hour: Int, _ minute: Int = 0) -> Int64 { zone.instant(of: day, minuteOfDay: hour * 60 + minute) }

        // A read-only calendar's event, to check that it cannot be picked up.
        let readOnlyRange = try? TimedRange(startUnixMilliseconds: at(today, 17, 30), endUnixMilliseconds: at(today, 18, 15))
        let readOnlyEvents = readOnlyRange.map {
            [CalendarEvent(
                id: CalendarEventID(rawValue: "demo-ro"), calendarID: holidays, title: "구독 일정", time: .timed($0),
                isEditable: false, revisionToken: "ro0"
            )]
        } ?? []
        let provider = InMemoryCalendarProvider(
            calendars: [
                CalendarDescriptor(id: life, title: "일상", colorHex: "#4C8DF6"),
                CalendarDescriptor(id: appointments, title: "약속", colorHex: "#F28B30"),
                CalendarDescriptor(id: school, title: "학교", colorHex: "#3FA66B"),
                CalendarDescriptor(id: holidays, title: "구독 캘린더", colorHex: "#8E8E93", isWritable: false),
            ],
            events: readOnlyEvents,
            supportedRecurrenceScopes: [.thisOccurrence, .allInSeries],
            dayZone: zone
        )
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

        let failFirstWrite = ProcessInfo.processInfo.arguments.contains("-demo-fail-next-write")
        let seed: @Sendable () async -> Void = {
            for item in drafts { _ = await provider.createEvent(item) }
            if let weekRange {
                _ = await provider.createEvent(CalendarEventDraft(calendarID: life, title: "기말 준비 주간", time: .allDay(weekRange)))
            }
            await provider.seedSeries(
                calendarID: school, title: "영어 회화",
                firstStartUnixMilliseconds: seriesStart, durationMilliseconds: 3_600_000, count: 4
            )
            // Debug hook: the user's first edit fails, to check rollback and the retry banner.
            if failFirstWrite { await provider.failNextWrite(with: .saveFailed(retryable: true, reason: "demo")) }
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

/// Links sample transactions to the demo events through the real command, so event blocks show linked spending inline.
enum DemoLinks {
    private static let links: [(event: String, transactions: [String])] = [
        ("점심 약속", ["sample-restaurant", "sample-dessert", "sample-parking", "sample-snack"]),   // four: shows the "+N" fold
        ("스터디", ["sample-cafe", "sample-convenience"]),
        ("저녁 운동", ["sample-refund"]),
    ]

    static func apply(service: CalendarCommandService, provider: any CalendarProvider, zone: DisplayTimeZone, day: LocalDate) async {
        let bounds = zone.dayBounds(day)
        guard let events = try? await provider.events(from: bounds.start, to: bounds.end, calendarIDs: nil) else { return }
        for link in links {
            guard let event = events.first(where: { $0.title == link.event }) else { continue }
            for raw in link.transactions {
                _ = await service.perform(.linkTransaction(LinkTransactionInput(
                    transactionID: SampleLedger.entryID(for: raw), target: .event(event.key), provenance: .user(at: 1, evidenceVersion: nil)
                )))
            }
        }
    }
}

/// Holds the timeline in a state worth screenshotting (`-demo-preview edit|move|resize|create`). Only used with `-demo`;
/// it drives the same editor entry points a finger does.
enum DemoPreview {
    @MainActor
    static func apply(_ mode: String, to model: AppModel) {
        guard let editor = model.editor, let timeline = model.timeline else { return }
        func selectClass() -> EventBlock? {
            guard let block = timeline.blocks.first(where: { $0.title == "알고리즘 수업" }),
                  editor.enterEditMode(for: block, pressMinute: block.startMinute + 10) else { return nil }
            return block
        }
        switch mode {
        case "edit":
            _ = selectClass()
        case "move":
            guard let block = selectClass() else { return }
            let geometry = editor.geometry
            if editor.begin(.move, block: block, timeline: timeline, geometry: geometry) {
                editor.update(translationY: geometry.y(minute: block.startMinute + 70) - geometry.y(minute: block.startMinute))
            }
        case "resize":
            guard let block = selectClass() else { return }
            let geometry = editor.geometry
            if editor.begin(.resizeEnd, block: block, timeline: timeline, geometry: geometry) {
                editor.update(translationY: geometry.y(minute: block.endMinute + 50) - geometry.y(minute: block.endMinute))
            }
        case "create":
            guard editor.focusForCreate(atMinute: 10 * 60 + 50) else { return }
            let geometry = editor.geometry
            if editor.beginCreate(atY: geometry.y(minute: 10 * 60 + 50), timeline: timeline, geometry: geometry) {
                editor.updateCreate(toY: geometry.y(minute: 11 * 60 + 55))
            }
        default:
            break
        }
    }
}
