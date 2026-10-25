import Foundation
import Testing
import NEOBudgetCalendar

private let date = day(2026, 10, 7)

private func draft(_ start: Int64, _ end: Int64, revision: String? = "r0", recurring: Bool = false, zone: DisplayTimeZone = seoul) throws -> EditDraft {
    try EditDraft(event: event("e1", calendar: "life", title: "회의", from: start, to: end, recurring: recurring, revision: revision), timeZone: zone)
}

private func snapshot(_ start: Int64, _ end: Int64, title: String = "회의", revision: String? = "r0", editable: Bool = true) -> EditDraft.Snapshot {
    EditDraft.Snapshot(event("e1", calendar: "life", title: title, from: start, to: end, editable: editable, revision: revision))
}

private func timeline(_ events: [CalendarEvent], on day: LocalDate = date) -> DayTimeline {
    DayTimelineBuilder.build(DayTimelineInput(day: day, timeZone: seoul, calendars: defaultCalendars, events: events, life: .empty, transactions: []))
}

// MARK: Starting

@Test func aDraftKeepsTheEventsAbsoluteRangeIdentityAndRevision() throws {
    let start = at(date, 10, 7) + 30_000   // off-grid, with seconds
    let end = at(date, 11, 50)
    let source = event("e1", calendar: "school", title: "세미나", from: start, to: end, recurring: true, revision: "rev-42")
    let d = try EditDraft(event: source, timeZone: seoul, generation: 3)

    #expect(d.range == timed(start, end))
    #expect(d.originalRange == timed(start, end))
    #expect(d.startDate == Date(timeIntervalSince1970: Double(start) / 1_000))
    #expect(d.endDate == Date(timeIntervalSince1970: Double(end) / 1_000))
    #expect(d.key == source.key && d.eventID == eventID("e1") && d.calendarID == calendarID("school"))
    #expect(d.originalRevisionToken == "rev-42")
    #expect(d.original.isRecurringInstance && d.original.title == "세미나")
    #expect(d.extent == .singleDay(date))
    #expect(d.days == [date])
    #expect(d.generation == 3)
    #expect(d.conflict == .none)
    #expect(!d.isChanged && d.update == nil && d.editEventInput() == nil)
}

@Test func aDraftFromATimelineBlockUsesTheRealRangeNotTheClippedMinutes() throws {
    let source = event("e1", from: at(date, 9, 0), to: at(date, 9, 40), revision: "r7")
    let block = try #require(timeline([source]).blocks.first)
    let d = try EditDraft(block: block, timeZone: seoul)
    #expect(d.range == timed(at(date, 9, 0), at(date, 9, 40)))
    #expect(d.original == EditDraft.Snapshot(source))
    #expect(d.key == source.key && d.originalRevisionToken == "r7")
}

@Test func draftsAreRefusedForAllDayReadOnlyMissingAndMultiDayEvents() throws {
    #expect(throws: EditDraftError.allDay) { try EditDraft(event: allDayEvent("a", from: date, to: date), timeZone: seoul) }
    #expect(throws: EditDraftError.readOnly) {
        try EditDraft(event: event("r", from: at(date, 9), to: at(date, 10), editable: false), timeZone: seoul)
    }
    #expect(throws: EditDraftError.spansDays) {
        try EditDraft(event: event("m", from: at(date, 23), to: at(date.adding(days: 1), 1)), timeZone: seoul)
    }
    // Ending exactly at the next midnight is still one day.
    let late = try draft(at(date, 23), seoul.dayBounds(date).end)
    #expect(late.extent == .singleDay(date) && late.days == [date])
}

// MARK: Steps

@Test func movingTheWholeEventKeepsItsLengthSnapsAndCanChangeTheDay() throws {
    var d = try draft(at(date, 10, 0), at(date, 11, 30))
    let moved1 = d.move(toDay: date, startMinute: 14 * 60 + 7); #expect(moved1)
    #expect(d.range == timed(at(date, 14, 0), at(date, 15, 30)))
    let next = date.adding(days: 1)
    let moved2 = d.move(toDay: next, startMinute: 23 * 60 + 45); #expect(moved2)
    #expect(d.range == timed(at(next, 22, 30), at(next.adding(days: 1), 0, 0)))
    #expect(d.extent == .singleDay(next) && d.days == [next] && d.isValid)
    let moved3 = d.move(toDay: next, startMinute: 23 * 60 + 45); #expect(!moved3)
    let moved4 = d.move(toDay: date, startMinute: -30); #expect(moved4)
    #expect(d.range == timed(at(date, 0, 0), at(date, 1, 30)))
}

