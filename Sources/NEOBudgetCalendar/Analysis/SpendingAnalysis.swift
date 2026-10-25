import Foundation

// Spending analysis: pure functions over already-resolved transactions. Nothing here reads or changes the ledger;
// the caller turns ledger entries into `AnalysisTransaction`s (netting, overrides, tags) and this only groups and sums.
// Amounts are "my share" (docs: records/20261025-지출분석-태그-정기지출-설계.md): refunds and settlements are already taken out,
// and what other people still owe for it is taken out too but remembered in `pendingMinorUnits` ("정산 대기 중").

public struct AnalysisActivity: Equatable, Sendable {
    public let id: ActivityID
    public let title: String
    /// Everyone counted on the activity, the user included.
    public let headcount: Int
    public let participants: [PersonID]

    public init(id: ActivityID, title: String, headcount: Int, participants: [PersonID]) {
        self.id = id
        self.title = title
        self.headcount = headcount
        self.participants = participants
    }

    /// A gathering is an activity with at least two people (the user included).
    public var isGathering: Bool { headcount >= 2 }
}

public struct AnalysisTransaction: Equatable, Sendable {
    public let id: String
    public let date: LocalDate
    /// What it cost me after refunds, settlements received and settlements still expected. Negative for a refund that belongs to no purchase.
    public let shareMinorUnits: Int64
    /// The part of the deduction that is only expected, not yet received (shown as "정산 대기 중"). Never more than the share before it.
    public let pendingMinorUnits: Int64
    public let category: CanonicalCategoryID?
    public let tags: Set<String>
    public let activity: AnalysisActivity?
    public let isRecurring: Bool

    public init(
        id: String, date: LocalDate, shareMinorUnits: Int64, pendingMinorUnits: Int64 = 0, category: CanonicalCategoryID? = nil,
        tags: Set<String> = [], activity: AnalysisActivity? = nil, isRecurring: Bool = false
    ) {
        self.id = id
        self.date = date
        self.shareMinorUnits = shareMinorUnits
        self.pendingMinorUnits = pendingMinorUnits
        self.category = category
        self.tags = tags
        self.activity = activity
        self.isRecurring = isRecurring
    }
}

/// An inclusive range of days.
public struct AnalysisPeriod: Equatable, Sendable {
    public let first: LocalDate
    public let last: LocalDate

    public init(first: LocalDate, last: LocalDate) {
        self.first = first
        self.last = last
    }

    /// A calendar month, or the month that starts on `startDay` (1–28) of `year`-`month`, as when salary day starts the month.
    public static func month(year: Int, month: Int, startDay: Int = 1) throws -> AnalysisPeriod {
        let first = try LocalDate(year: year, month: month, day: min(max(startDay, 1), 28))
        let nextYear = month == 12 ? year + 1 : year, nextMonth = month == 12 ? 1 : month + 1
        let next = try LocalDate(year: nextYear, month: nextMonth, day: min(max(startDay, 1), 28))
        return AnalysisPeriod(first: first, last: next.adding(days: -1))
    }

    public var dayCount: Int { last.daysSinceUnixEpoch - first.daysSinceUnixEpoch + 1 }
    public func contains(_ date: LocalDate) -> Bool { date >= first && date <= last }
    /// The same number of days directly before this period (for "vs last month" with equal day counts).
    public func shifted(byMonths months: Int) throws -> AnalysisPeriod {
        func move(_ date: LocalDate) throws -> LocalDate {
            let index = date.year * 12 + (date.month - 1) + months
            let year = index / 12, month = index % 12 + 1
            return try LocalDate(year: year, month: month, day: min(date.day, LocalDate.daysInMonth(year: year, month: month)))
        }
        return AnalysisPeriod(first: try move(first), last: try move(last))
    }
}

public struct SpendingSummary: Equatable, Sendable {
    public let totalMinorUnits: Int64
    public let pendingMinorUnits: Int64
    public let transactionCount: Int
    /// Over every day of the period up to `through`, days without spending included. Rounded toward zero.
    public let dailyAverageMinorUnits: Int64
    public let averageMinorUnits: Int64
    public let medianMinorUnits: Int64
    public let recurringMinorUnits: Int64
    public var oneOffMinorUnits: Int64 { totalMinorUnits - recurringMinorUnits }
}

