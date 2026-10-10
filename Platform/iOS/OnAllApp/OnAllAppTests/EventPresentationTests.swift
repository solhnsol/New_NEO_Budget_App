import CoreGraphics
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
import UIKit
@testable import OnAllApp

// Synthetic data only: invented titles, ids and amounts.

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let calendar = CalendarID(rawValue: "c")
private let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)
private let layoutWidth: CGFloat = 217.5                       // one of two day columns on a 375 point phone

private func event(_ index: Int, _ title: String, _ from: Int, _ to: Int) throws -> CalendarEvent {
    let range = try TimedRange(startUnixMilliseconds: zone.instant(of: day, minuteOfDay: from), endUnixMilliseconds: zone.instant(of: day, minuteOfDay: to))
    return CalendarEvent(id: CalendarEventID(rawValue: "e\(index)"), calendarID: calendar, title: title, time: .timed(range), revisionToken: "r")
}

private func spend(_ id: String, minute: Int, won: Int64 = 4_500) throws -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: minute),
        amount: try Money(minorUnits: won, currency: "KRW"), flow: .spend, title: "상점 \(id)"
    )
}

/// `link`: transaction id -> index of the event it is linked to.
private func timeline(_ events: [CalendarEvent], _ transactions: [TransactionMarker] = [], link: [String: Int] = [:]) throws -> DayTimeline {
    var changes: [LifeChange] = []
    for (id, index) in link.sorted(by: { $0.key < $1.key }) {
        let activityID = ActivityID(rawValue: "A\(index)")
        let source = try #require(events.first { $0.id.rawValue == "e\(index)" })
        if !changes.contains(where: { if case let .createActivity(activity) = $0 { return activity.id == activityID } else { return false } }) {
            changes.append(.createActivity(Activity.materialized(from: source, id: activityID, at: 1)))
        }
        let total = try #require(transactions.first { $0.id.rawValue == id }).amount
        changes.append(.upsertAllocation(
            TransactionAllocation(
                id: AllocationID(rawValue: "alloc-\(id)"), transactionID: LedgerEntryID(rawValue: id), activityID: activityID,
                amount: try AmountEntry(currency: "KRW", knowledge: .exact(total.minorUnits), provenance: provenance),
                provenance: provenance, createdAtUnixMilliseconds: 1),
            transactionTotal: total, flow: .spend))
    }
    return DayTimelineBuilder.build(DayTimelineInput(
        day: day, timeZone: zone, calendars: [CalendarDescriptor(id: calendar, title: "약속")],
        events: events, life: try LifeState.empty.applying(changes), transactions: transactions
    ))
}


private let standard = EventPresentation.Metrics.standard()

private func plan(_ tl: DayTimeline, pointsPerMinute: CGFloat, scale: CGFloat = 1, metrics: EventPresentation.Metrics? = nil) -> DayRenderPlan {
    DayRenderPlan(
        timeline: tl, role: nil, layout: nil, geometry: TimelineGeometry(totalMinutes: 1440, pointsPerMinute: pointsPerMinute), layoutWidth: layoutWidth,
        textScale: scale, metrics: metrics, titleWidth: { _ in 40 * scale }
    )
}

// MARK: Thresholds

@Test func theThresholdsComeInTheOrderTheThingsDisappear() {
    for metrics in [EventPresentation.Metrics.standard(), .standard(scale: 2), TextMeasurer.presentationMetrics(), TextMeasurer.presentationMetrics(contentSize: .accessibilityExtraExtraExtraLarge)] {
        #expect(metrics.lineHeight < metrics.cardHeight && metrics.cardHeight < metrics.titleNeed)
        #expect(metrics.titleNeed < metrics.startNeed && metrics.startNeed < metrics.endNeed)          // going down: end time, then start time, then the title
        #expect(metrics.endNeed < metrics.summaryNeed && metrics.summaryNeed < metrics.detailNeed)      // and before all of them the transactions
    }
}

