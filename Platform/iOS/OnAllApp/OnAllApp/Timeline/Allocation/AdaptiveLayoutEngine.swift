import CoreGraphics
import NEOBudgetCalendar

/// Adaptive Space Allocation: decides, from the content of two days and the height available, how much of each event and
/// transaction is shown, how the one shared time axis is shaped for that, and whether the screen has to scroll.
///
/// - Pure and deterministic: the same input gives the same layout. There is no clock, no randomness, no dictionary-order
///   dependence, and no input from rendered sizes or from the scroll position, so there is nothing to feed back.
/// - Computed once per change of content, viewport width/height, text size or mode, never per frame.
/// - Space goes **minimum first** (every event and transaction present, at its smallest form), then to the **main** day's
///   detail, then to the **secondary** day's. Only when the smallest form does not fit is scrolling allowed.
/// - It changes nothing about order, accounts or amounts. Amounts are summed per kind and currency and never mixed.
enum AdaptiveLayoutEngine {
    static func layout(_ input: AllocationInput) -> AdaptiveLayout {
        // While an event is edited the layout on screen is held exactly as it is.
        if case let .editing(frozen) = input.mode { return frozen }

        let scale = max(0.5, input.textScale)
        let context = Context(input: input, scale: scale)
        var state = context.initialState(previous: input.previous)
        let budget = max(0, input.viewportHeight)

        // Too big for the screen: give back detail, last in the priority order first, until it fits or nothing is left to give.
        var height = context.axis(for: state).height
        if height > budget {
            for step in context.steps.reversed() where height > budget {
                if context.revert(step, in: &state) { height = context.axis(for: state).height }
            }
        }
        // Room left over: spend it, in priority order, a step at a time. With a previous layout a step needs a little spare height,
        // so a small change of data does not flip many items between levels.
        let margin: CGFloat = input.previous == nil ? 0 : input.parameters.hysteresisMargin
        var mainIsComplete = true
        for step in context.steps {
            // The secondary day only gets what is left once the main day has everything it can use.
            if step.key.role == .secondary && !mainIsComplete { break }
            var attempt = state
            guard context.apply(step, in: &attempt) else { continue }
            let attemptHeight = context.axis(for: attempt).height
            if attemptHeight + margin <= budget {
                state = attempt
                height = attemptHeight
            } else if step.key.role == .main {
                mainIsComplete = false
            }
        }
        return context.build(state: state, viewportHeight: budget)
    }
}

// MARK: - Working data

private extension AdaptiveLayoutEngine {
    struct Heights {
        let title: CGFloat
        let preview: CGFloat
        let full: CGFloat
        let previewRows: Int
        let hiddenInPreview: Int
        func height(of level: EventLevel) -> CGFloat {
            switch level {
            case .title: return title
            case .preview: return preview
            case .full: return full
            }
        }
        /// The highest level that differs from the one below it.
        var topLevel: EventLevel { full > preview ? .full : preview > title ? .preview : .title }
        func rows(of level: EventLevel, linked: Int) -> (shown: Int, hidden: Int) {
            switch level {
            case .title: return (0, linked)
            case .preview: return (previewRows, hiddenInPreview)
            case .full: return (linked, 0)
            }
        }
    }

    struct Chain {
        let transactions: [AllocationTransaction]
        var first: Int { transactions.first?.minute ?? 0 }
        var last: Int { transactions.last?.minute ?? 0 }
        let canCluster: Bool
        var id: String { "\(first)-\(transactions.first?.id ?? "")" }
    }

    struct DayContext {
        let role: DayRole
        let day: AllocationDay
        let events: [AllocationEvent]               // sorted by (start, end descending, id)
        let heights: [String: Heights]
        let overlaps: [String: EventOverlap]
        let chains: [Chain]
    }

    struct Demand {
        let start: Int
        let end: Int
        let scale: CGFloat
    }

    /// One thing the engine can spend height on.
    struct Step: Equatable {
        enum Action: Equatable {
            case eventTo(EventLevel)
            case expandGroup
        }
        let key: ItemKey
        let action: Action
    }
}

private extension AdaptiveLayoutEngine {
    struct Context {
        let parameters: AllocationParameters
        let scale: CGFloat
        let days: [DayContext]
        let totalMinutes: Int
        let steps: [Step]

