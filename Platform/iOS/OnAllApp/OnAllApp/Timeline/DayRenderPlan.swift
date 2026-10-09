import CoreGraphics
import Foundation
import NEOBudgetCalendar
import NEOBudgetCore

/// Where everything of one day goes on screen, decided from the layout engine's output and the shared axis. Pure geometry: no
/// SwiftUI, so it is unit-tested, and the grid draws and hit-tests from the very same plan (what is drawn is what is touched).
///
/// It decides nothing about policy. Which events show their inside transactions, which titles move to a header, which transaction
/// lines overflow, and how overlapping events are indented, all come from `AdaptiveLayout`; this only turns them into rectangles. A
/// day that the engine did not lay out (one sliding in during a swipe) is drawn in its plainest form by the same rules.
struct DayRenderPlan {
    /// What a transaction line says. Looked up from the day's timeline by transaction id.
    struct TransactionDisplay: Equatable {
        let title: String?
        let amount: Money
        let flow: TransactionFlow
        let isApproximate: Bool
        /// The classified spending category, when there is one (it picks the row's icon).
        var categoryID: CanonicalCategoryID? = nil
    }

    struct EventItem {
        let block: EventBlock
        let placement: EventPlacement?
        let frame: CGRect
        /// The frame a finger may hit: never shorter than a finger needs.
        let touchFrame: CGRect
        var title: DayContentLayout.TitlePlacement
        /// The header above the start boundary, when the engine moved the title there. Same event, not part of its time.
        let header: CGRect?
        /// False when the title is drawn in a header or in an overlap summary instead.
        var showsTitleInCard: Bool
        /// Linked transactions inside the event's time, in the order the card shows them, and how many it shows / sums up.
        let insideRows: [AllocationItem]
        let shownRows: Int
        let hiddenRows: Int
        /// How wide the title may run, when the engine shortened it to stay clear of a transaction line's text; `nil` for the full card.
        var titleMaxWidth: CGFloat?
        /// Where on the axis each shown inside transaction happened (absolute y), in the order of the rows.
        var insideAnchors: [CGFloat] = []
        /// Too short for a title row but tall enough to hold its title in a line of its own: the card writes it inside, centred, smaller.
        var isCompact = false
        /// Drawn by a crowd's one card (see `Summary.segments`), not on its own.
        var isGrouped = false
    }

    /// Three or more overlapping events: one line naming them all, with a way to pick each.
    struct Summary {
        let frame: CGRect
        let items: [(id: BlockID, title: String)]
        /// A crowd of events that cannot each be named at the room the axis gives them (a day sliding in): only how many, and the events
        /// themselves stay in view as thin cards at their true times.
        var countOnly = false
        /// The calendar colour of each of its events, so a crowd of different colours is still readable at a glance.
        var colors: [String?] = []
        /// For a crowd: each event's colour over the part of the card (offset from its top, height) its time covers.
        var segments: [(offset: CGFloat, height: CGFloat, colorHex: String?)] = []
    }

    struct LineItem {
        let id: String
        let display: TransactionDisplay?
        let link: LinkMetadata?
        /// The title of the event a linked line belongs to, for its small label.
        let linkedEventTitle: String?
        var frame: CGRect
        var touchFrame: CGRect
        /// Where on the axis the transaction really happened. The row's text may sit elsewhere (stacked clear of another row, or lined up
        /// with a title that is not drawn); its leader then bends from this point to the text.
        var anchorY: CGFloat? = nil
    }

    struct OverflowItem {
        let id: String
        var frame: CGRect
        var touchFrame: CGRect
        var anchorY: CGFloat? = nil
        let members: [OverflowMember]
        let countsByKind: [KindCount]
        let amountTotals: [AmountSum]
        let showsAmountTotal: Bool
        /// The stable id to hand to a focus target.
        var focusTarget: FocusTarget { .overflow(overflowID: id, transactionIDs: members.map(\.transactionID)) }
    }

    enum Candidate: Hashable {
        case event(BlockID)
        case line(String)
        case overflow(String)
    }