@Test func thresholdsGrowWithTheRealFontsAndDynamicType() {
    let normal = TextMeasurer.presentationMetrics(contentSize: .large)
    let huge = TextMeasurer.presentationMetrics(contentSize: .accessibilityExtraExtraExtraLarge)
    #expect(huge.titleNeed > normal.titleNeed * 1.5 && huge.detailNeed > normal.detailNeed * 1.5)
    #expect(normal.titleLine >= 14 && normal.timeLine >= 10)                                                  // measured, not assumed
    #expect(EventPresentation.Metrics.standard(scale: 2).titleNeed == 2 * EventPresentation.Metrics.standard().titleNeed)
}

// MARK: Sweeping the height

@Test func sweepingTheHeightEverythingAppearsInOrderAndNothingJumps() {
    let step: CGFloat = 0.25
    var previous = EventPresentation.make(height: 0, insideCount: 5)
    var h = step
    var levelsSeen: [EventPresentation.Level] = [previous.level]
    while h <= 140 {
        let now = EventPresentation.make(height: h, insideCount: 5)
        // Growing only ever adds: every amount is monotone, so shrinking only ever removes.
        #expect(now.level >= previous.level && now.card >= previous.card && now.title >= previous.title)
        #expect(now.startTime >= previous.startTime && now.endTime >= previous.endTime && now.transactions >= previous.transactions)
        #expect(now.shownRows >= previous.shownRows)
        // The order of going: the title outlasts the start time, which outlasts the end time, which outlasts the transactions.
        #expect(now.transactions == 0 || now.endTime == 1)
        #expect(now.endTime == 0 || now.startTime == 1)
        #expect(now.startTime == 0 || now.title == 1)
        // No jumps: nothing changes by more than its ramp allows over one step (rows are whole numbers, not fades).
        let bound = step / standard.ramp + 0.0001
        #expect(now.title - previous.title <= bound && now.startTime - previous.startTime <= bound && now.endTime - previous.endTime <= bound)
        #expect(now.transactions - previous.transactions <= bound && now.card - previous.card <= step / (standard.cardHeight - standard.lineHeight) + 0.0001)
        if now.level != levelsSeen.last { levelsSeen.append(now.level) }
        previous = now
        h += step
    }
    #expect(levelsSeen == EventPresentation.Level.allCases)                                                   // E0 … E4, each in turn
}

@Test func theLevelBoundariesAreTheRealThresholds() {
    let m = standard
    func level(_ h: CGFloat) -> EventPresentation.Level { EventPresentation.make(height: h, metrics: m).level }
    #expect(level(m.lineHeight - 0.01) == .line && level(m.lineHeight) == .sliver)
    #expect(level(m.titleNeed - 0.01) == .sliver && level(m.titleNeed) == .low)
    #expect(level(m.summaryNeed - 0.01) == .low && level(m.summaryNeed) == .summary)
    #expect(level(m.detailNeed - 0.01) == .summary && level(m.detailNeed) == .detail)
    #expect(EventPresentation.Level.allCases.map(\.name) == ["E0", "E1", "E2", "E3", "E4"])
}

