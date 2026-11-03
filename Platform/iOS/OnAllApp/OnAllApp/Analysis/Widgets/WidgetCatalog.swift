import Foundation
import NEOBudgetCalendar

// The analysis tab's widgets: what exists (catalog), the numbers each one shows (data) and where they sit (packer).
// Nothing here touches the ledger or SwiftUI state, so the same pieces can later feed home-screen widgets.

enum WidgetSize: Int, Codable, CaseIterable, Comparable {
    case small, medium, large

    static func < (lhs: WidgetSize, rhs: WidgetSize) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Grid cells: the grid is two cells wide, so 2×2 is one cell, 4×2 two across, 4×4 two by two.
    var columns: Int { self == .small ? 1 : 2 }
    var rows: Int { self == .large ? 2 : 1 }
    var title: String { ["작게", "중간", "크게"][rawValue] }
    var spec: String { ["2×2", "4×2", "4×4"][rawValue] }
}

/// What a widget is about (the first level of the add sheet).
enum WidgetTopic: String, Codable, CaseIterable {
    case week, monthTrend, category, activity, spent, fixed, pending

    var title: String {
        switch self {
        case .week: return "이번 주"
        case .monthTrend: return "월별 추이"
        case .category: return "분류별"
        case .activity: return "일정별"
        case .spent: return "쓴 돈"
        case .fixed: return "고정 지출"
        case .pending: return "정산 받을 돈"
        }
    }

    var symbol: String {
        switch self {
        case .week, .monthTrend: return "chart.bar"
        case .category: return "square.grid.2x2"
        case .activity: return "calendar"
        case .spent: return "wonsign"
        case .fixed: return "repeat"
        case .pending: return "person.2"
        }
    }
}

/// How a topic is drawn (the second level: one topic has several).
enum WidgetStyle: String, Codable {
    case bars, barsList, line, number, list, top

    var title: String {
        switch self {
        case .bars: return "막대"
        case .barsList: return "막대 + 목록"
        case .line: return "꺾은선"
        case .number: return "숫자"
        case .list: return "목록"
        case .top: return "가장 많이 쓴 곳"
        }
    }
}

struct WidgetSpec: Codable, Hashable, Identifiable {
    var topic: WidgetTopic
    var style: WidgetStyle
    var size: WidgetSize

    var id: String { "\(topic.rawValue)-\(style.rawValue)-\(size.rawValue)" }

    private init(_ topic: WidgetTopic, _ style: WidgetStyle, _ size: WidgetSize) { self.topic = topic; self.style = style; self.size = size }

    /// Every widget the app offers. Order is the order the gallery shows.
    static let all: [WidgetSpec] = [
        .init(.week, .bars, .medium), .init(.week, .line, .medium), .init(.week, .number, .small), .init(.week, .barsList, .large),
        .init(.monthTrend, .bars, .medium), .init(.monthTrend, .line, .medium), .init(.monthTrend, .bars, .large),
        .init(.category, .top, .small), .init(.category, .list, .medium), .init(.category, .list, .large),
        .init(.activity, .list, .medium), .init(.activity, .list, .large),
        .init(.spent, .number, .small),
        .init(.fixed, .number, .small),
        .init(.pending, .number, .small), .init(.pending, .list, .medium),
    ]

    static func variants(of topic: WidgetTopic) -> [WidgetSpec] { all.filter { $0.topic == topic } }

    /// The same widget in another size, when the catalog has one.
    func sizes() -> [WidgetSpec] { Self.all.filter { $0.topic == topic && $0.style == style }.sorted { $0.size < $1.size } }
}

/// The numbers the widgets show for one month, taken from the user's share of each transaction (pending settlements are already
/// taken out; they only show up as "정산 대기 중").
struct AnalysisWidgetData: Equatable {
    struct Point: Equatable { var label: String; var won: Int64 }
    struct Line: Equatable { var symbol: String?; var title: String; var detail: String; var won: Int64 }

    /// Monday … Sunday of the week that contains `through`.
    var week: [Point] = []
    var weekToday = 0
    var weekTotal: Int64 = 0
    var weekAverage: Int64 = 0
    var weekTopDays: [Line] = []
    /// The last six months, the chosen one last.
    var months: [Point] = []
    var monthLabel = ""
    var spent: Int64 = 0
    var fixed: Int64 = 0
    var pending: Int64 = 0
    var pendingLines: [Line] = []
    var categories: [Line] = []
    var categoryTotal: Int64 = 0
    var activities: [Line] = []

    static let weekdayNames = ["월", "화", "수", "목", "금", "토", "일"]

