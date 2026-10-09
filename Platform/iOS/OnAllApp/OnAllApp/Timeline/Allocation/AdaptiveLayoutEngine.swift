import CoreGraphics
import NEOBudgetCalendar

/// Adaptive Space Allocation: decides, from the content of two days and the height available, how much of each event and
/// transaction is shown, how the one shared time axis is shaped for that, and whether the screen has to scroll.
///
/// - Pure and deterministic: the same input gives the same layout. There is no clock, no randomness, no dictionary-order
///   dependence, and no input from rendered sizes or from the scroll position, so there is nothing to feed back. The layout is
///   built in a fixed number of passes (never iterated to a fixed point).
/// - Computed once per change of content, viewport width/height, text size, mode or focus, never per frame.
/// - Space goes **minimum first** (every event and transaction present in its smallest form), then to the **main** day's detail,
///   then to the **secondary** day's. Only when the smallest form does not fit is scrolling allowed.
/// - The time axis is shaped by what each item *needs* (a height over its minutes); what an item *shows* (its level, whether
///   transaction lines overflow) is decided separately from the height available. Neither changes a time.
/// - It changes nothing about order, accounts or amounts. Amounts are summed per kind and currency and never mixed, and the ledger
///   total counts each transaction once however many places show it.
enum AdaptiveLayoutEngine {
    static func layout(_ input: AllocationInput) -> AdaptiveLayout {
        // While an event is edited the layout on screen is held exactly as it is.
        if case let .editing(frozen) = input.mode { return frozen }
        if let focus = input.focus, let focused = focusedLayout(input, focus) { return focused }
        return compute(input, focus: nil)
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
        func rows(of level: EventLevel, inside: Int) -> (shown: Int, hidden: Int) {
            switch level {
            case .title: return (0, inside)
            case .preview: return (previewRows, hiddenInPreview)
            case .full: return (inside, 0)
            }
        }
    }

    /// A transaction drawn on a line of its own on its day.
    struct Line {
        let transaction: AllocationTransaction
        let link: LinkMetadata?
    }

    /// Two neighbouring lines. Close enough that an ordinary time scale cannot keep them apart, they may be merged into an overflow.
    struct LineLink {
        let key: ItemKey
        let index: Int
        let delta: Int
        let isMergeable: Bool
    }

    /// What is drawn at one place on the axis: one line, or an overflow standing for several.
    struct Unit {
        let lines: [Line]
        var anchor: Int { lines.count == 1 ? lines[0].transaction.minute : ((lines.first?.transaction.minute ?? 0) + (lines.last?.transaction.minute ?? 0)) / 2 }
        var isOverflow: Bool { lines.count > 1 }
    }

    struct DayContext {
        let role: DayRole
        let day: AllocationDay
        let events: [AllocationEvent]               // sorted by (start, end descending, id)
        let heights: [String: Heights]
        let overlaps: [String: EventOverlap]
        let lines: [Line]                           // sorted by (minute, id)
        let links: [LineLink]
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
            case separate
        }
        let key: ItemKey
        let action: Action
    }

    struct Interval {
        let minY: CGFloat
        let maxY: CGFloat
        let id: String
    }
}

private extension AdaptiveLayoutEngine {
    struct Context {
        let input: AllocationInput
        let parameters: AllocationParameters
        let scale: CGFloat
        let days: [DayContext]
        let totalMinutes: Int
        let steps: [Step]

        var pitch: CGFloat { (parameters.transactionRow + parameters.lineGap) * scale }

