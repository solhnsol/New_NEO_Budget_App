/// The outcome of a gesture-derived edit: the resulting range and whether the policy had to adjust the
/// user's raw proposal (a UI can use that to shake or snap-bounce). Pure data; no gesture or screen concepts.
public struct TimedEdit: Equatable, Sendable {
    public let range: TimedRange
    public let wasClamped: Bool

    public init(range: TimedRange, wasClamped: Bool) {
        self.range = range
        self.wasClamped = wasClamped
    }
}

/// Domain meaning of timeline gestures. Every function is pure and deterministic: the same inputs always give
/// the same range. A UI converts pointer positions to proposed instants; this policy decides what they mean.
///
/// - whole event drag → `move` (duration preserved, start snapped)
/// - top edge drag → `resizeStart`; bottom edge drag → `resizeEnd` (never flips; keeps the minimum duration)
/// - empty-area drag → `create`
/// Overlapping events are allowed and events may cross midnight; nothing here forbids either.
public struct TimelineEditPolicy: Equatable, Sendable {
    public let snapMinutes: Int
    public let minimumDurationMinutes: Int
    public let defaultNewEventDurationMinutes: Int

    public init(snapMinutes: Int, minimumDurationMinutes: Int, defaultNewEventDurationMinutes: Int) throws {
        guard snapMinutes > 0, minimumDurationMinutes > 0, defaultNewEventDurationMinutes >= minimumDurationMinutes else {
            throw CalendarValidationError.invalidEditPolicy
        }
        self.snapMinutes = snapMinutes
        self.minimumDurationMinutes = minimumDurationMinutes
        self.defaultNewEventDurationMinutes = defaultNewEventDurationMinutes
    }

    /// 15-minute snapping, 15-minute minimum, 60-minute default.
    public static let standard = try! TimelineEditPolicy(snapMinutes: 15, minimumDurationMinutes: 15, defaultNewEventDurationMinutes: 60)
    /// 5-minute snapping for a zoomed-in timeline; the minimum duration stays 15 minutes.
    public static let zoomed = try! TimelineEditPolicy(snapMinutes: 5, minimumDurationMinutes: 15, defaultNewEventDurationMinutes: 60)

    private var snapMilliseconds: Int64 { Int64(snapMinutes) * 60_000 }
    private var minimumDurationMilliseconds: Int64 { Int64(minimumDurationMinutes) * 60_000 }
    private var defaultDurationMilliseconds: Int64 { Int64(defaultNewEventDurationMinutes) * 60_000 }

    /// Rounds to the nearest snap step measured from local midnight in `timeZone`; halfway rounds up.
    public func snap(_ instant: Int64, in timeZone: DisplayTimeZone) -> Int64 {
        let dayStart = timeZone.startOfDay(containing: instant)
        let elapsed = instant - dayStart
        let step = snapMilliseconds
        let steps = (elapsed + step / 2) / step
        return dayStart + steps * step
    }

    // MARK: Timed events

    /// Whole-event drag: the event keeps its duration and its start lands on the snap grid.
    public func move(_ range: TimedRange, toProposedStart proposedStart: Int64, in timeZone: DisplayTimeZone) -> TimedRange {
        let start = snap(proposedStart, in: timeZone)
        return shifted(range, toStart: start)
    }

    /// Dropping an event on another day keeps its local time of day and its duration.
    public func move(_ range: TimedRange, toDay day: LocalDate, in timeZone: DisplayTimeZone) -> TimedRange {
        let minute = timeZone.minuteOfDay(of: range.startUnixMilliseconds)
        return shifted(range, toStart: timeZone.instant(of: day, minuteOfDay: minute))
    }

    /// Top edge drag. The end stays put; the start cannot pass `end - minimumDuration`.
    public func resizeStart(_ range: TimedRange, toProposedStart proposedStart: Int64, in timeZone: DisplayTimeZone) -> TimedEdit {
        let snapped = snap(proposedStart, in: timeZone)
        let latestStart = range.endUnixMilliseconds - minimumDurationMilliseconds
        let start = min(snapped, latestStart)
        return edit(start: start, end: range.endUnixMilliseconds, wasClamped: start != snapped, fallback: range)
    }

