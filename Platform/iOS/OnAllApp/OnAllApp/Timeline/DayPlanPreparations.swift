import NEOBudgetCalendar

/// Keeps the prepared (static) part of each day's layout, so a frame only places it. An entry is found by what it was made from: the day's data, its role and the
/// engine's layout. Any of them changing finds nothing and prepares again; nothing else (the axis, the zoom, the text size, the focus) takes part.
/// A small number of days are kept, the oldest unused first out. Not thread-safe: it lives with the view that draws.
final class DayPlanPreparations {
    private struct Entry {
        let timeline: DayTimeline
        let role: DayRole?
        let layout: AdaptiveLayout?
        let prepared: DayRenderPlan.Prepared
    }

    let limit: Int
    private var entries: [Entry] = []
    /// How many times a day was prepared, and how many times one was found. For tests and diagnostics.
    private(set) var preparations = 0
    private(set) var hits = 0

    init(limit: Int = 8) { self.limit = max(1, limit) }

    var count: Int { entries.count }

    func prepared(timeline: DayTimeline, role: DayRole?, layout: AdaptiveLayout?) -> DayRenderPlan.Prepared {
        if let index = entries.firstIndex(where: { $0.role == role && $0.timeline == timeline && $0.layout == layout }) {
            hits += 1
            let found = entries.remove(at: index)
            entries.append(found)                            // most recently used last
            return found.prepared
        }
        preparations += 1
        let made = DayRenderPlan.Prepared(timeline: timeline, role: role, layout: layout)
        entries.append(Entry(timeline: timeline, role: role, layout: layout, prepared: made))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        return made
    }
}