        init(input: AllocationInput, scale: CGFloat) {
            self.input = input
            parameters = input.parameters
            self.scale = scale
            var built = [Context.makeDay(.main, input.main, parameters: input.parameters, scale: scale)]
            if let secondary = input.secondary { built.append(Context.makeDay(.secondary, secondary, parameters: input.parameters, scale: scale)) }
            days = built
            totalMinutes = max(1, built.map(\.day.totalMinutes).max() ?? 1440)

            // Main before secondary; within a day, in time order. Event detail comes in two passes so the first rows of every event
            // are shown before any event shows all of its. Transaction lines are separated cheapest first (those furthest apart).
            var order: [Step] = []
            for role in [DayRole.main, DayRole.secondary] {
                guard let day = built.first(where: { $0.role == role }) else { continue }
                for event in day.events where (day.heights[event.id]?.preview ?? 0) > (day.heights[event.id]?.title ?? 0) {
                    order.append(Step(key: ItemKey(role: role, kind: .event, id: event.id), action: .eventTo(.preview)))
                }
                for link in day.links.filter(\.isMergeable).sorted(by: { ($1.delta, $0.index) < ($0.delta, $1.index) }) {
                    order.append(Step(key: link.key, action: .separate))
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
                let inside = event.insideRange.count
                // A "+N" row takes the room of a row, so it is only worth it for two or more transactions it replaces.
                let shown = inside <= p.previewLinkedRows + 1 ? inside : p.previewLinkedRows
                let hidden = inside - shown
                let previewRows = shown + (hidden > 0 ? 1 : 0)
                heights[event.id] = Heights(
                    title: title, preview: title + CGFloat(previewRows) * p.linkedRow * scale,
                    full: title + CGFloat(inside) * p.linkedRow * scale, previewRows: shown, hiddenInPreview: hidden
                )
            }

            // Lines: unlinked transactions (wherever they fall in time), and linked ones that happened outside their event's time.
            var seen = Set<String>()
            var lines: [Line] = []
            for transaction in day.transactions where transaction.dayOffset == 0 && seen.insert(transaction.id).inserted {
                lines.append(Line(transaction: transaction, link: nil))
            }
            for event in events {
                for transaction in event.outsideRange where transaction.dayOffset == 0 && seen.insert(transaction.id).inserted {
                    lines.append(Line(transaction: transaction, link: LinkMetadata(eventID: event.id, happenedOutsideEventRange: true)))
                }
            }
            lines.sort { ($0.transaction.minute, $0.transaction.id) < ($1.transaction.minute, $1.transaction.id) }
            let pitch = (p.transactionRow + p.lineGap) * scale
            var links: [LineLink] = []
            for index in 0..<max(0, lines.count - 1) {
                let delta = lines[index + 1].transaction.minute - lines[index].transaction.minute
                // Merged only where the ordinary time scale cannot keep two lines apart: they would touch even before any compression.
                let mergeable = delta == 0 || CGFloat(delta) * p.browseScale < pitch
                links.append(LineLink(
                    key: ItemKey(role: role, kind: .transactionLink, id: "\(lines[index].transaction.id)>\(lines[index + 1].transaction.id)"),
                    index: index, delta: delta, isMergeable: mergeable
                ))
            }
            return DayContext(role: role, day: day, events: events, heights: heights, overlaps: overlaps(of: events), lines: lines, links: links)
        }

        static func overlaps(of events: [AllocationEvent]) -> [String: EventOverlap] { EventOverlapAnalysis.analyse(events) }

        // MARK: State

        /// The smallest form of everything (close lines merged into overflows), or the previous layout's choices where there are some.
        func initialState(previous: [ItemKey: Int]?) -> [ItemKey: Int] {
            var state: [ItemKey: Int] = [:]
            for day in days {
                for event in day.events {
                    let key = ItemKey(role: day.role, kind: .event, id: event.id)
                    let top = day.heights[event.id]?.topLevel ?? .title
                    state[key] = min(max(previous?[key] ?? 0, 0), top.rawValue)
                }
                for link in day.links where link.isMergeable {
                    state[link.key] = min(max(previous?[link.key] ?? 0, 0), 1)          // 0 merged, 1 separate
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
            case .separate:
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
            case .separate:
                guard state[step.key] == 1 else { return false }
                state[step.key] = 0
                return true
            }
        }

        func level(_ state: [ItemKey: Int], _ role: DayRole, _ event: AllocationEvent) -> EventLevel {
            EventLevel(rawValue: state[ItemKey(role: role, kind: .event, id: event.id)] ?? 0) ?? .title
        }

        /// What is drawn for a day's transactions: a line each, except where neighbouring lines have been merged.
        func units(_ state: [ItemKey: Int], _ day: DayContext) -> [Unit] {
            var result: [Unit] = []
            var run: [Line] = []
            for (index, line) in day.lines.enumerated() {
                run.append(line)
                let isMerged = index < day.links.count && day.links[index].isMergeable && state[day.links[index].key] == 0
                if !isMerged {
                    result.append(Unit(lines: run))
                    run = []
                }
            }
            return result
        }

        func height(of unit: Unit) -> CGFloat { (unit.isOverflow ? parameters.overflowCard : parameters.transactionRow) * scale }

        // MARK: Axis

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
                    let start = event.startMinute, end = event.effectiveEnd
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
                // Transactions: each unit needs its own height, and consecutive units need to stay a readable distance apart.
                let units = units(state, day)
                let gap = p.lineGap * scale
                for (index, unit) in units.enumerated() {
                    let window = p.transactionWindowMinutes
                    add(unit.anchor - window / 2, unit.anchor + window / 2, height(of: unit) / CGFloat(window))
                    if isMain { add(unit.lines.first!.transaction.minute - p.padding, unit.lines.last!.transaction.minute + p.padding, p.browseScale) }
                    if index + 1 < units.count {
                        let next = units[index + 1]
                        let need = (height(of: unit) + height(of: next)) / 2 + gap
                        let delta = max(1, next.anchor - unit.anchor)
                        add(unit.anchor, unit.anchor + delta, need / CGFloat(delta))
                    }
                }
            }
            if let main = days.first, main.events.isEmpty, main.lines.isEmpty {
                add(p.emptyDayFocus.lowerBound - p.padding, p.emptyDayFocus.upperBound + p.padding, p.browseScale)
            }
            return result
        }