@Test func stepsMoveOneEdgeByFifteenMinutes() throws {
    var d = try draft(at(date, 10, 0), at(date, 11, 0))
    try d.stepStart(by: -1)
    #expect(d.range == timed(at(date, 9, 45), at(date, 11, 0)))
    try d.stepEnd(by: 2)
    #expect(d.range == timed(at(date, 9, 45), at(date, 11, 30)))
    try d.stepStart(by: 3)
    #expect(d.range == timed(at(date, 10, 30), at(date, 11, 30)))
    try d.stepEnd(by: -1)
    #expect(d.range == timed(at(date, 10, 30), at(date, 11, 15)))
    try d.stepStart(by: 0)
    #expect(d.range == timed(at(date, 10, 30), at(date, 11, 15)))
    #expect(EditDraft.stepMinutes == 15 && EditDraft.minimumDurationMinutes == 15)
}

@Test func anOffGridEdgeLandsOnTheNextGridLineInTheStepsDirection() throws {
    var up = try draft(at(date, 10, 7) + 30_000, at(date, 11, 50))
    try up.stepStart(by: 1)
    #expect(up.range.startUnixMilliseconds == at(date, 10, 15))
    try up.stepStart(by: 1)
    #expect(up.range.startUnixMilliseconds == at(date, 10, 30))

    var down = try draft(at(date, 10, 7), at(date, 11, 50))
    try down.stepStart(by: -1)
    #expect(down.range.startUnixMilliseconds == at(date, 10, 0))
    try down.stepEnd(by: -2)
    #expect(down.range.endUnixMilliseconds == at(date, 11, 30))

    var twoAtOnce = try draft(at(date, 10, 7), at(date, 11, 50))
    try twoAtOnce.stepStart(by: -2)
    #expect(twoAtOnce.range.startUnixMilliseconds == at(date, 9, 45))
}

@Test func aStepThatWouldBreakTheRangeIsRefusedAndChangesNothing() throws {
    var d = try draft(at(date, 10, 0), at(date, 10, 30))
    let before = d
    #expect(throws: EditDraftError.startNotBeforeEnd) { try d.stepStart(by: 2) }       // 10:30–10:30
    #expect(throws: EditDraftError.startNotBeforeEnd) { try d.stepEnd(by: -3) }        // 10:00–09:45
    #expect(d == before)
    try d.stepStart(by: 1)                                                             // 10:15–10:30, exactly the minimum
    #expect(d.range == timed(at(date, 10, 15), at(date, 10, 30)) && d.isValid)
    #expect(throws: EditDraftError.startNotBeforeEnd) { try d.stepStart(by: 1) }
    #expect(d.range == timed(at(date, 10, 15), at(date, 10, 30)))

    // Off the grid a step can leave less than the minimum.
    var odd = try draft(at(date, 10, 0), at(date, 10, 20))
    let oddBefore = odd
    #expect(throws: EditDraftError.shorterThanMinimum) { try odd.stepStart(by: 1) }    // 10:15–10:20
    #expect(odd == oddBefore)
}

@Test func theRangeCannotLeaveItsDay() throws {
    var early = try draft(at(date, 0, 0), at(date, 1, 0))
    #expect(throws: EditDraftError.leavesDay(date)) { try early.stepStart(by: -1) }
    #expect(early.range == timed(at(date, 0, 0), at(date, 1, 0)))

    var late = try draft(at(date, 23, 0), at(date, 23, 45))
    try late.stepEnd(by: 1)                                                            // to midnight: allowed
    #expect(late.range.endUnixMilliseconds == seoul.dayBounds(date).end)
    #expect(throws: EditDraftError.leavesDay(date)) { try late.stepEnd(by: 1) }
    #expect(late.range.endUnixMilliseconds == seoul.dayBounds(date).end)

    var exact = try draft(at(date, 9), at(date, 10))
    #expect(throws: EditDraftError.leavesDay(date)) { try exact.setRange(timed(at(date, 23), at(date.adding(days: 1), 0, 30))) }
    try exact.setRange(timed(at(date, 13, 5), at(date, 14, 20)))                      // exact; no snapping
    #expect(exact.range == timed(at(date, 13, 5), at(date, 14, 20)))
}

