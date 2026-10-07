public enum CalendarValidationError: Error, Equatable, Sendable {
    case invalidDate(year: Int, month: Int, day: Int)
    case invalidTimedRange(start: Int64, end: Int64)
    case invalidDayRange
    case invalidTimeZone(String)
    case invalidEditPolicy
}

/// A calendar date without a time zone. All arithmetic is proleptic Gregorian and uses no system state.
public struct LocalDate: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        guard (1...12).contains(month), day >= 1, day <= Self.daysInMonth(year: year, month: month) else {
            throw CalendarValidationError.invalidDate(year: year, month: month, day: day)
        }
        self.year = year
        self.month = month
        self.day = day
    }

    private enum CodingKeys: String, CodingKey { case year, month, day }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            year: values.decode(Int.self, forKey: .year),
            month: values.decode(Int.self, forKey: .month),
            day: values.decode(Int.self, forKey: .day)
        )
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return isLeapYear(year) ? 29 : 28
        }
    }

    /// Days since 1970-01-01 (negative before). Howard Hinnant's civil-calendar algorithm.
    public var daysSinceUnixEpoch: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    public init(daysSinceUnixEpoch days: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let shiftedYear = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        // The algorithm only produces valid civil dates, so the memberwise assignment is safe.
        self.year = month <= 2 ? shiftedYear + 1 : shiftedYear
        self.month = month
        self.day = day
    }

    public func adding(days: Int) -> LocalDate { LocalDate(daysSinceUnixEpoch: daysSinceUnixEpoch + days) }

    /// 0 = Sunday … 6 = Saturday.
    public var weekday: Int {
        let value = (daysSinceUnixEpoch + 4) % 7
        return value >= 0 ? value : value + 7
    }
}
