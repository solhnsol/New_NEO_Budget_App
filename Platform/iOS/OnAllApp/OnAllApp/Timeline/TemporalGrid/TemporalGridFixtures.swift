import CoreGraphics
import NEOBudgetCalendar

#if DEBUG
/// Synthetic runs of consecutive days (no real data) for the temporal grid's tests, comparison and the `-render-grid` screen. The first
/// ten are the axis stabilization fixtures; the rest are the cases the temporal grid has to answer for.
enum TemporalGridFixtures {
    static let firstDay = (try? LocalDate(year: 2027, month: 3, day: 1)) ?? { fatalError("date") }()

    static func day(
        _ index: Int, events: [(Int, Int)] = [], transactions: [Int] = [], linkedPerEvent: Int = 0, titles: [String] = []
    ) -> AllocationDay {
        let date = firstDay.adding(days: index)
        let built = events.enumerated().map { offset, range -> AllocationEvent in
            let linked = (0..<linkedPerEvent).map { n in
                AllocationTransaction(id: "t\(index)-\(offset)-\(n)", minute: range.0 + min(n, max(0, range.1 - range.0 - 1)), kind: .spend, currency: "KRW", minorUnits: 3_000)
            }
            return AllocationEvent(id: "e\(index)-\(offset)", title: titles.indices.contains(offset) ? titles[offset] : "일정 \(offset)", startMinute: range.0, endMinute: range.1, linked: linked)
        }
        let loose = transactions.enumerated().map { offset, minute in
            AllocationTransaction(id: "x\(index)-\(offset)", minute: minute, kind: .spend, currency: "KRW", minorUnits: 2_000)
        }
        return AllocationDay(day: date, totalMinutes: 24 * 60, events: built, transactions: loose)
    }

    static func hours(_ from: Int, _ to: Int) -> (Int, Int) { (from * 60, to * 60) }
    static func at(_ hour: Int, _ minute: Int = 0) -> Int { hour * 60 + minute }

    static func busy(_ index: Int) -> AllocationDay {
        day(index, events: (8..<20).map { hours($0, $0 + 1) } + [(9 * 60 + 10, 9 * 60 + 30), (13 * 60, 13 * 60 + 20)], transactions: [9 * 60, 12 * 60, 15 * 60, 18 * 60], linkedPerEvent: 2)
    }

    static func scenario(_ name: String, count: Int = 9, viewport: CGFloat = 640, textScale: CGFloat = 1, _ make: (Int) -> AllocationDay) -> AxisStabilityScenario {
        AxisStabilityScenario(name: name, days: (0..<count).map(make), viewportHeight: viewport, textScale: textScale)
    }

    /// The ten runs the axis stabilization was measured on.
    static var stabilizationRuns: [AxisStabilityScenario] {
        [
            scenario("1 모두 한가한 6일") { day($0, events: [hours(14, 15)]) },
            scenario("2 하루만 매우 바쁨") { $0 == 4 ? busy($0) : day($0, events: [hours(14, 15)]) },
            scenario("3 바쁨/한가 번갈아") { $0 % 2 == 0 ? busy($0) : day($0, events: [hours(10, 11)]) },
            scenario("4 시간대가 분산") { day($0, events: [hours(6 + $0 * 2, 7 + $0 * 2), hours(7 + $0 * 2, 8 + $0 * 2)], transactions: [(6 + $0 * 2) * 60 + 30]) },
            scenario("5 긴 일정+짧은 일정") { day($0, events: [hours(9, 18), (10 * 60, 10 * 60 + 20), (12 * 60, 12 * 60 + 10), (15 * 60, 15 * 60 + 25)], linkedPerEvent: $0 % 3) },
            scenario("6 거래 밀집") { $0 % 3 == 1 ? day($0, events: [hours(9, 10)], transactions: (0..<14).map { 14 * 60 + $0 * 2 }) : day($0, events: [hours(11, 12)], transactions: [13 * 60]) },
            scenario("7 겹치는 일정 많음") { $0 % 2 == 0 ? day($0, events: [hours(9, 17), hours(10, 15), hours(11, 14), (12 * 60, 12 * 60 + 30), (9 * 60 + 30, 11 * 60)]) : day($0, events: [hours(13, 14)]) },
            scenario("8 자정을 넘는 일정") { day($0, events: [(0, 2 * 60), (22 * 60, 24 * 60), hours(12, 13)]) },
            scenario("9 작은 viewport", viewport: 360) { $0 % 2 == 0 ? busy($0) : day($0, events: [hours(10, 11), hours(16, 17)]) },
            scenario("10 큰 Dynamic Type", textScale: 2.2) { $0 % 2 == 0 ? busy($0) : day($0, events: [hours(10, 11), hours(16, 17)], linkedPerEvent: 1) },
        ]
    }

