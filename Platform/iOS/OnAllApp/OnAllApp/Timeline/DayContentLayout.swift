import CoreGraphics
import NEOBudgetCalendar

/// Where one event sits among the events it overlaps, independent of the screen width.
///
/// Every event of a day uses the same content column. An overlapping event is not squeezed into a narrower lane next to its
/// neighbours: it is stacked over them and shifted in from the left by one `level` step, so each card keeps its full
/// width, its own start and end edge, and its title. An event wholly inside another is also pulled in from the right
/// (`nestDepth`), which reads as an inner card.
struct CardSlot: Equatable, Hashable {
    /// 0 for an event nothing overlaps; otherwise the lowest level not taken by an event it overlaps.
    var level: Int = 0
    /// The highest level in the group of events that overlap one another (directly or through a chain), so the step is shared.
    var maxLevel: Int = 0
    /// How many events wholly contain this one.
    var nestDepth: Int = 0

    static let single = CardSlot()
}

/// How far a card is drawn in from the left and right edge of the day's content column.
struct CardInsets: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
    static let zero = CardInsets()
}

/// Stacked layout for the events of one day. Pure: no SwiftUI, and no knowledge of the axis beyond what a caller passes in.
struct DayContentLayout {
    /// Height of a card's title row. The title of a card that starts within this distance below the title of a card under it is
    /// moved down to clear that title, so both stay readable.
    static let titleRowHeight: CGFloat = 18
    static let maximumLevelStep: CGFloat = 16
    static let minimumLevelStep: CGFloat = 8
    static let nestedRightStep: CGFloat = 6
    /// The most of the column that levels may use between them; the rest is the card.
    static let maximumShiftShare: CGFloat = 0.45

    private(set) var slots: [BlockID: CardSlot] = [:]
    /// Back to front: later entries are drawn over earlier ones.
    private(set) var order: [BlockID] = []

    init(blocks: [EventBlock]) {
        // Drawn as the minutes the card spans, never shorter than a quarter hour, so a point-like event still overlaps what it sits in.
        let items = blocks.map { (id: $0.id, start: $0.displayStartMinute, end: max($0.displayEndMinute, $0.displayStartMinute + 1)) }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.end != rhs.end { return lhs.end > rhs.end }
                return lhs.id < rhs.id
            }
        order = items.map(\.id)