    enum Hit: Equatable {
        case nothing
        case event(BlockID)
        case line(String)
        case overflow(String)
        /// Several things could be meant: the touch areas meet, or the thing meant is covered. The person chooses.
        case choose([Candidate])
    }

    /// Back to front.
    private(set) var events: [EventItem] = []
    private(set) var summaries: [Summary] = []
    private(set) var lines: [LineItem] = []
    private(set) var overflows: [OverflowItem] = []
    private let conflicts: [[Candidate]]
    private let hitOrder: [BlockID]

    static let coveredEventSample = 24

    init(
        timeline: DayTimeline, role: DayRole?, layout: AdaptiveLayout?, geometry: TimelineGeometry, layoutWidth: CGFloat,
        textScale: CGFloat = 1, expanded: BlockID? = nil, focused: BlockID? = nil, parameters: AllocationParameters = AllocationParameters(),
        settled: Bool = true, titleWidth: (String) -> CGFloat
    ) {
        let scale = max(0.5, textScale)
        let contentWidth = geometry.contentWidth(totalWidth: layoutWidth)
        let contentLeft = geometry.gutterWidth
        let blocks = timeline.blocks
        let content = DayContentLayout(blocks: blocks)
        let byRealEnd: [String: Int] = Dictionary(blocks.map { ($0.id.rawValue, max($0.endMinute, $0.startMinute + 1)) }, uniquingKeysWith: { first, _ in first })
        let allocationDay = AllocationDay(timeline)
        let analysed = EventOverlapAnalysis.analyse(allocationDay.events.sorted { ($0.startMinute, -$0.endMinute, $0.id) < ($1.startMinute, -$1.endMinute, $1.id) })

        func placement(_ block: EventBlock) -> EventPlacement? {
            guard let role, let layout else { return nil }
            return layout.events.first { $0.key.role == role && $0.id == block.id.rawValue }
        }
        func overlap(_ block: EventBlock) -> EventOverlap? { placement(block)?.overlap ?? analysed[block.id.rawValue] }
        // Which events lie on one another is judged by their real times. The engine counts an event as at least a quarter hour long (what is
        // drawn), so a short event just before another would be called overlapping it and push it aside; on screen it is only the card's
        // minimum that reaches over, which is cut back below instead.
        let realOverlap: [String: EventOverlap] = EventOverlapAnalysis.analyse(
            allocationDay.events.map {
                AllocationEvent(id: $0.id, title: $0.title, startMinute: $0.startMinute, endMinute: byRealEnd[$0.id] ?? $0.endMinute, linked: $0.linked)
            }.sorted { ($0.startMinute, -$0.endMinute, $0.id) < ($1.startMinute, -$1.endMinute, $1.id) }
        )

        // How an event looks depends only on the room it has, never on whether anything is moving. A card is as tall as the axis makes it
        // (its start and end are never moved to suit a minimum), and what does not fit in that height is cut back in steps:
        //   a title row (≥ 19pt): the card as it is;
        //   less (≥ 11pt): the same card, thin, with its title in one smaller line inside it and nothing else;
        //   less than that: a sliver of the same card, its title taken out; where slivers follow one another they are named by one count.
        // The selected or opened event keeps the size its handles are drawn for.
        let incoming = role == nil || layout == nil || !settled
        let trueMinimumHeight: CGFloat = 3
        let titleRowHeight = (InlineAllocationPlan.titleHeight + 3) * scale
        let compactHeight = 11 * scale

        // Frames. An overlapping event keeps the full width, indented by at most one step; an inner one is also pulled in on the right.
        var frames: [BlockID: CGRect] = [:]
        for block in blocks {
            let shape = realOverlap[block.id.rawValue] ?? overlap(block)
            let insets = CardInsets(left: CGFloat(shape?.indent ?? 0) * parameters.indentStep, right: (shape?.pullsInOnRight ?? false) ? 6 : 0)
            var frame = geometry.blockFrame(block, totalWidth: layoutWidth, expanded: expanded == block.id, insets: insets)
            if expanded != block.id, block.id != focused {
                frame.size.height = max(trueMinimumHeight, geometry.y(minute: block.displayEndMinute) - geometry.y(minute: block.displayStartMinute) - 1)
            }
            frames[block.id] = frame
        }
        // A card never runs on over an event that begins after it ends, and two events with a gap in time never look joined: it stops 2pt
        // short of the next one's start (at most that much above its own true end, never below 3pt).
        for block in blocks where expanded != block.id {
            guard var frame = frames[block.id], block.id != focused else { continue }
            let realEnd = max(block.endMinute, block.startMinute + 1)
            let nextTops = blocks.compactMap { other -> CGFloat? in
                guard other.id != block.id, other.startMinute >= realEnd, let top = frames[other.id]?.minY, top > frame.minY + 0.5 else { return nil }
                return top
            }
            guard let nextTop = nextTops.min(), frame.maxY > nextTop - 2 else { continue }
            frame.size.height = max(trueMinimumHeight, nextTop - frame.minY - 2)
            frames[block.id] = frame
        }
        // Events that start within a title row of one another and share time cannot be stacked without one's edge crossing the other's title:
        // they go side by side, each in its own lane of the column (every other overlap keeps its indent).
        do {
            let movable = blocks.filter { $0.id != expanded && $0.id != focused && frames[$0.id] != nil }
                .sorted { (frames[$0.id]?.minY ?? 0, -(frames[$0.id]?.maxY ?? 0), $0.id) < (frames[$1.id]?.minY ?? 0, -(frames[$1.id]?.maxY ?? 0), $1.id) }
            var components: [[EventBlock]] = []
            var bottom: CGFloat = -.infinity
            for block in movable {
                guard let frame = frames[block.id] else { continue }
                if components.isEmpty || frame.minY >= bottom { components.append([block]); bottom = frame.maxY } else { components[components.count - 1].append(block); bottom = max(bottom, frame.maxY) }
            }
            let titleRow = (InlineAllocationPlan.titleHeight + 3) * scale
            for component in components where component.count >= 2 {
                let crowdedStarts = component.enumerated().contains { index, block in
                    guard let top = frames[block.id]?.minY else { return false }
                    return component.dropFirst(index + 1).contains { other in
                        guard let otherTop = frames[other.id]?.minY, let frame = frames[block.id] else { return false }
                        return otherTop - top < titleRow && otherTop < frame.maxY - 0.5
                    }
                }
                guard crowdedStarts else { continue }
                var laneEnds: [CGFloat] = []
                var lanes: [BlockID: Int] = [:]
                for block in component {
                    guard let frame = frames[block.id] else { continue }
                    if let lane = laneEnds.firstIndex(where: { $0 <= frame.minY }) { lanes[block.id] = lane; laneEnds[lane] = frame.maxY } else { lanes[block.id] = laneEnds.count; laneEnds.append(frame.maxY) }
                }
                // Two lanes are still wide enough for a title each; three or more at one moment keep the stacked indent and the one summary.
                guard laneEnds.count == 2 else { continue }
                let count = 2
                let base = geometry.blockFrame(component[0], totalWidth: layoutWidth)
                let gap: CGFloat = 3
                let width = (base.width - gap * CGFloat(count - 1)) / CGFloat(count)
                for block in component {
                    guard var frame = frames[block.id] else { continue }
                    let lane = min(lanes[block.id] ?? 0, count - 1)
                    frame.origin.x = base.minX + CGFloat(lane) * (width + gap)
                    frame.size.width = width
                    frames[block.id] = frame
                }
            }
        }
        let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Which events are compact (title inside, smaller) and which are slivers; runs of slivers are one count.
        var compactIDs = Set<BlockID>()
        var slivers: [EventBlock] = []
        for block in blocks where block.id != focused && block.id != expanded {
            guard let frame = frames[block.id], placement(block)?.header == nil else { continue }
            if frame.height < compactHeight { slivers.append(block) } else if frame.height < titleRowHeight { compactIDs.insert(block.id) }
        }
        slivers.sort { (frames[$0.id]?.minY ?? 0, $0.id) < (frames[$1.id]?.minY ?? 0, $1.id) }
        var crowdRuns: [[EventBlock]] = []
        var runBottom: CGFloat = -.infinity
        for block in slivers {
            guard let frame = frames[block.id] else { continue }
            if crowdRuns.isEmpty || frame.minY > runBottom + titleRowHeight {
                crowdRuns.append([block])
                runBottom = frame.maxY
            } else {
                crowdRuns[crowdRuns.count - 1].append(block)
                runBottom = max(runBottom, frame.maxY)
            }
        }
        let crowdIDs = Set(crowdRuns.filter { $0.count >= 2 }.flatMap { $0.map(\.id) })
        let titleContent = (compactIDs.isEmpty && crowdIDs.isEmpty) ? content : DayContentLayout(blocks: blocks.filter { !compactIDs.contains($0.id) && !crowdIDs.contains($0.id) })
        let places = titleContent.titlePlacements(
            top: { geometry.y(minute: byID[$0]?.displayStartMinute ?? 0) },
            bottom: { geometry.y(minute: byID[$0]?.displayEndMinute ?? 0) },
            left: { (frames[$0]?.minX ?? 0) + EventTitleLayer.horizontalPadding },
            right: { (frames[$0]?.maxX ?? 0) - EventTitleLayer.horizontalPadding },
            width: { titleWidth(byID[$0]?.title ?? "") },
            columnRight: contentLeft + contentWidth - EventTitleLayer.horizontalPadding,
            minimumHeight: trueMinimumHeight, focused: focused, rowHeight: DayContentLayout.titleRowHeight * scale,
            titlesOnly: true
        )

        // Overlap groups of three or more: their titles become one summary at the group's first card.
        var hiddenByGroup = Set<BlockID>()
        var summaries: [Summary] = []
        var groupMembers: [Int: [EventBlock]] = [:]
        for block in blocks where !compactIDs.contains(block.id) && !crowdIDs.contains(block.id) {
            if let shape = overlap(block), shape.summarisesTitles { groupMembers[shape.groupIndex, default: []].append(block) }
        }
        for index in groupMembers.keys.sorted() {
            let all = (groupMembers[index] ?? []).sorted { content.order.firstIndex(of: $0.id) ?? 0 < content.order.firstIndex(of: $1.id) ?? 0 }
            // Only events whose titles could not be kept apart by moving them (and the ones they would have landed on) are summarised;
            // a long event that merely holds the others, or events spread over the day, keep their own titles.
            let near = parameters.titleRow * 2 * scale
            let moved = all.filter { (places[$0.id] ?? .init()) != DayContentLayout.TitlePlacement() }
            let members = all.filter { member in
                moved.contains { $0.id == member.id } || moved.contains { abs((frames[$0.id]?.minY ?? 0) - (frames[member.id]?.minY ?? 0)) < near }
            }
            guard members.count >= 3, let first = members.first, let frame = frames[first.id] else { continue }
            let union = members.compactMap { frames[$0.id] }.reduce(frame) { $0.union($1) }
            summaries.append(Summary(
                frame: CGRect(x: union.minX, y: frame.minY, width: union.width, height: parameters.titleRow * scale),
                items: members.map { ($0.id, $0.title) }
            ))
            for member in members where member.id != focused && member.id != expanded { hiddenByGroup.insert(member.id) }
        }

        // Slivers that follow one another are named by one count, written over them in the card's own text place, with a dot per calendar
        // colour; the cards themselves stay, thin, at their true times.
        for run in crowdRuns where run.count >= 2 {
            let union = run.compactMap { frames[$0.id] }.reduce(CGRect.null) { $0.union($1) }
            let height = 14 * scale
            // One card stands for the run: its left edge is a stripe of each event's colour over the time that event covers, and its text is
            // the count. The events inside are not drawn on top of it.
            let card = CGRect(x: union.minX, y: union.minY, width: union.width, height: max(union.height, 16 * scale))
            summaries.append(Summary(
                frame: card, items: run.map { ($0.id, $0.title) }, countOnly: true, colors: run.map(\.calendarColorHex),
                segments: run.compactMap { block in frames[block.id].map { ($0.minY - card.minY, $0.height, block.calendarColorHex) } }
            ))
            for member in run { hiddenByGroup.insert(member.id) }
        }

        // Events, back to front.
        let ordered = content.hitOrder(focused: focused ?? expanded).reversed()
        var eventItems: [EventItem] = []
        for id in ordered {
            guard let block = byID[id], let frame = frames[id] else { continue }
            let isCompact = compactIDs.contains(id)
            let placed = placement(block)
            var header: CGRect?
            if let spec = placed?.header, expanded != block.id {
                header = CGRect(x: frame.minX, y: frame.minY - spec.height, width: frame.width, height: spec.height)
            }
            let inside = (isCompact || crowdIDs.contains(id)) ? (rows: [AllocationItem](), shown: 0, hidden: 0) : Self.insideAllocations(of: block, placement: placed, blockHeight: frame.height)
            let touchMissing = max(0, parameters.minimumTouchHeight - frame.height)
            eventItems.append(EventItem(
                block: block, placement: placed, frame: frame,
                touchFrame: frame.insetBy(dx: 0, dy: -touchMissing / 2), title: places[id] ?? .init(),
                header: header, showsTitleInCard: header == nil && !hiddenByGroup.contains(id) && !isCompact,
                insideRows: inside.rows, shownRows: inside.shown, hiddenRows: inside.hidden,
                titleMaxWidth: {
                    switch placed?.titleResolution {
                    case let .abbreviated(maxWidth)?: return maxWidth
                    case let .cramped(width)?: return width
                    default: return nil
                    }
                }(),
                insideAnchors: inside.rows.prefix(inside.shown).map { geometry.y(minute: Int(($0.occurredAtUnixMilliseconds - timeline.dayStartUnixMilliseconds) / 60_000)) },
                isCompact: isCompact, isGrouped: crowdIDs.contains(id)
            ))
        }

        // Transaction lines and overflows, stacked so that none sits on another.
        struct Unit {
            let anchor: Int
            let height: CGFloat
            let make: (CGFloat, CGFloat, CGFloat) -> Void        // center y, x, width
            let id: String
        }
        let displays = Self.displays(of: timeline)
        var lineItems: [LineItem] = []
        var overflowItems: [OverflowItem] = []
        let lineWidth = min(contentWidth, max(parameters.minimumLineWidth, contentWidth * parameters.lineWidthShare))
        let lineX = contentLeft + contentWidth - lineWidth - geometry.columnSpacing
        let gap = parameters.lineGap * scale

        struct Placed { let anchor: Int; let id: String; let height: CGFloat; let kind: Int; let index: Int }
        var placedUnits: [Placed] = []
        var sourceLines: [TransactionLine] = []
        var sourceOverflows: [TransactionOverflow] = []
        if let role, let layout {
            sourceLines = layout.lines.filter { $0.role == role }
            sourceOverflows = layout.overflows.filter { $0.role == role }
        } else {
            // A day the engine did not lay out: every transaction is a line to begin with.
            for marker in timeline.markers {
                sourceLines.append(TransactionLine(
                    key: ItemKey(role: .secondary, kind: .transactionLink, id: marker.transactionID.rawValue), role: .secondary,
                    transactionID: marker.transactionID.rawValue, minute: marker.positionMinute,
                    kind: marker.flow == .refund ? .refund : .spend, currency: marker.amount.currency, minorUnits: marker.amount.minorUnits,
                    link: nil, isPartlyLinked: false
                ))
            }
        }
        // The same rule as for events: what is written depends on the room the axis gives it right now. Where the engine's decision was made
        // for another axis (a day it did not lay out, or an axis still changing), transactions that would be closer together than a row
        // are one summary, not rows pushed apart down the day.
        if incoming {
            let pitch = (parameters.transactionRow + parameters.lineGap) * scale
            let flat: [TransactionLine] = sourceLines + sourceOverflows.flatMap { overflow in
                overflow.members.map {
                    TransactionLine(
                        key: ItemKey(role: overflow.role, kind: .transactionLink, id: $0.transactionID), role: overflow.role, transactionID: $0.transactionID,
                        minute: $0.minute, kind: $0.kind, currency: $0.currency, minorUnits: $0.minorUnits, link: $0.link, isPartlyLinked: false
                    )
                }
            }
            var clusters: [[TransactionLine]] = []
            var lastY: CGFloat = -.infinity
            for line in flat.sorted(by: { ($0.minute, $0.transactionID) < ($1.minute, $1.transactionID) }) {
                let y = geometry.y(minute: line.minute)
                if clusters.isEmpty || y - lastY >= pitch { clusters.append([line]) } else { clusters[clusters.count - 1].append(line) }
                lastY = y
            }
            sourceLines = clusters.filter { $0.count == 1 }.map { $0[0] }
            sourceOverflows = clusters.filter { $0.count > 1 }.map { cluster in
                let members = cluster.map { OverflowMember(transactionID: $0.transactionID, minute: $0.minute, kind: $0.kind, currency: $0.currency, minorUnits: $0.minorUnits, link: $0.link) }
                let totals = AmountSum.totals(of: cluster.map { AllocationTransaction(id: $0.transactionID, minute: $0.minute, kind: $0.kind, currency: $0.currency, minorUnits: $0.minorUnits) })
                let kinds = Dictionary(grouping: cluster, by: \.kind).map { KindCount(kind: $0.key, count: $0.value.count) }.sorted { $0.kind < $1.kind }
                return TransactionOverflow(
                    id: "overflow-\(cluster[0].minute)-\(cluster[0].transactionID)", role: cluster[0].role, members: members,
                    startMinute: cluster.first?.minute ?? 0, endMinute: cluster.last?.minute ?? 0, countsByKind: kinds, amountTotals: totals,
                    showsAmountTotal: totals.count == 1, requiredHeight: parameters.overflowCard * scale
                )
            }
        }
        for (i, line) in sourceLines.enumerated() { placedUnits.append(Placed(anchor: line.minute, id: line.transactionID, height: parameters.transactionRow * scale, kind: 0, index: i)) }
        for (i, overflow) in sourceOverflows.enumerated() {
            placedUnits.append(Placed(anchor: (overflow.startMinute + overflow.endMinute) / 2, id: overflow.id, height: overflow.requiredHeight, kind: 1, index: i))
        }
        placedUnits.sort { ($0.anchor, $0.id) < ($1.anchor, $1.id) }
        var previousCenter: CGFloat?
        var previousHeight: CGFloat = 0
        for unit in placedUnits {
            var center = geometry.y(minute: unit.anchor)
            if let previousCenter { center = max(center, previousCenter + (previousHeight + unit.height) / 2 + gap) }
            // A row never lands on the name of a crowd of events: it moves below it (its leader bends back to the time it happened).
            for _ in 0..<4 {
                guard let label = summaries.first(where: { abs(center - $0.frame.midY) < (unit.height + $0.frame.height) / 2 }) else { break }
                center = label.frame.maxY + unit.height / 2 + gap
            }
            previousCenter = center
            previousHeight = unit.height
            // A row writes from the day's left edge, like the text of an event, unless the title of an event is on its row: then it keeps to
            // the right part the engine left it, so the two never print over one another.
            var frame = CGRect(x: lineX, y: center - unit.height / 2, width: lineWidth, height: unit.height)
            let rowText = frame.insetBy(dx: 0, dy: 4 * scale)
            let titleRows = eventItems.filter { $0.header == nil && $0.showsTitleInCard }.map { CGRect(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: (EventTitleLayer.rowHeight + 2) * scale) }
                + eventItems.compactMap(\.header) + summaries.map(\.frame)
            if !titleRows.contains(where: { $0.intersects(rowText) }) {
                frame = CGRect(x: contentLeft, y: frame.minY, width: frame.maxX - contentLeft, height: frame.height)
            }
            let missing = max(0, parameters.minimumTouchHeight - unit.height)
            let touch = frame.insetBy(dx: 0, dy: -missing / 2)
            if unit.kind == 0 {
                let line = sourceLines[unit.index]
                let linkTitle = line.link.flatMap { link in blocks.first { $0.id.rawValue == link.eventID }?.title }
                lineItems.append(LineItem(id: unit.id, display: displays[unit.id], link: line.link, linkedEventTitle: linkTitle, frame: frame, touchFrame: touch, anchorY: geometry.y(minute: unit.anchor)))
            } else {
                let overflow = sourceOverflows[unit.index]
                overflowItems.append(OverflowItem(
                    id: overflow.id, frame: frame, touchFrame: touch, anchorY: geometry.y(minute: unit.anchor), members: overflow.members, countsByKind: overflow.countsByKind,
                    amountTotals: overflow.amountTotals, showsAmountTotal: overflow.showsAmountTotal
                ))
            }
        }

        // What the engine says about touch areas meeting, in terms of what the renderer draws.
        func candidate(_ id: String) -> Candidate? {
            if lineItems.contains(where: { $0.id == id }) { return .line(id) }
            if overflowItems.contains(where: { $0.id == id }) { return .overflow(id) }
            if let block = blocks.first(where: { $0.id.rawValue == id }) { return .event(block.id) }
            return nil
        }
        var conflictSets: [[Candidate]] = []
        if let layout, let role {
            let mine = Set(layout.events.filter { $0.key.role == role }.map(\.id) + sourceLines.map(\.transactionID) + sourceOverflows.map(\.id))
            for conflict in layout.touchConflicts where conflict.candidates.allSatisfy({ mine.contains($0) }) {
                let list = conflict.candidates.compactMap(candidate)
                if list.count > 1 { conflictSets.append(list) }
            }
        }

        // The engine shortens a title that could meet a line's text; here it is only kept short if a drawn line or overflow really is on the
        // title's row, so a title is never cut for a line that is below it.
        let drawnLines = (lineItems.map(\.frame) + overflowItems.map(\.frame)).map { $0.insetBy(dx: 0, dy: 4 * scale) }      // the text, not the row's air
        var hiddenTitleRows: [CGRect] = []
        eventItems = eventItems.map { item in
            guard item.titleMaxWidth != nil else { return item }
            let row = CGRect(x: item.frame.minX, y: item.frame.minY, width: item.frame.width, height: (InlineAllocationPlan.titleHeight + 2) * scale)
            guard drawnLines.contains(where: { $0.intersects(row) }) else { var copy = item; copy.titleMaxWidth = nil; return copy }
            // A transaction is on the title and there is no header to move it to: the transaction is what is shown, and the title is left out.
            var copy = item
            copy.showsTitleInCard = false
            hiddenTitleRows.append(CGRect(x: item.frame.minX, y: item.frame.minY, width: item.frame.width, height: (EventTitleLayer.rowHeight + 2) * scale))
            return copy
        }
        // Where a title is left out, the transaction takes the title's row and is written there, neatly under the card's top edge; its leader
        // bends from the moment it happened to that row.
        func lineUp(_ frame: CGRect, _ touch: CGRect) -> (CGRect, CGRect) {
            guard let row = hiddenTitleRows.first(where: { $0.intersects(frame.insetBy(dx: 0, dy: 4 * scale)) }) else { return (frame, touch) }
            let dy = (row.minY + 11 * scale) - frame.midY
            return (frame.offsetBy(dx: 0, dy: dy), touch.offsetBy(dx: 0, dy: dy))
        }
        for index in lineItems.indices { (lineItems[index].frame, lineItems[index].touchFrame) = lineUp(lineItems[index].frame, lineItems[index].touchFrame) }
        for index in overflowItems.indices { (overflowItems[index].frame, overflowItems[index].touchFrame) = lineUp(overflowItems[index].frame, overflowItems[index].touchFrame) }
        events = eventItems
        self.summaries = summaries
        lines = lineItems
        overflows = overflowItems
        conflicts = conflictSets
        hitOrder = content.hitOrder(focused: focused ?? expanded)
    }

