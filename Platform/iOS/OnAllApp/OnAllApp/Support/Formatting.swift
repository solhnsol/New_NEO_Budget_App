import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// Display formatting for the timeline. Domain values stay exact; this only chooses how they are written.
enum Formatting {
    private static let locale = Locale(identifier: "ko_KR")

    static func money(_ minorUnits: Int64, currency: String) -> String {
        switch currency {
        case "KRW": return grouped(minorUnits) + "원"
        case "JPY": return grouped(minorUnits) + "엔"
        default:
            let major = Double(minorUnits) / 100
            return String(format: "%.2f", major) + " " + currency
        }
    }

    /// `1234567` → `1,234,567`, as ko_KR writes it. Done by hand: this runs for every amount the grid and the lists draw, and a
    /// `NumberFormatter` made per call is slow enough to show while days scroll.
    static func grouped(_ value: Int64) -> String {
        let digits = String(value.magnitude)
        var result = ""
        result.reserveCapacity(digits.count + digits.count / 3 + 1)
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return value < 0 ? "-" + result : result
    }

    /// Date formatters by format and zone, made once: making one per call is slow, and lists and the grid write many times.
    /// `DateFormatter` is safe to use from several threads once it is set up.
    private final class DateFormatters: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String: DateFormatter] = [:]

        func formatter(_ format: String, zoneIdentifier: String, locale: Locale) -> DateFormatter {
            lock.lock()
            defer { lock.unlock() }
            let key = format + "|" + zoneIdentifier + "|" + locale.identifier
            if let known = made[key] { return known }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = TimeZone(identifier: zoneIdentifier)
            formatter.dateFormat = format
            made[key] = formatter
            return formatter
        }
    }

    private static let dateFormatters = DateFormatters()

    private static func string(_ unixMilliseconds: Int64, format: String, zoneIdentifier: String) -> String {
        dateFormatters.formatter(format, zoneIdentifier: zoneIdentifier, locale: locale)
            .string(from: Date(timeIntervalSince1970: Double(unixMilliseconds) / 1_000))
    }

    /// A total that never looks more certain than it is.
    static func aggregate(_ aggregate: AmountAggregate) -> String {
        let known = money(aggregate.knownMinorUnits, currency: aggregate.currency)
        if aggregate.isFullyKnown { return known }
        if aggregate.knownMinorUnits == 0 { return "금액 미정 \(aggregate.unresolvedCount)건" }
        return "\(known) 외 미정 \(aggregate.unresolvedCount)건"
    }

    static func knowledge(_ knowledge: AmountKnowledge, currency: String) -> String {
        switch knowledge {
        case let .exact(value): return money(value, currency: currency)
        case let .inferred(value, _): return "약 " + money(value, currency: currency)
        case let .estimated(value): return "추정 " + money(value, currency: currency)
        case .range:
            let bounds = knowledge.bounds
            guard let upper = bounds.upper else { return money(bounds.lower, currency: currency) + " 이상" }
            return money(bounds.lower, currency: currency) + " ~ " + money(upper, currency: currency)
        case .unknown: return "금액 미정"
        }
    }

    static func time(_ unixMilliseconds: Int64, zoneIdentifier: String) -> String {
        string(unixMilliseconds, format: "a h:mm", zoneIdentifier: zoneIdentifier)
    }

    @MainActor private static var clockFormatters: [String: DateFormatter] = [:]

    /// "9:30" (24-hour): the short form drawn on an event's corners, where room is tight.
    @MainActor static func shortClock(_ unixMilliseconds: Int64, zoneIdentifier: String) -> String {
        let formatter: DateFormatter
        if let known = clockFormatters[zoneIdentifier] {
            formatter = known
        } else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: zoneIdentifier)
            formatter.dateFormat = "H:mm"
            clockFormatters[zoneIdentifier] = formatter
        }
        return formatter.string(from: Date(timeIntervalSince1970: Double(unixMilliseconds) / 1_000))
    }

    /// "10/7": the date of something that happened on another day.
    static func shortDate(_ unixMilliseconds: Int64, zoneIdentifier: String) -> String {
        string(unixMilliseconds, format: "M/d", zoneIdentifier: zoneIdentifier)
    }

    static func timeRange(_ start: Int64, _ end: Int64, zoneIdentifier: String) -> String {
        time(start, zoneIdentifier: zoneIdentifier) + " – " + time(end, zoneIdentifier: zoneIdentifier)
    }

    /// "5시간 30분", "45분": how long a folded stretch of the day is.
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest)분"
        case (_, 0): return "\(hours)시간"
        default: return "\(hours)시간 \(rest)분"
        }
    }

    /// "13:05" for a minute of the day, as a short label for lists.
    static func clock(minute: Int) -> String { String(format: "%d:%02d", minute / 60, minute % 60) }
    static func hourLabel(_ hour: Int) -> String {
        // No 오전/오후: the axis reads top to bottom through the day, and midnight and noon have names of their own.
        switch hour {
        case 0, 24: return "자정"
        case 12: return "정오"
        default: return "\(hour % 12)시"
        }
    }

    private static let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]
    static func weekdayShort(_ day: LocalDate) -> String { weekdaySymbols[day.weekday] }
    /// "10월 9일 – 10일", or with both months when the two days are in different ones.
    static func dayRangeTitle(_ first: LocalDate, _ second: LocalDate) -> String {
        first.month == second.month ? "\(first.month)월 \(first.day)일 – \(second.day)일" : "\(first.month)월 \(first.day)일 – \(second.month)월 \(second.day)일"
    }
    static func dayTitle(_ day: LocalDate) -> String { "\(day.month)월 \(day.day)일 (\(weekdayShort(day)))" }
}

extension Color {
    /// `#RRGGBB` (the provider's calendar color), or `nil` if it cannot be read.
    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