@Test func validationReportsTheFirstProblemInAFixedOrder() throws {
    let d = try draft(at(date, 10), at(date, 11))
    #expect(d.issue(start: at(date, 11), end: at(date, 10)) == .startNotBeforeEnd)
    #expect(d.issue(start: at(date, 10), end: at(date, 10)) == .startNotBeforeEnd)
    #expect(d.issue(start: at(date.adding(days: -1), 23, 55), end: at(date, 0, 5)) == .leavesDay(date))
    #expect(d.issue(start: at(date, 10), end: at(date, 10, 10)) == .shorterThanMinimum)
    #expect(d.issue(start: at(date, 10), end: at(date, 10, 15)) == nil)

    // A short original is kept as it is, but it is not a range an edit may produce.
    var short = try draft(at(date, 10), at(date, 10, 10))
    #expect(short.validationIssue == .shorterThanMinimum && !short.isChanged && short.update == nil)
    try short.stepEnd(by: 1)                                                           // 10:10 → 10:15
    #expect(short.range == timed(at(date, 10), at(date, 10, 15)) && short.isValid)
}

@Test func stepsFollowTheWallClockGridOnDaylightSavingDays() throws {
    let spring = day(2026, 3, 8)                                                      // New York: 02:00 → 03:00
    var d = try draft(at(spring, 1, 30, in: newYork), at(spring, 4, 0, in: newYork), zone: newYork)
    try d.stepStart(by: 2)
    #expect(d.range.startUnixMilliseconds == at(spring, 3, 0, in: newYork))
    #expect(newYork.minuteOfDay(of: d.range.startUnixMilliseconds) == 180)
    var fall = try draft(at(day(2026, 11, 1), 23, 0, in: newYork), newYork.dayBounds(day(2026, 11, 1)).end, zone: newYork)
    #expect(throws: EditDraftError.leavesDay(day(2026, 11, 1))) { try fall.stepEnd(by: 1) }
}

// MARK: Cancel and comparison

@Test func revertingRestoresTheOriginalAndTheOriginalNeverChanges() throws {
    var d = try draft(at(date, 10), at(date, 11), revision: "r5")
    let original = d.original
    try d.stepStart(by: -2)
    try d.stepEnd(by: 4)
    try d.setRange(timed(at(date, 14), at(date, 15, 30)))
    #expect(d.original == original && d.originalRange == timed(at(date, 10), at(date, 11)))
    #expect(d.originalRevisionToken == "r5" && d.key == key("life", "e1"))
    d.revert()
    #expect(d.range == d.originalRange && !d.isChanged && d.update == nil)
    #expect(d.original == original)
}

@Test func theComparisonShowsBothRangesAndTheirDifferences() throws {
    var d = try draft(at(date, 10), at(date, 11))
    #expect(d.comparison == EditDraft.Comparison(before: timed(at(date, 10), at(date, 11)), after: timed(at(date, 10), at(date, 11))))
    #expect(!d.comparison.isChanged)

    try d.stepStart(by: -1)
    try d.stepEnd(by: 2)
    let c = d.comparison
    #expect(c.before == timed(at(date, 10), at(date, 11)))
    #expect(c.after == timed(at(date, 9, 45), at(date, 11, 30)))
    #expect(c.startDeltaMilliseconds == -15 * 60_000 && c.endDeltaMilliseconds == 30 * 60_000)
    #expect(c.durationDeltaMilliseconds == 45 * 60_000)
    #expect(c.startChanged && c.endChanged && c.isChanged)

    try d.stepStart(by: 1)
    #expect(!d.comparison.startChanged && d.comparison.endChanged)
}

