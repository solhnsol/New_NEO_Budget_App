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
        /// The event has no room for a card at its true size: it is a thin bar at its true start and end, named by a label beside the bars.
        var isMarker = false
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
        let allocationDay = AllocationDay(timeline)
        let analysed = EventOverlapAnalysis.analyse(allocationDay.events.sorted { ($0.startMinute, -$0.endMinute, $0.id) < ($1.startMinute, -$1.endMinute, $1.id) })

        func placement(_ block: EventBlock) -> EventPlacement? {
            guard let role, let layout else { return nil }
            return layout.events.first { $0.key.role == role && $0.id == block.id.rawValue }
        }
        func overlap(_ block: EventBlock) -> EventOverlap? { placement(block)?.overlap ?? analysed[block.id.rawValue] }

        // A day the engine did not lay out (one sliding in during a swipe) is drawn on the axis the two days on screen already have: every
        // event keeps its true start and end, never stretched to a minimum height, and what does not fit in its true height is cut back.
        // The same goes for any day while the axis is still changing shape under it: the engine's decisions are for the axis it is heading
        // to, and the room an event has on the way there is only what the axis gives it at that moment.
        let incoming = role == nil || layout == nil || !settled
        let trueMinimumHeight: CGFloat = 3

        // Frames. An overlapping event keeps the full width, indented by at most one step; an inner one is also pulled in on the right.
        var frames: [BlockID: CGRect] = [:]
        for block in blocks {
            let shape = overlap(block)
            let insets = CardInsets(left: CGFloat(shape?.indent ?? 0) * parameters.indentStep, right: (shape?.pullsInOnRight ?? false) ? 6 : 0)
            var frame = geometry.blockFrame(block, totalWidth: layoutWidth, expanded: expanded == block.id, insets: insets)
            if incoming, expanded != block.id {
                frame.size.height = max(trueMinimumHeight, geometry.y(minute: block.displayEndMinute) - geometry.y(minute: block.displayStartMinute) - 1)
            }
            frames[block.id] = frame
        }
        let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // An event with less room than a title needs is not given a card it cannot fill: it becomes a bar (below), and the others' titles
        // are placed as if it were not there.
        let titleRowHeight = (InlineAllocationPlan.titleHeight + 3) * scale
        var markerIDs = Set<BlockID>()
        if incoming {
            for block in blocks {
                if let frame = frames[block.id], frame.height < titleRowHeight, block.id != focused, block.id != expanded { markerIDs.insert(block.id) }
            }
        }
        let titleContent = markerIDs.isEmpty ? content : DayContentLayout(blocks: blocks.filter { !markerIDs.contains($0.id) })
        let places = titleContent.titlePlacements(
            top: { geometry.y(minute: byID[$0]?.displayStartMinute ?? 0) },
            bottom: { geometry.y(minute: byID[$0]?.displayEndMinute ?? 0) },
            left: { (frames[$0]?.minX ?? 0) + EventTitleLayer.horizontalPadding },
            right: { (frames[$0]?.maxX ?? 0) - EventTitleLayer.horizontalPadding },
            width: { titleWidth(byID[$0]?.title ?? "") },
            columnRight: contentLeft + contentWidth - EventTitleLayer.horizontalPadding,
            minimumHeight: incoming ? trueMinimumHeight : geometry.minimumBlockHeight, focused: focused, rowHeight: DayContentLayout.titleRowHeight * scale,
            titlesOnly: incoming
        )

        // Overlap groups of three or more: their titles become one summary at the group's first card.
        var hiddenByGroup = Set<BlockID>()
        var summaries: [Summary] = []
        var groupMembers: [Int: [EventBlock]] = [:]
        for block in blocks where !markerIDs.contains(block.id) {
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

        // Events too short for a card on this axis are bars at their true times, in lanes side by side where they overlap, with one label
        // to their right per run: the title if there is one event, else how many (and their colours).
        var markerFrames: [BlockID: CGRect] = [:]
        if !markerIDs.isEmpty {
            let marked = blocks.filter { markerIDs.contains($0.id) }
                .sorted { (frames[$0.id]?.minY ?? 0, $0.id) < (frames[$1.id]?.minY ?? 0, $1.id) }
            var runs: [[EventBlock]] = []
            var runBottom: CGFloat = -.infinity
            for block in marked {
                guard let frame = frames[block.id] else { continue }
                if runs.isEmpty || frame.minY > runBottom + titleRowHeight {
                    runs.append([block])
                    runBottom = frame.maxY
                } else {
                    runs[runs.count - 1].append(block)
                    runBottom = max(runBottom, frame.maxY)
                }
            }
            let barWidth: CGFloat = 4, laneStep: CGFloat = 6
            for run in runs {
                var laneEnds: [CGFloat] = []
                var lanes: [BlockID: Int] = [:]
                for block in run {
                    guard let frame = frames[block.id] else { continue }
                    if let lane = laneEnds.firstIndex(where: { $0 <= frame.minY }) {
                        lanes[block.id] = lane
                        laneEnds[lane] = frame.maxY
                    } else {
                        lanes[block.id] = laneEnds.count
                        laneEnds.append(frame.maxY)
                    }
                }
                for block in run {
                    guard let frame = frames[block.id] else { continue }
                    markerFrames[block.id] = CGRect(x: contentLeft + CGFloat(lanes[block.id] ?? 0) * laneStep, y: frame.minY, width: barWidth, height: frame.height)
                }
                let labelX = contentLeft + CGFloat(laneEnds.count) * laneStep + 4
                let top = run.compactMap { frames[$0.id]?.minY }.min() ?? 0
                summaries.append(Summary(
                    frame: CGRect(x: labelX, y: top - 3 * scale, width: max(0, contentLeft + contentWidth - labelX), height: 16 * scale),
                    items: run.map { ($0.id, $0.title) }, countOnly: true, colors: run.map(\.calendarColorHex)
                ))
                for member in run { hiddenByGroup.insert(member.id) }
            }
        }

        // Events, back to front.
        let ordered = content.hitOrder(focused: focused ?? expanded).reversed()
        var eventItems: [EventItem] = []
        for id in ordered {
            guard let block = byID[id], let cardFrame = frames[id] else { continue }
            let isMarker = markerFrames[id] != nil
            let frame = markerFrames[id] ?? cardFrame
            let placed = placement(block)
            var header: CGRect?
            if !isMarker, let spec = placed?.header, expanded != block.id {
                header = CGRect(x: frame.minX, y: frame.minY - spec.height, width: frame.width, height: spec.height)
            }
            let inside = isMarker ? (rows: [AllocationItem](), shown: 0, hidden: 0) : Self.insideAllocations(of: block, placement: placed, blockHeight: frame.height)
            let touchMissing = max(0, parameters.minimumTouchHeight - frame.height)
            eventItems.append(EventItem(
                block: block, placement: placed, frame: frame,
                touchFrame: frame.insetBy(dx: isMarker ? -6 : 0, dy: -touchMissing / 2), title: places[id] ?? .init(),
                header: header, showsTitleInCard: header == nil && !hiddenByGroup.contains(id),
                insideRows: inside.rows, shownRows: inside.shown, hiddenRows: inside.hidden,
                titleMaxWidth: {
                    switch placed?.titleResolution {
                    case let .abbreviated(maxWidth)?: return maxWidth
                    case let .cramped(width)?: return width
                    default: return nil
                    }
                }(),
                insideAnchors: isMarker ? [] : inside.rows.prefix(inside.shown).map { geometry.y(minute: Int(($0.occurredAtUnixMilliseconds - timeline.dayStartUnixMilliseconds) / 60_000)) },
                isMarker: isMarker
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
            for (i, line) in sourceLines.enumerated() { placedUnits.append(Placed(anchor: line.minute, id: line.transactionID, height: parameters.transactionRow * scale, kind: 0, index: i)) }
            for (i, overflow) in sourceOverflows.enumerated() {
                placedUnits.append(Placed(anchor: (overflow.startMinute + overflow.endMinute) / 2, id: overflow.id, height: overflow.requiredHeight, kind: 1, index: i))
            }
        } else {
            // A day the engine did not lay out: every transaction on its own line.
            for (i, marker) in timeline.markers.enumerated() {
                let line = TransactionLine(
                    key: ItemKey(role: .secondary, kind: .transactionLink, id: marker.transactionID.rawValue), role: .secondary,
                    transactionID: marker.transactionID.rawValue, minute: marker.positionMinute,
                    kind: marker.flow == .refund ? .refund : .spend, currency: marker.amount.currency, minorUnits: marker.amount.minorUnits,
                    link: nil, isPartlyLinked: false
                )
                sourceLines.append(line)
                placedUnits.append(Placed(anchor: marker.positionMinute, id: marker.transactionID.rawValue, height: parameters.transactionRow * scale, kind: 0, index: i))
            }
        }
        placedUnits.sort { ($0.anchor, $0.id) < ($1.anchor, $1.id) }
        var previousCenter: CGFloat?
        var previousHeight: CGFloat = 0
        for unit in placedUnits {
            var center = geometry.y(minute: unit.anchor)
            if let previousCenter { center = max(center, previousCenter + (previousHeight + unit.height) / 2 + gap) }
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
