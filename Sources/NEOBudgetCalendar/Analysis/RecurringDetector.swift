// Finds spending that repeats on a fixed cycle (rent, phone, subscriptions) and keeps the user's yes/no on it.
// Only a fixed cycle counts. A café visited often on varying days is a habit, not a recurring expense.
// Detection only suggests; a suggestion counts as recurring in analysis once the user confirms it.

public enum RecurringCycle: String, Codable, Sendable {
    case weekly, biweekly, monthly, yearly

    /// How many of these fit in a month, for "월 환산 고정비".
    var perMonth: Double {
        switch self {
        case .weekly: return 52.0 / 12
        case .biweekly: return 26.0 / 12
        case .monthly: return 1
        case .yearly: return 1.0 / 12
        }
    }
}

public struct RecurringInput: Equatable, Sendable {
    public let id: String
    public let name: String
    public let date: LocalDate
    public let amountMinorUnits: Int64

    public init(id: String, name: String, date: LocalDate, amountMinorUnits: Int64) {
        self.id = id
        self.name = name
        self.date = date
        self.amountMinorUnits = amountMinorUnits
    }
}

/// A repeating expense: its name key, its cycle and the usual amount. Matches later transactions by name and a similar amount.
public struct RecurringSeries: Codable, Equatable, Sendable {
    public let key: String
    public var displayName: String
    public let cycle: RecurringCycle
    public let expectedMinorUnits: Int64
    /// `true` when the amount varies a little from time to time (utilities), `false` when it is the same each time.
    public let isVariableAmount: Bool
    public let lastDate: LocalDate
    public let transactionIDs: [String]

    /// Approximate: last date plus the cycle's usual length (a month is the same day of next month, clamped).
    public var nextDue: LocalDate {
        switch cycle {
        case .weekly: return lastDate.adding(days: 7)
        case .biweekly: return lastDate.adding(days: 14)
        case .monthly, .yearly:
            let months = cycle == .monthly ? 1 : 12
            let index = lastDate.year * 12 + (lastDate.month - 1) + months
            let year = index / 12, month = index % 12 + 1
            let day = min(lastDate.day, LocalDate.daysInMonth(year: year, month: month))
            return (try? LocalDate(year: year, month: month, day: day)) ?? lastDate.adding(days: 30)
        }
    }

    public var perMonthMinorUnits: Int64 { Int64((Double(expectedMinorUnits) * cycle.perMonth).rounded()) }

    func matches(name: String, amountMinorUnits: Int64) -> Bool {
        RecurringDetector.normalize(name) == key && RecurringDetector.sameAmountGroup(amountMinorUnits, expectedMinorUnits)
    }
}

/// What the user decided, saved as one small file. Detection results are never saved, only these answers.
public struct RecurringDecisions: Codable, Equatable, Sendable {
    public var confirmed: [RecurringSeries] = []
    public var dismissedKeys: Set<String> = []
    /// Per transaction: `true` = recurring, `false` = not, whatever the series says.
    public var overrides: [String: Bool] = [:]

    public init(confirmed: [RecurringSeries] = [], dismissedKeys: Set<String> = [], overrides: [String: Bool] = [:]) {
        self.confirmed = confirmed
        self.dismissedKeys = dismissedKeys
        self.overrides = overrides
    }

    public mutating func confirm(_ series: RecurringSeries) {
        dismissedKeys.remove(series.key)
        confirmed.removeAll { $0.key == series.key && $0.cycle == series.cycle }
        confirmed.append(series)
    }

    public mutating func dismiss(_ series: RecurringSeries) {
        confirmed.removeAll { $0.key == series.key }
        dismissedKeys.insert(series.key)
    }

    public func isRecurring(id: String, name: String, amountMinorUnits: Int64) -> Bool {
        if let own = overrides[id] { return own }
        return confirmed.contains { $0.matches(name: name, amountMinorUnits: amountMinorUnits) }
    }

    /// Fixed costs per month from the confirmed series.
    public var perMonthMinorUnits: Int64 { confirmed.reduce(0) { $0 + $1.perMonthMinorUnits } }
}

