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

    private static func grouped(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
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
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: zoneIdentifier)
        formatter.dateFormat = "a h:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(unixMilliseconds) / 1_000))
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

    static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "오전 12시"
        case 1..<12: return "오전 \(hour)시"
        case 12: return "오후 12시"
        default: return "오후 \(hour - 12)시"
        }
    }

    private static let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]
    static func weekdayShort(_ day: LocalDate) -> String { weekdaySymbols[day.weekday] }
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