@Test func atEveryHeightTextOfOneKindNeverMeetsTextOfAnother() {
    let m = standard
    var h: CGFloat = 0
    while h <= 200 {
        let p = EventPresentation.make(height: h, insideCount: 5, metrics: m)
        let titleBottom = m.padding + m.titleLine                                       // the title's line, from the card's top
        let endTop = h - m.padding - m.timeLine                                          // the end time's line, from the card's bottom
        if p.showsTitle { #expect(titleBottom <= h + 0.001) }                            // the title is wholly inside the card
        if p.showsEndTime { #expect(titleBottom <= endTop + 0.001, "title meets end time at \(h)") }
        if p.showsEndTime { #expect(m.padding + m.timeLine <= endTop + 0.001) }          // the start time's line (top right) clear of the end time's
        if p.shownRows > 0 || p.showsSummaryRow {
            let rows = CGFloat(p.shownRows + (p.hiddenRows > 0 && p.shownRows > 0 ? 1 : p.showsSummaryRow ? 1 : 0))
            #expect(m.titleNeed + rows * m.rowHeight <= endTop + m.padding + 0.001, "rows meet the end time at \(h)")
        }
        h += 0.5
    }
}

@Test func whatEachHeightShowsForAnEventWithTransactions() {
    func p(_ h: CGFloat, _ n: Int = 5) -> EventPresentation { EventPresentation.make(height: h, insideCount: n, metrics: standard) }
    #expect(p(2).level == .line && !p(2).showsTitle && p(2).card == 0)                  // a line: no card at all
    #expect(p(6).level == .sliver && p(6).card > 0 && p(6).card < 1 && !p(6).showsTitle)
    #expect(p(10).card == 1 && !p(10).showsTitle)                                        // a card with no text
    #expect(p(30).showsTitle && p(30).showsStartTime && p(30).transactions == 0)
    #expect(p(44).transactionSummary > 0 && p(44).shownRows == 0)                        // a count, no rows yet
    #expect(p(140).shownRows == 2 && p(140).hiddenRows == 3 && p(140).showsEndTime)
    #expect(p(140, 1).shownRows == 1 && p(140, 1).hiddenRows == 0)
}

// MARK: Through the plan: same event at every height

@Test func oneEventAtEveryHeightIsTheSameEventAtTheSameAxisPosition() throws {
    let tl = try timeline([event(0, "회의", 600, 660)], [spend("in", minute: 620)], link: ["in": 0])
    var levels: [EventPresentation.Level] = []
    var ppm: CGFloat = 0.01
    while ppm <= 2.2 {
        let p = plan(tl, pointsPerMinute: ppm)
        let item = try #require(p.events.first)
        #expect(p.events.count == 1 && item.block.title == "회의")                    // the same Event ID throughout
        #expect(abs(item.frame.minY - 600 * ppm) < 0.001 && abs(item.frame.height - 60 * ppm) < 0.001) // exactly the axis' span, never stretched for text
        #expect(item.presentation == EventPresentation.make(height: item.frame.height, insideCount: 1, metrics: .standard()))
        #expect(p.hit(at: CGPoint(x: item.drawnFrame.midX, y: item.drawnFrame.midY)) == .event(item.block.id))      // the same touch target, line or card
        if item.presentation.showsTitle { #expect(item.showsTitleInCard || item.header != nil) }
        if levels.last != item.presentation.level { levels.append(item.presentation.level) }
        ppm += 0.01
    }
    #expect(levels == EventPresentation.Level.allCases)                                   // E0 → E4 as the room grows, and back the same way
}

@Test func theDrawnLineIsCentredOnTheTrueSpanAndNeverThinnerThanItCanBeSeen() throws {
    let p = plan(try timeline([event(0, "짧음", 600, 605)]), pointsPerMinute: 0.05)       // 0.25pt
    let item = try #require(p.events.first)
    #expect(item.frame.height < 1 && item.drawnFrame.height == DayRenderPlan.thinnestDrawn)
    #expect(abs(item.drawnFrame.midY - item.frame.midY) < 0.001)
    #expect(item.touchFrame.height >= AllocationParameters().minimumTouchHeight - 0.01)     // visual minimum and touch area are separate
}

@Test func titlesAndTimesAreHeldBackWhereTheyWouldCrossAtAnyDynamicType() throws {
    for scale in [1, 1.4, 2.2] as [CGFloat] {
        let metrics = EventPresentation.Metrics.standard(scale: scale)
        let tl = try timeline([event(0, "회의", 600, 660)], [spend("a", minute: 610), spend("b", minute: 620), spend("c", minute: 630)], link: ["a": 0, "b": 0, "c": 0])
        var ppm: CGFloat = 0.1
        while ppm <= 6 {
            let p = plan(tl, pointsPerMinute: ppm, scale: scale, metrics: metrics)
            let item = try #require(p.events.first)
            let pr = item.presentation
            if pr.showsEndTime { #expect(metrics.padding + metrics.titleLine <= item.frame.height - metrics.padding - metrics.timeLine + 0.001) }
            if pr.shownRows > 0 {
                #expect(pr.endTime == 1 && pr.title == 1)                                    // the rows only come with the title and the end time in place
                #expect(metrics.titleNeed + CGFloat(pr.shownRows) * metrics.rowHeight <= item.frame.height + 0.001)
            }
            ppm += 0.1
        }
    }
}

// MARK: Transactions

@Test func aDenseStretchKeepsEveryTransactionAndWritesOnlyWhatHasRoom() throws {
    let burst = try (0..<10).map { try spend("t\($0)", minute: 700 + $0) }
    let tl = try timeline([], burst)
    var lastWritten = 0
    var ppm: CGFloat = 0.1
    while ppm <= 26 {
        let p = plan(tl, pointsPerMinute: ppm)
        #expect(p.lines.count == 10 && p.overflows.isEmpty)                                  // nothing is dropped or regrouped by the room it has
        for line in p.lines { #expect(abs(line.frame.midY - (700 + CGFloat(Int(line.id.dropFirst()) ?? 0)) * ppm) < 0.01) }   // each at its real time
        let written = p.lines.filter { $0.reveal > 0.999 }.sorted { $0.frame.midY < $1.frame.midY }
        for (a, b) in zip(written, written.dropFirst()) { #expect(b.frame.midY - a.frame.midY >= 16 + 2 - 0.01, "written rows meet at \(ppm)") }
        #expect(written.count >= lastWritten)                                                 // more room never writes fewer
        lastWritten = written.count
        ppm += 0.25
    }
    #expect(lastWritten == 10)                                                                // with room, all ten are written
}

@Test func aHiddenRowStillHasItsDotAndItsTouchArea() throws {
    let tl = try timeline([], [spend("a", minute: 700), spend("b", minute: 700)])
    let p = plan(tl, pointsPerMinute: 1.2)
    let hidden = try #require(p.lines.first { $0.reveal == 0 })
    #expect(hidden.touchFrame.height >= AllocationParameters().minimumTouchHeight - 0.01)
    if case .nothing = p.hit(at: CGPoint(x: hidden.touchFrame.midX, y: hidden.touchFrame.midY)) { Issue.record("a transaction whose text waits cannot be touched") }
}

@Test func theRevealComesInAsTheRoomAppears() throws {
    let tl = try timeline([], [spend("a", minute: 700), spend("b", minute: 701)])
    var last: CGFloat = 0
    var sawPartial = false
    var ppm: CGFloat = 0.1
    while ppm <= 40 {
        let b = try #require(plan(tl, pointsPerMinute: ppm).lines.first { $0.id == "b" })
        #expect(b.reveal >= last - 0.0001)
        sawPartial = sawPartial || (b.reveal > 0 && b.reveal < 1)
        last = b.reveal
        ppm += 0.2
    }
    #expect(last == 1 && sawPartial)
}

@Test func aTitleAndATransactionNeverPrintOnEachOther() throws {
    // The title is on the row of an independent transaction: the row keeps to the right part, or its text waits; never the two together.
    for minute in 600...606 {
        let tl = try timeline([event(0, "아주 긴 일정 제목입니다", 600, 720)], [spend("t", minute: minute)])
        let p = DayRenderPlan(timeline: tl, role: nil, layout: nil, geometry: TimelineGeometry(totalMinutes: 1440, pointsPerMinute: 1.2), layoutWidth: layoutWidth, titleWidth: { _ in 150 })
        let item = try #require(p.events.first), line = try #require(p.lines.first)
        let title = CGRect(x: item.frame.minX + 6, y: item.frame.minY, width: 150, height: 19)
        if line.reveal > 0 { #expect(!title.intersects(line.frame.insetBy(dx: 0, dy: 4))) }
    }
}
