import Foundation

/// The day view's vertical axis for the rail timeline (design cal-v7 "자동"): minutes are mapped to points piecewise-linearly, and every minute that
/// something sits on (a transaction, an event's start or end, the now line) gets at least the room that thing needs. Empty hours shrink to
/// `emptyPointsPerMinute`, so the day stays short while nothing overlaps. Pure, so it is tested; `DaySection` draws on it.
public struct RailAxis: Equatable, Sendable {
    public struct Event: Equatable, Sendable {
        public let start: Int
        public let end: Int
        /// Still to come: drawn as a card (needs room for its height) instead of a bar on the rail.
        public let isCard: Bool
        public init(start: Int, end: Int, isCard: Bool) { (self.start, self.end, self.isCard) = (start, end, isCard) }
    }

    /// Room (points) at least needed from the previous key up to a transaction, a past event's start, a card's end, and any other key.
    public struct Needs: Equatable, Sendable {
        public var transaction = 46.0
        public var pastEventStart = 28.0
        public var cardEnd = 56.0
        public var other = 14.0
        /// Row pitch for transactions sharing one minute: that minute is stretched on the axis so each gets its own place inside it.
        public var sameMinutePitch = 28.0
        /// Points per minute where nothing needs more room.
        public var emptyPointsPerMinute = 0.35
        public init() {}
    }

    public let firstMinute: Int
    public let lastMinute: Int
    private let keys: [Int]
    private let ys: [Double]

    public var height: Double { ys.last ?? 0 }

    public init(events: [Event], transactions: [Int], now: Int?, firstMinute: Int, lastMinute: Int, needs: Needs = Needs()) {
        precondition(lastMinute > firstMinute)
        var need: [Int: Double] = [:]
        func add(_ minute: Int, _ points: Double) {
            guard minute >= firstMinute, minute <= lastMinute else { return }
            need[minute] = max(need[minute] ?? 0, points)
        }
        add(firstMinute, 0)
        add(lastMinute, 0)
        for event in events {
            add(event.start, event.isCard ? needs.other : needs.pastEventStart)
            add(event.end, event.isCard ? needs.cardEnd : needs.other)
        }
        for minute in transactions { add(minute, needs.transaction) }
        // k transactions in one minute stretch that minute (not the dots): the next key sits (k-1) pitches further on.
        for (minute, count) in Dictionary(transactions.map { ($0, 1) }, uniquingKeysWith: +) where count > 1 {
            add(minute + 1, Double(count - 1) * needs.sameMinutePitch + needs.transaction)
        }
        if let now { add(now, needs.other) }
        let sorted = need.keys.sorted()
        var ys = [0.0]
        for index in sorted.indices.dropFirst() {
            let gap = Double(sorted[index] - sorted[index - 1])
            ys.append(ys[index - 1] + max(need[sorted[index]] ?? 0, gap * needs.emptyPointsPerMinute))
        }
        (self.firstMinute, self.lastMinute, keys, self.ys) = (firstMinute, lastMinute, sorted, ys)
    }

    /// Where a minute sits, in points from the top; minutes outside the range are held at its ends.
    public func y(_ minute: Int) -> Double {
        if minute <= keys[0] { return 0 }
        if minute >= keys[keys.count - 1] { return ys[ys.count - 1] }
        var upper = 1
        while keys[upper] < minute { upper += 1 }
        let (k0, k1) = (keys[upper - 1], keys[upper])
        return ys[upper - 1] + (ys[upper] - ys[upper - 1]) * Double(minute - k0) / Double(k1 - k0)
    }

    /// The whole hours to label: one per hour in range, dropping a label closer than `minimumGap` to the one before it, or to `avoiding`
    /// (the now line's label).
    public func hourMarks(minimumGap: Double = 16, avoiding minute: Int? = nil) -> [(hour: Int, y: Double)] {
        var marks: [(hour: Int, y: Double)] = []
        var last = -Double.infinity
        for hour in Int((Double(firstMinute) / 60).rounded(.up))...min(lastMinute / 60, 23) {
            let y = y(hour * 60)
            if let minute, abs(y - self.y(minute)) < 14 { continue }
            if y - last < minimumGap && hour * 60 != firstMinute { continue }
            last = y
            marks.append((hour, y))
        }
        return marks
    }

    /// The whole hours the day's content spans, with an hour of air around it; 9–18 when the day is empty. `minutes` are everything that sits on the axis.
    public static func hourRange(covering minutes: [Int], totalMinutes: Int = 1440) -> (first: Int, last: Int) {
        guard let low = minutes.min(), let high = minutes.max() else { return (9 * 60, 18 * 60) }
        let first = max(0, low / 60 * 60 - 60)
        var last = min(totalMinutes / 60 * 60, (high + 59) / 60 * 60 + 60)
        if last <= first { last = first + 60 }
        return (first, last)
    }
}