        /// The shared axis for a state: every minute at the largest scale any demand asks of it, quiet stretches folded.
        func axis(for state: [ItemKey: Int], extra: [Demand] = []) -> TimelineAxis {
            let p = parameters
            let demands = demands(for: state) + extra
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
    }
}

// MARK: - Computing a layout

private extension AdaptiveLayoutEngine {
    static func compute(_ input: AllocationInput, focus: FocusLayout?) -> AdaptiveLayout {
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
        return build(context: context, state: state, budget: budget, focus: focus)
    }

    static func titleWidth(_ title: String, scale: CGFloat) -> CGFloat {
        title.unicodeScalars.reduce(CGFloat(0)) { $0 + ($1.value >= 0x2E80 ? 12 : 7) } * scale + 12
    }

    static func build(context: Context, state: [ItemKey: Int], budget: CGFloat, focus: FocusLayout?) -> AdaptiveLayout {
        let p = context.parameters
        let scale = context.scale
        let width = max(1, context.input.contentWidth)
        let lineWidth = min(width, max(p.minimumLineWidth, width * p.lineWidthShare))
        let titleRoom = width - lineWidth - 4                                  // what a title may use without reaching a line

        var axis = context.axis(for: state)
        var extra: [Demand] = []
        var resolutions: [ItemKey: TitleResolution] = [:]
        var headers: [ItemKey: EventHeader] = [:]

        // Title and transaction lines wanting the same place, resolved in a fixed order on the axis as it stands: a header above the
        // event if there is clear room, else a shorter title, else more room for the stretch, else a cut title.
        func layoutIntervals(_ day: DayContext, on axis: TimelineAxis) -> (events: [Interval], units: [Interval]) {
            let eventIntervals = day.events.map { event -> Interval in
                let top = axis.y(minute: event.startMinute)
                return Interval(minY: top, maxY: top + max(axis.y(minute: event.effectiveEnd) - top, p.titleRow * scale), id: event.id)
            }
            let unitIntervals = context.units(state, day).map { unit -> Interval in
                let center = axis.y(minute: unit.anchor)
                let half = context.height(of: unit) / 2
                return Interval(minY: center - half, maxY: center + half, id: unit.lines[0].transaction.id)
            }
            return (eventIntervals, unitIntervals)
        }

        for day in context.days {
            let (eventIntervals, unitIntervals) = layoutIntervals(day, on: axis)
            var occupied = eventIntervals + unitIntervals
            for event in day.events {
                let key = ItemKey(role: day.role, kind: .event, id: event.id)
                guard let overlap = day.overlaps[event.id], let own = eventIntervals.first(where: { $0.id == event.id }) else { continue }
                let indent = CGFloat(overlap.indent) * p.indentStep
                let titleEnd = indent + (context.input.titleWidths[event.title] ?? titleWidth(event.title, scale: scale))
                let titleBottom = own.minY + p.titleRow * scale
                let conflicting = unitIntervals.filter { $0.maxY > own.minY + 0.01 && $0.minY < titleBottom - 0.01 }
                guard !conflicting.isEmpty, titleEnd > width - lineWidth - 4 else { resolutions[key] = TitleResolution.none; continue }

                let headerHeight = p.headerRow * scale
                let regionMin = own.minY - headerHeight
                let free = regionMin >= -0.01 && !occupied.contains { $0.id != event.id && $0.maxY > regionMin + 0.01 && $0.minY < own.minY - 0.01 }
                if free {
                    resolutions[key] = .externalHeader
                    headers[key] = EventHeader(eventID: event.id, height: headerHeight, attachedToMinute: event.startMinute)
                    occupied.append(Interval(minY: regionMin, maxY: own.minY, id: "header-\(event.id)"))
                    continue
                }
                let available = titleRoom - indent
                if available >= p.minimumTitleWidth {
                    resolutions[key] = .abbreviated(maxWidth: available)
                    continue
                }
                // More room for the stretch between the event's start and its first line, so the title has a row of its own.
                if let first = day.lines.filter({ line in conflicting.contains { $0.id == line.transaction.id } }).map(\.transaction.minute).min()
                    ?? day.lines.map(\.transaction.minute).first(where: { $0 >= event.startMinute }) {
                    let need = p.titleRow * scale + p.lineGap * scale + p.transactionRow * scale / 2
                    let span = max(1, first - event.startMinute)
                    extra.append(Demand(start: event.startMinute, end: min(context.totalMinutes, event.startMinute + span), scale: need / CGFloat(span)))
                    resolutions[key] = .expandedRange
                } else {
                    resolutions[key] = .cramped(width: max(p.minimumTitleWidth, available))
                }
            }
        }
        if !extra.isEmpty {
            let enlarged = context.axis(for: state, extra: extra)
            if enlarged.height <= budget + 0.5 {
                axis = enlarged
            } else {
                // No room to enlarge: the cut title is the fallback, never a title printed over a line.
                for (key, resolution) in resolutions where resolution == .expandedRange {
                    resolutions[key] = .cramped(width: max(p.minimumTitleWidth, titleRoom))
                }
            }
        }

        // Events.
        var events: [EventPlacement] = []
        var allLinked: [AllocationTransaction] = []
        for day in context.days {
            for event in day.events {
                guard let heights = day.heights[event.id], let overlap = day.overlaps[event.id] else { continue }
                let key = ItemKey(role: day.role, kind: .event, id: event.id)
                let level = context.level(state, day.role, event)
                let rows = heights.rows(of: level, inside: event.insideRange.count)
                allLinked += event.linked
                events.append(EventPlacement(
                    key: key, id: event.id, startMinute: event.startMinute, endMinute: event.endMinute, level: level,
                    minimumHeight: heights.title, preferredHeight: heights.preview, expandedHeight: heights.full,
                    requiredHeight: heights.height(of: level), shownInsideRows: rows.shown, hiddenInsideCount: rows.hidden,
                    linkedTotals: AmountSum.totals(of: event.linked, allocated: true), outsideLinkedCount: event.outsideRange.count,
                    overlap: overlap, titleResolution: resolutions[key] ?? TitleResolution.none, header: headers[key]
                ))
            }
        }

        // Lines and overflows.
        var lines: [TransactionLine] = []
        var overflows: [TransactionOverflow] = []
        for day in context.days {
            for unit in context.units(state, day) {
                if unit.isOverflow {
                    let members = unit.lines.map { OverflowMember(
                        transactionID: $0.transaction.id, minute: $0.transaction.minute, kind: $0.transaction.kind,
                        currency: $0.transaction.currency, minorUnits: $0.transaction.minorUnits, link: $0.link
                    ) }
                    let transactions = unit.lines.map(\.transaction)
                    let totals = AmountSum.totals(of: transactions)
                    let kinds = Dictionary(grouping: transactions, by: \.kind).map { KindCount(kind: $0.key, count: $0.value.count) }.sorted { $0.kind < $1.kind }
                    overflows.append(TransactionOverflow(
                        id: "overflow-\(unit.lines[0].transaction.minute)-\(unit.lines[0].transaction.id)", role: day.role, members: members,
                        startMinute: unit.lines.first?.transaction.minute ?? 0, endMinute: unit.lines.last?.transaction.minute ?? 0,
                        countsByKind: kinds, amountTotals: totals, showsAmountTotal: totals.count == 1,
                        requiredHeight: p.overflowCard * scale
                    ))
                } else if let line = unit.lines.first {
                    let t = line.transaction
                    lines.append(TransactionLine(
                        key: ItemKey(role: day.role, kind: .transactionLink, id: t.id), role: day.role, transactionID: t.id, minute: t.minute,
                        kind: t.kind, currency: t.currency, minorUnits: t.minorUnits, link: line.link, isPartlyLinked: t.isPartlyLinked
                    ))
                }
            }
        }

        // The ledger counts every transaction once, however many places refer to it.
        var seen = Set<String>()
        var unique: [AllocationTransaction] = []
        for day in context.days {
            for transaction in day.events.flatMap(\.linked) + day.day.transactions where seen.insert(transaction.id).inserted { unique.append(transaction) }
        }

        let (targets, conflicts) = touch(events: events, lines: lines, overflows: overflows, axis: axis, parameters: p, scale: scale)
        return AdaptiveLayout(
            axis: axis, events: events, lines: lines, overflows: overflows, touchTargets: targets, touchConflicts: conflicts,
            ledgerTotals: AmountSum.totals(of: unique), contentHeight: axis.height, viewportHeight: budget,
            requiresScroll: axis.height > budget + 0.5, state: state, focus: focus
        )
    }