public struct AnalysisGroup<Key: Hashable & Sendable>: Equatable, Sendable {
    public let key: Key
    public let totalMinorUnits: Int64
    public let pendingMinorUnits: Int64
    public let count: Int
    public var averageMinorUnits: Int64 { count == 0 ? 0 : totalMinorUnits / Int64(count) }
}

/// A repeating activity ("스터디") or a one-off, with what was spent on every occurrence.
public struct ActivityGroup: Equatable, Sendable {
    public let title: String
    public let occurrences: Int
    public let totalMinorUnits: Int64
    public let isGathering: Bool
    public var perOccurrenceMinorUnits: Int64 { occurrences == 0 ? 0 : totalMinorUnits / Int64(occurrences) }
}

public struct PersonGroup: Equatable, Sendable {
    public let personID: PersonID
    /// Activities they took part in that had spending in the period.
    public let activityCount: Int
    /// The full share spent on those activities. It is not divided between the people there, so the totals of two people overlap.
    public let totalMinorUnits: Int64
    public var perActivityMinorUnits: Int64 { activityCount == 0 ? 0 : totalMinorUnits / Int64(activityCount) }
}

public struct GatheringSummary: Equatable, Sendable {
    public let count: Int
    public let totalMinorUnits: Int64
    public let perGatheringMinorUnits: Int64
    /// Total divided by the people counted at each gathering.
    public let perPersonMinorUnits: Int64
}

public enum SpendingAnalysis {
    public static func inPeriod(_ transactions: [AnalysisTransaction], _ period: AnalysisPeriod) -> [AnalysisTransaction] {
        transactions.filter { period.contains($0.date) }
    }

    /// `through`: the last day that counts toward the daily average, so a month in progress is not diluted by days to come.
    public static func summary(_ transactions: [AnalysisTransaction], in period: AnalysisPeriod, through: LocalDate? = nil) -> SpendingSummary {
        let rows = inPeriod(transactions, period)
        let total = rows.reduce(Int64(0)) { $0 + $1.shareMinorUnits }
        let end = min(through ?? period.last, period.last)
        let days = max(1, end.daysSinceUnixEpoch - period.first.daysSinceUnixEpoch + 1)
        let sorted = rows.map(\.shareMinorUnits).sorted()
        let median: Int64 = sorted.isEmpty ? 0 : (sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2)
        return SpendingSummary(
            totalMinorUnits: total, pendingMinorUnits: rows.reduce(0) { $0 + $1.pendingMinorUnits }, transactionCount: rows.count,
            dailyAverageMinorUnits: total / Int64(days), averageMinorUnits: rows.isEmpty ? 0 : total / Int64(rows.count), medianMinorUnits: median,
            recurringMinorUnits: rows.filter(\.isRecurring).reduce(0) { $0 + $1.shareMinorUnits }
        )
    }

    /// Largest first; ties by key description so the order is stable. `nil` is "no category".
    public static func byCategory(_ transactions: [AnalysisTransaction], in period: AnalysisPeriod) -> [AnalysisGroup<CanonicalCategoryID?>] {
        group(inPeriod(transactions, period)) { [$0.category] }.sorted { ($0.totalMinorUnits, "\($1.key?.rawValue ?? "")") > ($1.totalMinorUnits, "\($0.key?.rawValue ?? "")") }
    }

    /// A transaction with two tags counts in both, so tag totals can add up to more than the total. `nil` is "no tag".
    public static func byTag(_ transactions: [AnalysisTransaction], in period: AnalysisPeriod) -> [AnalysisGroup<String?>] {
        group(inPeriod(transactions, period)) { $0.tags.isEmpty ? [nil] : $0.tags.sorted().map { Optional($0) } }
            .sorted { ($0.totalMinorUnits, $1.key ?? "") > ($1.totalMinorUnits, $0.key ?? "") }
    }

    private static func group<Key: Hashable & Sendable>(_ rows: [AnalysisTransaction], keys: (AnalysisTransaction) -> [Key]) -> [AnalysisGroup<Key>] {
        var table: [Key: (total: Int64, pending: Int64, count: Int)] = [:]
        for row in rows {
            for key in keys(row) {
                var entry = table[key] ?? (0, 0, 0)
                entry.total += row.shareMinorUnits
                entry.pending += row.pendingMinorUnits
                entry.count += 1
                table[key] = entry
            }
        }
        return table.map { AnalysisGroup(key: $0.key, totalMinorUnits: $0.value.total, pendingMinorUnits: $0.value.pending, count: $0.value.count) }
    }

