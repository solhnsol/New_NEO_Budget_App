import CoreGraphics
import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let first = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let calendar = CalendarID(rawValue: "c")

private func dayTimeline(_ date: LocalDate, titles: [(String, Int, Int)], markers: [TransactionMarker] = []) -> DayTimeline {
    let events = titles.enumerated().compactMap { index, item -> CalendarEvent? in
        guard let range = try? TimedRange(startUnixMilliseconds: zone.instant(of: date, minuteOfDay: item.1), endUnixMilliseconds: zone.instant(of: date, minuteOfDay: item.2)) else { return nil }
        return CalendarEvent(id: CalendarEventID(rawValue: "e\(index)"), calendarID: calendar, title: item.0, time: .timed(range), revisionToken: "r")
    }
    return DayTimelineBuilder.build(DayTimelineInput(day: date, timeZone: zone, events: events, life: .empty, transactions: markers))
}

private func marker(_ id: String, on date: LocalDate, minute: Int) -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: date, minuteOfDay: minute),
        amount: (try? Money(minorUnits: 3_000, currency: "KRW")) ?? { fatalError("money") }(), flow: .spend, title: "상점 \(id)"
    )
}

@MainActor
private func makeEditor() -> TimelineEditor {
    TimelineEditor(environment: TimelineEditor.Environment(
        perform: { _ in .applied(AppliedCommand()) }, reload: {}, supportedScopes: [.thisOccurrence], zone: zone, policy: .standard, calendars: { [] }
    ))
}

private let environment = TimelineEditor.AdaptiveEnvironment(viewportHeight: 700, contentWidth: 150, textScale: 1, contentSize: "large")

@MainActor private final class Counter { var measured = 0 }

@MainActor private func rig() -> (TimelineEditor, Counter, [DayTimeline]) {
    let editor = makeEditor()
    let counter = Counter()
    editor.measureTitle = { title, _ in counter.measured += 1; return CGFloat(title.count) * 10 }
    let days = [
        dayTimeline(first, titles: [("회의", 600, 660)], markers: [marker("t", on: first, minute: 700)]),
        dayTimeline(first.adding(days: 1), titles: [("점심", 720, 780)]),
    ]
    editor.timelinesDidChange(days)
    editor.updateEnvironment(environment)
    return (editor, counter, days)
}

@MainActor @Test func theEngineRunsOnceForTheFirstEnvironmentAndNothingMoreUntilAnInputChanges() {
    let (editor, _, days) = rig()
    #expect(editor.adaptive != nil && editor.adaptiveRuns == 1)
    // The same room and text size again, the same days again: nothing to recompute.
    editor.updateEnvironment(environment)
    editor.timelinesDidChange(days)
    editor.timelinesDidChange(days)
    #expect(editor.adaptiveRuns == 1)
}

@MainActor @Test func scrollingNeverRunsTheEngineBecauseNoScrollPositionIsAnInput() {
    let (editor, _, days) = rig()
    let before = editor.adaptiveRuns
    // What a scroll does to the editor: it is asked how far the content may shift, never told where it is.
    editor.visibleRange = { 100...500 }
    for offset in stride(from: CGFloat(0), through: 400, by: 20) {
        editor.visibleRange = { offset...(offset + 400) }
        _ = editor.visibleRange?()
        editor.timelinesDidChange(days)                                                 // a reload that finds nothing new
    }
    #expect(editor.adaptiveRuns == before)
    let reflected = Mirror(reflecting: editor.adaptive as Any).description.lowercased()
    #expect(!reflected.contains("scrolloffset") && !reflected.contains("contentoffset"))
}