    /// The cases the temporal grid is asked about.
    static var gridRuns: [AxisStabilityScenario] {
        [
            scenario("11 하루 종일 비어 있음") { day($0) },
            scenario("12 하루 종일 일정") { day($0, events: [(0, 24 * 60), hours(9, 10)], titles: ["종일 일정", "회의"]) },
            scenario("13 짧은 일정 분산") { day($0, events: [(at(7, 30), at(7, 50)), (at(10, 15), at(10, 35)), (at(13), at(13, 20)), (at(16, 40), at(17)), (at(21), at(21, 15))], transactions: [at(12, 30), at(19)]) },
            scenario("14 짧은 일정 밀집") { day($0, events: [(at(9), at(9, 15)), (at(9, 15), at(9, 30)), (at(9, 30), at(9, 45)), (at(9, 45), at(10)), (at(10), at(10, 17)), (at(10, 20), at(10, 25)), (at(10, 30), at(10, 40)), (at(10, 45), at(11))], transactions: [at(9, 5), at(9, 50), at(10, 12)]) },
            scenario("15 긴 일정+짧은 일정 겹침") { day($0, events: [hours(9, 18), (at(10), at(10, 17)), (at(12), at(12, 5)), (at(15), at(15, 25)), (at(17, 30), at(18, 30))], linkedPerEvent: 2) },
            scenario("16 메인·보조가 다른 시간에 바쁨") { $0 % 2 == 0 ? day($0, events: (8..<12).map { (at($0), at($0, 50)) }, transactions: [at(9, 5), at(9, 8), at(11, 20)]) : day($0, events: (15..<20).map { (at($0), at($0, 50)) }, transactions: [at(16, 5), at(16, 8), at(18, 20)]) },
            scenario("17 거래 매우 밀집") { $0 % 2 == 0 ? day($0, events: [hours(9, 10)], transactions: (0..<40).map { at(14) + $0 * 1 } + [at(14, 12), at(14, 12), at(14, 12)]) : day($0, events: [hours(11, 12)], transactions: [at(13)]) },
            scenario("18 일정 32개") { day($0, events: (0..<32).map { (at(6) + $0 * 30, at(6) + $0 * 30 + 25) }, transactions: [at(8, 5), at(12, 10), at(18, 2)]) },
            scenario("19 Dynamic Type 3.0x 바쁜 날", textScale: 3.0) { $0 % 2 == 0 ? busy($0) : day($0, events: [hours(10, 11)], linkedPerEvent: 2) },
            demoTransRun(),
        ]
    }

    /// Mirrors `-demo-trans`: a quiet day, a morning cluster before and after, a busy afternoon, a full day (events by hour), and a week of the
    /// shapes seen on a phone with real data. Same minutes and titles as the `DemoData` drafts.
    static func demoTransRun() -> AxisStabilityScenario {
        let yesterday = day(0, events: [(at(9), at(9, 20)), (at(9, 20), at(9, 40)), (at(9, 40), at(10)), (at(10), at(10, 15)), hours(14, 17), (at(20), at(20, 10)), (at(20, 10), at(23))],
                            titles: ["조회 가", "조회 나", "조회 다", "조회 라", "오후 수업", "짧은 준비", "밤 작업"])
        let today = day(1, events: [hours(13, 14)], titles: ["점심 회의"])
        let tomorrow = day(2, events: [(at(14), at(14, 30)), (at(14, 30), at(15)), (at(15), at(15, 30)), hours(16, 18)], titles: ["오후 미팅 가", "오후 미팅 나", "오후 미팅 다", "저녁 약속"])
        let day2 = day(3, events: [(at(9), at(9, 15)), (at(9, 10), at(9, 40)), (at(9, 30), at(10, 30)), (at(9, 5), at(9, 25)), (at(10), at(10, 15))], titles: ["아침 스탠드업", "아침 리뷰", "아침 기획", "아침 메모", "커피 챗"])
        let day3 = day(4, events: (8..<20).map { (at($0), at($0, 50)) }, titles: (8..<20).map { "일정 \($0)시" })
        let rest = (5..<9).map { day($0, events: [hours(14, 15)]) }
        return AxisStabilityScenario(name: "20 -demo-trans", days: [yesterday, today, tomorrow, day2, day3] + rest)
    }

    static var all: [AxisStabilityScenario] { stabilizationRuns + gridRuns }
}
#endif
