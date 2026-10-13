import CoreGraphics
import Foundation
import NEOBudgetCalendar
import NEOBudgetCore

/// Where everything of one day goes on screen, decided from the layout engine's output and the shared axis. Pure geometry: no
/// SwiftUI, so it is unit-tested, and the grid draws and hit-tests from the very same plan (what is drawn is what is touched).
///
/// Every coordinate comes from the axis as it is: an event's top and bottom are the axis' y of its start and end, a transaction's
/// anchor is the axis' y of its time. What is *written* is decided by height alone, in `EventPresentation` (events) and by the room a
/// row really has (transactions); nothing here depends on whether the day is moving, on how many events there are, or on a second
/// kind of "compact" drawing. Which events show their inside transactions' kinds, how overlapping events are indented, which
/// transactions the engine folded into an overflow, all still come from `AdaptiveLayout`.
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
        /// Exactly from the axis: its start and end, never moved for text.
        let frame: CGRect
        /// What is drawn: the frame, but never thinner than a line can be seen (centred on the same time span).
        let drawnFrame: CGRect
        /// The frame a finger may hit: never shorter than a finger needs.
        let touchFrame: CGRect
        var title: DayContentLayout.TitlePlacement
        /// What the height allows to be written (see `EventPresentation`).
        let presentation: EventPresentation
        /// The header above the start boundary: an auxiliary place for the title of the same event, only where it covers nothing.
        var header: CGRect?
        /// False when the title is not written inside the card (no room, or it is in the header).
        var showsTitleInCard: Bool
        /// Linked transactions inside the event's time, in the order the card shows them, and how many it shows / sums up.
        let insideRows: [AllocationItem]
        let shownRows: Int
        let hiddenRows: Int
        /// How wide the title may run, when the engine shortened it to stay clear of a transaction line's text; `nil` for the full card.
        var titleMaxWidth: CGFloat?
        /// Where on the axis each shown inside transaction happened (absolute y), in the order of the rows.
        var insideAnchors: [CGFloat] = []
        /// Whether the start time has its place beside the title (the title and the time together fit the card's width).
        var startTimeFits = true
        /// Where the card writes its inside rows (with the "그 외"/summary row), in the stack `EventBlockView` lays out; `nil` when it writes none.
        var rowsFrame: CGRect?
    }

    struct LineItem {
        let id: String
        let display: TransactionDisplay?
        let link: LinkMetadata?
        /// The title of the event a linked line belongs to, for its small label.
        let linkedEventTitle: String?
        var frame: CGRect
        var touchFrame: CGRect
        /// Where on the axis the transaction really happened: the middle of its row, always.
        var anchorY: CGFloat? = nil
        /// 0 … 1: how much of the row's text there is room for (it is written from the left as this grows). The dot at the time stays.
        var reveal: CGFloat = 1
        /// Its dot and leader, at the column's edge on the row's height: drawn wherever the row is, so a touch there is the line's (unless a card is
        /// drawn there and the line's own row does not reach it).
        var markFrame: CGRect = .zero

        /// Whether a touch at `point` is this line's. Where no card is drawn: on its row or its dot. Over a card: on its row while any of its text is
        /// written, else only where its row and its dot meet, so the card under the unwritten text (its rows too) is touched as the card.
        func touches(_ point: CGPoint, overCard: Bool) -> Bool {
            guard overCard else { return frame.contains(point) || markFrame.contains(point) }
            return reveal > 0 ? frame.contains(point) : frame.intersection(markFrame).contains(point)
        }
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
        var reveal: CGFloat = 1
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
    private(set) var lines: [LineItem] = []
    private(set) var overflows: [OverflowItem] = []
    private let conflicts: [[Candidate]]
    private let hitOrder: [BlockID]

    static let coveredEventSample = 24
    /// The thinnest an event is ever drawn, however short its time is.
    static let thinnestDrawn: CGFloat = 2

    /// Everything about one day that does not depend on where time is drawn, how large it is drawn or what is focused: which events overlap and how, the
    /// engine's decision for each event and transaction, the linked transactions inside each event in the order they are shown, what each transaction says,
    /// which transactions are lines and which overflows, which touch areas meet. It changes only when the day's data, the role or the engine's layout
    /// changes, so it is made once and every frame (a zoom, a scroll, a move between two days) only places it (`init(prepared:...)`): no overlap analysis, no
    /// ordering, no lookups of what a transaction says, no matching of the engine's output to the day's items.
    final class Prepared {
        struct Shape { let indent: Int; let pullsInOnRight: Bool }
        /// A transaction line or an overflow, in time order. `requiredHeight` is the overflow's own height; a line's height depends on the text size.
        struct Unit {
            let anchor: Int
            let id: String
            let requiredHeight: CGFloat?
            let index: Int
            var isOverflow: Bool { requiredHeight != nil }
        }

        let day: LocalDate
        let role: DayRole?
        let blocks: [EventBlock]
        let byID: [BlockID: EventBlock]
        let content: DayContentLayout
        let shapes: [BlockID: Shape]
        let placements: [BlockID: EventPlacement]
        let insideAll: [BlockID: [AllocationItem]]
        /// The inside transactions in the order a card shows them, and the minute of the day each happened at (for where its row's dot is).
        let insideSorted: [BlockID: [AllocationItem]]
        let insideMinutes: [BlockID: [Int]]
        let displays: [String: TransactionDisplay]
        let sourceLines: [TransactionLine]
        let sourceOverflows: [TransactionOverflow]
        let units: [Unit]
        /// The title of the event each line is linked to, by the line's index.
        let lineLinkTitles: [String?]
        let conflicts: [[Candidate]]
        let defaultHitOrder: [BlockID]

        init(timeline: DayTimeline, role: DayRole?, layout: AdaptiveLayout?) {
            let blocks = timeline.blocks
            let allocationDay = AllocationDay(timeline)
            let byRealEnd: [String: Int] = Dictionary(blocks.map { ($0.id.rawValue, max($0.endMinute, $0.startMinute + 1)) }, uniquingKeysWith: { first, _ in first })
            let analysed = EventOverlapAnalysis.analyse(allocationDay.events.sorted { ($0.startMinute, -$0.endMinute, $0.id) < ($1.startMinute, -$1.endMinute, $1.id) })
            var placements: [BlockID: EventPlacement] = [:]
            if let role, let layout {
                for placement in layout.events where placement.key.role == role {
                    for block in blocks where block.id.rawValue == placement.id && placements[block.id] == nil { placements[block.id] = placement }
                }
            }
            // Which events lie on one another is judged by their real times (the engine counts an event as at least a quarter hour long).
            let realOverlap: [String: EventOverlap] = EventOverlapAnalysis.analyse(
                allocationDay.events.map {
                    AllocationEvent(id: $0.id, title: $0.title, startMinute: $0.startMinute, endMinute: byRealEnd[$0.id] ?? $0.endMinute, linked: $0.linked)
                }.sorted { ($0.startMinute, -$0.endMinute, $0.id) < ($1.startMinute, -$1.endMinute, $1.id) }
            )
            var shapes: [BlockID: Shape] = [:]
            for block in blocks {
                let overlap = realOverlap[block.id.rawValue] ?? placements[block.id]?.overlap ?? analysed[block.id.rawValue]
                shapes[block.id] = Shape(indent: overlap?.indent ?? 0, pullsInOnRight: overlap?.pullsInOnRight ?? false)
            }
            var insideAll: [BlockID: [AllocationItem]] = [:]
            var insideSorted: [BlockID: [AllocationItem]] = [:]
            var insideMinutes: [BlockID: [Int]] = [:]
            for block in blocks {
                let inside = DayRenderPlan.insideTransactions(of: block)
                insideAll[block.id] = inside
                let sorted = AllocationOrdering.byAmountDescending(inside)
                insideSorted[block.id] = sorted
                insideMinutes[block.id] = sorted.map { Int(($0.occurredAtUnixMilliseconds - timeline.dayStartUnixMilliseconds) / 60_000) }
            }

            var sourceLines: [TransactionLine] = []
            var sourceOverflows: [TransactionOverflow] = []
            if let role, let layout {
                sourceLines = layout.lines.filter { $0.role == role }
                sourceOverflows = layout.overflows.filter { $0.role == role }
            } else {
                // A day the engine did not lay out: every transaction is a line, at its time.
                for marker in timeline.markers {
                    sourceLines.append(TransactionLine(
                        key: ItemKey(role: .secondary, kind: .transactionLink, id: marker.transactionID.rawValue), role: .secondary,
                        transactionID: marker.transactionID.rawValue, minute: marker.positionMinute,
                        kind: marker.flow == .refund ? .refund : .spend, currency: marker.amount.currency, minorUnits: marker.amount.minorUnits,
                        link: nil, isPartlyLinked: false
                    ))
                }
            }
            var units: [Unit] = []
            for (i, line) in sourceLines.enumerated() { units.append(Unit(anchor: line.minute, id: line.transactionID, requiredHeight: nil, index: i)) }
            for (i, overflow) in sourceOverflows.enumerated() {
                units.append(Unit(anchor: (overflow.startMinute + overflow.endMinute) / 2, id: overflow.id, requiredHeight: overflow.requiredHeight, index: i))
            }
            units.sort { ($0.anchor, $0.id) < ($1.anchor, $1.id) }
            var titles: [String: String] = [:]
            for block in blocks where titles[block.id.rawValue] == nil { titles[block.id.rawValue] = block.title }
            lineLinkTitles = sourceLines.map { line in line.link.flatMap { titles[$0.eventID] } }

            // What the engine says about touch areas meeting, in terms of what the renderer draws.
            let lineIDs = Set(sourceLines.map(\.transactionID)), overflowIDs = Set(sourceOverflows.map(\.id)), blockIDs = Dictionary(blocks.map { ($0.id.rawValue, $0.id) }, uniquingKeysWith: { first, _ in first })
            func candidate(_ id: String) -> Candidate? {
                if lineIDs.contains(id) { return .line(id) }
                if overflowIDs.contains(id) { return .overflow(id) }
                if let block = blockIDs[id] { return .event(block) }
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

            let content = DayContentLayout(blocks: blocks)
            self.day = timeline.day
            self.role = role
            self.blocks = blocks
            self.byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.content = content
            self.shapes = shapes
            self.placements = placements
            self.insideAll = insideAll
            self.insideSorted = insideSorted
            self.insideMinutes = insideMinutes
            self.displays = DayRenderPlan.displays(of: timeline)
            self.sourceLines = sourceLines
            self.sourceOverflows = sourceOverflows
            self.units = units
            self.conflicts = conflictSets
            self.defaultHitOrder = content.hitOrder(focused: nil)
        }
    }

    init(
        timeline: DayTimeline, role: DayRole?, layout: AdaptiveLayout?, geometry: any TimeAxisMapping, layoutWidth: CGFloat,
        textScale: CGFloat = 1, expanded: BlockID? = nil, focused: BlockID? = nil, parameters: AllocationParameters = AllocationParameters(),
        metrics: EventPresentation.Metrics? = nil, maximumInlineRows: Int = InlineAllocationPlan.maximumRows, titleWidth: (String) -> CGFloat
    ) {
        self.init(
            prepared: Prepared(timeline: timeline, role: role, layout: layout), geometry: geometry, layoutWidth: layoutWidth, textScale: textScale,
            expanded: expanded, focused: focused, parameters: parameters, metrics: metrics, maximumInlineRows: maximumInlineRows, titleWidth: titleWidth
        )
    }

    /// Places a prepared day: only what depends on the axis, the text size and the focus is worked out here.
    init(
        prepared: Prepared, geometry: any TimeAxisMapping, layoutWidth: CGFloat,
        textScale: CGFloat = 1, expanded: BlockID? = nil, focused: BlockID? = nil, parameters: AllocationParameters = AllocationParameters(),
        metrics: EventPresentation.Metrics? = nil, maximumInlineRows: Int = InlineAllocationPlan.maximumRows, titleWidth: (String) -> CGFloat
    ) {
        let scale = max(0.5, textScale)
        let metrics = metrics ?? .standard(scale: scale)
        let contentWidth = geometry.contentWidth(totalWidth: layoutWidth)
        let contentLeft = geometry.gutterWidth
        let blocks = prepared.blocks
        let content = prepared.content
        let byID = prepared.byID

        // Frames. An event is exactly as tall as its time on the axis: nothing stretches it, nothing shortens it for the next event.
        // Events that truly overlap overlap on screen, in the same column, each indented by at most one step (an inner one is also pulled
        // in on the right). The selected or opened event keeps the size its handles are drawn for.
        var frames: [BlockID: CGRect] = [:]
        for block in blocks {
            let shape = prepared.shapes[block.id]
            let insets = CardInsets(left: CGFloat(shape?.indent ?? 0) * parameters.indentStep, right: (shape?.pullsInOnRight ?? false) ? 6 : 0)
            var frame = geometry.blockFrame(block, totalWidth: layoutWidth, expanded: expanded == block.id, insets: insets)
            if expanded != block.id, block.id != focused {
                // The real span (the display span is padded to a quarter hour for short events, which would stretch them).
                frame.origin.y = geometry.y(minute: block.startMinute)
                frame.size.height = max(0, geometry.y(bottomOfSpanFrom: block.startMinute, to: block.endMinute) - frame.origin.y)
            }
            frames[block.id] = frame
        }

        // How each event looks, from its height alone.
        var presentations: [BlockID: EventPresentation] = [:]
        for block in blocks {
            presentations[block.id] = EventPresentation.make(height: frames[block.id]?.height ?? 0, insideCount: prepared.insideAll[block.id]?.count ?? 0, metrics: metrics, maximumRows: maximumInlineRows)
        }

        // Titles written inside cards are kept apart by moving them down their column; an event without room for one has none to place.
        let titled = blocks.filter { ($0.id == focused || $0.id == expanded) || (presentations[$0.id]?.showsTitle ?? false) }
        let titleContent = titled.count == blocks.count ? content : DayContentLayout(blocks: titled)
        let places = titleContent.titlePlacements(
            top: { frames[$0]?.minY ?? 0 },
            bottom: { frames[$0]?.maxY ?? 0 },
            left: { (frames[$0]?.minX ?? 0) + EventTitleLayer.horizontalPadding },
            right: { (frames[$0]?.maxX ?? 0) - EventTitleLayer.horizontalPadding },
            width: { titleWidth(byID[$0]?.title ?? "") },
            columnRight: contentLeft + contentWidth - EventTitleLayer.horizontalPadding,
            minimumHeight: 1, focused: focused, rowHeight: DayContentLayout.titleRowHeight * scale,
            titlesOnly: true
        )

        // Events, back to front.
        let ordered = (focused ?? expanded).map { content.hitOrder(focused: $0) } ?? prepared.defaultHitOrder
        var eventItems: [EventItem] = []
        for id in ordered.reversed() {
            guard let block = byID[id], let frame = frames[id], let presentation = presentations[id] else { continue }
            let placed = prepared.placements[id]
            let inside = prepared.insideSorted[id] ?? []
            let shown = presentation.shownRows
            let place = places[id] ?? .init()
            var drawn = frame
            if drawn.height < Self.thinnestDrawn {
                drawn = CGRect(x: frame.minX, y: frame.midY - Self.thinnestDrawn / 2, width: frame.width, height: Self.thinnestDrawn)
            }
            let touchMissing = max(0, parameters.minimumTouchHeight - drawn.height)
            let titleRoom = titleWidth(block.title) + 36 * scale
            eventItems.append(EventItem(
                block: block, placement: placed, frame: frame, drawnFrame: drawn,
                touchFrame: drawn.insetBy(dx: 0, dy: -touchMissing / 2), title: place, presentation: presentation,
                header: nil, showsTitleInCard: presentation.showsTitle || id == focused,
                insideRows: inside, shownRows: shown, hiddenRows: presentation.hiddenRows,
                titleMaxWidth: {
                    switch placed?.titleResolution {
                    case let .abbreviated(maxWidth)?: return maxWidth
                    case let .cramped(width)?: return width
                    default: return nil
                    }
                }(),
                insideAnchors: (prepared.insideMinutes[id] ?? []).prefix(shown).map { geometry.y(minute: $0) },
                startTimeFits: place.dx == 0 && place.dy == 0 && !place.overflows && frame.width >= titleRoom,
                rowsFrame: Self.rowsFrame(card: drawn, titleOffset: place.dy, hasHeader: false, presentation: presentation, scale: scale)
            ))
        }

        // Transactions. Every one is written at the time it happened (its row's middle is the axis' y of that minute), and only where a row
        // really has room: a row is written once there is a row's height between it and the one before it in time, whether or not that one
        // is written (so what is written only ever grows with the room, and never flickers); until then its dot stays, and so does its touch
        // area, and its text comes in from the left as the room appears. The engine's overflow cards are the one summary there is; none is made here.
        let displays = prepared.displays
        var lineItems: [LineItem] = []
        var overflowItems: [OverflowItem] = []
        let lineWidth = min(contentWidth, max(parameters.minimumLineWidth, contentWidth * parameters.lineWidthShare))
        let lineX = contentLeft + contentWidth - lineWidth - geometry.columnSpacing
        let gap = parameters.lineGap * scale
        let airInset = 4 * scale
        let ramp = metrics.ramp
        let sourceLines = prepared.sourceLines
        let sourceOverflows = prepared.sourceOverflows

        // Where an event's title is written, a row keeps to the right part the engine left it; if even that meets the title, its text waits.
        func titleRects(wide: Bool) -> [CGRect] {
            eventItems.filter { $0.header == nil && $0.showsTitleInCard && $0.presentation.showsTitle }.map { item in
                let width = wide ? item.frame.width : min(titleWidth(item.block.title), item.titleMaxWidth ?? .infinity)
                return CGRect(x: item.frame.minX + item.title.dx, y: item.frame.minY + item.title.dy, width: wide ? width : width + EventTitleLayer.horizontalPadding, height: (EventTitleLayer.rowHeight + 2) * scale)
            }
        }
        let wideTitleRows = titleRects(wide: true)
        let realTitleRows = titleRects(wide: false)
        // Where a card writes its inside rows, a line's text gives way as they come in (its dot and touch area stay): the card's rows
        // span its whole width, so there is no part of the row left to keep to. A card that may get a header writes its rows higher.
        let insideRowAreas: [(area: CGRect, shown: CGFloat)] = eventItems.compactMap { item in
            guard let rows = item.rowsFrame else { return nil }
            let raised = item.placement?.header == nil ? nil
                : Self.rowsFrame(card: item.drawnFrame, titleOffset: item.title.dy, hasHeader: true, presentation: item.presentation, scale: scale)
            return (raised.map { rows.union($0) } ?? rows, item.presentation.transactions)
        }
        var lastCenter: CGFloat?
        var lastText: CGFloat = 0
        for unit in prepared.units {
            let unitHeight = unit.requiredHeight ?? parameters.transactionRow * scale
            let center = geometry.y(minute: unit.anchor)
            let text = unitHeight - 2 * airInset
            var reveal: CGFloat = 1
            if let lastCenter, !unit.isOverflow {
                let need = (lastText + text) / 2 + gap
                reveal = min(1, max(0, (center - lastCenter - need) / max(0.001, ramp)))
            }
            var frame = CGRect(x: lineX, y: center - unitHeight / 2, width: lineWidth, height: unitHeight)
            if !wideTitleRows.contains(where: { $0.intersects(frame.insetBy(dx: 0, dy: airInset)) }) {
                frame = CGRect(x: contentLeft, y: frame.minY, width: frame.maxX - contentLeft, height: frame.height)
            } else if realTitleRows.contains(where: { $0.intersects(frame.insetBy(dx: 0, dy: airInset)) }) {
                reveal = 0
            }
            if !unit.isOverflow {
                for rows in insideRowAreas where rows.area.intersects(frame.insetBy(dx: 0, dy: airInset)) { reveal = min(reveal, 1 - rows.shown) }
            }
            lastCenter = center
            lastText = text
            let missing = max(0, parameters.minimumTouchHeight - unitHeight)
            let touch = frame.insetBy(dx: 0, dy: -missing / 2)
            if !unit.isOverflow {
                let line = sourceLines[unit.index]
                lineItems.append(LineItem(
                    id: unit.id, display: displays[unit.id], link: line.link, linkedEventTitle: prepared.lineLinkTitles[unit.index], frame: frame, touchFrame: touch,
                    anchorY: center, reveal: reveal, markFrame: CGRect(x: contentLeft, y: frame.minY, width: LeaderLayout.textStart(scale), height: frame.height)
                ))
            } else {
                let overflow = sourceOverflows[unit.index]
                overflowItems.append(OverflowItem(
                    id: overflow.id, frame: frame, touchFrame: touch, anchorY: center, members: overflow.members, countsByKind: overflow.countsByKind,
                    amountTotals: overflow.amountTotals, showsAmountTotal: overflow.showsAmountTotal, reveal: reveal
                ))
            }
        }

        // The engine shortens a title that could meet a line's text; it stays short only where a written line really is on the title's row.
        let drawnLines = (lineItems.filter { $0.reveal > 0 }.map(\.frame) + overflowItems.map(\.frame)).map { $0.insetBy(dx: 0, dy: airInset) }
        eventItems = eventItems.map { item in
            guard item.titleMaxWidth != nil else { return item }
            let row = CGRect(x: item.frame.minX, y: item.frame.minY, width: item.frame.width, height: (InlineAllocationPlan.titleHeight + 2) * scale)
            guard drawnLines.contains(where: { $0.intersects(row) }) else { var copy = item; copy.titleMaxWidth = nil; return copy }
            return item
        }

        // A header is an auxiliary place for an event's title, attached to the same event: the engine's, or a small tab for a card too
        // thin to write in. Only where it covers nothing; a line (E0) never gets one.
        var occupied: [CGRect] = eventItems.map(\.drawnFrame) + lineItems.filter { $0.reveal > 0 }.map(\.frame) + overflowItems.map(\.frame)
        let headerHeight = parameters.headerRow * scale
        for index in eventItems.indices.sorted(by: { eventItems[$0].frame.minY < eventItems[$1].frame.minY }) {
            let item = eventItems[index]
            guard item.presentation.level > .line, item.block.id != expanded else { continue }
            let own = item.drawnFrame
            var rect: CGRect?
            if let spec = item.placement?.header { rect = CGRect(x: own.minX, y: own.minY - spec.height, width: own.width, height: spec.height) }
            else if !item.presentation.showsTitle, item.block.id != focused {
                rect = CGRect(x: own.minX, y: own.minY - headerHeight, width: min(own.width, titleWidth(item.block.title) + 24), height: headerHeight)
            }
            guard let rect, rect.minY >= 0 else { continue }
            guard !occupied.contains(where: { $0 != own && $0.intersects(rect.insetBy(dx: 0, dy: 0.5)) }) else { continue }
            eventItems[index].header = rect
            eventItems[index].showsTitleInCard = false
            eventItems[index].rowsFrame = Self.rowsFrame(card: own, titleOffset: item.title.dy, hasHeader: true, presentation: item.presentation, scale: scale)
            occupied.append(rect)
        }
        events = eventItems
        lines = lineItems
        overflows = overflowItems
        conflicts = prepared.conflicts
        hitOrder = (focused ?? expanded).map { content.hitOrder(focused: $0) } ?? prepared.defaultHitOrder
    }

    /// Where a card of `presentation` writes its inside rows: below the title's room (or the header's thin edge), one row per shown transaction
    /// and one for the "그 외"/summary row, cut off at the card's bottom like the card's own clip. The same stack as `EventBlockView`.
    static func rowsFrame(card: CGRect, titleOffset: CGFloat, hasHeader: Bool, presentation: EventPresentation, scale: CGFloat) -> CGRect? {
        guard presentation.transactions > 0 else { return nil }
        let extra = presentation.showsSummaryRow || (presentation.hiddenRows > 0 && presentation.shownRows > 0) ? 1 : 0
        let count = presentation.shownRows + extra
        guard count > 0 else { return nil }
        let titleRow = hasHeader ? 2 : InlineAllocationPlan.titleHeight * scale + titleOffset
        let rowHeight = (InlineAllocationPlan.rowHeight - 2) * scale
        let top = card.minY + EventBlockView.verticalPadding + titleRow + EventBlockView.rowSpacing
        let bottom = min(card.maxY, top + CGFloat(count) * rowHeight + CGFloat(count - 1) * EventBlockView.rowSpacing)
        guard bottom > top else { return nil }
        return CGRect(x: card.minX, y: top, width: card.width, height: bottom - top)
    }

    /// The linked transactions that happened within the event's own time, whatever the card has room to show.
    static func insideTransactions(of block: EventBlock) -> [AllocationItem] {
        block.allocations.filter { item in
            guard item.occursOnSelectedDay else { return false }
            let minute = Int((item.occurredAtUnixMilliseconds - (block.startUnixMilliseconds - Int64(block.startMinute) * 60_000)) / 60_000)
            return minute >= block.startMinute && minute < max(block.endMinute, block.startMinute + 1)
        }
    }

    // MARK: Hit testing

    /// What a touch at `point` (in this day's layout coordinates) means. A line or overflow drawn at the point wins, then an event or
    /// its header. Where nothing is drawn but touch areas meet, or where the thing drawn covers another that can be reached no other way,
    /// the candidates are returned for the person to choose between.
    func hit(at point: CGPoint) -> Hit {
        if let overflow = overflows.first(where: { $0.frame.contains(point) }) {
            return covered(by: .overflow(overflow.id), at: point)
        }
        let onCard = events.contains { $0.drawnFrame.contains(point) || ($0.header?.contains(point) ?? false) }
        if let line = lines.first(where: { $0.touches(point, overCard: onCard) }) { return covered(by: .line(line.id), at: point) }
        for id in hitOrder {
            guard let item = events.first(where: { $0.block.id == id }) else { continue }
            if item.drawnFrame.contains(point) || (item.header?.contains(point) ?? false) { return .event(id) }
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
        let hidden = events.filter { $0.drawnFrame.contains(point) && !isReachable($0) }.map { Candidate.event($0.block.id) }
        let met = conflicts.first { $0.contains(top) }.map { $0.filter { $0 != top } } ?? []
        let others = hidden + met
        return others.isEmpty ? Self.hit(of: top) : .choose([top] + others)
    }

    /// Whether some part of the event can be touched without touching a line or overflow.
    private func isReachable(_ item: EventItem) -> Bool {
        let frame = item.drawnFrame
        let steps = Self.coveredEventSample
        for row in 0...3 {
            for column in 0...steps {
                let point = CGPoint(x: frame.minX + 2 + (frame.width - 4) * CGFloat(column) / CGFloat(steps), y: frame.minY + 2 + (max(0, frame.height - 4)) * CGFloat(row) / 3)
                if !lines.contains(where: { $0.touches(point, overCard: true) }) && !overflows.contains(where: { $0.frame.contains(point) }) { return true }
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