@Test func aSaveTargetsTheOriginalKeyAndRevisionWithOnlyTheNewTime() throws {
    var d = try draft(at(date, 10), at(date, 11), revision: "r9", recurring: true)
    try d.stepEnd(by: 1)
    #expect(d.target == EventTarget(key: key("life", "e1"), expectedRevisionToken: "r9"))
    #expect(d.update == CalendarEventUpdate(time: .timed(timed(at(date, 10), at(date, 11, 15)))))
    let input = try #require(d.editEventInput(scope: .thisOccurrence))
    #expect(input == EditEventInput(target: d.target, update: CalendarEventUpdate(time: .timed(d.range)), scope: .thisOccurrence))
    // Title, notes, location, zone: left alone.
    #expect(input.update.title == nil && input.update.location.isKeep && input.update.notes.isKeep && input.update.timeZoneIdentifier.isKeep)
}

// MARK: Conflicts

@Test func theSameEventSeenAgainIsNoConflict() throws {
    let d = try draft(at(date, 10), at(date, 11))
    #expect(d.conflict(with: .present(snapshot(at(date, 10), at(date, 11)))) == .none)
    #expect(d.conflict(with: EditDraft.Observation(providerEvent: event("e1", title: "회의", from: at(date, 10), to: at(date, 11)))) == .none)
}

@Test func changesToTheOriginalAreNamedByField() throws {
    let d = try draft(at(date, 10), at(date, 11))
    let moved = snapshot(at(date, 12), at(date, 13), revision: "r1")
    #expect(d.conflict(with: .present(moved)) == .changed(current: moved, fields: [.time, .revision]))
    let renamed = snapshot(at(date, 10), at(date, 11), title: "회의 (변경)", revision: "r1")
    #expect(d.conflict(with: .present(renamed)) == .changed(current: renamed, fields: [.title, .revision]))
    let locked = snapshot(at(date, 10), at(date, 11), revision: "r1", editable: false)
    #expect(d.conflict(with: .present(locked)) == .changed(current: locked, fields: [.editability, .revision]))
    // Something the domain does not model (an alarm, an attendee) moved only the token.
    let tokenOnly = snapshot(at(date, 10), at(date, 11), revision: "r1")
    #expect(d.conflict(with: .present(tokenOnly)) == .changed(current: tokenOnly, fields: [.revision]))
    #expect(d.conflict(with: .present(tokenOnly)).blocksSave)
}

@Test func withoutRevisionTokensTheFieldsDecide() throws {
    let d = try draft(at(date, 10), at(date, 11), revision: nil)
    #expect(d.conflict(with: .present(snapshot(at(date, 10), at(date, 11), revision: nil))) == .none)
    #expect(d.conflict(with: .present(snapshot(at(date, 10), at(date, 11), revision: "new"))) == .none)
    let moved = snapshot(at(date, 10, 30), at(date, 11), revision: nil)
    #expect(d.conflict(with: .present(moved)) == .changed(current: moved, fields: [.time]))
}

@Test func deletionAndUnknownStateAreConflicts() throws {
    let d = try draft(at(date, 10), at(date, 11))
    #expect(d.conflict(with: EditDraft.Observation(providerEvent: nil)) == .deleted)
    #expect(d.conflict(with: .deleted).blocksSave)
    #expect(d.conflict(with: .unavailable) == .unverified)
    #expect(d.conflict(with: .unavailable).blocksSave)
    // A snapshot of another event (or the same event ID in another calendar) proves nothing.
    let other = EditDraft.Snapshot(event("e1", calendar: "school", title: "회의", from: at(date, 10), to: at(date, 11)))
    #expect(d.conflict(with: .present(other)) == .unverified)
    #expect(!EditDraft.Conflict.none.blocksSave)
}

@Test func timelineLookupFindsTheEventOrSaysItIsUnknownNeverDeleted() throws {
    let source = event("e1", title: "회의", from: at(date, 10), to: at(date, 11))
    let d = try EditDraft(event: source, timeZone: seoul)
    let other = timeline([event("x", from: at(date, 9), to: at(date, 10))])
    let found = EditDraft.Observation.lookup(d.key, in: [other, timeline([source])])
    #expect(found == .present(EditDraft.Snapshot(source)))
    #expect(d.conflict(with: found) == .none)
    // Gone from the day that was read: it may have moved to a day not read, so this is not a deletion.
    #expect(EditDraft.Observation.lookup(d.key, in: [other]) == .unavailable)
    #expect(EditDraft.Observation.lookup(d.key, in: []) == .unavailable)
}

