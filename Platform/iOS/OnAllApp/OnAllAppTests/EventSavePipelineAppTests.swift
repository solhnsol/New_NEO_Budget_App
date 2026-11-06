import Foundation
import NEOBudgetCalendar
import NEOBudgetInMemoryCalendar
import Testing
@testable import OnAllApp

// The Phase 3A save adapter (`EventSavePipeline`, package) against the app's existing edit path: for the same block and range it must send the
// command `TimelineEditPlanner` sends and offer the scopes it offers, so a draft saved through it means exactly what a timeline drag means. And
// `AppModel.save` runs it on the real model and shows the result.

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let work = CalendarID(rawValue: "work")

private func at(_ date: LocalDate, _ hour: Int, _ minute: Int = 0) -> Int64 { zone.instant(of: date, minuteOfDay: hour * 60 + minute) }
private func range(_ from: Int64, _ to: Int64) -> TimedRange { (try? TimedRange(startUnixMilliseconds: from, endUnixMilliseconds: to)) ?? { fatalError("range") }() }

private func timeline(scopes: Set<RecurrenceScope>) async throws -> DayTimeline {
    let late = CalendarEvent(
        id: CalendarEventID(rawValue: "late"), calendarID: work, title: "야간", time: .timed(range(at(day, 23), at(day.adding(days: 1), 1))), revisionToken: "r0"
    )
    let single = CalendarEvent(
        id: CalendarEventID(rawValue: "one"), calendarID: work, title: "회의", time: .timed(range(at(day, 10), at(day, 11))), revisionToken: "r0"
    )
    let provider = InMemoryCalendarProvider(
        calendars: [CalendarDescriptor(id: work, title: "업무")], events: [single, late], supportedRecurrenceScopes: scopes, dayZone: zone
    )
    await provider.seedSeries(calendarID: work, title: "스터디", firstStartUnixMilliseconds: at(day, 14), durationMilliseconds: 3_600_000, count: 3)
    let service = CalendarCommandService(
        provider: provider, repository: InMemoryLifeRepository(), transactions: InMemoryTransactionSource(),
        configuration: CalendarServiceConfiguration(displayTimeZone: zone), makeID: { "id-\($0.rawValue)" }, now: { 1 }
    )
    return try await service.dayTimeline(for: day)
}

private func noWrites(_: CalendarCommand) async -> CalendarCommandOutcome { .rejected(.storageUnavailable) }
private func noReads(_: CalendarEventKey) async throws -> CalendarEvent? { nil }

@MainActor
@Test func theAdapterSendsTheCommandAndOffersTheScopesOfTheTimelineEditor() async throws {
    for scopes: Set<RecurrenceScope> in [[.thisOccurrence], [.thisOccurrence, .allInSeries]] {
        let timeline = try await timeline(scopes: scopes)
        let planner = TimelineEditPlanner(policy: .standard, zone: zone, geometry: TimelineGeometry(totalMinutes: timeline.totalMinutes), timeline: timeline)
        let pipeline = EventSavePipeline(supportedScopes: scopes, zone: zone, perform: noWrites, read: noReads)
        #expect(timeline.blocks.count == 3)
        for block in timeline.blocks {
            let start = block.startUnixMilliseconds
            let end = block.endUnixMilliseconds
            let hour: Int64 = 3_600_000
            let cases: [(TimelineEditPlanner.Kind, TimedRange)] = [
                (.move, range(start + hour, end + hour)),
                (.move, range(start + 24 * hour, end + 24 * hour)),           // to the next day
                (.resizeStart, range(start - hour / 2, end)),
                (.resizeEnd, range(start, end + hour / 4)),
            ]
            for (kind, proposed) in cases {
                let request = EventSaveRequest(
                    original: EventSaveOriginal(block: block),
                    proposedStart: EventSaveTime.date(proposed.startUnixMilliseconds), proposedEnd: EventSaveTime.date(proposed.endUnixMilliseconds),
                    endLimit: EventSaveTime.date(timeline.dayEndUnixMilliseconds)
                )
                #expect(pipeline.scopeOptions(for: request) == planner.scopeOptions(for: block, newRange: proposed, supported: scopes))
                for scope in [nil, RecurrenceScope.thisOccurrence, .allInSeries] {
                    #expect(request.command(scope: scope) == planner.command(kind, block: block, newRange: proposed, scope: scope), "\(block.title) \(kind)")
                }
            }
        }
    }
}

@MainActor
@Test func savingThroughTheModelAsksForTheScopeThenShowsTheSavedOccurrence() async throws {
    let model = try AppModel.demo()
    await model.start()
    let today = model.selectedDay
    let block = try #require(model.visibleTimelines.first?.blocks.first { $0.title == "영어 회화" })
    #expect(block.isRecurringInstance)
    let original = EventSaveOriginal(block: block)
    let hour: TimeInterval = 3_600
    let request = EventSaveRequest(original: original, proposedStart: original.start + hour, proposedEnd: original.end + hour)
    let generation = model.dataGeneration
    #expect(await model.save(request) == .needsScope([.thisOccurrence, .allInSeries]))
    #expect(model.dataGeneration == generation)                                       // nothing written, nothing read
    guard case let .saved(receipt)? = await model.save(request.scoped(.thisOccurrence)) else { Issue.record("expected saved"); return }
    #expect(receipt.start == original.start + hour && receipt.scope == .thisOccurrence)
    #expect(model.dataGeneration > generation)                                        // the days were read again
    let shown = try #require(model.visibleTimelines.first { $0.day == today }?.blocks.first { $0.eventKey == block.eventKey })
    #expect(shown.startUnixMilliseconds == EventSaveTime.milliseconds(receipt.start))
    #expect(shown.revisionToken == receipt.event.revisionToken)
    // The same original again is no longer what the calendar holds.
    guard case .refused(.targetChanged)? = await model.save(request.scoped(.thisOccurrence)) else { Issue.record("expected targetChanged"); return }
}
