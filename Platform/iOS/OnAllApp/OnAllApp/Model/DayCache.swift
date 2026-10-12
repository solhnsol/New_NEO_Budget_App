import NEOBudgetCalendar

/// Which days the app keeps read, and which it reads. One place, so the numbers are not scattered.
///
/// - **Required**: the days the screen draws or plans for around the first day on screen `D`: `D-1 ... D+2` (the day before, the two shown, the day after).
///   They are always present after a read.
/// - **Retained**: the required days and `margin` more on each side. A day that is already read and falls in this window is kept, not read again and not
///   dropped when `D` moves by a day or two or goes back again. A window of this size follows `D` as it moves.
/// - **Capacity**: no more than this many days are ever kept after an eviction (the retained window is smaller; the room above it is for days read ahead of a far
///   jump, which `insert` takes in without evicting until the move has landed).
///
/// Eviction happens only when the window moves (`merge`) and removes what is outside the retained window, then, if still over capacity, the days farthest from `D`.
/// A read of the calendar that means "something changed" (`replaceAll`) keeps exactly the days it read: whatever else was kept may be stale.
struct DayCachePolicy: Equatable {
    var before = 1
    var after = 2
    var margin = 2
    var capacity = 12

    static let standard = DayCachePolicy()

    func required(around day: LocalDate) -> [LocalDate] { (-before...after).map { day.adding(days: $0) } }

    func retained(around day: LocalDate) -> Set<LocalDate> { Set((-(before + margin)...(after + margin)).map { day.adding(days: $0) }) }
}

struct DayCache: Equatable {
    private(set) var timelines: [LocalDate: DayTimeline] = [:]

    subscript(day: LocalDate) -> DayTimeline? { timelines[day] }
    var days: Set<LocalDate> { Set(timelines.keys) }
    var count: Int { timelines.count }

    /// What was read, and nothing else: the calendar changed, so no other day can be trusted.
    mutating func replaceAll(with loaded: [LocalDate: DayTimeline]) { timelines = loaded }

    /// A day read ahead of a far jump. Nothing is evicted.
    mutating func insert(_ timeline: DayTimeline) { timelines[timeline.day] = timeline }

    /// Days just read are added (or replace the same day); then what the window no longer covers is dropped.
    mutating func merge(_ loaded: [LocalDate: DayTimeline], around day: LocalDate, policy: DayCachePolicy = .standard, protecting: Set<LocalDate> = []) {
        for (key, timeline) in loaded { timelines[key] = timeline }
        evict(around: day, policy: policy, protecting: protecting)
    }

    /// `protecting`: days that stay whatever the window says (the days on screen while the window is somewhere else, ahead of a move).
    mutating func evict(around day: LocalDate, policy: DayCachePolicy = .standard, protecting: Set<LocalDate> = []) {
        let keep = policy.retained(around: day).union(protecting)
        for key in timelines.keys where !keep.contains(key) { timelines[key] = nil }
        if timelines.count > policy.capacity {
            let farthest = timelines.keys.filter { !protecting.contains($0) }.sorted { abs($0.daysSinceUnixEpoch - day.daysSinceUnixEpoch) > abs($1.daysSinceUnixEpoch - day.daysSinceUnixEpoch) }
            for key in farthest.prefix(timelines.count - policy.capacity) { timelines[key] = nil }
        }
    }

    /// The required days (and `extra` more each side, never more than the margin) that are not here yet, in the order they are needed: nearest first.
    func missing(around day: LocalDate, policy: DayCachePolicy = .standard, extra: Int = 0) -> [LocalDate] {
        let reach = min(max(extra, 0), policy.margin)
        let wanted = (-(policy.before + reach)...(policy.after + reach)).map { day.adding(days: $0) }
        return wanted.filter { timelines[$0] == nil }.sorted { abs($0.daysSinceUnixEpoch - day.daysSinceUnixEpoch) < abs($1.daysSinceUnixEpoch - day.daysSinceUnixEpoch) }
    }
}
