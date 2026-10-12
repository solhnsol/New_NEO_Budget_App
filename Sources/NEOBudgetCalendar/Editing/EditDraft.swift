import Foundation

/// Why a draft could not be started, or why a range was refused. A refused change leaves the draft as it was.
public enum EditDraftError: Error, Hashable, Sendable {
    // Starting a draft
    /// All-day events are not edited by a draft.
    case allDay
    /// The event cannot be written (`isEditable == false`, for example a read-only calendar).
    case readOnly
    /// The block is a ghost of an event that is gone from the calendar.
    case eventMissing
    /// The event already runs over more than one local day. Not supported yet; the stored range would allow it.
    case spansDays

    // Changing the range
    /// The start would not be before the end.
    case startNotBeforeEnd
    /// The range would be shorter than `EditDraft.minimumDurationMinutes`.
    case shorterThanMinimum
    /// The range would leave the draft's day (crossing midnight is not supported yet).
    case leavesDay(LocalDate)
}

/// An edit of one existing timed event, kept apart from the calendar until it is saved or dropped.
///
/// - The range is the event's real, absolute range (`TimedRange`, unix milliseconds; `startDate`/`endDate` give the same
///   instants as `Date`), never minutes clipped to a column. Columns are projections of it (`segment(on:)`).
/// - `original` is taken once and never changes: the event's key (event ID + calendar ID), revision token and fields as
///   the draft began. Cancelling is dropping the draft; nothing is written and the original is untouched.
/// - Every change goes through one check (`issue(start:end:)`). A refused change throws and leaves the draft as it was,
///   so a draft only ever holds the original or a valid range.
/// - Conflicts are judged against the original: what the calendar says now (`observe`), and reloads that make an earlier
///   check stale (`noteReload`). Detecting only; resolving a conflict and saving belong to the caller.
///
/// For now a draft is one timed event on one local day (`Extent.singleDay`). Several days need a new `Extent` case and its
/// check; the range, the original and the projection already work for any span.
public struct EditDraft: Hashable, Sendable {
    /// One step of `stepStart`/`stepEnd`, on a grid aligned to local midnight (the standard edit policy's snap).
    public static let stepMinutes = TimelineEditPolicy.standard.snapMinutes
    /// The shortest range a change may produce (the same minimum the command service enforces on a save).
    public static let minimumDurationMinutes = TimelineEditPolicy.standard.minimumDurationMinutes

    // MARK: Values

    /// What the draft knows of the event at one moment: its identity, revision and the fields a conflict is judged on.
    public struct Snapshot: Hashable, Sendable {
        public let key: CalendarEventKey
        public let revisionToken: String?
        public let title: String
        public let time: EventTimeRange
        public let isEditable: Bool
        public let isRecurringInstance: Bool

        public init(key: CalendarEventKey, revisionToken: String?, title: String, time: EventTimeRange, isEditable: Bool, isRecurringInstance: Bool) {
            self.key = key
            self.revisionToken = revisionToken
            self.title = title
            self.time = time
            self.isEditable = isEditable
            self.isRecurringInstance = isRecurringInstance
        }

        public init(_ event: CalendarEvent) {
            self.init(
                key: event.key, revisionToken: event.revisionToken, title: event.title, time: event.time,
                isEditable: event.isEditable, isRecurringInstance: event.isRecurringInstance
            )
        }

        /// From a timeline block: its real (unclipped) range, not the minutes drawn on that day.
        public init(_ block: EventBlock) {
            // A block's range comes from a valid `TimedRange`, so it cannot be empty.
            let range = (try? TimedRange(startUnixMilliseconds: block.startUnixMilliseconds, endUnixMilliseconds: block.endUnixMilliseconds))
                ?? (try! TimedRange(startUnixMilliseconds: block.startUnixMilliseconds, endUnixMilliseconds: block.startUnixMilliseconds + 1))
            self.init(
                key: block.eventKey, revisionToken: block.revisionToken, title: block.title, time: .timed(range),
                isEditable: block.isEditable, isRecurringInstance: block.isRecurringInstance
            )
        }

        public var eventID: CalendarEventID { key.eventID }
        public var calendarID: CalendarID { key.calendarID }

