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
        /// How far apart rows that share a minute are drawn (a row and the gap to the next): the axis makes room for the stack.
        public var stackStep = 38.0
        /// Room under a past event's start for its name (it stands beside the rail there, 22 high) plus half a row, since the next row is centred on its key.
        public var nameRoom = 40.0
        /// A past event's name is this high; a row at the very minute the event began is drawn under it (`nameHeight` below its start).
        public var nameHeight = 22.0
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
            // The name of an event that has begun sits under its start: nothing else may be drawn in that room. (The event that is going on now
            // keeps its true proportion instead, below: its name has the room the rest of its stretch has.)
            if !event.isCard, !(now.map { event.start <= $0 && $0 < event.end } ?? false) { add(event.start + 1, needs.nameRoom) }
        }
        for minute in transactions { add(minute, needs.transaction) }
        // Rows at the very minute a past event began stand under its name: the minute that follows is that far away.
        for event in events where !event.isCard {
            let count = transactions.filter { $0 == event.start }.count
            if count > 0 { add(event.start + 1, needs.nameHeight + Double(count) * needs.stackStep) }
        }
        // Rows that share a minute are stacked; the axis grows by the stack (the design: the time axis is stretched, not the rows moved).
        for (minute, count) in Dictionary(grouping: transactions, by: { $0 }).mapValues(\.count) where count > 1 {
            add(minute + 1, Double(count - 1) * needs.stackStep)
        }
        if let now { add(now, needs.other) }
        func layout() -> (keys: [Int], ys: [Double]) {
            let sorted = need.keys.sorted()
            var ys = [0.0]
            for index in sorted.indices.dropFirst() {
                let gap = Double(sorted[index] - sorted[index - 1])
                ys.append(ys[index - 1] + max(need[sorted[index]] ?? 0, gap * needs.emptyPointsPerMinute))
            }
            return (sorted, ys)
        }
        // The event that is going on now keeps its true proportion: the time since it began and the time left are drawn at the same points per
        // minute (the longer-stretched side sets it), so the now-line reads how far along the event is.
        if let now, let running = events.first(where: { !$0.isCard && $0.start <= now && now < $0.end }),
           running.start >= firstMinute, running.end <= lastMinute {
            add(running.start, 0); add(running.end, 0)
            let natural = layout()
            func at(_ minute: Int) -> Double {
                let upper = natural.keys.firstIndex { $0 >= minute } ?? natural.keys.count - 1
                return natural.ys[upper]
            }
            let (done, left) = (at(now) - at(running.start), at(running.end) - at(now))
            let scale = max(needs.emptyPointsPerMinute, done / Double(max(1, now - running.start)), left / Double(max(1, running.end - now)))
            if done < scale * Double(now - running.start) { need[now] = (need[now] ?? 0) + scale * Double(now - running.start) - done }
            if left < scale * Double(running.end - now) { need[running.end] = (need[running.end] ?? 0) + scale * Double(running.end - now) - left }
        }
        let (sorted, ys) = layout()
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

    /// The minute at a height (the inverse of `y`): what a finger held at that point on the rail means. Held at the ends of the range.
    public func minute(atY y: Double) -> Int {
        if y <= 0 { return keys[0] }
        if y >= ys[ys.count - 1] { return keys[keys.count - 1] }
        var upper = 1
        while ys[upper] < y { upper += 1 }
        let span = ys[upper] - ys[upper - 1]
        guard span > 0 else { return keys[upper - 1] }
        return keys[upper - 1] + Int(((y - ys[upper - 1]) / span * Double(keys[upper] - keys[upper - 1])).rounded())
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
