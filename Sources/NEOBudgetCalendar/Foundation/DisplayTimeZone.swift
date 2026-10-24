import Foundation

/// A validated IANA time zone used to interpret local dates and wall-clock minutes. The zone is always an
/// explicit input; nothing here reads the device time zone, locale, or clock.
public struct DisplayTimeZone: Codable, Hashable, Sendable {
    public let identifier: String

    public init(identifier: String) throws {
        guard TimeZone(identifier: identifier) != nil else {
            throw CalendarValidationError.invalidTimeZone(identifier)
        }
        self.identifier = identifier
    }

    private enum CodingKeys: String, CodingKey { case identifier }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identifier: values.decode(String.self, forKey: .identifier))
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // Validated in `init`, so the force unwrap cannot fail for a constructed value.
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private static func date(_ unixMilliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(unixMilliseconds) / 1_000)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    /// The local calendar date that contains `instant`.
    public func localDate(of instant: Int64) -> LocalDate {
        let parts = calendar.dateComponents([.year, .month, .day], from: Self.date(instant))
        // Foundation returns valid components for a valid instant.
        return (try? LocalDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1))
            ?? LocalDate(daysSinceUnixEpoch: 0)
    }

    private func noon(of day: LocalDate) -> Date {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
            ?? Date(timeIntervalSince1970: Double(day.daysSinceUnixEpoch) * 86_400 + 43_200)
    }

    /// The first instant of `day` in this zone. Uses noon as the anchor so a midnight DST gap cannot break it.
    public func startOfDay(_ day: LocalDate) -> Int64 {
        Self.milliseconds(calendar.startOfDay(for: noon(of: day)))
    }

    public func startOfDay(containing instant: Int64) -> Int64 {
        Self.milliseconds(calendar.startOfDay(for: Self.date(instant)))
    }

    /// Half-open `[start, end)` bounds of `day`. A DST day is 23 or 25 hours long.
    public func dayBounds(_ day: LocalDate) -> (start: Int64, end: Int64) {
        (startOfDay(day), startOfDay(day.adding(days: 1)))
    }

    /// Wall-clock minutes since local midnight (0...1439) at `instant`.
    public func minuteOfDay(of instant: Int64) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: Self.date(instant))
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The instant at wall-clock `minuteOfDay` on `day`. A nonexistent local time (spring-forward gap) resolves
    /// to the next valid instant; a repeated time (fall-back) resolves to its first occurrence.
    public func instant(of day: LocalDate, minuteOfDay: Int) -> Int64 {
        let clamped = max(0, min(minuteOfDay, 24 * 60 - 1))
        if let date = calendar.date(
            bySettingHour: clamped / 60,
            minute: clamped % 60,
            second: 0,
            of: noon(of: day),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) {
            return Self.milliseconds(date)
        }
        return startOfDay(day) + Int64(clamped) * 60_000
    }
}