    // MARK: Hit testing

    /// What a touch at `point` (in this day's layout coordinates) means. A line or overflow drawn at the point wins, then an event or
    /// its header. Where nothing is drawn but touch areas meet, or where the thing drawn covers another that can be reached no other way,
    /// the candidates are returned for the person to choose between.
    func hit(at point: CGPoint) -> Hit {
        if let overflow = overflows.first(where: { $0.frame.contains(point) }) {
            return covered(by: .overflow(overflow.id), at: point)
        }
        if let line = lines.first(where: { $0.frame.contains(point) }) { return covered(by: .line(line.id), at: point) }
        for id in hitOrder {
            guard let item = events.first(where: { $0.block.id == id }) else { continue }
            if item.frame.contains(point) || (item.header?.contains(point) ?? false) { return .event(id) }
        }
        // Nothing drawn here: the touch areas decide.
        var near: [Candidate] = []
        for item in events where item.touchFrame.contains(point) { near.append(.event(item.block.id)) }
        for line in lines where line.touchFrame.contains(point) { near.append(.line(line.id)) }
        for overflow in overflows where overflow.touchFrame.contains(point) { near.append(.overflow(overflow.id)) }
        switch near.count {
        case 0: return .nothing
        case 1: return Self.hit(of: near[0])
        default: return .choose(near)
        }
    }