    /// Bottom edge drag. The start stays put; the end cannot go below `start + minimumDuration`.
    /// `clampingToDayEnd` (the selected day's end instant) stops a resize from running past that day's bottom.
    public func resizeEnd(
        _ range: TimedRange,
        toProposedEnd proposedEnd: Int64,
        in timeZone: DisplayTimeZone,
        clampingToDayEnd dayEnd: Int64? = nil
    ) -> TimedEdit {
        var end = snap(proposedEnd, in: timeZone)
        var clamped = false
        if let dayEnd, end > dayEnd {
            end = dayEnd
            clamped = true
        }
        let earliestEnd = range.startUnixMilliseconds + minimumDurationMilliseconds
        if end < earliestEnd {
            end = earliestEnd
            clamped = true
        }
        return edit(start: range.startUnixMilliseconds, end: end, wasClamped: clamped, fallback: range)
    }

    /// Dragging across empty space. The two ends are ordered and snapped; a drag shorter than the minimum
    /// becomes the minimum. With `day`, the result is kept inside that day. Whether a pointer movement counts
    /// as a drag at all (versus a tap) is a UI decision.
    public func create(
        dragFrom first: Int64,
        to second: Int64,
        in timeZone: DisplayTimeZone,
        keepingInside day: LocalDate? = nil
    ) -> TimedEdit {
        var start = snap(min(first, second), in: timeZone)
        var end = snap(max(first, second), in: timeZone)
        var clamped = false
        if end - start < minimumDurationMilliseconds {
            end = start + minimumDurationMilliseconds
            clamped = true
        }
        if let day {
            let bounds = timeZone.dayBounds(day)
            if start < bounds.start {
                start = bounds.start
                clamped = true
            }
            if end > bounds.end {
                end = bounds.end
                clamped = true
                if end - start < minimumDurationMilliseconds { start = max(bounds.start, end - minimumDurationMilliseconds) }
            }
        }
        // `start < end` holds because the minimum duration is positive and the day is longer than it.
        let range = (try? TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: max(end, start + 1)))
            ?? (try! TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: start + minimumDurationMilliseconds))
        return TimedEdit(range: range, wasClamped: clamped)
    }

    // MARK: All-day conversion and movement

    /// A timed event dragged to the all-day area becomes whole days. The time of day is lost; the first and
    /// last day are the local days that contain the start and the last instant before the end.
    public func timedToAllDay(_ range: TimedRange, in timeZone: DisplayTimeZone) -> DayRange {
        let first = timeZone.localDate(of: range.startUnixMilliseconds)
        let last = timeZone.localDate(of: range.endUnixMilliseconds - 1)
        return (try? DayRange(firstDay: first, lastDay: max(first, last))) ?? (try! DayRange(firstDay: first, lastDay: first))
    }

    /// An all-day event dropped into the time grid becomes a timed event of the default duration at the
    /// snapped drop position.
    public func allDayToTimed(atProposedStart proposedStart: Int64, in timeZone: DisplayTimeZone) -> TimedRange {
        let start = snap(proposedStart, in: timeZone)
        return (try! TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: start + defaultDurationMilliseconds))
    }

    /// Moves an all-day event so it starts on `firstDay`, keeping its length in days.
    public func move(_ range: DayRange, toFirstDay firstDay: LocalDate) -> DayRange {
        let lastDay = firstDay.adding(days: range.dayCount - 1)
        return (try! DayRange(firstDay: firstDay, lastDay: lastDay))
    }

    // MARK: Helpers

    private func shifted(_ range: TimedRange, toStart start: Int64) -> TimedRange {
        (try! TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: start + range.durationMilliseconds))
    }

    private func edit(start: Int64, end: Int64, wasClamped: Bool, fallback: TimedRange) -> TimedEdit {
        if let range = try? TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: end) {
            return TimedEdit(range: range, wasClamped: wasClamped)
        }
        // Unreachable with a positive minimum duration; keep the original range rather than trap.
        return TimedEdit(range: fallback, wasClamped: true)
    }
}