@Test func aGhostBlockCannotStartADraftAndReadsAsDeleted() throws {
    let gone = event("e1", title: "회의", from: at(date, 10), to: at(date, 11))
    let missing = CalendarEventAssociation(event: gone).markedMissing(at: 5)
    let life = try LifeState.empty.applying([
        .createActivity(Activity.materialized(from: gone, id: ActivityID(rawValue: "a1"), at: 1)),
        .updateAssociation(ActivityID(rawValue: "a1"), missing)
    ])
    let ghosts = DayTimelineBuilder.build(DayTimelineInput(day: date, timeZone: seoul, calendars: defaultCalendars, events: [], life: life, transactions: []))
    let ghost = try #require(ghosts.blocks.first)
    #expect(ghost.state == .eventMissing)
    #expect(throws: EditDraftError.eventMissing) { try EditDraft(block: ghost, timeZone: seoul) }

    let d = try EditDraft(event: gone, timeZone: seoul)
    #expect(EditDraft.Observation.lookup(d.key, in: [ghosts]) == .deleted)
}

@Test func aReloadMakesACleanDraftUnverifiedUntilTheEventIsSeenAgain() throws {
    var d = try EditDraft(event: event("e1", title: "회의", from: at(date, 10), to: at(date, 11)), timeZone: seoul, generation: 1)
    d.observe(.present(snapshot(at(date, 10), at(date, 11))), readGeneration: 1)
    #expect(d.conflict == .none)

    d.noteReload(generation: 2)
    #expect(d.conflict == .unverified && d.generation == 2)
    // A read that started before the reload lands late: ignored.
    d.observe(.present(snapshot(at(date, 10), at(date, 11))), readGeneration: 1)
    #expect(d.conflict == .unverified)
    // Read again after the reload, unchanged: clean.
    d.observe(.present(snapshot(at(date, 10), at(date, 11))), readGeneration: 2)
    #expect(d.conflict == .none)
    // An old reload notice changes nothing.
    d.noteReload(generation: 2)
    d.noteReload(generation: 1)
    #expect(d.conflict == .none && d.generation == 2)
}

@Test func aReloadThatChangedOrDeletedTheEventIsKeptUntilSeenAgain() throws {
    var d = try draft(at(date, 10), at(date, 11))
    try d.stepEnd(by: 1)
    let moved = snapshot(at(date, 14), at(date, 15), revision: "r1")
    d.observe(.present(moved), readGeneration: 1)                                      // a newer read counts as the reload
    #expect(d.conflict == .changed(current: moved, fields: [.time, .revision]) && d.generation == 1)
    d.noteReload(generation: 2)
    #expect(d.conflict == .changed(current: moved, fields: [.time, .revision]))      // still known to be changed
    d.observe(.deleted, readGeneration: 2)
    #expect(d.conflict == .deleted)
    d.noteReload(generation: 3)
    #expect(d.conflict == .deleted)
    d.observe(.unavailable, readGeneration: 3)
    #expect(d.conflict == .unverified)
    // The edit and the original are untouched by any of this.
    #expect(d.range == timed(at(date, 10), at(date, 11, 15)) && d.originalRange == timed(at(date, 10), at(date, 11)))
    #expect(d.originalRevisionToken == "r0" && d.target.expectedRevisionToken == "r0")
}

@Test func revertKeepsTheConflict() throws {
    var d = try draft(at(date, 10), at(date, 11))
    try d.stepStart(by: 1)
    d.observe(.deleted, readGeneration: 0)
    d.revert()
    #expect(d.conflict == .deleted && !d.isChanged)
}

// MARK: Projection (ready for more than one day)