    private func covered(by top: Candidate, at point: CGPoint) -> Hit {
        // An event the lines leave no way to touch is offered together with the line, so it can still be chosen.
        let hidden = events.filter { $0.frame.contains(point) && !isReachable($0) }.map { Candidate.event($0.block.id) }
        let met = conflicts.first { $0.contains(top) }.map { $0.filter { $0 != top } } ?? []
        let others = hidden + met
        return others.isEmpty ? Self.hit(of: top) : .choose([top] + others)
    }

    /// Whether some part of the event can be touched without touching a line or overflow.
    private func isReachable(_ item: EventItem) -> Bool {
        let frame = item.frame
        let steps = Self.coveredEventSample
        for row in 0...3 {
            for column in 0...steps {
                let point = CGPoint(x: frame.minX + 2 + (frame.width - 4) * CGFloat(column) / CGFloat(steps), y: frame.minY + 2 + (max(0, frame.height - 4)) * CGFloat(row) / 3)
                if !lines.contains(where: { $0.frame.contains(point) }) && !overflows.contains(where: { $0.frame.contains(point) }) { return true }
            }
        }
        return false
    }

    private static func hit(of candidate: Candidate) -> Hit {
        switch candidate {
        case let .event(id): return .event(id)
        case let .line(id): return .line(id)
        case let .overflow(id): return .overflow(id)
        }
    }