@MainActor @Test func eachInputThatMattersInvalidatesTheResultExactlyOnce() {
    let (editor, _, days) = rig()
    var runs = editor.adaptiveRuns

    // A transaction appears.
    var changed = days
    changed[0] = dayTimeline(first, titles: [("회의", 600, 660)], markers: [marker("t", on: first, minute: 700), marker("u", on: first, minute: 800)])
    editor.timelinesDidChange(changed)
    #expect(editor.adaptiveRuns == runs + 1); runs += 1

    // An event changes its time.
    changed[1] = dayTimeline(first.adding(days: 1), titles: [("점심", 730, 780)])
    editor.timelinesDidChange(changed)
    #expect(editor.adaptiveRuns == runs + 1); runs += 1

    // An event is renamed.
    changed[1] = dayTimeline(first.adding(days: 1), titles: [("저녁", 730, 780)])
    editor.timelinesDidChange(changed)
    #expect(editor.adaptiveRuns == runs + 1); runs += 1

    // The days move over by one.
    editor.timelinesDidChange([changed[1], dayTimeline(first.adding(days: 2), titles: [])])
    #expect(editor.adaptiveRuns == runs + 1); runs += 1

    // The screen changes size (rotation, split view).
    var env = environment
    env.viewportHeight = 500
    editor.updateEnvironment(env)
    #expect(editor.adaptiveRuns == runs + 1); runs += 1
    env.contentWidth = 90
    editor.updateEnvironment(env)
    #expect(editor.adaptiveRuns == runs + 1); runs += 1

    // Dynamic Type changes.
    env.textScale = 1.6
    env.contentSize = "accessibility1"
    editor.updateEnvironment(env)
    #expect(editor.adaptiveRuns == runs + 1); runs += 1

    // Only the setting's name changing (same scale) still invalidates: the widths were measured at another size.
    env.contentSize = "accessibility2"
    editor.updateEnvironment(env)
    #expect(editor.adaptiveRuns == runs + 1)
}

@MainActor @Test func titlesAreMeasuredWhenTheEngineRunsAndNotWhileDrawing() {
    let (editor, counter, days) = rig()
    let measuredAtRun = counter.measured
    #expect(measuredAtRun == 2)                                                           // one per title, once
    for _ in 0..<50 { _ = editor.titleWidth(for: "회의"); _ = editor.titleWidth(for: "점심") }
    #expect(counter.measured == measuredAtRun)                                            // drawing only looks widths up
    #expect(editor.titleWidth(for: "회의") == 20 && editor.titleWidth(for: "점심") == 20)
    editor.timelinesDidChange(days)
    #expect(counter.measured == measuredAtRun)                                            // and an unchanged reload measures nothing
}

@MainActor @Test func theShapeOfTheAxisComesFromTheEngineOnceItHasRun() {
    let (editor, _, days) = rig()
    #expect(editor.geometry.axis == editor.adaptive?.axis)
    let plain = makeEditor()
    plain.timelinesDidChange(days)
    #expect(plain.adaptive == nil)                                                         // before the grid reports its room: the browse axis
    #expect(plain.geometry.axis == TimelineAxis.browse(main: days[0], secondary: days[1]))
}

@MainActor @Test func whileAnEventIsEditedTheLayoutIsHeldAndLeavingTakesInWhatChanged() throws {
    let (editor, _, days) = rig()
    let block = try #require(days[0].blocks.first)
    #expect(editor.enterEditMode(for: block, pressMinute: 610))
    editor.completeTransition()
    let held = editor.adaptive
    let runs = editor.adaptiveRuns
    var changed = days
    changed[0] = dayTimeline(first, titles: [("회의", 600, 660)], markers: [marker("t", on: first, minute: 700), marker("v", on: first, minute: 900)])
    editor.timelinesDidChange(changed)
    var env = environment
    env.viewportHeight = 400
    editor.updateEnvironment(env)
    #expect(editor.adaptive == held && editor.adaptiveRuns == runs)                       // nothing reshapes under the finger
    editor.exitEditMode()
    editor.completeTransition()
    #expect(editor.adaptiveRuns == runs + 1 && editor.adaptive != held)                    // and afterwards it is all taken in, once
}