        /// The fields that differ from `other`. `.revision` only when both sides have a token; without tokens the fields decide.
        public func differences(from other: Snapshot) -> Set<Field> {
            var fields: Set<Field> = []
            if time != other.time { fields.insert(.time) }
            if title != other.title { fields.insert(.title) }
            if isEditable != other.isEditable { fields.insert(.editability) }
            if let mine = revisionToken, let theirs = other.revisionToken, mine != theirs { fields.insert(.revision) }
            return fields
        }
    }

    /// A field a conflict can name. `.revision` alone means the calendar changed something the domain does not model.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case time, title, editability, revision
    }

    /// How far the range may reach. Only one day for now; a multi-day case can be added without changing how the range is stored.
    public enum Extent: Hashable, Sendable {
        /// The range stays inside `[start, end]` of this local day; it may end exactly at the next midnight.
        case singleDay(LocalDate)
    }

    /// What the calendar says about the event now, by its key.
    public enum Observation: Hashable, Sendable {
        case present(Snapshot)
        /// The key no longer resolves: `CalendarProvider.event(_:)` returned `nil` or a write reported `.eventMissing`.
        /// An event moved to another calendar gets a new key, so it is also `deleted` here.
        case deleted
        /// Not known now: not read since a reload, access lost, or not in the days that were read (it may have moved).
        case unavailable

        /// From `CalendarProvider.event(_:)`.
        public init(providerEvent: CalendarEvent?) {
            self = providerEvent.map { .present(Snapshot($0)) } ?? .deleted
        }

        /// From built timelines. Not finding the event is `unavailable`, never `deleted`: it may be on a day not read.
        public static func lookup(_ key: CalendarEventKey, in timelines: [DayTimeline]) -> Observation {
            for timeline in timelines {
                if let block = timeline.blocks.first(where: { $0.eventKey == key }) {
                    return block.state == .eventMissing ? .deleted : .present(Snapshot(block))
                }
            }
            return .unavailable
        }
    }

    /// The original compared with what the calendar says now. Anything but `.none` should stop a save.
    public enum Conflict: Hashable, Sendable {
        /// Seen now and the same as the original.
        case none
        /// A reload happened (or the event could not be read) and nothing newer has been seen yet.
        case unverified
        /// Seen now and different. `current` is what the calendar has; `fields` say what moved.
        case changed(current: Snapshot, fields: Set<Field>)
        case deleted

        public var blocksSave: Bool { self != .none }
    }

    /// One column's part of the range, in the same terms as `EventBlock` (minutes from that day's start, ends rounded up).
    public struct DaySegment: Hashable, Sendable {
        public let day: LocalDate
        /// The range clipped to the day.
        public let range: TimedRange
        public let startMinute: Int
        public let endMinute: Int
        public let continuesFromPreviousDay: Bool
        public let continuesToNextDay: Bool
    }

    /// Before and after, as the save would see it.
    public struct Comparison: Hashable, Sendable {
        public let before: TimedRange
        public let after: TimedRange

        public init(before: TimedRange, after: TimedRange) {
            self.before = before
            self.after = after
        }

        public var startDeltaMilliseconds: Int64 { after.startUnixMilliseconds - before.startUnixMilliseconds }
        public var endDeltaMilliseconds: Int64 { after.endUnixMilliseconds - before.endUnixMilliseconds }
        public var durationDeltaMilliseconds: Int64 { after.durationMilliseconds - before.durationMilliseconds }
        public var startChanged: Bool { startDeltaMilliseconds != 0 }
        public var endChanged: Bool { endDeltaMilliseconds != 0 }
        public var isChanged: Bool { startChanged || endChanged }
    }

    // MARK: State

    /// The event as the draft began. Never changes.
    public let original: Snapshot
    public let timeZone: DisplayTimeZone
    public let extent: Extent
    /// The edited range. Always the original or a range `issue(start:end:)` accepts.
    public private(set) var range: TimedRange
    /// The latest conflict judgement (see `observe` and `noteReload`).
    public private(set) var conflict: Conflict = .none
    /// The newest data generation seen; observations read in an older one are ignored.
    public private(set) var generation: Int

    // MARK: Starting

    /// Starts a draft of `original` as it was read in data generation `generation` (for example `AppModel.dataGeneration`).
    /// Days are local days in `timeZone`, the zone the grid is drawn in.
    public init(original: Snapshot, timeZone: DisplayTimeZone, generation: Int = 0) throws(EditDraftError) {
        guard case let .timed(range) = original.time else { throw .allDay }
        guard original.isEditable else { throw .readOnly }
        let first = timeZone.localDate(of: range.startUnixMilliseconds)
        let last = timeZone.localDate(of: range.endUnixMilliseconds - 1)
        guard first == last else { throw .spansDays }
        self.original = original
        self.timeZone = timeZone
        self.extent = .singleDay(first)
        self.range = range
        self.generation = generation
    }

    public init(event: CalendarEvent, timeZone: DisplayTimeZone, generation: Int = 0) throws(EditDraftError) {
        try self.init(original: Snapshot(event), timeZone: timeZone, generation: generation)
    }

    public init(block: EventBlock, timeZone: DisplayTimeZone, generation: Int = 0) throws(EditDraftError) {
        guard block.state != .eventMissing else { throw .eventMissing }
        try self.init(original: Snapshot(block), timeZone: timeZone, generation: generation)
    }

    // MARK: Reading

    public var key: CalendarEventKey { original.key }
    public var eventID: CalendarEventID { original.key.eventID }
    public var calendarID: CalendarID { original.key.calendarID }
    /// The revision the draft was made against; a save passes it as the expected revision.
    public var originalRevisionToken: String? { original.revisionToken }
    /// The original's range. A draft only starts from a timed event, so this always exists.
    public var originalRange: TimedRange {
        if case let .timed(range) = original.time { return range }
        preconditionFailure("EditDraft is only made from timed events")
    }

    public var startDate: Date { Self.date(range.startUnixMilliseconds) }
    public var endDate: Date { Self.date(range.endUnixMilliseconds) }

    public var comparison: Comparison { Comparison(before: originalRange, after: range) }
    public var isChanged: Bool { range != originalRange }

    /// Why the current range would be refused, or `nil`. An untouched original shorter than the minimum reports it too.
    public var validationIssue: EditDraftError? { issue(start: range.startUnixMilliseconds, end: range.endUnixMilliseconds) }
    public var isValid: Bool { validationIssue == nil }

    /// The local days the range touches, in order. One day while `extent` is `.singleDay`.
    public var days: [LocalDate] {
        let first = timeZone.localDate(of: range.startUnixMilliseconds)
        let last = timeZone.localDate(of: range.endUnixMilliseconds - 1)
        return (0...max(0, last.daysSinceUnixEpoch - first.daysSinceUnixEpoch)).map { first.adding(days: $0) }
    }

    /// The part of the range on `day`, or `nil` if it does not touch that day.
    public func segment(on day: LocalDate) -> DaySegment? {
        let bounds = timeZone.dayBounds(day)
        let start = max(range.startUnixMilliseconds, bounds.start)
        let end = min(range.endUnixMilliseconds, bounds.end)
        guard start < end, let clipped = try? TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: end) else { return nil }
        return DaySegment(
            day: day,
            range: clipped,
            startMinute: Int((start - bounds.start) / 60_000),
            endMinute: Int((end - bounds.start + 59_999) / 60_000),
            continuesFromPreviousDay: range.startUnixMilliseconds < bounds.start,
            continuesToNextDay: range.endUnixMilliseconds > bounds.end
        )
    }

    /// Why `[start, end)` would be refused as this draft's range, or `nil`. Checked in this order: order, extent, minimum.
    public func issue(start: Int64, end: Int64) -> EditDraftError? {
        guard start < end else { return .startNotBeforeEnd }
        switch extent {
        case let .singleDay(day):
            let bounds = timeZone.dayBounds(day)
            guard start >= bounds.start, end <= bounds.end else { return .leavesDay(day) }
        }
        guard end - start >= Int64(Self.minimumDurationMinutes) * 60_000 else { return .shorterThanMinimum }
        return nil
    }

    // MARK: Changing

    /// Moves the start by `steps` grid steps (negative is earlier); the end stays. From an off-grid start the first step
    /// lands on the next grid line in that direction (10:07 → 10:15 or 10:00), later steps are whole steps.
    public mutating func stepStart(by steps: Int) throws(EditDraftError) {
        guard steps != 0 else { return }
        try apply(start: stepped(range.startUnixMilliseconds, by: steps), end: range.endUnixMilliseconds)
    }

    /// Moves the end by `steps` grid steps; the start stays. Same grid rule as `stepStart`.
    public mutating func stepEnd(by steps: Int) throws(EditDraftError) {
        guard steps != 0 else { return }
        try apply(start: range.startUnixMilliseconds, end: stepped(range.endUnixMilliseconds, by: steps))
    }

    /// Sets the range exactly (no snapping; a gesture snaps first with `TimelineEditPolicy.snap`).
    public mutating func setRange(_ newRange: TimedRange) throws(EditDraftError) {
        try apply(start: newRange.startUnixMilliseconds, end: newRange.endUnixMilliseconds)
    }

    /// Back to the original range. Conflict state is about the original and stays.
    public mutating func revert() {
        range = originalRange
    }

    // MARK: Conflicts

    /// The original compared with `observation`. Pure; does not change the draft.
    public func conflict(with observation: Observation) -> Conflict {
        switch observation {
        case .unavailable:
            return .unverified
        case .deleted:
            return .deleted
        case let .present(current):
            // A snapshot of some other event says nothing about this one.
            guard current.key == original.key else { return .unverified }
            let fields = current.differences(from: original)
            return fields.isEmpty ? .none : .changed(current: current, fields: fields)
        }
    }

    /// The calendar may have changed (a reload, `dataGeneration` moved to `generation`). A clean draft becomes `unverified`
    /// until the event is seen again; a known `changed`/`deleted` stays. An older or equal generation is ignored.
    public mutating func noteReload(generation newGeneration: Int) {
        guard newGeneration > generation else { return }
        generation = newGeneration
        if conflict == .none { conflict = .unverified }
    }

    /// Records what the calendar says now, read in data generation `readGeneration`. A read from before the latest reload
    /// is stale and ignored; a newer one also counts as that reload.
    public mutating func observe(_ observation: Observation, readGeneration: Int) {
        guard readGeneration >= generation else { return }
        generation = readGeneration
        conflict = conflict(with: observation)
    }

    // MARK: Saving (data only)

    /// Where a save writes: the original key with the original revision, so a changed event is refused, not overwritten.
    public var target: EventTarget { EventTarget(key: original.key, expectedRevisionToken: original.revisionToken) }

    /// The patch a save sends: the new time only. `nil` while unchanged or invalid.
    public var update: CalendarEventUpdate? {
        guard isChanged, isValid else { return nil }
        return CalendarEventUpdate(time: .timed(range))
    }

    /// The command a save would run, or `nil` when there is nothing valid to save. Conflicts are not checked here; see `conflict`.
    public func editEventInput(scope: RecurrenceScope? = nil) -> EditEventInput? {
        update.map { EditEventInput(target: target, update: $0, scope: scope) }
    }

    // MARK: Helpers

    private mutating func apply(start: Int64, end: Int64) throws(EditDraftError) {
        if let issue = issue(start: start, end: end) { throw issue }
        // `issue` returned nil, so `start < end`.
        range = try! TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: end)
    }

    /// `instant` moved by `steps` steps of the grid aligned to local midnight. Off-grid, the first step goes to the
    /// nearest grid line in the step's direction.
    private func stepped(_ instant: Int64, by steps: Int) -> Int64 {
        let step = Int64(Self.stepMinutes) * 60_000
        let dayStart = timeZone.startOfDay(containing: instant)
        let below = dayStart + (instant - dayStart) / step * step
        if below == instant { return instant + Int64(steps) * step }
        return steps > 0 ? below + Int64(steps) * step : below + Int64(steps + 1) * step
    }

    private static func date(_ unixMilliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(unixMilliseconds) / 1_000)
    }
}
