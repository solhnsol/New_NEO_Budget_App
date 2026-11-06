import Foundation

/// How the minutes of one local day (elapsed since the day's start, which is what `DayTimeline` and every event block use) relate to the
/// **wall clock** of that day (0:00 ... 24:00 on the clock on the wall). They are the same on an ordinary day. On a daylight-saving day they are not:
///
/// - **spring forward** (23 hours): the wall hour that does not exist (`skippedWall`, e.g. 02:00-03:00) has no instants. Elapsed minute 120 is
///   wall minute 180.
/// - **fall back** (25 hours): one wall hour happens twice (`repeatedWall`, e.g. 01:00-02:00). Two different elapsed minutes have the same wall minute.
///
/// This type only *maps*; it never changes an instant. Events and transactions keep their absolute times and their identity; what is decided here is where a
/// time sits on an axis that is drawn in wall-clock hours (the fixed grid, which has 24 labelled hours every day and the same hour at the same height on two
/// neighbouring days). The rules, the same ones `DisplayTimeZone.instant(of:minuteOfDay:)` already uses to go from the clock to an instant:
///
/// 1. **Instant → wall** (`wallMinute(forElapsed:)`): the clock reading at that instant. Never ambiguous. The end of the day is wall minute 1440.
/// 2. **Wall → instant** (`elapsedMinute(forWall:)`): a time inside the skipped hour is the next real instant after the gap; a time inside the repeated hour is its
///    **first** occurrence. So the second occurrence of the repeated hour cannot be named from the wall axis (nothing can be dragged *onto* it).
/// 3. **A span** (`wallRange(startElapsed:endElapsed:)`): from the wall minute of its start to the end of the last minute it covers, but never above the highest wall
///    minute it reaches. Inside the repeated hour, spans that lie in the second occurrence are drawn over the same wall minutes as the first (they overlap each other
///    on the axis, as two events at the same clock time would). A span across the gap covers the gap. A span across the fold ends at the end of the first occurrence
///    at the latest (its real duration is not drawn).
/// 4. Everything is clamped to the day: a span that continues past either end is drawn to the edge.
public struct DayWallClock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case regular, springForward, fallBack }

    public static let wallMinutesPerDay = 24 * 60

    public let totalMinutes: Int
    public let kind: Kind
    /// Wall minutes that do not exist on this day (spring forward), or `nil`.
    public let skippedWall: Range<Int>?
    /// Wall minutes that happen twice (fall back), or `nil`.
    public let repeatedWall: Range<Int>?

    /// The wall minute of each elapsed minute `0..<totalMinutes`. Empty for an ordinary day (identity).
    private let wallAtElapsed: [Int]
    /// The first elapsed minute whose wall minute is at least `w`, for `w` in `0...1440`. Empty for an ordinary day.
    private let firstElapsedAtWall: [Int]

    public init(day: LocalDate, zone: DisplayTimeZone) {
        let bounds = zone.dayBounds(day)
        let total = max(0, Int((bounds.end - bounds.start) / 60_000))
        totalMinutes = total
        func wall(_ elapsed: Int) -> Int { zone.minuteOfDay(of: bounds.start + Int64(elapsed) * 60_000) }
        // A day of the usual length whose first and last minute are where an ordinary day's are has no transition in it.
        if total == Self.wallMinutesPerDay, total > 0, wall(0) == 0, wall(total - 1) == total - 1, wall(total / 2) == total / 2 {
            kind = .regular; skippedWall = nil; repeatedWall = nil; wallAtElapsed = []; firstElapsedAtWall = []
            return
        }
        let table = (0..<total).map(wall)
        var skipped: Range<Int>?
        var repeated: Range<Int>?
        for index in 0..<max(0, total - 1) {
            let step = table[index + 1] - table[index]
            if step > 1, skipped == nil { skipped = (table[index] + 1)..<table[index + 1] }
            if step < 1, repeated == nil { repeated = table[index + 1]..<(table[index] + 1) }
        }
        var first = [Int](repeating: total, count: Self.wallMinutesPerDay + 1)
        var filled = 0                                               // wall minutes below `filled` already have their first elapsed minute
        for (elapsed, w) in table.enumerated() where w + 1 > filled {
            for target in filled...(w) { first[target] = elapsed }
            filled = w + 1
        }
        skippedWall = skipped
        repeatedWall = repeated
        kind = repeated != nil ? .fallBack : (skipped != nil ? .springForward : .regular)
        wallAtElapsed = table
        firstElapsedAtWall = first
    }

    private var isIdentity: Bool { wallAtElapsed.isEmpty }

    /// 1. The wall minute (0...1440) at elapsed minute `elapsed`; the end of the day (and anything after it) is 1440.
    public func wallMinute(forElapsed elapsed: Int) -> Int {
        if elapsed <= 0 { return 0 }
        if elapsed >= totalMinutes { return Self.wallMinutesPerDay }
        return isIdentity ? elapsed : wallAtElapsed[elapsed]
    }

    /// 2. The elapsed minute at wall minute `wall`: a skipped time gives the next real minute, a repeated time its first occurrence; 1440 gives the end of the day.
    public func elapsedMinute(forWall wall: Int) -> Int {
        if wall <= 0 { return 0 }
        if wall >= Self.wallMinutesPerDay { return totalMinutes }
        return isIdentity ? wall : firstElapsedAtWall[wall]
    }

    /// The end of the last minute covered by a span that ends at elapsed minute `end` (exclusive), as a wall minute.
    public func exclusiveEndWall(forElapsed end: Int) -> Int {
        if end <= 0 { return 0 }
        if end >= totalMinutes { return Self.wallMinutesPerDay }
        return wallMinute(forElapsed: end - 1) + 1
    }

    /// 3. Where a span `[startElapsed, endElapsed)` is on the wall-clock axis, as `top <= bottom` wall minutes (a point has `top == bottom`).
    public func wallRange(startElapsed: Int, endElapsed: Int) -> (top: Int, bottom: Int) {
        let start = min(max(startElapsed, 0), totalMinutes)
        let end = min(max(endElapsed, start), totalMinutes)
        let top = wallMinute(forElapsed: start)
        guard end > start else { return (top, top) }
        if isIdentity { return (top, end) }
        var bottom = top
        for elapsed in start..<end { bottom = max(bottom, wallAtElapsed[elapsed] + 1) }
        return (top, bottom)
    }
}
