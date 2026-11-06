import CoreGraphics

/// Where a precision bubble goes next to the handle it is for. Pure, so it is tested; `PrecisionBubbleOverlay` asks it every time the handle or the bubble's
/// size changes (a scroll, a pinch, a 15-minute step, Dynamic Type).
///
/// - The start handle sits on the card's top edge, so its bubble prefers **above** it; the end handle sits on the bottom edge, so its bubble prefers **below**.
///   Either way the bubble covers the time around the edge, not the event.
/// - Too close to the top or bottom of the visible area: it flips to the other side. Neither fits (a large Dynamic Type bubble on a short screen): beside the
///   handle, on whichever side has more room. Nothing fits: inside the area, on the roomier side, without an arrow (`clamped`).
/// - Sideways it is centred on the handle and kept inside the area; the arrow follows the handle as far as the rounded corners allow.
/// - It never covers the handle's touch circle (`clearance`, the handle radius), so the handle can still be dragged with the bubble open.
/// - The handle scrolled out of the area: the bubble stays at that edge (`pinnedTop` / `pinnedBottom`) with no arrow, and says which way the handle is.
/// - Hysteresis: once flipped away from its preferred side, the bubble comes back only when the preferred side has `hysteresis` points to spare, so a handle
///   scrolled slowly across the flip line does not flicker (a big jump, a zoom or a scenario, still lands on the preferred side).
enum PrecisionBubbleLayout {
    enum Side: Equatable, Sendable {
        case above, below, leading, trailing
        /// The handle is above / below the visible area.
        case pinnedTop, pinnedBottom
        /// Nothing fits next to the handle: inside the area, no arrow.
        case clamped

        var isVertical: Bool { self == .above || self == .below }
    }

    struct Placement: Equatable, Sendable {
        /// The bubble's body (the arrow is outside it, between it and the handle).
        let frame: CGRect
        let side: Side
        /// Where the arrow points (a point on the handle's touch circle). `nil` when there is no arrow (`pinned…`, `clamped`).
        let arrowTip: CGPoint?
        /// Whether the handle is inside the visible area (vertically; the days do not move while editing, so sideways it always is).
        var anchorVisible: Bool { side != .pinnedTop && side != .pinnedBottom }
    }

    static let arrowLength: CGFloat = 8
    static let arrowHalfWidth: CGFloat = 9
    static let cornerRadius: CGFloat = 14
    static let hysteresis: CGFloat = 24

    /// - Parameters:
    ///   - anchor: the handle's centre, in the same space as `bounds`.
    ///   - size: the bubble's body.
    ///   - bounds: where the bubble may be (the visible grid, already inset by the margins it keeps).
    ///   - clearance: the radius around the handle the bubble keeps clear (its touch circle).
    ///   - previous: the side chosen last time, for hysteresis.
    static func place(
        anchor: CGPoint, edge: PrecisionEdge, size: CGSize, bounds: CGRect, clearance: CGFloat = EditHit.handleRadius, previous: Side? = nil
    ) -> Placement {
        let reach = clearance + arrowLength
        let centredX = clamp(anchor.x - size.width / 2, bounds.minX, bounds.maxX - size.width)

        if anchor.y < bounds.minY {
            return Placement(frame: CGRect(x: centredX, y: bounds.minY, width: size.width, height: size.height), side: .pinnedTop, arrowTip: nil)
        }
        if anchor.y > bounds.maxY {
            return Placement(frame: CGRect(x: centredX, y: bounds.maxY - size.height, width: size.width, height: size.height), side: .pinnedBottom, arrowTip: nil)
        }

        func vertical(_ side: Side, slack: CGFloat = 0) -> Placement? {
            let y = side == .above ? anchor.y - reach - size.height : anchor.y + reach
            guard y >= bounds.minY + slack - 0.5, y + size.height <= bounds.maxY - slack + 0.5, size.width <= bounds.width + 0.5 else { return nil }
            let frame = CGRect(x: centredX, y: y, width: size.width, height: size.height)
            let tipX = clamp(anchor.x, frame.minX + cornerRadius + arrowHalfWidth, frame.maxX - cornerRadius - arrowHalfWidth)
            return Placement(frame: frame, side: side, arrowTip: CGPoint(x: tipX, y: side == .above ? anchor.y - clearance : anchor.y + clearance))
        }

        func beside(_ side: Side) -> Placement? {
            let x = side == .leading ? anchor.x - reach - size.width : anchor.x + reach
            guard x >= bounds.minX - 0.5, x + size.width <= bounds.maxX + 0.5, size.height <= bounds.height + 0.5 else { return nil }
            let y = clamp(anchor.y - size.height / 2, bounds.minY, bounds.maxY - size.height)
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            let tipY = clamp(anchor.y, frame.minY + cornerRadius + arrowHalfWidth, frame.maxY - cornerRadius - arrowHalfWidth)
            return Placement(frame: frame, side: side, arrowTip: CGPoint(x: side == .leading ? anchor.x - clearance : anchor.x + clearance, y: tipY))
        }

        let preferred: Side = edge == .start ? .above : .below
        let other: Side = preferred == .above ? .below : .above
        if let placement = vertical(preferred, slack: previous == other ? hysteresis : 0) ?? vertical(other) ?? vertical(preferred) { return placement }

        let roomLeading = anchor.x - bounds.minX, roomTrailing = bounds.maxX - anchor.x
        for side in roomTrailing >= roomLeading ? [Side.trailing, .leading] : [.leading, .trailing] {
            if let placement = beside(side) { return placement }
        }

        // Nothing fits beside the handle: inside the area on the roomier vertical side, covering what it must.
        let roomAbove = anchor.y - bounds.minY, roomBelow = bounds.maxY - anchor.y
        let y = roomAbove >= roomBelow ? max(bounds.minY, anchor.y - reach - size.height) : min(bounds.maxY - size.height, anchor.y + reach)
        return Placement(frame: CGRect(x: centredX, y: max(bounds.minY, y), width: size.width, height: size.height), side: .clamped, arrowTip: nil)
    }

    /// `value` inside `low … high`; `low` when the range is empty (a bubble wider than the area starts at its leading edge).
    static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        high < low ? low : min(max(value, low), high)
    }
}
