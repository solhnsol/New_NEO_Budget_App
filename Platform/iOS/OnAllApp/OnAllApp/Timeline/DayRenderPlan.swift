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

    /// The name written beside the dot a very thin event has become: a chip like a transaction's, at the event's middle. It is the only text such an
    /// event has, so it is held to what the day shows at rest while the days move (`holdingVisibility`).
    struct DotLabel: Equatable {
        var frame: CGRect
        /// 0 … 1: how much of the chip there is room for (another event's name just above it takes the room first).
        var reveal: CGFloat
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
        /// False when the title is not written inside the card (no room).
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
        /// The name beside the dot, for an event thinner than the small title needs; `nil` for every other.
        var dotLabel: DotLabel?
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
        /// The colour of the event this transaction is linked to (its chip is outlined in it); `nil` when it is linked to nothing on this day.
        var linkColorHex: String? = nil
        /// For a linked transaction outside its event's time: the event's stripe carried on from the card's nearer edge to the transaction's
        /// time, so it reads as that event's. `nil` when there is no such event card on this day.
        var tail: Tail? = nil

        /// Whether a touch at `point` is this line's. Where no card is drawn: on its row or its dot. Over a card: on its row while any of its text is
        /// written, else only where its row and its dot meet, so the card under the unwritten text (its rows too) is touched as the card.
        func touches(_ point: CGPoint, overCard: Bool) -> Bool {
            guard overCard else { return frame.contains(point) || markFrame.contains(point) }
            return reveal > 0 ? frame.contains(point) : frame.intersection(markFrame).contains(point)
        }
    }

    /// A dashed line at `x` from `fromY` (the card's edge) to `toY` (the transaction's time), in the linked event's colour.
    struct Tail: Equatable {
        let x: CGFloat
        let fromY: CGFloat
        let toY: CGFloat
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
    /// The chip of a dot's name: its height and how far right of the card's edge it begins (past the dot).
    static let dotLabelHeight: CGFloat = 17
    static let dotLabelInset: CGFloat = 11

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
        metrics: EventPresentation.Metrics? = nil, maximumInlineRows: Int = InlineAllocationPlan.maximumRows, presentationGeometry: (any TimeAxisMapping)? = nil, titleWidth: (String) -> CGFloat
    ) {
        self.init(
            prepared: Prepared(timeline: timeline, role: role, layout: layout), geometry: geometry, layoutWidth: layoutWidth, textScale: textScale,
            expanded: expanded, focused: focused, parameters: parameters, metrics: metrics, maximumInlineRows: maximumInlineRows, presentationGeometry: presentationGeometry, titleWidth: titleWidth
        )
    }

    /// Places a prepared day: only what depends on the axis, the text size and the focus is worked out here.
    init(
        prepared: Prepared, geometry: any TimeAxisMapping, layoutWidth: CGFloat,
        textScale: CGFloat = 1, expanded: BlockID? = nil, focused: BlockID? = nil, parameters: AllocationParameters = AllocationParameters(),
        metrics: EventPresentation.Metrics? = nil, maximumInlineRows: Int = InlineAllocationPlan.maximumRows, presentationGeometry: (any TimeAxisMapping)? = nil, titleWidth: (String) -> CGFloat
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

        // How each event looks, from its height alone. `presentationGeometry`: the axis the heights are read from when it is not the one the cards are placed on (the days
        // moving: cards are placed on the blend of two partitions, but what is written in them is what the decision they come from makes of the cards at rest, so a card
        // that the blend squeezes or stretches on its way neither loses its rows nor shows rows it never has).
        // A card's rows stop where an event that begins inside it is drawn over it (its title is written there): the rows go first, as they do for a lower card.
        var presentations: [BlockID: EventPresentation] = [:]
        var presentationInputs: [BlockID: (height: CGFloat, rowRoom: CGFloat?)] = [:]
        for block in blocks {
            var height = frames[block.id]?.height ?? 0
            let axis: any TimeAxisMapping
            if let basis = presentationGeometry, expanded != block.id, block.id != focused {
                height = max(0, basis.y(bottomOfSpanFrom: block.startMinute, to: block.endMinute) - basis.y(minute: block.startMinute))
                axis = basis
            } else {
                axis = geometry
            }
            var rowRoom: CGFloat?
            if let own = frames[block.id], block.id != expanded, block.id != focused {
                let inner = blocks.filter { other in
                    guard other.id != block.id, other.startMinute > block.startMinute, other.startMinute < block.endMinute, let frame = frames[other.id] else { return false }
                    return frame.minX < own.maxX && frame.maxX > own.minX
                }
                rowRoom = inner.map { axis.y(minute: $0.startMinute) - axis.y(minute: block.startMinute) }.min()
            }
            presentationInputs[block.id] = (height, rowRoom)
            presentations[block.id] = EventPresentation.make(
                height: height, insideCount: prepared.insideAll[block.id]?.count ?? 0, metrics: metrics, maximumRows: maximumInlineRows, rowRoom: rowRoom
            )
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
        // A title moved down its card takes its rows down with it: they still stop above the end time's line (and where an inner event begins).
        for block in blocks {
            guard let dy = places[block.id]?.dy, dy > 0, block.id != expanded, block.id != focused, let input = presentationInputs[block.id] else { continue }
            presentations[block.id] = EventPresentation.make(
                height: input.height, insideCount: prepared.insideAll[block.id]?.count ?? 0, metrics: metrics, maximumRows: maximumInlineRows,
                rowRoom: max(0, min(input.rowRoom ?? input.height, input.height) - dy)
            )
        }

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
                showsTitleInCard: presentation.writesTitle || id == focused,
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
                rowsFrame: Self.rowsFrame(card: drawn, titleOffset: place.dy, presentation: presentation, scale: scale)
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
            eventItems.filter { $0.showsTitleInCard && $0.presentation.writesTitle }.map { item in
                if !item.presentation.showsTitle {
                    // The small title of a thin card: the card's own height is its row.
                    let width = wide ? item.frame.width : min(item.frame.width, titleWidth(item.block.title) * EventPresentation.Metrics.compactShare + EventTitleLayer.horizontalPadding)
                    return CGRect(x: item.frame.minX, y: item.drawnFrame.minY, width: width, height: item.drawnFrame.height)
                }
                let width = wide ? item.frame.width : min(titleWidth(item.block.title), item.titleMaxWidth ?? .infinity)
                return CGRect(x: item.frame.minX + item.title.dx, y: item.frame.minY + item.title.dy, width: wide ? width : width + EventTitleLayer.horizontalPadding, height: (EventTitleLayer.rowHeight + 2) * scale)
            }
        }
        let wideTitleRows = titleRects(wide: true)
        let realTitleRows = titleRects(wide: false)
        // Where a card writes its inside rows, a line's text gives way as they come in (its dot and touch area stay): the card's rows
        // span its whole width, so there is no part of the row left to keep to.
        let insideRowAreas: [(area: CGRect, shown: CGFloat)] = eventItems.compactMap { item in
            guard let rows = item.rowsFrame else { return nil }
            return (rows, item.presentation.transactions)
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

        // An event too thin for even the small title has become a dot, and its name is written beside it in a chip of its own. It gives way to everything else that is written: another event's title or rows, a
        // transaction's text.
        let chipHeight = Self.dotLabelHeight * scale
        let chipLeft = Self.dotLabelInset * scale
        // Names whose rows meet share the name area in two columns, left and right, each half as wide; a name with no other beside it keeps the whole area.
        // A column takes a name once there is a chip's height between it and the last name in that column; a name that fits in neither stays a dot.
        let order = eventItems.indices.filter { eventItems[$0].presentation.dot > 0 }.sorted { eventItems[$0].drawnFrame.midY < eventItems[$1].drawnFrame.midY }
        var lastInColumn: [CGFloat?] = [nil, nil]
        for (position, index) in order.enumerated() {
            let item = eventItems[index]
            let centre = item.drawnFrame.midY
            let area = max(0, item.frame.width - chipLeft - 2)
            let meets = (position > 0 && centre - eventItems[order[position - 1]].drawnFrame.midY < chipHeight)
                || (position + 1 < order.count && eventItems[order[position + 1]].drawnFrame.midY - centre < chipHeight)
            let column = lastInColumn.firstIndex { $0 == nil || centre - $0! >= chipHeight }
            let columnWidth = meets ? area / 2 : area
            let width = min(titleWidth(item.block.title) * 0.95 + 14 * scale, columnWidth - (meets ? 2 : 0))
            let x = item.frame.minX + chipLeft + CGFloat(meets ? (column ?? 0) : 0) * columnWidth
            let chip = CGRect(x: x, y: centre - chipHeight / 2, width: max(0, width), height: chipHeight)
            var reveal: CGFloat = width >= 30 * scale && column != nil ? 1 : 0
            if (wideTitleRows + insideRowAreas.map(\.area) + drawnLines).contains(where: { $0.intersects(chip) }) { reveal = 0 }
            if let column, reveal > 0 { lastInColumn[meets ? column : 0] = centre }
            eventItems[index].dotLabel = DotLabel(frame: chip, reveal: reveal)
        }

        // A linked transaction's chip takes its event's colour; outside the event's time, the event's stripe runs on to it.
        let cardsByEvent = Dictionary(eventItems.map { ($0.block.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        lineItems = lineItems.map { line in
            guard let link = line.link, let card = cardsByEvent[link.eventID] else { return line }
            var copy = line
            copy.linkColorHex = card.block.calendarColorHex ?? "#3182F6"
            if let anchor = line.anchorY {
                let frame = card.drawnFrame
                if anchor < frame.minY - 1 { copy.tail = Tail(x: frame.minX + 1.5, fromY: frame.minY, toY: anchor) }
                else if anchor > frame.maxY + 1 { copy.tail = Tail(x: frame.minX + 1.5, fromY: frame.maxY, toY: anchor) }
            }
            return copy
        }

        events = eventItems
        lines = lineItems
        overflows = overflowItems
        conflicts = prepared.conflicts
        hitOrder = (focused ?? expanded).map { content.hitOrder(focused: $0) } ?? prepared.defaultHitOrder
    }

    /// This plan, with what it shows held to `rest`: the same day under the same decision, placed on the partition that decision has at rest. While the days move
    /// the cards are placed on the blend of two partitions, so how far apart things are changes with the position; what is written (a line's text, its width, a
    /// shortened title) is what the day shows at rest, so nothing comes and goes because the time between two things is squeezed on the way.
    /// Only where things are drawn follows the moving axis.
    func holdingVisibility(of rest: DayRenderPlan, textScale: CGFloat) -> DayRenderPlan {
        let scale = max(0.5, textScale)
        var held = self
        var restLines: [String: LineItem] = [:]
        for line in rest.lines { restLines[line.id] = line }
        held.lines = lines.map { line in
            guard let kept = restLines[line.id] else { return line }
            var copy = line
            copy.reveal = kept.reveal
            copy.frame = CGRect(x: kept.frame.minX, y: line.frame.minY, width: kept.frame.width, height: line.frame.height)
            copy.touchFrame = CGRect(x: kept.touchFrame.minX, y: line.touchFrame.minY, width: kept.touchFrame.width, height: line.touchFrame.height)
            return copy
        }
        var restOverflows: [String: OverflowItem] = [:]
        for overflow in rest.overflows { restOverflows[overflow.id] = overflow }
        held.overflows = overflows.map { overflow in
            guard let kept = restOverflows[overflow.id] else { return overflow }
            var copy = overflow
            copy.reveal = kept.reveal
            copy.frame = CGRect(x: kept.frame.minX, y: overflow.frame.minY, width: kept.frame.width, height: overflow.frame.height)
            copy.touchFrame = CGRect(x: kept.touchFrame.minX, y: overflow.touchFrame.minY, width: kept.touchFrame.width, height: overflow.touchFrame.height)
            return copy
        }
        var restEvents: [BlockID: EventItem] = [:]
        for item in rest.events { restEvents[item.block.id] = item }
        held.events = events.map { item in
            guard let kept = restEvents[item.block.id] else { return item }
            var copy = item
            copy.titleMaxWidth = kept.titleMaxWidth
            copy.showsTitleInCard = kept.showsTitleInCard
            copy.dotLabel = item.dotLabel.flatMap { moving in
                kept.dotLabel.map { DotLabel(frame: CGRect(x: kept.frame.minX, y: moving.frame.minY, width: kept.frame.width, height: moving.frame.height), reveal: $0.reveal) }
            }
            copy.rowsFrame = Self.rowsFrame(card: item.drawnFrame, titleOffset: item.title.dy, presentation: item.presentation, scale: scale)
            return copy
        }
        return held
    }

    /// Where a card of `presentation` writes its inside rows: below the title's room , one row per shown transaction
    /// and one for the "그 외"/summary row, cut off at the card's bottom like the card's own clip. The same stack as `EventBlockView`.
    static func rowsFrame(card: CGRect, titleOffset: CGFloat, presentation: EventPresentation, scale: CGFloat) -> CGRect? {
        guard presentation.transactions > 0 else { return nil }
        let extra = presentation.showsSummaryRow || (presentation.hiddenRows > 0 && presentation.shownRows > 0) ? 1 : 0
        let count = presentation.shownRows + extra
        guard count > 0 else { return nil }
        let titleRow = InlineAllocationPlan.titleHeight * scale + titleOffset
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
        let onCard = events.contains { $0.drawnFrame.contains(point) || ($0.dotLabel?.frame.contains(point) ?? false) }
        if let line = lines.first(where: { $0.touches(point, overCard: onCard) }) { return covered(by: .line(line.id), at: point) }
        for id in hitOrder {
            guard let item = events.first(where: { $0.block.id == id }) else { continue }
            if item.drawnFrame.contains(point) || (item.dotLabel?.frame.contains(point) ?? false) { return .event(id) }
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