@Test func aSegmentProjectsTheRangeOntoOneDayLikeATimelineBlock() throws {
    var d = try draft(at(date, 10, 7) + 30_000, at(date, 11, 50))
    let segment = try #require(d.segment(on: date))
    let block = try #require(timeline([event("e1", from: at(date, 10, 7) + 30_000, to: at(date, 11, 50))]).blocks.first)
    #expect(segment.startMinute == block.startMinute && segment.endMinute == block.endMinute)
    #expect(segment.range == d.range && !segment.continuesFromPreviousDay && !segment.continuesToNextDay)
    #expect(d.segment(on: date.adding(days: 1)) == nil && d.segment(on: date.adding(days: -1)) == nil)
    try d.stepStart(by: -1)
    #expect(d.segment(on: date)?.startMinute == 600)
}

// MARK: Dragging an edge

@Test func draggingAnEdgeSnapsToTheNearestGridLineAndKeepsTheOtherEdge() throws {
    var d = try draft(at(date, 10, 0), at(date, 11, 0))
    do { let moved = d.drag(.start, to: at(date, 9, 37)); #expect(moved) }
    #expect(d.range == timed(at(date, 9, 30), at(date, 11, 0)))
    do { let moved = d.drag(.end, to: at(date, 11, 53)); #expect(moved) }
    #expect(d.range == timed(at(date, 9, 30), at(date, 12, 0)))
    // Within half a step of where it is: nothing moves.
    do { let moved = d.drag(.end, to: at(date, 12, 7)); #expect(!moved) }
    #expect(d.range == timed(at(date, 9, 30), at(date, 12, 0)))
    // Halfway goes later.
    do { let moved = d.drag(.end, to: at(date, 12, 7) + 30_000); #expect(moved) }
    #expect(d.range.endUnixMilliseconds == at(date, 12, 15))
}

@Test func draggingAnEdgePastALimitHoldsItAtTheLimit() throws {
    var d = try draft(at(date, 10, 0), at(date, 11, 0))
    // Past the other edge: the minimum length stays.
    do { let moved = d.drag(.start, to: at(date, 13, 0)); #expect(moved) }
    #expect(d.range == timed(at(date, 10, 45), at(date, 11, 0)))
    do { let moved = d.drag(.end, to: at(date, 8, 0)); #expect(!moved) }
    #expect(d.range == timed(at(date, 10, 45), at(date, 11, 0)))
    // Past the day: midnight either side.
    let bounds = seoul.dayBounds(date)
    do { let moved = d.drag(.start, to: bounds.start - 3 * 3_600_000); #expect(moved) }
    #expect(d.range.startUnixMilliseconds == bounds.start)
    do { let moved = d.drag(.end, to: bounds.end + 3 * 3_600_000); #expect(moved) }
    #expect(d.range.endUnixMilliseconds == bounds.end)
    #expect(d.isValid)
}

@Test func aShortOriginalGrowsToTheMinimumWhenDragged() throws {
    // 10 minutes long: a start dragged later than allowed lands 15 minutes before the end; the end grows to the minimum.
    var d = try draft(at(date, 10, 0), at(date, 10, 10))
    do { let moved = d.drag(.start, to: at(date, 10, 5)); #expect(moved) }
    #expect(d.range == timed(at(date, 9, 55), at(date, 10, 10)) && d.isValid)
    // At the very start of the day the start has nowhere allowed to go.
    let bounds = seoul.dayBounds(date)
    var f = try draft(bounds.start, bounds.start + 600_000)
    do { let moved = f.drag(.start, to: bounds.start + 3_600_000); #expect(!moved) }
    var e = try draft(at(date, 10, 0), at(date, 10, 10))
    do { let moved = e.drag(.end, to: at(date, 10, 12)); #expect(moved) }
    #expect(e.range == timed(at(date, 10, 0), at(date, 10, 15)))
}

@Test func canStepSaysWhetherAStepWouldBeTaken() throws {
    let d = try draft(at(date, 10, 0), at(date, 10, 15))
    #expect(d.canStep(.start, by: -1) && !d.canStep(.start, by: 1))
    #expect(d.canStep(.end, by: 1) && !d.canStep(.end, by: -1))
    let bounds = seoul.dayBounds(date)
    let edge = try draft(bounds.start, bounds.end)
    #expect(!edge.canStep(.start, by: -1) && !edge.canStep(.end, by: 1))
    #expect(edge.canStep(.start, by: 1) && edge.canStep(.end, by: -1))
}