public enum RecurringDetector {
    /// Names that suggest a subscription or fixed bill; they need only two occurrences.
    static let hints = ["구독", "통신", "보험", "관리비", "월세", "넷플릭스", "유튜브", "멜론", "스포티파이", "쿠팡와우", "요금", "학원", "정기"]

    /// Lowercased with spaces, digits and punctuation removed, so "넷플릭스 1234" and "넷플릭스" are one name.
    public static func normalize(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter })
    }

    /// Amounts within a factor of 1.6 of each other belong to one series (a bill that varies a little).
    static func sameAmountGroup(_ a: Int64, _ b: Int64) -> Bool {
        let low = min(a, b), high = max(a, b)
        return low > 0 && Double(high) <= Double(low) * 1.6
    }

    /// Suggestions for repeating expenses, skipping series the user already decided on. Oldest data first is not required.
    public static func suggestions(_ inputs: [RecurringInput], decisions: RecurringDecisions = RecurringDecisions()) -> [RecurringSeries] {
        var byName: [String: [RecurringInput]] = [:]
        for input in inputs where input.amountMinorUnits > 0 {
            let key = normalize(input.name)
            if !key.isEmpty, !decisions.dismissedKeys.contains(key) { byName[key, default: []].append(input) }
        }
        var found: [RecurringSeries] = []
        for (key, rows) in byName {
            for cluster in amountClusters(rows) {
                guard let series = series(key: key, rows: cluster), !decisions.confirmed.contains(where: { $0.key == key && $0.cycle == series.cycle && sameAmountGroup($0.expectedMinorUnits, series.expectedMinorUnits) }) else { continue }
                found.append(series)
            }
        }
        return found.sorted { ($0.perMonthMinorUnits, $1.key) > ($1.perMonthMinorUnits, $0.key) }
    }

    private static func amountClusters(_ rows: [RecurringInput]) -> [[RecurringInput]] {
        var clusters: [[RecurringInput]] = []
        for row in rows.sorted(by: { $0.amountMinorUnits < $1.amountMinorUnits }) {
            if let lowest = clusters.last?.first?.amountMinorUnits, sameAmountGroup(lowest, row.amountMinorUnits) {
                clusters[clusters.count - 1].append(row)
            } else {
                clusters.append([row])
            }
        }
        return clusters
    }

    private static func series(key: String, rows: [RecurringInput]) -> RecurringSeries? {
        let rows = rows.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        let hinted = hints.contains { key.contains(normalize($0)) }
        guard rows.count >= 2 else { return nil }
        let gaps = zip(rows, rows.dropFirst()).map { $1.date.daysSinceUnixEpoch - $0.date.daysSinceUnixEpoch }
        guard gaps.allSatisfy({ $0 >= 5 }) else { return nil }   // several in one week is a habit, not a cycle
        let ordered = gaps.sorted()
        let median = ordered[ordered.count / 2]
        let cycle: RecurringCycle, range: ClosedRange<Int>
        switch median {
        case 6...8: (cycle, range) = (.weekly, 6...8)
        case 12...16: (cycle, range) = (.biweekly, 12...16)
        case 27...34: (cycle, range) = (.monthly, 27...34)
        case 355...375: (cycle, range) = (.yearly, 355...375)
        default: return nil
        }
        let minimum = (cycle == .yearly || hinted) ? 2 : 3
        guard rows.count >= minimum else { return nil }
        // A missed month shows as a gap of two cycles; it still counts as on time.
        let onTime = gaps.filter { range.contains($0) || range.contains($0 / 2) && $0 % 2 <= 1 }.count
        guard Double(onTime) / Double(gaps.count) >= 0.75 else { return nil }
        let amounts = rows.map { Double($0.amountMinorUnits) }
        let mean = amounts.reduce(0, +) / Double(amounts.count)
        let deviation = (amounts.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(amounts.count)).squareRoot()
        guard deviation / mean <= 0.35 else { return nil }
        let sortedAmounts = rows.map(\.amountMinorUnits).sorted()
        return RecurringSeries(
            key: key, displayName: rows.last?.name ?? key, cycle: cycle, expectedMinorUnits: sortedAmounts[sortedAmounts.count / 2],
            isVariableAmount: deviation / mean > 0.10, lastDate: rows[rows.count - 1].date, transactionIDs: rows.map(\.id)
        )
    }
}
