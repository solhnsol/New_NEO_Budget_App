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
        let usualDrafts: [CalendarEventDraft] = [
            draft(school, "알고리즘 수업", today, (9, 0), (10, 30), location: "공학관 302"),
            draft(appointments, "점심 약속", today, (12, 0), (13, 0), location: "성수"),
            draft(life, "스터디", today, (12, 30), (14, 30)),
            draft(life, "저녁 운동", today, (19, 0), (20, 30)),
            draft(school, "팀 회의", tomorrow, (15, 0), (16, 0)),
            draft(appointments, "영화", yesterday, (20, 0), (22, 10)),
        ]
        // `-demo-long`: events of 30 minutes, 2 hours and 8 hours today and one that fills tomorrow, to check editing of
        // long events. Replaces the usual events so nothing overlaps them.
        let fullDay = try? TimedRange(startUnixMilliseconds: at(tomorrow, 0), endUnixMilliseconds: at(tomorrow.adding(days: 1), 0))
        // `-demo-overlap`: a workshop that holds a class (which holds a break), a partial overlap, and three events starting
        // together, with unlinked transactions during and outside them.
        let overlapDrafts: [CalendarEventDraft] = [
            draft(life, "종일 워크숍", today, (9, 0), (17, 0)),
            draft(school, "알고리즘 수업", today, (10, 0), (11, 30), location: "공학관 302"),
            draft(life, "휴식", today, (10, 30), (11, 0)),
            draft(appointments, "점심 약속", today, (12, 0), (13, 0), location: "성수"),
            draft(life, "스터디", today, (12, 30), (14, 30)),
            draft(appointments, "A 회의", today, (16, 0), (17, 30)),
            draft(life, "B 통화", today, (16, 0), (17, 0)),
            draft(life, "C 메모", today, (16, 5), (16, 40)),
            draft(life, "저녁 운동", today, (19, 0), (20, 30)),
            draft(school, "팀 회의", tomorrow, (15, 0), (16, 0)),
        ]
        let drafts: [CalendarEventDraft] = ProcessInfo.processInfo.arguments.contains("-demo-overlap") ? overlapDrafts
            : !ProcessInfo.processInfo.arguments.contains("-demo-long") ? usualDrafts : [
            draft(life, "30분 일정", today, (8, 0), (8, 30)),
            draft(life, "2시간 일정", today, (10, 0), (12, 0)),
            draft(appointments, "8시간 일정", today, (13, 0), (21, 0)),
        ] + (fullDay.map { [CalendarEventDraft(calendarID: life, title: "24시간 일정", time: .timed($0))] } ?? [])
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

