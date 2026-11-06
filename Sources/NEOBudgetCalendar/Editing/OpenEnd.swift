import Foundation

// 종료 미정 일정. EventKit cannot store an event without an end, so a start-only event is saved with a short placeholder end
// and remembered here as "open end". This file is platform-independent; the app persists `OpenEndMarks` itself.
// Design: records/20261103-종료-미정-EventKit-구현가능성.md (placeholder + local mark; spike on a phone still pending).

public enum OpenEnd {
    /// shortcut: 30 minutes everywhere, until the phone spike says Length-0 is safe for iCloud accounts.
    public static let placeholderMilliseconds: Int64 = 30 * 60_000

    /// The end saved to the calendar for an event that only has a start. Stays inside `day` (never crosses midnight) and after `start`.
    public static func placeholderEnd(start: Int64, on day: LocalDate, in zone: DisplayTimeZone) -> Int64 {
        let lastMinute = zone.startOfDay(day.adding(days: 1)) - 60_000
        return max(min(start + placeholderMilliseconds, lastMinute), start + 60_000)
    }
}

/// A time found in a title ("18시 저녁 약속"): offered as one "18:00 – 미정" suggestion.
public struct TitleTimeSuggestion: Equatable, Sendable {
    public let minuteOfDay: Int
    /// The title without the matched time text.
    public let strippedTitle: String

    public var label: String { String(format: "%02d:%02d – 미정", minuteOfDay / 60, minuteOfDay % 60) }

    // 오전/오후 prefix, N시 [M분|반]; or HH:MM. `시` is not followed by 간 (3시간 is a length, not a time).
    private static var pattern: NSRegularExpression {
        try! NSRegularExpression(
        pattern: #"(오전|오후|아침|저녁|새벽|밤)?\s*(\d{1,2})\s*시(?!간)(?:\s*(?:(\d{1,2})\s*분|(반)))?|(?<!\d)(\d{1,2}):(\d{2})(?!\d)"#
        )
    }

    /// The first time written in `title`, or `nil`. Hours 0–23 and minutes 0–59 only.
    public static func find(in title: String) -> TitleTimeSuggestion? {
        let whole = NSRange(title.startIndex..., in: title)
        for match in pattern.matches(in: title, range: whole) {
            func text(_ i: Int) -> String? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : Range(r, in: title).map { String(title[$0]) }
            }
            var hour: Int, minute: Int
            if let h = text(5), let m = text(6) {
                (hour, minute) = (Int(h) ?? 99, Int(m) ?? 99)
            } else if let h = text(2) {
                hour = Int(h) ?? 99
                minute = text(4) != nil ? 30 : Int(text(3) ?? "0") ?? 99
                switch text(1) {
                case "오후", "저녁": if hour < 12 { hour += 12 }
                case "밤": if (6..<12).contains(hour) { hour += 12 }
                case "오전", "새벽": if hour == 12 { hour = 0 }
                default: break
                }
            } else { continue }
            guard (0..<24).contains(hour), (0..<60).contains(minute), let range = Range(match.range, in: title) else { continue }
            var rest = title
            rest.removeSubrange(range)
            let stripped = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return TitleTimeSuggestion(minuteOfDay: hour * 60 + minute, strippedTitle: stripped)
        }
        return nil
    }
}

/// What the create sheet has when "저장" is pressed.
public struct NewEventInput: Hashable, Sendable {
    public var title: String
    public var calendarID: CalendarID
    public var day: LocalDate
    public var allDay: Bool
    public var startMinute: Int?
    public var endMinute: Int?

    public init(title: String, calendarID: CalendarID, day: LocalDate, allDay: Bool = false, startMinute: Int? = nil, endMinute: Int? = nil) {
        self.title = title
        self.calendarID = calendarID
        self.day = day
        self.allDay = allDay
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// No start (the suggestion was not taken) or all-day on: an all-day event. Start without an end: open end, saved with a placeholder end.
    /// Both: a normal timed event; an end that is not after the start throws `invalidTimedRange`.
    public func plan(in zone: DisplayTimeZone) throws -> (draft: CalendarEventDraft, isOpenEnd: Bool) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !allDay, let startMinute else {
            let one = try DayRange(firstDay: day, lastDay: day)
            return (CalendarEventDraft(calendarID: calendarID, title: name, time: .allDay(one)), false)
        }
        let start = zone.instant(of: day, minuteOfDay: startMinute)
        let end = endMinute.map { zone.instant(of: day, minuteOfDay: $0) } ?? OpenEnd.placeholderEnd(start: start, on: day, in: zone)
        let range = try TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: end)
        return (CalendarEventDraft(calendarID: calendarID, title: name, time: .timed(range), timeZoneIdentifier: zone.identifier), endMinute == nil)
    }
}

/// Which events are open-end, with the placeholder length that was saved for each. Keyed by the provider's event key.
/// shortcut: keyed by provider key, not calendarItemExternalIdentifier; switch when the EventKit provider exposes it.
public struct OpenEndMarks: Codable, Equatable, Sendable {
    private var durations: [String: Int64] = [:]

    public init() {}

    private static func id(_ key: CalendarEventKey) -> String { key.calendarID.rawValue + "\u{1F}" + key.eventID.rawValue }

    public func isOpenEnd(_ key: CalendarEventKey) -> Bool { durations[Self.id(key)] != nil }

    public mutating func mark(_ key: CalendarEventKey, placeholderMilliseconds: Int64 = OpenEnd.placeholderMilliseconds) {
        durations[Self.id(key)] = placeholderMilliseconds
    }

    public mutating func clear(_ key: CalendarEventKey) { durations[Self.id(key)] = nil }

    public var count: Int { durations.count }

    /// Every marked event, to look each up again (`reconcile`).
    public var keys: [CalendarEventKey] {
        durations.keys.compactMap { id in
            let parts = id.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
            return parts.count == 2 ? CalendarEventKey(calendarID: CalendarID(rawValue: parts[0]), eventID: CalendarEventID(rawValue: parts[1])) : nil
        }
    }

    /// After the calendar may have changed elsewhere: `lookup` returns the event as it is now (`nil`: gone). A mark stays only while the
    /// event is timed, not recurring, and still the placeholder length (moved is fine); anything else means the person set an end.
    public mutating func reconcile(_ keys: [CalendarEventKey], lookup: (CalendarEventKey) -> CalendarEvent?) {
        for key in keys {
            guard let duration = durations[Self.id(key)] else { continue }
            if let event = lookup(key), !event.isRecurringInstance, case let .timed(range) = event.time, range.durationMilliseconds == duration { continue }
            clear(key)
        }
    }
}
