import NEOBudgetCalendar

/// The original an edit session is made against: taken when the session opens (`FixedGridBrowseModel.freeze`), never updated during it. Whatever is read
/// later is compared with it to tell what changed outside the session — a calendar change (`reload`, a new data generation), a day whose content changed, the
/// chosen event itself changed or gone. Saving and resolving a conflict are not here: this only says that one exists and where.
///
/// The boundary:
/// - `dataGeneration` (`AppModel.dataGeneration`): moves only when the calendar may have changed. A session that sees it move must treat everything it read as
///   possibly stale, even days that compare equal (they may be read again).
/// - `dataRevision` (`AppModel.dataRevision`): moves whenever a kept day is added, replaced or dropped — a read landing, an eviction. While it has not moved,
///   nothing is compared.
/// - the days (`days`): the timelines of the windows on screen at the start, as they were. A day not kept any more is `unknown`, not changed.
/// - the target: the chosen event by its calendar key, with its revision token and its time as the session started.
struct FixedGridEditBaseline: Equatable {
    struct Target: Equatable {
        let day: LocalDate
        let blockID: BlockID
        let eventKey: CalendarEventKey
        let revisionToken: String?
        let startMinute: Int
        let endMinute: Int
    }

    let dataGeneration: Int
    let dataRevision: Int
    let days: [LocalDate: DayTimeline]
    let target: Target?

    init(dataGeneration: Int, dataRevision: Int, days: [LocalDate: DayTimeline], target: (day: LocalDate, block: EventBlock)?) {
        self.dataGeneration = dataGeneration
        self.dataRevision = dataRevision
        self.days = days
        self.target = target.map {
            Target(day: $0.day, blockID: $0.block.id, eventKey: $0.block.eventKey, revisionToken: $0.block.revisionToken, startMinute: $0.block.startMinute, endMinute: $0.block.endMinute)
        }
    }

    enum TargetState: Equatable { case none, unchanged, changed, gone, unknown }

    struct Changes: Equatable {
        /// The calendar may have changed since the session began (a reload).
        var reloaded = false
        var changedDays: Set<LocalDate> = []
        /// Days of the original that are not kept now (evicted): not known to have changed.
        var unknownDays: Set<LocalDate> = []
        var target: TargetState = .none

        var isClean: Bool { !reloaded && changedDays.isEmpty && (target == .none || target == .unchanged) }
    }

    /// What differs now from the original. Cheap while nothing moved (`dataGeneration` and `dataRevision` as they were); otherwise it compares the days.
    func changes(dataGeneration: Int, dataRevision: Int, timelineFor: (LocalDate) -> DayTimeline?) -> Changes {
        var result = Changes()
        result.target = target == nil ? .none : .unchanged
        guard dataGeneration != self.dataGeneration || dataRevision != self.dataRevision else { return result }
        result.reloaded = dataGeneration != self.dataGeneration
        for (day, original) in days {
            guard let now = timelineFor(day) else { result.unknownDays.insert(day); continue }
            if now != original { result.changedDays.insert(day) }
        }
        if let target {
            guard let now = timelineFor(target.day) else { result.target = .unknown; return result }
            // Matched by the calendar's key (the block id is the timeline's own and may be rebuilt); a series' occurrence keeps its key per occurrence.
            if let block = now.blocks.first(where: { $0.eventKey == target.eventKey }) {
                let same = block.revisionToken == target.revisionToken && block.startMinute == target.startMinute && block.endMinute == target.endMinute
                result.target = same ? .unchanged : .changed
            } else {
                result.target = .gone
            }
        }
        return result
    }
}