/// Meaning for the demo events (type, area, people, tags), as the initial state of the life repository. Nothing here
/// is real data; it only gives the expanded event something to show.
enum DemoLife {
    static func initialState(events: [CalendarEvent]) -> LifeState {
        func provenance() -> AssignmentProvenance { .user(at: 1, evidenceVersion: nil) }
        let sungsu = Area(id: AreaID(rawValue: "demo-sungsu"), displayName: "성수")
        let sinchon = Area(id: AreaID(rawValue: "demo-sinchon"), displayName: "신촌")
        let gathering = Tag(id: TagID(rawValue: "demo-gathering"), name: "#모임")
        let people = [
            Person(id: PersonID(rawValue: "demo-me"), displayName: "나", isSelf: true),
            Person(id: PersonID(rawValue: "demo-jieun"), displayName: "지은"),
            Person(id: PersonID(rawValue: "demo-gayoung"), displayName: "가영"),
            Person(id: PersonID(rawValue: "demo-minsu"), displayName: "민수"),
        ]
        var changes: [LifeChange] = [.upsertArea(sungsu), .upsertArea(sinchon), .upsertTag(gathering)] + people.map { .upsertPerson($0) }

        func describe(_ title: String, type: ActivityTypeID, area: Area?, people ids: [String], tag: Tag? = nil) {
            guard let event = events.first(where: { $0.title == title }) else { return }
            let id = ActivityID(rawValue: "demo-activity-\(title)")
            changes.append(.createActivity(Activity.materialized(from: event, id: id, at: 1)))
            changes.append(.setActivityType(id, Assigned(type, provenance: provenance())))
            if let area { changes.append(.setActivityArea(id, Assigned(area.id, provenance: provenance()))) }
            if let tag { changes.append(.setActivityTag(id, TagAssignment(tagID: tag.id, provenance: provenance()))) }
            for person in ids {
                changes.append(.addParticipant(id, ParticipantAssignment(personID: PersonID(rawValue: person), provenance: provenance())))
            }
        }
        describe("점심 약속", type: .social, area: sungsu, people: ["demo-me", "demo-jieun", "demo-gayoung", "demo-minsu"], tag: gathering)
        describe("스터디", type: .study, area: nil, people: ["demo-me", "demo-minsu"])
        describe("알고리즘 수업", type: .study, area: sinchon, people: ["demo-me"])
        describe("저녁 운동", type: .exercise, area: nil, people: ["demo-me", "demo-jieun"])
        return (try? LifeState.empty.applying(changes)) ?? .empty
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

/// Holds the timeline in a state worth screenshotting (`-demo-preview expand|edit|move|resize|create`). Only used with `-demo`;
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
        case "expand":
            if let block = timeline.blocks.first(where: { $0.title == "점심 약속" }) { editor.toggleExpanded(block) }
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

extension DemoPreview {
    /// `-demo-preview script-zoom`: plays one handle drag by itself, with real pauses, so a screen recording can be measured
    /// frame by frame. Enters edit mode on the 24 hour event (use with `-demo-long`), drags its end handle quickly into the
    /// compressed middle, rests there (the zone moves by itself after 400 ms), nudges by 15 minutes, lets go, and leaves edit mode.
    @MainActor
    static func runScript(_ mode: String, on model: AppModel) async {
        if mode == "script-return" { await runReturnScript(on: model); return }
        if mode == "script-oscillate" { await runReturnScript(on: model, oscillate: true); return }
        guard mode == "script-zoom", let editor = model.editor else { return }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        await model.shift(days: 1)
        await pause(2.5)
        guard let timeline = model.timeline, let block = timeline.blocks.first(where: { $0.title == "24시간 일정" }) else { return }
        _ = editor.enterEditMode(for: block, pressMinute: 12 * 60)
        await pause(1.0)
        let geometry = editor.geometry
        let start = geometry.y(minute: block.endMinute)
        let target = geometry.y(minute: 13 * 60 + 15)
        editor.setFingerAnchor(y: start)
        guard editor.begin(.resizeEnd, block: block, timeline: timeline, geometry: geometry) else { return }
        for step in 1...8 {
            editor.update(fingerY: start + (target - start) * CGFloat(step) / 8)
            await pause(0.03)
        }
        await pause(1.2)                                         // rest: the zone opens here by itself
        editor.update(fingerY: editor.fingerContentY - 15 * TimelineAxis.Parameters.standard.editScale)   // one 15 minute step in the zoomed zone
        await pause(0.8)
        editor.finish()
        await pause(1.5)
        editor.exitEditMode(anchorMinute: 12 * 60)
    }
}

extension DemoPreview {
    /// `-demo-preview script-return`: the first event of the day, its end handle dragged later until a zone opens, then dragged
    /// back to where it started and let go (nothing changes, so the zone folds away and the view returns). For measuring that return.
    @MainActor
    static func runReturnScript(on model: AppModel, oscillate: Bool = false) async {
        guard let editor = model.editor, let timeline = model.timeline,
              let block = timeline.blocks.first(where: { $0.title == "알고리즘 수업" }) else { return }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        await pause(2.5)
        _ = editor.enterEditMode(for: block, pressMinute: block.startMinute + 10)
        await pause(1.0)
        let geometry = editor.geometry
        let start = geometry.y(minute: block.endMinute)
        let target = geometry.y(minute: block.endMinute + 100)
        editor.setFingerAnchor(y: start)
        guard editor.begin(.resizeEnd, block: block, timeline: timeline, geometry: geometry) else { return }
        for step in 1...8 {
            editor.update(fingerY: start + (target - start) * CGFloat(step) / 8)
            await pause(0.03)
        }
        await pause(1.2)                                         // rest: a zone opens at the later time
        if oscillate {
            // Up and down through the compressed stretch, resting each time, and then stay: the event must still be in view.
            for extra in [40, 120, 40, 120] {
                let g = editor.geometry
                let finger = editor.fingerContentY
                let current = g.minute(atY: finger)
                _ = current
                let targetY = g.y(minute: block.endMinute + extra)
                for step in 1...6 { editor.update(fingerY: finger + (targetY - finger) * CGFloat(step) / 6); await pause(0.03) }
                await pause(1.0)
            }
            await pause(6)
            editor.cancel()
            return
        }
        let back = editor.geometry.y(minute: block.endMinute)    // where the original end is drawn now
        for step in 1...8 {
            editor.update(fingerY: editor.fingerContentY + (back - editor.fingerContentY) * CGFloat(step) / 8)
            await pause(0.03)
        }
        await pause(0.6)
        editor.finish()                                          // back where it started: nothing is written
        await pause(2.0)
    }
}
