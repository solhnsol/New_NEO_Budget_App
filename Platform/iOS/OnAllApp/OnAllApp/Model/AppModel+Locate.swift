import NEOBudgetCalendar

extension AppModel {
    /// An event and the day it is on: among the two days on screen first, then every day kept. The fixed grid can open a sheet on a day other
    /// than those two, and a reload can briefly empty them; looking only there would show "일정을 찾을 수 없어요" in the event's sheets.
    func locate(_ key: CalendarEventKey) -> (block: EventBlock, timeline: DayTimeline)? {
        let kept = cachedDays.sorted().compactMap { cachedTimeline(for: $0) }
        for day in visibleTimelines + kept {
            if let block = day.blocks.first(where: { $0.eventKey == key }) { return (block, day) }
        }
        return nil
    }
}