        init(input: AllocationInput, scale: CGFloat) {
            parameters = input.parameters
            self.scale = scale
            var built = [Context.makeDay(.main, input.main, parameters: input.parameters, scale: scale)]
            if let secondary = input.secondary { built.append(Context.makeDay(.secondary, secondary, parameters: input.parameters, scale: scale)) }
            days = built
            totalMinutes = max(1, built.map(\.day.totalMinutes).max() ?? 1440)

            // Main before secondary; within a day, in time order. Event detail comes in two passes so the first linked rows of every
            // event are shown before any event shows all of its.
            var order: [Step] = []
            for role in [DayRole.main, DayRole.secondary] {
                guard let day = built.first(where: { $0.role == role }) else { continue }
                for event in day.events where (day.heights[event.id]?.preview ?? 0) > (day.heights[event.id]?.title ?? 0) {
                    order.append(Step(key: ItemKey(role: role, kind: .event, id: event.id), action: .eventTo(.preview)))
                }
                for chain in day.chains where chain.canCluster {
                    order.append(Step(key: ItemKey(role: role, kind: .transactionGroup, id: chain.id), action: .expandGroup))
                }
                for event in day.events where (day.heights[event.id]?.full ?? 0) > (day.heights[event.id]?.preview ?? 0) {
                    order.append(Step(key: ItemKey(role: role, kind: .event, id: event.id), action: .eventTo(.full)))
                }
            }
            steps = order
        }

        // MARK: Days

        static func makeDay(_ role: DayRole, _ day: AllocationDay, parameters p: AllocationParameters, scale: CGFloat) -> DayContext {
            let events = day.events.sorted { ($0.startMinute, -$0.endMinute, $0.id) < ($1.startMinute, -$1.endMinute, $1.id) }
            var heights: [String: Heights] = [:]
            for event in events {
                let title = p.titleRow * scale
                let linked = event.linked.count
                // A "+N" row takes the room of a row, so it is only worth it for two or more transactions it replaces.
                let shown = linked <= p.previewLinkedRows + 1 ? linked : p.previewLinkedRows
                let hidden = linked - shown
                let previewRows = shown + (hidden > 0 ? 1 : 0)
                heights[event.id] = Heights(
                    title: title, preview: title + CGFloat(previewRows) * p.linkedRow * scale,
                    full: title + CGFloat(linked) * p.linkedRow * scale, previewRows: shown, hiddenInPreview: hidden
                )
            }
            return DayContext(
                role: role, day: day, events: events, heights: heights,
                overlaps: overlaps(of: events), chains: chains(of: day.transactions, parameters: p)
            )
        }

        /// Roles of overlapping events. At most one step of indent, whatever the depth of the overlap.
        static func overlaps(of events: [AllocationEvent]) -> [String: EventOverlap] {
            var result: [String: EventOverlap] = [:]
            var placed: [AllocationEvent] = []
            var groups: [[String]] = []
            var groupEnd = Int.min
            for event in events {
                let end = max(event.endMinute, event.startMinute + 1)
                let active = placed.filter { max($0.endMinute, $0.startMinute + 1) > event.startMinute }
                let containing = active.filter { $0.startMinute <= event.startMinute && max($0.endMinute, $0.startMinute + 1) >= end }
                let role: EventOverlap.Role
                if let parent = containing.min(by: { ($0.endMinute - $0.startMinute, $0.id) < ($1.endMinute - $1.startMinute, $1.id) }) {
                    role = .contained(in: parent.id)
                } else if let other = active.first {
                    role = .partial(with: other.id)
                } else {
                    role = .none
                }
                result[event.id] = EventOverlap(
                    role: role, indent: role == .none ? 0 : 1, pullsInOnRight: { if case .contained = role { return true } else { return false } }(),
                    groupSize: 1, summarisesTitles: false
                )
                if event.startMinute >= groupEnd {
                    groups.append([event.id])
                    groupEnd = end
                } else {
                    groups[groups.count - 1].append(event.id)
                    groupEnd = max(groupEnd, end)
                }
                placed.append(event)
            }
            for group in groups {
                for id in group {
                    guard let old = result[id] else { continue }
                    result[id] = EventOverlap(
                        role: old.role, indent: old.indent, pullsInOnRight: old.pullsInOnRight,
                        groupSize: group.count, summarisesTitles: group.count >= 3
                    )
                }
            }
            return result
        }