    static func make(rows: [AnalysisTransaction], month: AnalysisMonth, today: LocalDate) -> AnalysisWidgetData {
        var data = AnalysisWidgetData()
        guard let period = try? AnalysisPeriod.month(year: month.year, month: month.month) else { return data }
        let through = month == AnalysisMonth(today) ? today : period.last
        data.monthLabel = month.shortTitle

        // Week (Monday first).
        let start = through.adding(days: -((through.weekday + 6) % 7))
        var perDay = [Int64](repeating: 0, count: 7)
        for row in rows {
            let offset = row.date.daysSinceUnixEpoch - start.daysSinceUnixEpoch
            if (0..<7).contains(offset) { perDay[offset] += row.shareMinorUnits }
        }
        data.weekToday = (through.weekday + 6) % 7
        data.week = perDay.enumerated().map { Point(label: weekdayNames[$0.offset], won: $0.element) }
        data.weekTotal = perDay.reduce(0, +)
        data.weekAverage = data.weekTotal / Int64(data.weekToday + 1)
        data.weekTopDays = data.week.enumerated().filter { $0.element.won > 0 }.sorted { $0.element.won > $1.element.won }.prefix(3).map {
            let date = start.adding(days: $0.offset)
            return Line(symbol: nil, title: "\($0.element.label)요일", detail: "\(date.month)월 \(date.day)일", won: $0.element.won)
        }

        // Six months.
        data.months = (-5...0).map { back in
            let m = month.moved(by: back)
            let total = (try? AnalysisPeriod.month(year: m.year, month: m.month)).map { SpendingAnalysis.summary(rows, in: $0).totalMinorUnits } ?? 0
            return Point(label: m.shortTitle, won: total)
        }

        // The chosen month.
        let summary = SpendingAnalysis.summary(rows, in: period, through: through)
        data.spent = summary.totalMinorUnits
        data.fixed = summary.recurringMinorUnits
        data.pending = summary.pendingMinorUnits
        var pendingByTitle: [String: Int64] = [:]
        for row in SpendingAnalysis.inPeriod(rows, period) where row.pendingMinorUnits > 0 {
            pendingByTitle[row.activity?.title ?? "정산 대기", default: 0] += row.pendingMinorUnits
        }
        data.pendingLines = pendingByTitle.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { Line(symbol: nil, title: $0.key, detail: "정산 대기 중", won: $0.value) }
        let groups = SpendingAnalysis.byCategory(rows, in: period).filter { $0.totalMinorUnits > 0 }
        data.categoryTotal = groups.reduce(0) { $0 + $1.totalMinorUnits }
        data.categories = groups.prefix(5).map {
            Line(symbol: AnalysisText.categorySymbol($0.key), title: AnalysisText.category($0.key), detail: "\($0.count)번", won: $0.totalMinorUnits)
        }
        data.activities = SpendingAnalysis.byActivity(rows, in: period).filter { $0.totalMinorUnits > 0 }.prefix(4).map {
            Line(symbol: nil, title: $0.title, detail: $0.occurrences > 1 ? "\($0.occurrences)번" : "한 번", won: $0.totalMinorUnits)
        }
        return data
    }
}

/// Lays widgets out on a two-cell-wide grid, in order like the iPhone home screen: each widget takes the next free place at or after the
/// previous one, so the order of the list is the reading order.
enum WidgetPacker {
    static let gap: CGFloat = 12

    static func unit(width: CGFloat) -> CGFloat { max(0, (width - gap) / 2) }

    static func size(_ size: WidgetSize, unit: CGFloat) -> CGSize {
        CGSize(width: CGFloat(size.columns) * unit + CGFloat(size.columns - 1) * gap, height: CGFloat(size.rows) * unit + CGFloat(size.rows - 1) * gap)
    }

    static func frames(_ sizes: [WidgetSize], width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let unit = unit(width: width)
        var taken: [[Bool]] = []
        var cursor = 0
        var frames: [CGRect] = []
        for size in sizes {
            var position = cursor
            while true {
                let row = position / 2, column = position % 2
                while taken.count < row + size.rows { taken.append([false, false]) }
                let fits = column + size.columns <= 2 && (0..<size.rows).allSatisfy { r in (0..<size.columns).allSatisfy { !taken[row + r][column + $0] } }
                if fits {
                    for r in 0..<size.rows { for c in 0..<size.columns { taken[row + r][column + c] = true } }
                    let box = Self.size(size, unit: unit)
                    frames.append(CGRect(x: CGFloat(column) * (unit + gap), y: CGFloat(row) * (unit + gap), width: box.width, height: box.height))
                    cursor = position
                    break
                }
                position += 1
            }
        }
        return (frames, frames.map(\.maxY).max() ?? 0)
    }

    /// Where a widget dropped at `point` goes: before the first widget that is below the point, or in the same row and right of it.
    static func insertionIndex(_ frames: [CGRect], at point: CGPoint) -> Int {
        for (index, frame) in frames.enumerated() {
            if point.y < frame.minY { return index }
            if point.y <= frame.maxY && point.x < frame.midX { return index }
        }
        return frames.count
    }
}