        var placed: [(id: BlockID, start: Int, end: Int)] = []
        var groups: [[BlockID]] = []
        var groupEnd = Int.min
        for item in items {
            let active = placed.filter { $0.end > item.start }
            let taken = Set(active.compactMap { slots[$0.id]?.level })
            var level = 0
            while taken.contains(level) { level += 1 }
            let containing = active.filter { $0.start <= item.start && $0.end >= item.end }
            slots[item.id] = CardSlot(level: level, maxLevel: level, nestDepth: containing.count)
            if item.start >= groupEnd {
                groups.append([item.id])
                groupEnd = item.end
            } else {
                groups[groups.count - 1].append(item.id)
                groupEnd = max(groupEnd, item.end)
            }
            placed.append(item)
        }
        // Events that overlap one another, directly or through a chain, share one step so they line up.
        for group in groups {
            let top = group.compactMap { slots[$0]?.level }.max() ?? 0
            for id in group { slots[id]?.maxLevel = top }
        }
    }

    func slot(of id: BlockID) -> CardSlot { slots[id] ?? .single }

    /// Insets for a slot in a column `available` points wide.
    static func insets(for slot: CardSlot, available: CGFloat) -> CardInsets {
        guard slot.maxLevel > 0 || slot.nestDepth > 0 else { return .zero }
        let step = slot.maxLevel > 0
            ? min(maximumLevelStep, max(minimumLevelStep, available * maximumShiftShare / CGFloat(slot.maxLevel)))
            : 0
        return CardInsets(
            left: CGFloat(slot.level) * step,
            right: CGFloat(min(slot.nestDepth, 3)) * nestedRightStep
        )
    }

    /// Where inside its card a title is drawn, relative to the card's top-left title spot.
    struct TitlePlacement: Equatable {
        var dy: CGFloat = 0
        var dx: CGFloat = 0
        /// The title runs past its own card, to the edge of the day's column, because there was no other room for it.
        var overflows = false
    }

    /// Titles narrower than this are not worth placing beside another one.
    static let minimumTitleWidth: CGFloat = 36
    static let titleGap: CGFloat = 4

    /// Where each title is drawn so no title sits over another. Cards keep their true top and bottom; only the text moves: first
    /// down (to a line of its own, if its card has the room), else to the right along the same line, after the title it would
    /// have covered. `top`/`bottom` are drawn positions in points, `left`/`right` where a title may start and must end, and
    /// `width` how wide a title wants to be. A card that is `focused` (selected or opened) is drawn on top of everything, so
    /// its title stays at its own top and the others do not need to clear it.
    func titlePlacements(
        top: (BlockID) -> CGFloat, bottom: (BlockID) -> CGFloat, left: (BlockID) -> CGFloat, right: (BlockID) -> CGFloat,
        width: (BlockID) -> CGFloat, columnRight: CGFloat, minimumHeight: CGFloat, focused: BlockID?, rowHeight: CGFloat = DayContentLayout.titleRowHeight,
        titlesOnly: Bool = false
    ) -> [BlockID: TitlePlacement] {
        var result: [BlockID: TitlePlacement] = [:]
        var placed: [(rect: CGRect, bottom: CGFloat)] = []
        let row = rowHeight
        for id in order {
            let trueTop = top(id)
            let trueBottom = max(bottom(id), trueTop + minimumHeight)
            let baseX = left(id)
            let wanted = min(width(id), max(0, right(id) - baseX))
            var place = TitlePlacement()
            if id != focused {
                let limit = max(0, trueBottom - trueTop - row)
                for _ in 0..<8 {
                    let rect = CGRect(x: baseX + place.dx, y: trueTop + place.dy, width: wanted, height: row)
                    guard let under = placed.first(where: { ($0.bottom > trueTop || titlesOnly) && $0.rect.intersects(rect) }) else { break }
                    let lower = under.rect.maxY - trueTop
                    let after = under.rect.maxX + Self.titleGap - baseX
                    if lower <= limit {
                        place.dy = lower
                    } else if baseX + after + Self.minimumTitleWidth <= right(id) {
                        place.dx = after
                    } else if baseX + after + Self.minimumTitleWidth <= columnRight {
                        place.dx = after
                        place.overflows = true
                    } else {
                        // No room beside it either: it takes the next free line below, even past the bottom of its own card. A title
                        // that runs on below its card is better than one printed over another.
                        place.dy = lower
                    }
                }
            }
            result[id] = place
            if id != focused {
                let reach = place.overflows ? columnRight : right(id)
                placed.append((CGRect(x: baseX + place.dx, y: trueTop + place.dy, width: min(wanted, max(0, reach - baseX - place.dx)), height: row), trueBottom))
            }
        }
        return result
    }

    /// A rough width for a title at the card title size, so titles can be set side by side. Korean and other wide characters
    /// count more than Latin ones. Exactness is not needed: a title that is longer than its room is cut with an ellipsis.
    static func estimatedTitleWidth(_ title: String, extra: CGFloat = 0) -> CGFloat {
        let glyphs = title.unicodeScalars.reduce(CGFloat(0)) { $0 + ($1.value >= 0x2E80 ? 12 : 7) }
        return glyphs + extra + 8
    }

    /// Cards from front to back at a point: the focused one first, then higher levels over lower ones.
    func hitOrder(focused: BlockID?) -> [BlockID] {
        var front = Array(order.reversed())
        if let focused, let index = front.firstIndex(of: focused) {
            front.remove(at: index)
            front.insert(focused, at: 0)
        }
        return front
    }

    /// The card a touch at `point` lands on, given where each card is drawn.
    func topmost(at point: CGPoint, frames: [BlockID: CGRect], focused: BlockID?) -> BlockID? {
        hitOrder(focused: focused).first { frames[$0]?.contains(point) == true }
    }
}
