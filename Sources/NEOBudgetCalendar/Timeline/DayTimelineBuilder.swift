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
                    isRecurringInstance: event.isRecurringInstance, isEditable: event.isEditable, state: .normal
                ))
            case let .allDay(range):
                guard range.contains(input.day) else { continue }
                allDay.append(AllDayCandidate(
                    key: event.key, calendar: calendar, title: event.title, range: range, activity: activity,
                    isEditable: event.isEditable, state: .normal
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
                        activity: activity, isRecurringInstance: false, isEditable: false, state: .eventMissing
                    ))
                case let .allDay(range):
                    guard range.contains(input.day) else { continue }
                    allDay.append(AllDayCandidate(
                        key: association.key, calendar: calendar, title: association.lastKnown.title, range: range,
                        activity: activity, isEditable: false, state: .eventMissing
                    ))
                }
            }
        }

        func linkedItems(for activity: Activity?) -> [LinkedTransactionItem] {
            guard let activity else { return [] }
            return input.life.links(forActivity: activity.id).compactMap { link in
                guard let marker = transactionsByID[link.transactionID] else { return nil }
                return LinkedTransactionItem(
                    transactionID: marker.id,
                    title: marker.title,
                    amount: marker.amount,
                    flow: marker.flow,
                    occurredAtUnixMilliseconds: marker.occurredAtUnixMilliseconds,
                    timePrecision: marker.timePrecision,
                    occursOnSelectedDay: marker.occurredAtUnixMilliseconds >= bounds.start && marker.occurredAtUnixMilliseconds < bounds.end,
                    linkSource: link.provenance.source
                )
            }
            .sorted { ($0.occurredAtUnixMilliseconds, $0.transactionID.rawValue) < ($1.occurredAtUnixMilliseconds, $1.transactionID.rawValue) }
        }

        func badge(for activity: Activity?) -> ActivityBadge? {
            guard let activity else { return nil }
            return ActivityBadge(
                activityID: activity.id,
                activityType: activity.activityType?.value,
                areaID: activity.area?.value,
                tagIDs: activity.tags.map(\.tagID).sorted()
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
            let linked = linkedItems(for: candidate.activity)
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
                linked: linked,
                linkedTotals: netTotals(linked.map { ($0.amount.currency, $0.flow == .spend ? $0.amount.minorUnits : -$0.amount.minorUnits) }),
                isRecurringInstance: candidate.isRecurringInstance,
                isEditable: candidate.isEditable,
                state: candidate.state
            ))
        }

        allDay.sort { lhs, rhs in
            (lhs.range.firstDay, rhs.range.lastDay, lhs.key) < (rhs.range.firstDay, lhs.range.lastDay, rhs.key)
        }
        let allDayItems: [AllDayItem] = allDay.map { candidate in
            let linked = linkedItems(for: candidate.activity)
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
                linked: linked,
                linkedTotals: netTotals(linked.map { ($0.amount.currency, $0.flow == .spend ? $0.amount.minorUnits : -$0.amount.minorUnits) }),
                isEditable: candidate.isEditable,
                state: candidate.state
            )
        }

        // Transactions that happened on this day.
        let visibleActivityIDs = Set(blocks.compactMap { $0.activity?.activityID } + allDayItems.compactMap { $0.activity?.activityID })
        let dayTransactions = input.transactions
            .filter { $0.occurredAtUnixMilliseconds >= bounds.start && $0.occurredAtUnixMilliseconds < bounds.end }
            .sorted { ($0.occurredAtUnixMilliseconds, $0.id.rawValue) < ($1.occurredAtUnixMilliseconds, $1.id.rawValue) }

        var markers: [TransactionMarkerItem] = []
        var linkedAmounts: [(String, Int64)] = []
        var unlinkedAmounts: [(String, Int64)] = []
        for transaction in dayTransactions {
            let link = input.life.link(for: transaction.id)
            if link == nil {
                unlinkedAmounts.append((transaction.amount.currency, transaction.signedMinorUnits))
            } else {
                linkedAmounts.append((transaction.amount.currency, transaction.signedMinorUnits))
            }
            let state: MarkerLinkState
            if let link {
                if visibleActivityIDs.contains(link.activityID) { continue }
                let activity = input.life.activities[link.activityID]
                state = .linkedElsewhere(
                    activityID: link.activityID,
                    activityTitle: activity?.displayTitle ?? "",
                    eventMissing: activity?.isEventMissing ?? false
                )
            } else {
                state = .unlinked
            }
            markers.append(TransactionMarkerItem(
                transactionID: transaction.id,
                title: transaction.title,
                amount: transaction.amount,
                flow: transaction.flow,
                occurredAtUnixMilliseconds: transaction.occurredAtUnixMilliseconds,
                positionMinute: Int((transaction.occurredAtUnixMilliseconds - bounds.start) / 60_000),
                timePrecision: transaction.timePrecision,
                linkState: state
            ))
        }

        let unlinkedCount = dayTransactions.filter { input.life.link(for: $0.id) == nil }.count
        let currencies = Set(linkedAmounts.map(\.0) + unlinkedAmounts.map(\.0)).sorted()
        let totals = currencies.map { currency in
            CurrencyTotals(
                currency: currency,
                linkedNetMinorUnits: linkedAmounts.filter { $0.0 == currency }.reduce(0) { $0 + $1.1 },
                unlinkedNetMinorUnits: unlinkedAmounts.filter { $0.0 == currency }.reduce(0) { $0 + $1.1 }
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
        let state: BlockState
    }

    private struct AllDayCandidate {
        let key: CalendarEventKey
        let calendar: CalendarDescriptor?
        let title: String
        let range: DayRange
        let activity: Activity?
        let isEditable: Bool
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

    private static func netTotals(_ amounts: [(String, Int64)]) -> [Money] {
        var byCurrency: [String: Int64] = [:]
        for (currency, value) in amounts { byCurrency[currency, default: 0] += value }
        return byCurrency.keys.sorted().compactMap { try? Money(minorUnits: byCurrency[$0] ?? 0, currency: $0) }
    }
}