        /// Transactions close in time form a chain. A chain of enough of them can be shown as one card.
        static func chains(of transactions: [AllocationTransaction], parameters p: AllocationParameters) -> [Chain] {
            let sorted = transactions.sorted { ($0.minute, $0.id) < ($1.minute, $1.id) }
            var groups: [[AllocationTransaction]] = []
            for transaction in sorted {
                if let last = groups.last?.last, transaction.minute - last.minute <= p.clusterGapMinutes {
                    groups[groups.count - 1].append(transaction)
                } else {
                    groups.append([transaction])
                }
            }
            return groups.map { Chain(transactions: $0, canCluster: $0.count >= p.minimumClusterSize) }
        }

        // MARK: State

        /// The smallest form of everything, or the previous layout's choices where there are some.
        func initialState(previous: [ItemKey: Int]?) -> [ItemKey: Int] {
            var state: [ItemKey: Int] = [:]
            for day in days {
                for event in day.events {
                    let key = ItemKey(role: day.role, kind: .event, id: event.id)
                    let top = day.heights[event.id]?.topLevel ?? .title
                    state[key] = min(previous?[key] ?? 0, top.rawValue)
                }
                for chain in day.chains {
                    let key = ItemKey(role: day.role, kind: .transactionGroup, id: chain.id)
                    // 0 clustered, 1 rows. A chain too small to cluster is always rows.
                    state[key] = chain.canCluster ? min(max(previous?[key] ?? 0, 0), 1) : 1
                }
            }
            return state
        }

        func apply(_ step: Step, in state: inout [ItemKey: Int]) -> Bool {
            switch step.action {
            case let .eventTo(level):
                guard let current = state[step.key], current < level.rawValue else { return false }
                state[step.key] = level.rawValue
                return true
            case .expandGroup:
                guard state[step.key] == 0 else { return false }
                state[step.key] = 1
                return true
            }
        }

        func revert(_ step: Step, in state: inout [ItemKey: Int]) -> Bool {
            switch step.action {
            case let .eventTo(level):
                guard let current = state[step.key], current >= level.rawValue else { return false }
                state[step.key] = level.rawValue - 1
                return true
            case .expandGroup:
                guard state[step.key] == 1 else { return false }
                state[step.key] = 0
                return true
            }
        }

        // MARK: Axis

        func level(_ state: [ItemKey: Int], _ role: DayRole, _ event: AllocationEvent) -> EventLevel {
            EventLevel(rawValue: state[ItemKey(role: role, kind: .event, id: event.id)] ?? 0) ?? .title
        }

        func presentation(_ state: [ItemKey: Int], _ role: DayRole, _ chain: Chain) -> TransactionGroup.Presentation {
            (state[ItemKey(role: role, kind: .transactionGroup, id: chain.id)] ?? 1) == 0 ? .cluster : .rows
        }

        func groupHeight(_ chain: Chain, _ presentation: TransactionGroup.Presentation) -> CGFloat {
            presentation == .cluster ? parameters.clusterCard * scale : CGFloat(chain.transactions.count) * parameters.transactionRow * scale
        }

        func demands(for state: [ItemKey: Int]) -> [Demand] {
            let p = parameters
            var result: [Demand] = []
            func clamp(_ minute: Int) -> Int { min(max(minute, 0), totalMinutes) }
            func add(_ start: Int, _ end: Int, _ scale: CGFloat) {
                let a = clamp(start), b = clamp(end)
                if b > a, scale > 0 { result.append(Demand(start: a, end: b, scale: scale)) }
            }
            for day in days {
                let isMain = day.role == .main
                for event in day.events {
                    guard let heights = day.heights[event.id] else { continue }
                    let required = heights.height(of: level(state, day.role, event))
                    let start = event.startMinute, end = max(event.endMinute, event.startMinute + 1)
                    let span = end - start
                    if span <= p.longEventMinutes {
                        add(start, end, required / CGFloat(span))
                    } else {
                        // A long event keeps its two edges readable and its middle compressed to what the level needs.
                        let topScale = max(p.browseScale, heights.title / CGFloat(p.padding))
                        add(start, start + p.padding, topScale)
                        add(end - p.padding, end, p.browseScale)
                        let remainder = required - CGFloat(p.padding) * (topScale + p.browseScale)
                        add(start + p.padding, end - p.padding, remainder / CGFloat(max(1, span - 2 * p.padding)))
                    }
                    if isMain {                                            // the main day also keeps its surroundings at browse size
                        add(start - p.padding, start + p.padding, p.browseScale)
                        add(end - p.padding, end + p.padding, p.browseScale)
                    }
                }
                for chain in day.chains {
                    let shape = presentation(state, day.role, chain)
                    let window = p.transactionWindowMinutes
                    if shape == .cluster {
                        let middle = (chain.first + chain.last) / 2
                        add(middle - window / 2, middle + window / 2, groupHeight(chain, .cluster) / CGFloat(window))
                    } else {
                        let start = chain.first - window / 2, end = chain.last + window / 2
                        add(start, end, groupHeight(chain, .rows) / CGFloat(max(1, end - start)))
                    }
                    if isMain { add(chain.first - p.padding, chain.last + p.padding, p.browseScale) }
                }
            }
            if let main = days.first, main.events.isEmpty, main.chains.isEmpty {
                add(p.emptyDayFocus.lowerBound - p.padding, p.emptyDayFocus.upperBound + p.padding, p.browseScale)
            }
            return result
        }