    /// Touch areas never smaller than a finger needs. Where they run into each other the candidates are returned, not chosen between.
    static func touch(
        events: [EventPlacement], lines: [TransactionLine], overflows: [TransactionOverflow],
        axis: TimelineAxis, parameters p: AllocationParameters, scale: CGFloat
    ) -> ([TouchTarget], [TouchConflict]) {
        func target(_ id: String, _ kind: TouchTarget.Kind, _ role: DayRole, _ minY: CGFloat, _ maxY: CGFloat) -> TouchTarget {
            let missing = max(0, p.minimumTouchHeight - (maxY - minY))
            return TouchTarget(id: id, kind: kind, role: role, visualMinY: minY, visualMaxY: maxY, touchMinY: minY - missing / 2, touchMaxY: maxY + missing / 2)
        }
        var targets: [TouchTarget] = []
        for event in events {
            let top = axis.y(minute: event.startMinute)
            targets.append(target(event.id, .event, event.key.role, top, top + max(axis.y(minute: max(event.endMinute, event.startMinute + 1)) - top, event.minimumHeight)))
        }
        for line in lines {
            let center = axis.y(minute: line.minute), half = p.transactionRow * scale / 2
            targets.append(target(line.transactionID, .transaction, line.role, center - half, center + half))
        }
        for overflow in overflows {
            let center = axis.y(minute: (overflow.startMinute + overflow.endMinute) / 2), half = overflow.requiredHeight / 2
            targets.append(target(overflow.id, .overflow, overflow.role, center - half, center + half))
        }
        targets.sort { ($0.visualMinY, $0.id) < ($1.visualMinY, $1.id) }

        // Pairs whose touch areas meet. A line over an event, and events stacked on each other, overlap on purpose (their visual
        // areas already meet); what is reported is the meeting that the touch areas add, and lines that meet one another.
        var parent = Array(0..<targets.count)
        func find(_ i: Int) -> Int { var j = i; while parent[j] != j { j = parent[j] }; return j }
        var involved = Set<Int>()
        for i in targets.indices {
            for j in (i + 1)..<max(i + 1, targets.count) {
                let a = targets[i], b = targets[j]
                guard a.touchMaxY > b.touchMinY + 0.01 && b.touchMaxY > a.touchMinY + 0.01 else { continue }
                let visualMeet = a.visualMaxY > b.visualMinY + 0.01 && b.visualMaxY > a.visualMinY + 0.01
                let bothTransactionLike = a.kind != .event && b.kind != .event
                guard !visualMeet || bothTransactionLike else { continue }
                parent[find(j)] = find(i)
                involved.insert(i); involved.insert(j)
            }
        }
        var groups: [Int: [Int]] = [:]
        for index in involved { groups[find(index), default: []].append(index) }
        let conflicts = groups.values.map { members -> TouchConflict in
            let items = members.sorted().map { targets[$0] }
            return TouchConflict(candidates: items.map(\.id), minY: items.map(\.touchMinY).min() ?? 0, maxY: items.map(\.touchMaxY).max() ?? 0)
        }.sorted { ($0.minY, $0.candidates.first ?? "") < ($1.minY, $1.candidates.first ?? "") }
        return (targets, conflicts)
    }
}

// MARK: - Focus

private extension AdaptiveLayoutEngine {
    /// One thing in focus: its day becomes the main day, the other day shrinks to a header, and the detail is measured inside its own
    /// area. The timeline is not stretched for it. Entering and leaving are described by `FocusRestore`; nothing here animates.
    static func focusedLayout(_ input: AllocationInput, _ focus: FocusRequest) -> AdaptiveLayout? {
        let scale = max(0.5, input.textScale)
        let p = input.parameters
        let days = [input.main] + (input.secondary.map { [$0] } ?? [])

        func ownLines(_ day: AllocationDay) -> [AllocationTransaction] {
            day.transactions + day.events.flatMap { $0.outsideRange.filter { $0.dayOffset == 0 } }
        }
        var targetDay: AllocationDay?
        var rows: [FocusDetailRow] = []
        var needed: CGFloat = 0
        switch focus.target {
        case let .event(eventID):
            for day in days {
                guard let event = day.events.first(where: { $0.id == eventID }) else { continue }
                targetDay = day
                rows = event.linked.sorted { ($0.dayOffset, $0.minute, $0.id) < ($1.dayOffset, $1.minute, $1.id) }.map { transaction in
                    FocusDetailRow(
                        transactionID: transaction.id, minute: transaction.minute, dayOffset: transaction.dayOffset, kind: transaction.kind,
                        currency: transaction.currency, minorUnits: transaction.minorUnits,
                        relation: event.contains(transaction) ? .insideEventRange : .outsideEventRange
                    )
                }
                needed = (p.titleRow + CGFloat(rows.count) * p.detailRow) * scale
            }
        case let .overflow(_, ids):
            for day in days {
                let available = ownLines(day)
                let members = ids.compactMap { id in available.first { $0.id == id } }
                guard members.count == ids.count, !ids.isEmpty else { continue }
                targetDay = day
                rows = members.sorted { ($0.minute, $0.id) < ($1.minute, $1.id) }.map { transaction in
                    FocusDetailRow(
                        transactionID: transaction.id, minute: transaction.minute, dayOffset: 0, kind: transaction.kind,
                        currency: transaction.currency, minorUnits: transaction.minorUnits, relation: .overflowMember
                    )
                }
                needed = (p.titleRow + CGFloat(rows.count) * p.detailRow) * scale
            }
        }
        guard let target = targetDay else { return nil }

        let other = days.first { $0.day != target.day }
        let header = other == nil ? 0 : p.secondaryHeader * scale
        let available = max(0, input.viewportHeight - header - p.focusContext * scale)
        let focusLayout = FocusLayout(
            target: focus.target, mainDay: target.day, secondaryDay: other?.day,
            secondary: other == nil ? .none : .headerOnly(height: header),
            rows: rows, detailHeightNeeded: needed, detailHeightAvailable: available, restore: focus.restore
        )
        // The timeline behind the detail is the focused day alone, kept to the small context area.
        var context = input
        context.main = target
        context.secondary = nil
        context.focus = nil
        context.previous = nil
        context.viewportHeight = p.focusContext * scale
        return compute(context, focus: focusLayout)
    }
}

/// How events relate to the ones they overlap, for any day. At most one step of indent, whatever the depth of the overlap. Shared by the
/// engine and by the renderer, so a day the engine did not lay out (one sliding in) is drawn by the same rule.
enum EventOverlapAnalysis {
    /// Events must be sorted by (start, end descending, id).
    static func analyse(_ events: [AllocationEvent]) -> [String: EventOverlap] {
        var result: [String: EventOverlap] = [:]
        var placed: [AllocationEvent] = []
        var groups: [[String]] = []
        var groupEnd = Int.min
        for event in events {
            let end = event.effectiveEnd
            let active = placed.filter { $0.effectiveEnd > event.startMinute }
            let containing = active.filter { $0.startMinute <= event.startMinute && $0.effectiveEnd >= end }
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
        for (groupIndex, group) in groups.enumerated() {
            for id in group {
                guard let old = result[id] else { continue }
                result[id] = EventOverlap(
                    role: old.role, indent: old.indent, pullsInOnRight: old.pullsInOnRight,
                    groupSize: group.count, groupIndex: groupIndex, summarisesTitles: group.count >= 3
                )
            }
        }
        return result
    }
}
