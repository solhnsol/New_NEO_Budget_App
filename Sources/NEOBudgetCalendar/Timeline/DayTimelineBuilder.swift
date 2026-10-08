import NEOBudgetCore

public struct DayTimelineInput: Sendable {
    public let day: LocalDate
    public let timeZone: DisplayTimeZone
    public let calendars: [CalendarDescriptor]
    /// Events the provider returned for the day. Events outside the day are ignored.
    public let events: [CalendarEvent]
    public let life: LifeState
    /// The day's transactions plus any transaction linked to an activity that might be shown.
    public let transactions: [TransactionMarker]
    public let policy: TimelineDisplayPolicy

    public init(
        day: LocalDate,
        timeZone: DisplayTimeZone,
        calendars: [CalendarDescriptor] = [],
        events: [CalendarEvent],
        life: LifeState,
        transactions: [TransactionMarker],
        policy: TimelineDisplayPolicy = .standard
    ) {
        self.day = day
        self.timeZone = timeZone
        self.calendars = calendars
        self.events = events
        self.life = life
        self.transactions = transactions
        self.policy = policy
    }
}

/// Builds the one-day timeline read model. A pure function of its input: no clock, no I/O, no platform types,
/// and the output order is fully determined by the data.
public enum DayTimelineBuilder {
    public static func build(_ input: DayTimelineInput) -> DayTimeline {
        let bounds = input.timeZone.dayBounds(input.day)
        let totalMinutes = Int((bounds.end - bounds.start) / 60_000)
        let calendarsByID = Dictionary(input.calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let activitiesByEvent = input.life.activitiesByEvent()
        let transactionsByID = Dictionary(input.transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var presentKeys = Set<CalendarEventKey>()
        var timed: [TimedCandidate] = []
        var allDay: [AllDayCandidate] = []

        for event in input.events {
            presentKeys.insert(event.key)
            let calendar = calendarsByID[event.calendarID]
            let activity = activitiesByEvent[event.key]
            switch event.time {
            case let .timed(range):
                guard range.overlaps(from: bounds.start, to: bounds.end) else { continue }
                timed.append(TimedCandidate(
                    key: event.key, calendar: calendar, title: event.title, range: range, activity: activity,
                    isRecurringInstance: event.isRecurringInstance, isEditable: event.isEditable,
                    revisionToken: event.revisionToken, state: .normal
                ))
            case let .allDay(range):
                guard range.contains(input.day) else { continue }
                allDay.append(AllDayCandidate(
                    key: event.key, calendar: calendar, title: event.title, range: range, activity: activity,
                    isEditable: event.isEditable, revisionToken: event.revisionToken, state: .normal
                ))
            }
        }

        if input.policy.includeMissingEventGhosts {
            for activity in input.life.activities.values {
                guard let association = activity.association, association.isMissing, !presentKeys.contains(association.key) else { continue }
                let calendar = calendarsByID[association.key.calendarID]
                switch association.lastKnown.time {
                case let .timed(range):
                    guard range.overlaps(from: bounds.start, to: bounds.end) else { continue }
                    timed.append(TimedCandidate(
                        key: association.key, calendar: calendar, title: association.lastKnown.title, range: range,
                        activity: activity, isRecurringInstance: false, isEditable: false, revisionToken: nil, state: .eventMissing
                    ))
                case let .allDay(range):
                    guard range.contains(input.day) else { continue }
                    allDay.append(AllDayCandidate(
                        key: association.key, calendar: calendar, title: association.lastKnown.title, range: range,
                        activity: activity, isEditable: false, revisionToken: nil, state: .eventMissing
                    ))
                }
            }
        }

        func allocationItems(for activity: Activity?) -> [AllocationItem] {
            guard let activity else { return [] }
            return input.life.allocations(forActivity: activity.id).compactMap { allocation in
                guard let marker = transactionsByID[allocation.transactionID] else { return nil }
                let wholeTransaction = allocation.amount.knowledge.knownValue == marker.amount.minorUnits
                return AllocationItem(
                    allocationID: allocation.id,
                    transactionID: marker.id,
                    title: marker.title,
                    transactionAmount: marker.amount,
                    flow: marker.flow,
                    occurredAtUnixMilliseconds: marker.occurredAtUnixMilliseconds,
                    timePrecision: marker.timePrecision,
                    occursOnSelectedDay: marker.occurredAtUnixMilliseconds >= bounds.start && marker.occurredAtUnixMilliseconds < bounds.end,
                    allocatedAmount: allocation.amount.knowledge,
                    isPartOfTransaction: !wholeTransaction,
                    source: allocation.provenance.source
                )
            }
            .sorted { ($0.occurredAtUnixMilliseconds, $0.allocationID) < ($1.occurredAtUnixMilliseconds, $1.allocationID) }
        }

        func aggregates(_ items: [AllocationItem], flow: TransactionFlow) -> [AmountAggregate] {
            AmountAggregate.summarize(items.filter { $0.flow == flow }.map { ($0.transactionAmount.currency, $0.allocatedAmount) })
        }

        func badge(for activity: Activity?) -> ActivityBadge? {
            guard let activity else { return nil }
            return ActivityBadge(
                activityID: activity.id,
                activityType: activity.activityType?.value,
                areaID: activity.area?.value,
                tagIDs: activity.tags.map(\.tagID).sorted(),
                participantIDs: activity.participants.map(\.personID).sorted(),
                openObligationCount: input.life.obligations(forActivity: activity.id).filter { $0.isSettleable }.count,
                display: display(for: activity)
            )
        }

        func display(for activity: Activity) -> ActivityDisplay {
            let life = input.life
            let people = activity.participants.compactMap { life.persons[$0.personID] }
                .sorted { lhs, rhs in
                    if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
                    return (lhs.displayName, lhs.id) < (rhs.displayName, rhs.id)
                }
            return ActivityDisplay(
                typeName: activity.activityType.flatMap { life.activityTypes[$0.value]?.displayName },
                areaName: activity.area.flatMap { life.areaCatalog.areasByID[$0.value]?.displayName },
                participantNames: people.map(\.displayName),
                tagNames: activity.tags.compactMap { life.tags[$0.tagID]?.name }.sorted()
            )
        }

        // Timed blocks: clip to the day, apply the visual floor, then assign overlap columns.
        let minimumVisual = input.policy.minimumVisualDurationMinutes
        var prepared: [PreparedBlock] = timed.map { candidate in
            let clippedStart = max(candidate.range.startUnixMilliseconds, bounds.start)
            let clippedEnd = min(candidate.range.endUnixMilliseconds, bounds.end)
            let startMinute = Int((clippedStart - bounds.start) / 60_000)
            let endMinute = max(startMinute + 1, Int((clippedEnd - bounds.start + 59_999) / 60_000))
            var displayStart = startMinute
            var displayEnd = max(endMinute, startMinute + minimumVisual)
            if displayEnd > totalMinutes {
                displayEnd = totalMinutes
                displayStart = max(0, min(startMinute, totalMinutes - minimumVisual))
            }
            return PreparedBlock(
                candidate: candidate,
                startMinute: startMinute, endMinute: min(endMinute, totalMinutes),
                displayStart: displayStart, displayEnd: displayEnd
            )
        }
        prepared.sort(by: PreparedBlock.order)
        let layouts = assignColumns(prepared.map { ($0.displayStart, $0.displayEnd) })

        var blocks: [EventBlock] = []
        for (index, item) in prepared.enumerated() {
            let candidate = item.candidate
            let items = allocationItems(for: candidate.activity)
            blocks.append(EventBlock(
                id: blockID(for: candidate.key),
                eventKey: candidate.key,
                calendarTitle: candidate.calendar?.title,
                calendarColorHex: candidate.calendar?.colorHex,
                title: candidate.title,
                startUnixMilliseconds: candidate.range.startUnixMilliseconds,
                endUnixMilliseconds: candidate.range.endUnixMilliseconds,
                startMinute: item.startMinute,
                endMinute: item.endMinute,
                displayStartMinute: item.displayStart,
                displayEndMinute: item.displayEnd,
                continuesFromPreviousDay: candidate.range.startUnixMilliseconds < bounds.start,
                continuesToNextDay: candidate.range.endUnixMilliseconds > bounds.end,
                layout: layouts[index],
                activity: badge(for: candidate.activity),
                allocations: items,
                allocatedSpend: aggregates(items, flow: .spend),
                allocatedRefunds: aggregates(items, flow: .refund),
                isRecurringInstance: candidate.isRecurringInstance,
                isEditable: candidate.isEditable,
                revisionToken: candidate.revisionToken,
                state: candidate.state
            ))
        }

        allDay.sort { lhs, rhs in
            (lhs.range.firstDay, rhs.range.lastDay, lhs.key) < (rhs.range.firstDay, lhs.range.lastDay, rhs.key)
        }
        let allDayItems: [AllDayItem] = allDay.map { candidate in
            let items = allocationItems(for: candidate.activity)
            return AllDayItem(
                id: blockID(for: candidate.key),
                eventKey: candidate.key,
                calendarTitle: candidate.calendar?.title,
                calendarColorHex: candidate.calendar?.colorHex,
                title: candidate.title,
                firstDay: candidate.range.firstDay,
                lastDay: candidate.range.lastDay,
                isFirstDayOfEvent: candidate.range.firstDay == input.day,
                isLastDayOfEvent: candidate.range.lastDay == input.day,
                activity: badge(for: candidate.activity),
                allocations: items,
                allocatedSpend: aggregates(items, flow: .spend),
                allocatedRefunds: aggregates(items, flow: .refund),
                isEditable: candidate.isEditable,
                revisionToken: candidate.revisionToken,
                state: candidate.state
            )
        }

        // Transactions that happened on this day.
        let visibleActivityIDs = Set(blocks.compactMap { $0.activity?.activityID } + allDayItems.compactMap { $0.activity?.activityID })
        let dayTransactions = input.transactions
            .filter { $0.occurredAtUnixMilliseconds >= bounds.start && $0.occurredAtUnixMilliseconds < bounds.end }
            .sorted { ($0.occurredAtUnixMilliseconds, $0.id.rawValue) < ($1.occurredAtUnixMilliseconds, $1.id.rawValue) }

        var markers: [TransactionMarkerItem] = []
        var totalsByCurrency: [String: (linked: Int64, unlinked: Int64, uncertain: Int64)] = [:]
        var unlinkedCount = 0
        var partialCount = 0
        for transaction in dayTransactions {
            let sign: Int64 = transaction.flow == .spend ? 1 : -1
            let total = transaction.amount.minorUnits
            let set = input.life.allocationSet(for: transaction.id)
            let allocations = set?.allocations ?? []
            let toActivities = allocations.filter { $0.activityID != nil }

            if toActivities.isEmpty {
                unlinkedCount += 1
            } else if allocations.count > 1 || !(set?.isFullyAllocated ?? false) {
                partialCount += 1
            }

            var linked: Int64 = 0, unlinked: Int64 = 0, uncertain: Int64 = 0
            if allocations.isEmpty {
                unlinked = total
            } else {
                let linkedKnown = toActivities.compactMap { $0.amount.knowledge.knownValue }.reduce(0, +)
                let nonActivityKnown = allocations.filter { $0.activityID == nil }.compactMap { $0.amount.knowledge.knownValue }.reduce(0, +)
                linked = linkedKnown
                if allocations.contains(where: { !$0.amount.knowledge.isKnown }) {
                    unlinked = nonActivityKnown
                    uncertain = total - linkedKnown - nonActivityKnown
                } else {
                    unlinked = total - linkedKnown
                }
            }
            var entry = totalsByCurrency[transaction.amount.currency] ?? (0, 0, 0)
            entry.linked += sign * linked
            entry.unlinked += sign * unlinked
            entry.uncertain += sign * uncertain
            totalsByCurrency[transaction.amount.currency] = entry

            // A transaction wholly accounted for inside the drawn activities needs no stray marker.
            let insideBlocks = !allocations.isEmpty && (set?.isFullyAllocated ?? false) &&
                allocations.allSatisfy { $0.activityID.map(visibleActivityIDs.contains) ?? false }
            if insideBlocks { continue }

            markers.append(TransactionMarkerItem(
                transactionID: transaction.id,
                title: transaction.title,
                amount: transaction.amount,
                flow: transaction.flow,
                occurredAtUnixMilliseconds: transaction.occurredAtUnixMilliseconds,
                positionMinute: Int((transaction.occurredAtUnixMilliseconds - bounds.start) / 60_000),
                timePrecision: transaction.timePrecision,
                allocations: allocations.map { allocation in
                    let activity = allocation.activityID.flatMap { input.life.activities[$0] }
                    return MarkerAllocation(
                        allocationID: allocation.id,
                        activityID: allocation.activityID,
                        activityTitle: activity?.displayTitle,
                        amount: allocation.amount.knowledge,
                        eventMissing: activity?.isEventMissing ?? false,
                        isShownToday: allocation.activityID.map(visibleActivityIDs.contains) ?? false
                    )
                },
                remainder: set?.remainder ?? AmountBounds(lower: total, upper: total),
                isFullyAllocated: set?.isFullyAllocated ?? false
            ))
        }

        let totals = totalsByCurrency.keys.sorted().map { currency in
            let entry = totalsByCurrency[currency] ?? (0, 0, 0)
            return CurrencyTotals(
                currency: currency,
                linkedNetMinorUnits: entry.linked,
                unlinkedNetMinorUnits: entry.unlinked,
                uncertainNetMinorUnits: entry.uncertain
            )
        }

        return DayTimeline(
            day: input.day,
            timeZoneIdentifier: input.timeZone.identifier,
            dayStartUnixMilliseconds: bounds.start,
            dayEndUnixMilliseconds: bounds.end,
            totalMinutes: totalMinutes,
            allDay: allDayItems,
            blocks: blocks,
            markers: markers,
            summary: DaySummary(
                eventCount: blocks.count,
                allDayCount: allDayItems.count,
                unlinkedTransactionCount: unlinkedCount,
                partiallyAllocatedTransactionCount: partialCount,
                totals: totals
            )
        )
    }

    // MARK: Internals

    private struct TimedCandidate {
        let key: CalendarEventKey
        let calendar: CalendarDescriptor?
        let title: String
        let range: TimedRange
        let activity: Activity?
        let isRecurringInstance: Bool
        let isEditable: Bool
        let revisionToken: String?
        let state: BlockState
    }

    private struct AllDayCandidate {
        let key: CalendarEventKey
        let calendar: CalendarDescriptor?
        let title: String
        let range: DayRange
        let activity: Activity?
        let isEditable: Bool
        let revisionToken: String?
        let state: BlockState
    }

    private struct PreparedBlock {
        let candidate: TimedCandidate
        let startMinute: Int
        let endMinute: Int
        let displayStart: Int
        let displayEnd: Int

        /// Earlier start first; for equal starts the longer block first; then identity, so order never varies.
        static func order(_ lhs: PreparedBlock, _ rhs: PreparedBlock) -> Bool {
            if lhs.displayStart != rhs.displayStart { return lhs.displayStart < rhs.displayStart }
            if lhs.displayEnd != rhs.displayEnd { return lhs.displayEnd > rhs.displayEnd }
            return lhs.candidate.key < rhs.candidate.key
        }
    }

    private static func blockID(for key: CalendarEventKey) -> BlockID {
        let calendar = key.calendarID.rawValue
        let event = key.eventID.rawValue
        return BlockID(rawValue: "event/\(calendar.utf8.count):\(calendar)/\(event.utf8.count):\(event)")
    }

    /// Greedy column assignment over blocks already sorted by start. A cluster is a maximal group of blocks
    /// connected by overlap; every block in it reports the cluster's column count.
    private static func assignColumns(_ ranges: [(start: Int, end: Int)]) -> [OverlapLayout] {
        var columns: [Int] = []          // end minute of the last block in each column
        var assigned: [Int] = []         // column of each block
        var clusterStart = 0
        var clusterEnd = Int.min
        var result = [OverlapLayout](repeating: OverlapLayout(column: 0, columnCount: 1), count: ranges.count)

        func closeCluster(upTo index: Int) {
            guard index > clusterStart else { return }
            let count = columns.count
            for position in clusterStart..<index {
                result[position] = OverlapLayout(column: assigned[position], columnCount: count)
            }
        }

        for (index, range) in ranges.enumerated() {
            if index > clusterStart, range.start >= clusterEnd {
                closeCluster(upTo: index)
                clusterStart = index
                columns = []
                clusterEnd = Int.min
            }
            if let free = columns.firstIndex(where: { $0 <= range.start }) {
                columns[free] = range.end
                assigned.append(free)
            } else {
                columns.append(range.end)
                assigned.append(columns.count - 1)
            }
            clusterEnd = max(clusterEnd, range.end)
        }
        closeCluster(upTo: ranges.count)
        return result
    }
}