        /// The shared axis for a state: every minute at the largest scale any demand asks of it, quiet stretches folded.
        func axis(for state: [ItemKey: Int]) -> TimelineAxis {
            let p = parameters
            let demands = demands(for: state)
            var cuts = Set([0, totalMinutes])
            for demand in demands { cuts.insert(demand.start); cuts.insert(demand.end) }
            let points = cuts.sorted()
            var pieces: [(start: Int, end: Int, scale: CGFloat?)] = []
            for (a, b) in zip(points, points.dropFirst()) {
                let asked = demands.filter { $0.start <= a && $0.end >= b }.map(\.scale).max()
                if asked == nil, let last = pieces.last, last.scale == nil {
                    pieces[pieces.count - 1].end = b
                } else {
                    pieces.append((a, b, asked))
                }
            }
            var segments: [TimelineAxis.Segment] = []
            for piece in pieces {
                let minutes = piece.end - piece.start
                if let scale = piece.scale ?? (minutes < p.minimumFoldMinutes ? p.browseScale : nil) {
                    if let last = segments.last, !last.isFolded, abs(last.pointsPerMinute - scale) < 1e-6 {
                        segments[segments.count - 1] = TimelineAxis.Segment(
                            startMinute: last.startMinute, endMinute: piece.end, pointsPerMinute: scale,
                            height: last.height + CGFloat(minutes) * scale, isFolded: false
                        )
                    } else {
                        segments.append(TimelineAxis.Segment(
                            startMinute: piece.start, endMinute: piece.end, pointsPerMinute: scale,
                            height: CGFloat(minutes) * scale, isFolded: false
                        ))
                    }
                } else {
                    segments.append(TimelineAxis.Segment(
                        startMinute: piece.start, endMinute: piece.end, pointsPerMinute: p.foldedScale,
                        height: max(p.minimumFoldedHeight, CGFloat(minutes) * p.foldedScale), isFolded: true
                    ))
                }
            }
            return TimelineAxis(totalMinutes: totalMinutes, segments: segments)
        }

        // MARK: Result

        func build(state: [ItemKey: Int], viewportHeight: CGFloat) -> AdaptiveLayout {
            let axis = axis(for: state)
            var events: [EventPlacement] = []
            var groups: [TransactionGroup] = []
            for day in days {
                for event in day.events {
                    guard let heights = day.heights[event.id], let overlap = day.overlaps[event.id] else { continue }
                    let level = level(state, day.role, event)
                    let rows = heights.rows(of: level, linked: event.linked.count)
                    events.append(EventPlacement(
                        key: ItemKey(role: day.role, kind: .event, id: event.id), id: event.id,
                        startMinute: event.startMinute, endMinute: event.endMinute, level: level,
                        minimumHeight: heights.title, preferredHeight: heights.preview, expandedHeight: heights.full,
                        requiredHeight: heights.height(of: level), shownLinkedRows: rows.shown, hiddenLinkedCount: rows.hidden,
                        linkedTotals: AmountSum.totals(of: event.linked), overlap: overlap
                    ))
                }
                for chain in day.chains {
                    let shape = presentation(state, day.role, chain)
                    groups.append(TransactionGroup(
                        key: ItemKey(role: day.role, kind: .transactionGroup, id: chain.id), role: day.role,
                        transactionIDs: chain.transactions.map(\.id), startMinute: chain.first, endMinute: chain.last,
                        presentation: shape, totals: AmountSum.totals(of: chain.transactions), requiredHeight: groupHeight(chain, shape)
                    ))
                }
            }
            return AdaptiveLayout(
                axis: axis, events: events, groups: groups, contentHeight: axis.height, viewportHeight: viewportHeight,
                requiresScroll: axis.height > viewportHeight + 0.5, state: state
            )
        }
    }
}
