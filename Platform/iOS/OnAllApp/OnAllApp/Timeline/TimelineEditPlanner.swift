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

    /// The minute an edge ends up at when it starts at `minute` and the finger moves `translationY` points. Goes through
    /// the axis, so it is exact where the axis is enlarged and coarse inside a folded stretch.
    private func minute(movedFrom minute: Int, by translationY: CGFloat) -> Int {
        geometry.minute(atY: geometry.y(minute: minute) + translationY)
    }

    func preview(_ kind: Kind, block: EventBlock, translationY: CGFloat) -> TimedEdit? {
        guard let original = range(of: block) else { return nil }
        switch kind {
        case .move:
            let delta = Int64(minute(movedFrom: block.startMinute, by: translationY) - block.startMinute) * 60_000
            return TimedEdit(range: policy.move(original, toProposedStart: original.startUnixMilliseconds + delta, in: zone), wasClamped: false)
        case .resizeStart:
            let delta = Int64(minute(movedFrom: block.startMinute, by: translationY) - block.startMinute) * 60_000
            return policy.resizeStart(original, toProposedStart: original.startUnixMilliseconds + delta, in: zone)
        case .resizeEnd:
            let delta = Int64(minute(movedFrom: block.endMinute, by: translationY) - block.endMinute) * 60_000
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

/// Where a touch landed on the event being edited. The handles are dots outside the corners, like the system calendar,
/// so even a 15 minute event has something to grab. Pure geometry: it knows nothing about the axis or the scroll view.
///
/// Dragging is for handles only. The body is a target for a long press (to move the event), never for a plain drag, which
/// belongs to the scroll view.
enum EditHit: Equatable {
    case body
    case resizeStart
    case resizeEnd

    /// A handle's touch target is a circle this big, which is also Apple's minimum comfortable size.
    static let handleRadius: CGFloat = 22
    static let minimumTouchSide: CGFloat = handleRadius * 2
    /// Distance of the handle dots from the block's corners, inward along the edge.
    static let handleInset: CGFloat = 28

    static func startHandle(of frame: CGRect) -> CGPoint { CGPoint(x: frame.maxX - handleInset, y: frame.minY) }
    static func endHandle(of frame: CGRect) -> CGPoint { CGPoint(x: frame.minX + handleInset, y: frame.maxY) }

    /// The square an assistive technology activates for a handle.
    static func touchFrame(around center: CGPoint) -> CGRect {
        CGRect(x: center.x - handleRadius, y: center.y - handleRadius, width: minimumTouchSide, height: minimumTouchSide)
    }

    /// The handle under a point, or `nil`. Where the two circles overlap (a very short event) the nearer centre wins.
    static func handle(at point: CGPoint, frame: CGRect, canResizeStart: Bool, canResizeEnd: Bool) -> EditHit? {
        var best: (hit: EditHit, distance: CGFloat)?
        for (hit, center, enabled) in [
            (EditHit.resizeStart, startHandle(of: frame), canResizeStart),
            (EditHit.resizeEnd, endHandle(of: frame), canResizeEnd),
        ] where enabled {
            let distance = hypot(point.x - center.x, point.y - center.y)
            if distance <= handleRadius, distance < (best?.distance ?? .infinity) { best = (hit, distance) }
        }
        return best?.hit
    }

    /// `nil` when the touch is not on the block or either handle. A handle wins over the body where they overlap.
    static func hit(_ point: CGPoint, frame: CGRect, canResizeStart: Bool, canResizeEnd: Bool) -> EditHit? {
        handle(at: point, frame: frame, canResizeStart: canResizeStart, canResizeEnd: canResizeEnd)
            ?? (frame.contains(point) ? .body : nil)
    }
}

/// What a touch landed on, in the grid. Classification is the view's job (it knows the frames); what each gesture then
/// means is decided here, so the whole gesture table can be tested without a screen.
enum TimelineTouchTarget: Equatable {
    case handle(EditHit)
    /// The event being edited (not its handles).
    case selectedEvent
    /// Any other event.
    case otherEvent
    case emptyTime
}

/// The gesture table. In edit mode and out of it:
///
/// | gesture | on | result |
/// |---|---|---|
/// | tap | an event | open it in place |
/// | tap | empty time | leave edit mode |
/// | first long press | an event | enter edit mode (nothing moves) |
/// | plain drag | anywhere | scroll |
/// | drag | a handle | change that edge |
/// | second long press, then drag | the selected event | move it |
/// | long press | empty time | start a new event |
enum TimelineGestureRouter {
    enum LongPress: Equatable {
        case enterEditMode
        case pickUp
        case startNewEvent
        case ignore
    }

    static func longPress(on target: TimelineTouchTarget, isEditing: Bool) -> LongPress {
        switch target {
        case .handle: return .ignore                                  // a handle's own drag does the work
        case .selectedEvent: return isEditing ? .pickUp : .enterEditMode
        case .otherEvent: return .enterEditMode                       // switches the event being edited
        case .emptyTime: return .startNewEvent
        }
    }

    /// Whether the edit pan (as opposed to scrolling) takes a touch that begins on `target`. Only a handle does: the body of
    /// an event, other events and empty time always scroll.
    static func panBegins(on target: TimelineTouchTarget, isEditing: Bool) -> Bool {
        guard isEditing, case .handle = target else { return false }
        return true
    }

    /// Whether a tap on `target` ends edit mode.
    static func tapEndsEditing(on target: TimelineTouchTarget) -> Bool { target == .emptyTime }
}
