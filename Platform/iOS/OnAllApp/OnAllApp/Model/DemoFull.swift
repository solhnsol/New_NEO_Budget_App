import Foundation
import NEOBudgetCalendar
import NEOBudgetCore

/// Six weeks of a student's ordinary life (four back, two ahead): classes, lunches, the gym, weekend dates, and the spending
/// that goes with them, some of it linked to its event and every spend classified. It is what the app opens with when it is
/// launched without `-demo` or `-live` (the phone build, until real data is connected), and with `-demo-full`. Deterministic,
/// so the same day always looks the same. Nothing here is real data.
enum DemoFull {
    enum CalendarKind { case life, appointments, school }

    struct Event {
        let calendar: CalendarKind
        let title: String
        let day: LocalDate
        let from: (Int, Int)
        let to: (Int, Int)
        var location: String? = nil
    }

    struct Spend {
        let raw: String
        let kind: DraftEventKind
        let direction: TransactionDirection
        let won: Int64
        let day: LocalDate
        let minute: Int
        let merchant: String?
        var card = false
        /// Canonical category id (see `CategoryIcon`); nil for money that only moves.
        var category: String? = nil
        /// The title of the event on the same day it belongs to.
        var event: String? = nil
    }

    static var isOn: Bool {
        let args = ProcessInfo.processInfo.arguments
        // Tests build the sample ledger and demo themselves and expect the usual day.
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return args.contains("-demo-full") || (!testing && !args.contains("-demo") && !args.contains("-live"))
    }

    static let firstOffset = -28, lastOffset = 14

    static func events(today: LocalDate) -> [Event] {
        var result: [Event] = []
        for offset in firstOffset...lastOffset {
            let day = today.adding(days: offset)
            let week = (offset - firstOffset) / 7
            func add(_ calendar: CalendarKind, _ title: String, _ from: (Int, Int), _ to: (Int, Int), _ location: String? = nil) {
                result.append(Event(calendar: calendar, title: title, day: day, from: from, to: to, location: location))
            }
            switch day.weekday {
            case 1:
                add(.school, "알고리즘 수업", (9, 0), (10, 30), "공학관 302")
                add(.life, "헬스", (19, 0), (20, 30))
            case 2:
                add(.school, "데이터베이스", (10, 30), (12, 0), "공학관 210")
                add(.appointments, week % 2 == 0 ? "점심 약속" : "동기 점심", (12, 0), (13, 0), "성수")
                add(.life, "알바", (17, 0), (21, 0), "카페 온")
            case 3:
                add(.school, "알고리즘 수업", (9, 0), (10, 30), "공학관 302")
                add(.life, "스터디", (14, 0), (16, 0), "도서관")
                add(.life, "헬스", (19, 0), (20, 30))
            case 4:
                add(.school, "데이터베이스", (10, 30), (12, 0), "공학관 210")
                add(.school, "팀 프로젝트 회의", (16, 0), (17, 30))
                add(.life, "알바", (18, 0), (21, 0), "카페 온")
            case 5:
                add(.school, "알고리즘 수업", (9, 0), (10, 30), "공학관 302")
                if week % 2 == 0 {
                    add(.appointments, "친구 저녁", (19, 0), (21, 30), "홍대")
                } else {
                    add(.life, "헬스", (18, 30), (20, 0))
                }
            case 6:
                if week % 2 == 0 {
                    add(.appointments, "데이트", (13, 0), (20, 0), "성수")
                } else {
                    add(.life, "동아리 모임", (15, 0), (18, 0), "학생회관")
                    add(.appointments, "영화", (19, 30), (21, 40), "용산")
                }
            default:
                add(.life, "장보기", (11, 0), (12, 0), "마트")
                add(.appointments, "가족 저녁", (18, 0), (20, 0))
            }
        }
        return result
    }