    // MARK: From the timeline

    /// The linked transactions that happened within the event's time, in the order its card shows them, and how many it shows.
    static func insideAllocations(of block: EventBlock, placement: EventPlacement?, blockHeight: CGFloat) -> (rows: [AllocationItem], shown: Int, hidden: Int) {
        let inside = block.allocations.filter { item in
            guard item.occursOnSelectedDay else { return false }
            let minute = Int((item.occurredAtUnixMilliseconds - (block.startUnixMilliseconds - Int64(block.startMinute) * 60_000)) / 60_000)
            return minute >= block.startMinute && minute < max(block.endMinute, block.startMinute + 1)
        }
        let ordered = AllocationOrdering.byAmountDescending(inside)
        guard let placement else {
            let plan = InlineAllocationPlan.make(allocationCount: ordered.count, blockHeight: blockHeight, showsTime: false)
            return (ordered, plan.shown, ordered.count - plan.shown)
        }
        return (ordered, min(placement.shownInsideRows, ordered.count), placement.hiddenInsideCount)
    }

    /// What each transaction of the day says: its name and amount, from the timeline's own records.
    static func displays(of timeline: DayTimeline) -> [String: TransactionDisplay] {
        var result: [String: TransactionDisplay] = [:]
        for block in timeline.blocks {
            for item in block.allocations where result[item.transactionID.rawValue] == nil {
                result[item.transactionID.rawValue] = TransactionDisplay(
                    title: item.title, amount: item.transactionAmount, flow: item.flow, isApproximate: item.timePrecision == .approximate,
                    categoryID: item.categoryID
                )
            }
        }
        for marker in timeline.markers {
            result[marker.transactionID.rawValue] = TransactionDisplay(
                title: marker.title, amount: marker.amount, flow: marker.flow, isApproximate: marker.timePrecision == .approximate,
                categoryID: marker.categoryID
            )
        }
        return result
    }
}
