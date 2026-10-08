import CoreGraphics
import NEOBudgetCalendar

/// What a gesture means, computed without any UI or provider: the preview the user sees while dragging and the
/// command sent once on release. Both come from `TimelineEditPolicy`, so the preview is exactly what is committed.
struct TimelineEditPlanner {
    let policy: TimelineEditPolicy
    let zone: DisplayTimeZone
    let geometry: TimelineGeometry
    let day: LocalDate
    let dayStartUnixMilliseconds: Int64
    let dayEndUnixMilliseconds: Int64

    init(policy: TimelineEditPolicy, zone: DisplayTimeZone, geometry: TimelineGeometry, timeline: DayTimeline) {
        self.policy = policy
        self.zone = zone
        self.geometry = geometry
        day = timeline.day
        dayStartUnixMilliseconds = timeline.dayStartUnixMilliseconds
        dayEndUnixMilliseconds = timeline.dayEndUnixMilliseconds
    }

    enum Kind: Equatable {
        case move
        case resizeStart
        case resizeEnd
        case create
    }

    // MARK: Previews

    func range(of block: EventBlock) -> TimedRange? {
        try? TimedRange(startUnixMilliseconds: block.startUnixMilliseconds, endUnixMilliseconds: block.endUnixMilliseconds)
    }

    private func milliseconds(forTranslation translationY: CGFloat) -> Int64 {
        Int64((translationY / geometry.pointsPerMinute).rounded()) * 60_000
    }

    func preview(_ kind: Kind, block: EventBlock, translationY: CGFloat) -> TimedEdit? {
        guard let original = range(of: block) else { return nil }
        let delta = milliseconds(forTranslation: translationY)
        switch kind {
        case .move:
            return TimedEdit(range: policy.move(original, toProposedStart: original.startUnixMilliseconds + delta, in: zone), wasClamped: false)
        case .resizeStart:
            return policy.resizeStart(original, toProposedStart: original.startUnixMilliseconds + delta, in: zone)
        case .resizeEnd:
            return policy.resizeEnd(original, toProposedEnd: original.endUnixMilliseconds + delta, in: zone, clampingToDayEnd: dayEndUnixMilliseconds)
        case .create:
            return nil
        }
    }

    /// A drag across empty space between two vertical positions in the grid.
    func createPreview(fromY: CGFloat, toY: CGFloat) -> TimedEdit {
        let first = dayStartUnixMilliseconds + Int64(geometry.minute(atY: fromY)) * 60_000
        let second = dayStartUnixMilliseconds + Int64(geometry.minute(atY: toY)) * 60_000
        return policy.create(dragFrom: first, to: second, in: zone, keepingInside: day)
    }

    // MARK: Commit

    /// Whether the change moves the event to another local day. A series cannot take a date change.
    func changesDate(of block: EventBlock, to range: TimedRange) -> Bool {
        zone.localDate(of: block.startUnixMilliseconds) != zone.localDate(of: range.startUnixMilliseconds)
    }

    /// The scopes the user may choose from for a recurring event. `thisAndFuture` is never offered: it re-identifies
    /// the future occurrences, which the calendar boundary cannot keep stable.
    func scopeOptions(for block: EventBlock, newRange: TimedRange, supported: Set<RecurrenceScope>) -> [RecurrenceScope] {
        var options: [RecurrenceScope] = []
        if supported.contains(.thisOccurrence) { options.append(.thisOccurrence) }
        if supported.contains(.allInSeries), !changesDate(of: block, to: newRange) { options.append(.allInSeries) }
        return options
    }

    func command(_ kind: Kind, block: EventBlock, newRange: TimedRange, scope: RecurrenceScope?) -> CalendarCommand? {
        let target = EventTarget(key: block.eventKey, expectedRevisionToken: block.revisionToken)
        switch kind {
        case .move:
            return .moveEvent(MoveEventInput(target: target, destination: .proposedStart(newRange.startUnixMilliseconds), scope: scope))
        case .resizeStart:
            return .resizeEvent(ResizeEventInput(target: target, edge: .start, proposedInstant: newRange.startUnixMilliseconds, scope: scope))
        case .resizeEnd:
            return .resizeEvent(ResizeEventInput(
                target: target, edge: .end, proposedInstant: newRange.endUnixMilliseconds,
                clampToDayEnd: dayEndUnixMilliseconds, scope: scope
            ))
        case .create:
            return nil
        }
    }

    func createCommand(title: String, calendarID: CalendarID, range: TimedRange) -> CalendarCommand {
        .createEvent(CreateEventInput(draft: CalendarEventDraft(
            calendarID: calendarID, title: title, time: .timed(range), timeZoneIdentifier: zone.identifier
        )))
    }

    // MARK: Drawing

    /// The frame of a previewed range inside the grid, kept inside the selected day. `column`/`columns` come from the
    /// block being edited so a preview stays in its column; a new event uses the whole width.
    func previewFrame(_ range: TimedRange, column: Int, columns: Int, totalWidth: CGFloat) -> CGRect {
        let first = max(0, Int((range.startUnixMilliseconds - dayStartUnixMilliseconds) / 60_000))
        let last = min(geometry.totalMinutes, Int((range.endUnixMilliseconds - dayStartUnixMilliseconds + 59_999) / 60_000))
        let available = max(0, totalWidth - geometry.gutterWidth - geometry.markerRailWidth)
        let count = CGFloat(max(1, columns))
        let columnWidth = available / count
        return CGRect(
            x: geometry.gutterWidth + columnWidth * CGFloat(column),
            y: geometry.y(minute: first),
            width: max(0, columnWidth - geometry.columnSpacing),
            height: max(geometry.y(minute: policy.minimumDurationMinutes), geometry.y(minute: last) - geometry.y(minute: first) - 1)
        )
    }
}