    /// Spending up to now (nothing in the future), and the month's salary, bills and savings.
    static func spends(today: LocalDate, zone: DisplayTimeZone, now: Int64) -> [Spend] {
        var result: [Spend] = []
        for offset in firstOffset...0 {
            let day = today.adding(days: offset)
            let week = (offset - firstOffset) / 7
            let wiggle = Int64(((offset * 37) % 5 + 5) % 5) * 100
            func spend(_ name: String, _ won: Int64, _ hour: Int, _ minute: Int, _ category: String?, card: Bool = false, event: String? = nil,
                       kind: DraftEventKind = .purchase, direction: TransactionDirection = .outflow) {
                let raw = "full-\(day.year)-\(day.month)-\(day.day)-\(result.count)"
                result.append(Spend(raw: raw, kind: kind, direction: direction, won: won, day: day, minute: hour * 60 + minute,
                                    merchant: name, card: card, category: category, event: event))
            }
            let weekday = day.weekday
            if (1...5).contains(weekday) {
                spend("지하철", 1_550, 8, 25, "transport")
                if weekday != 4 { spend("커피 가게", 4_500 + wiggle, 8, 48, "cafe", card: true) }
                spend("지하철", 1_550, 21, 15, "transport")
            }
            switch weekday {
            case 1, 3:
                spend("학식", 6_000, 12, 20, "food")
                if weekday == 3 { spend("스터디 카페", 5_800, 14, 20, "cafe", card: true, event: "스터디") }
                spend("편의점", 2_800 + wiggle, 20, 40, "shopping")
            case 2:
                let lunch = week % 2 == 0 ? "점심 약속" : "동기 점심"
                spend("성수 식당", 14_000 + wiggle * 2, 12, 25, "food", card: true, event: lunch)
                spend("디저트 카페", 5_500, 12, 50, "cafe", event: lunch)
            case 4:
                spend("학식", 6_000, 12, 15, "food")
                spend("프린트", 1_200, 15, 40, "educat")
                if week % 2 == 1 { spend("배달", 21_000 + wiggle * 3, 21, 30, "food", card: true) }
            case 5:
                spend("학식", 6_000, 12, 20, "food")
                if week % 2 == 0 {
                    spend("홍대 술집", 38_000 + wiggle * 10, 19, 40, "food", card: true, event: "친구 저녁")
                    spend("택시", 12_400 + wiggle * 4, 22, 5, "transport", card: true)
                } else {
                    spend("단백질 음료", 2_800, 20, 10, "health")
                }
            case 6:
                if week % 2 == 0 {
                    spend("성수 식당", 32_000 + wiggle * 5, 13, 30, "food", card: true, event: "데이트")
                    spend("카페", 11_000, 15, 20, "cafe", card: true, event: "데이트")
                    spend("소품샵", 24_000, 17, 0, "shopping", card: true, event: "데이트")
                } else {
                    spend("동아리 회비", 10_000, 15, 10, "social", event: "동아리 모임")
                    spend("영화관", 28_000, 19, 35, "movie", card: true, event: "영화")
                    spend("팝콘", 9_000, 19, 45, "movie", card: true, event: "영화")
                }
            default:
                spend("마트", 43_200 + wiggle * 6, 11, 30, "grocery", card: true, event: "장보기")
                if week % 2 == 1 { spend("배달", 19_500, 21, 10, "food", card: true) }
            }
            switch day.day {
            case 5: spend("넷플릭스", 13_500, 9, 0, "subscription", card: true)
            case 10: spend("알바 급여", 620_000, 10, 0, nil, kind: .deposit, direction: .inflow)
            case 15: spend("카드대금", 412_000, 9, 30, nil, kind: .cardBillPayment)
            case 21: spend("통신비", 55_000, 9, 0, "telecom")
            case 25: spend("용돈", 300_000, 9, 0, nil, kind: .deposit, direction: .inflow)
            case 26: spend("저축", 150_000, 10, 0, nil, kind: .transferOut)
            default: break
            }
        }
        return result.filter { zone.instant(of: $0.day, minuteOfDay: $0.minute) <= now }
    }
}