    /// Activities with spending in the period. Occurrences with the same normalized title are one repeating activity.
    public static func byActivity(_ transactions: [AnalysisTransaction], in period: AnalysisPeriod) -> [ActivityGroup] {
        var perActivity: [ActivityID: (title: String, gathering: Bool, total: Int64)] = [:]
        for row in inPeriod(transactions, period) {
            guard let activity = row.activity else { continue }
            var entry = perActivity[activity.id] ?? (activity.title.trimmingCharacters(in: .whitespaces), activity.isGathering, 0)
            entry.total += row.shareMinorUnits
            perActivity[activity.id] = entry
        }
        var series: [String: (title: String, gathering: Bool, count: Int, total: Int64)] = [:]
        for entry in perActivity.values {
            let key = RecurringDetector.normalize(entry.title)
            var row = series[key] ?? (entry.title, entry.gathering, 0, 0)
            row.count += 1
            row.total += entry.total
            row.gathering = row.gathering || entry.gathering
            series[key] = row
        }
        return series.map { ActivityGroup(title: $0.value.title, occurrences: $0.value.count, totalMinorUnits: $0.value.total, isGathering: $0.value.gathering) }
            .sorted { ($0.totalMinorUnits, $1.title) > ($1.totalMinorUnits, $0.title) }
    }

    public static func gatherings(_ transactions: [AnalysisTransaction], in period: AnalysisPeriod) -> GatheringSummary {
        var perActivity: [ActivityID: (head: Int, total: Int64)] = [:]
        for row in inPeriod(transactions, period) {
            guard let activity = row.activity, activity.isGathering else { continue }
            perActivity[activity.id, default: (activity.headcount, 0)].total += row.shareMinorUnits
        }
        let total = perActivity.values.reduce(Int64(0)) { $0 + $1.total }
        let people = perActivity.values.reduce(0) { $0 + $1.head }
        return GatheringSummary(
            count: perActivity.count, totalMinorUnits: total, perGatheringMinorUnits: perActivity.isEmpty ? 0 : total / Int64(perActivity.count),
            perPersonMinorUnits: people == 0 ? 0 : total / Int64(people)
        )
    }

    /// `excluding`: the user's own person id, so they do not appear as their own companion.
    public static func byPerson(_ transactions: [AnalysisTransaction], in period: AnalysisPeriod, excluding me: PersonID? = nil) -> [PersonGroup] {
        var perActivity: [ActivityID: (people: [PersonID], total: Int64)] = [:]
        for row in inPeriod(transactions, period) {
            guard let activity = row.activity else { continue }
            perActivity[activity.id, default: (activity.participants, 0)].total += row.shareMinorUnits
        }
        var table: [PersonID: (count: Int, total: Int64)] = [:]
        for entry in perActivity.values {
            for person in Set(entry.people) where person != me {
                table[person, default: (0, 0)].count += 1
                table[person, default: (0, 0)].total += entry.total
            }
        }
        return table.map { PersonGroup(personID: $0.key, activityCount: $0.value.count, totalMinorUnits: $0.value.total) }
            .sorted { ($0.totalMinorUnits, $1.personID) > ($1.totalMinorUnits, $0.personID) }
    }

    /// This period so far against the same number of days of the period `months` earlier (default last month).
    public static func versusEarlier(
        _ transactions: [AnalysisTransaction], period: AnalysisPeriod, through: LocalDate, months: Int = -1
    ) throws -> (current: Int64, earlier: Int64) {
        let end = min(through, period.last)
        let elapsed = end.daysSinceUnixEpoch - period.first.daysSinceUnixEpoch
        let earlierPeriod = try period.shifted(byMonths: months)
        let earlierEnd = min(earlierPeriod.first.adding(days: elapsed), earlierPeriod.last)
        func sum(_ range: AnalysisPeriod) -> Int64 { inPeriod(transactions, range).reduce(0) { $0 + $1.shareMinorUnits } }
        return (sum(AnalysisPeriod(first: period.first, last: end)), sum(AnalysisPeriod(first: earlierPeriod.first, last: earlierEnd)))
    }
}
