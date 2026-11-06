import CoreGraphics

/// The arithmetic of a pinch on the temporal grid: one zoom factor for the whole grid (`totalHeight = viewport × zoom`), a vertical scroll offset
/// inside it, and the rule that the time under the fingers stays under the fingers. Pure. The partition (the cells and what each stands for) is
/// not an input: scaling the grid never changes a time's *fraction* of the grid height, so the anchor can be kept as a fraction.
enum PinchZoomMath {
    /// The zoom range of the experiment: 1 fits the whole day in the viewport, 8 is the most the pinch goes to.
    static let range: ClosedRange<CGFloat> = 1...8
    /// How far past each end of the range a pinch may stretch before it saturates, in zoom units.
    static let upperStretch: CGFloat = 0.6
    static let lowerStretch: CGFloat = 0.12

    /// The zoom a raw pinch (start zoom × finger scale) is shown at: unchanged inside the range, and past an end it follows the fingers
    /// with a slope of 1 at the end that falls off to a limit (`d·L/(L+d)`), the same feel as a scroll view's edge.
    static func rubberBanded(_ raw: CGFloat) -> CGFloat {
        if raw > range.upperBound { let d = raw - range.upperBound; return range.upperBound + d * upperStretch / (upperStretch + d) }
        if raw < range.lowerBound { let d = range.lowerBound - raw; return range.lowerBound - d * lowerStretch / (lowerStretch + d) }
        return raw
    }

    static func clamped(_ zoom: CGFloat) -> CGFloat { min(max(zoom, range.lowerBound), range.upperBound) }

    /// The scroll offsets a grid of `zoom × viewport` can rest at.
    static func offsetRange(zoom: CGFloat, viewport: CGFloat) -> ClosedRange<CGFloat> { 0...max(0, viewport * zoom - viewport) }

    static func clampedOffset(_ offset: CGFloat, zoom: CGFloat, viewport: CGFloat) -> CGFloat {
        let limits = offsetRange(zoom: zoom, viewport: viewport)
        return min(max(offset, limits.lowerBound), limits.upperBound)
    }

    /// How much of the fingers' movement past an end the content follows at the end itself (UIKit's own bounce is about 0.55).
    static let overscrollSlope: CGFloat = 0.55

    /// How far past an end of `range` the scroll is drawn during a pinch, when the fingers take it there: inside unchanged; beyond, it follows with a slope
    /// of `overscrollSlope` at the end that falls off towards `limit` (`L·(1 − 1/(k·d/L + 1))`), the feel of the scroll view's own bounce.
    static func rubberBandedOffset(_ offset: CGFloat, range: ClosedRange<CGFloat>, limit: CGFloat) -> CGFloat {
        func band(_ d: CGFloat) -> CGFloat { limit * (1 - 1 / (overscrollSlope * d / limit + 1)) }
        if offset < range.lowerBound { return range.lowerBound - band(range.lowerBound - offset) }
        if offset > range.upperBound { return range.upperBound + band(offset - range.upperBound) }
        return offset
    }

    /// The offset whose rubber band is `shown` (the inverse of `rubberBandedOffset`): a pinch that takes over a scroll past an end starts from the content
    /// exactly where it is drawn. Beyond 95 % of the limit it is taken as 95 %.
    static func unbandedOffset(_ shown: CGFloat, range: ClosedRange<CGFloat>, limit: CGFloat) -> CGFloat {
        func unband(_ r: CGFloat) -> CGFloat { let r = min(r, limit * 0.95); return limit * r / (overscrollSlope * (limit - r)) }
        if shown < range.lowerBound { return range.lowerBound - unband(range.lowerBound - shown) }
        if shown > range.upperBound { return range.upperBound + unband(shown - range.upperBound) }
        return shown
    }

    /// The most a pinch draws the scroll past an end: a tenth of the viewport.
    static func overscrollLimit(viewport: CGFloat) -> CGFloat { max(1, viewport * 0.1) }

    /// A fling that reaches an end at `velocity` (points per second, signed): how far past the end it goes (signed, at most `overscrollLimit`, the
    /// pinch's rubber band applied to the 30 ms the speed would carry it on) and how soon it gets there (`tau`, so it leaves the end at the fling's speed).
    static func flingBounce(velocity: CGFloat, viewport: CGFloat) -> (peak: CGFloat, tau: CGFloat) {
        let limit = overscrollLimit(viewport: viewport)
        let peak = rubberBandedOffset(abs(velocity) * 0.03, range: 0...0, limit: limit)
        let tau = min(0.15, max(0.05, peak * CGFloat(M_E) / max(1, abs(velocity))))
        return (velocity < 0 ? -peak : peak, tau)
    }

    /// How far past the end a fling's bounce is `t` seconds after it reached it: out to `peak` at `tau` and back, critically damped (`p·(t/τ)·e^(1−t/τ)`).
    /// `nil` once it is back within a quarter point (after about 6τ).
    static func bounceOffset(at t: CGFloat, peak: CGFloat, tau: CGFloat) -> CGFloat? {
        let x = max(0, t) / tau
        let d = peak * x * exp(1 - x)
        return x > 1 && abs(d) < 0.25 ? nil : d
    }

    /// Where the zoom alone may put the scroll during a pinch: the ends of the grid at 1× and above (zooming never draws past an end; the time under the
    /// fingers slides instead), and below 1× anywhere that keeps the shrunken grid inside the viewport, so it shrinks around the fingers.
    static func pinchRange(zoom: CGFloat, viewport: CGFloat, inset: CGFloat = 0) -> ClosedRange<CGFloat> {
        let spare = viewport * zoom - viewport
        return min(0, spare)...(max(0, spare) + inset)
    }

    /// A pinch from one step to the next. The offset is kept in two parts: `inside`, where the zoom and the scrolling within the grid put it (never past
    /// an end), and `over`, how far the fingers' centre has pulled past an end (unbanded; drawn with resistance). Drawn at `inside + band(over)`.
    struct Pinch: Equatable {
        var zoom: CGFloat
        var focal: CGFloat
        var inside: CGFloat
        var over: CGFloat = 0
        /// How far `over` can draw the content: `overscrollLimit`, or more when the pinch took over a pull that was already further out.
        var limit: CGFloat
        /// Past an end where nothing pulls (a bounce or an easing coming back, taken over): drawn as it is and let go of (`settled`).
        var returning: CGFloat = 0

        /// A pinch that starts from the content where it is drawn. Past an end, a finger's pull (`pulled`) goes on as the pinch's `over`; anything else
        /// is `returning`, which comes back to the end while the pinch goes on.
        init(zoom: CGFloat, focal: CGFloat, shown: CGFloat, viewport: CGFloat, inset: CGFloat = 0, pulled: Bool = false) {
            self.zoom = zoom; self.focal = focal
            let range = PinchZoomMath.pinchRange(zoom: zoom, viewport: viewport, inset: inset)
            inside = min(max(shown, range.lowerBound), range.upperBound)
            limit = PinchZoomMath.overscrollLimit(viewport: viewport)
            if pulled {
                limit = max(limit, abs(shown - inside) / 0.9)
                over = PinchZoomMath.unbandedOffset(shown - inside, range: 0...0, limit: limit)
            } else {
                returning = shown - inside
            }
        }

        /// The offset the content is drawn at.
        var shown: CGFloat { inside + PinchZoomMath.rubberBandedOffset(over, range: 0...0, limit: limit) + returning }

        /// `returning` after `elapsed` seconds more: it halves every 50 ms (about a quarter of a second to the end, like an easing's tail).
        func settled(after elapsed: CGFloat) -> Pinch {
            var result = self
            result.returning = abs(returning) < 0.25 ? 0 : returning * pow(0.5, elapsed / 0.05)
            return result
        }

        /// The next step: the zoom about the last centre (the time there stays there, until the grid's end stops it), then the centre's move. The move
        /// scrolls within the grid; past an end, and always below 1×, it only pulls with resistance.
        func step(zoom next: CGFloat, focal now: CGFloat, viewport: CGFloat, inset: CGFloat = 0) -> Pinch {
            var result = self
            let zoomed = (inside + focal) * next / max(0.0001, zoom) - focal
            let range = PinchZoomMath.pinchRange(zoom: next, viewport: viewport, inset: inset)
            result.inside = min(max(zoomed, range.lowerBound), range.upperBound)
            let total = result.inside + over - (now - focal)
            let rest = PinchZoomMath.offsetRange(zoom: next, viewport: viewport)
            let scrolls = rest.lowerBound...(rest.upperBound + inset)
            if scrolls.contains(result.inside) { result.inside = min(max(total, scrolls.lowerBound), scrolls.upperBound) }
            result.over = total - result.inside
            result.zoom = next; result.focal = now
            return result
        }
    }

    /// The raw zoom (start zoom × finger scale) whose rubber band is `shown` (the inverse of `rubberBanded`), for a pinch that goes on from a stretched zoom.
    /// Beyond 95 % of a stretch it is taken as 95 %.
    static func unbandedZoom(_ shown: CGFloat) -> CGFloat {
        func unband(_ r: CGFloat, _ limit: CGFloat) -> CGFloat { let r = min(r, limit * 0.95); return r * limit / (limit - r) }
        if shown > range.upperBound { return range.upperBound + unband(shown - range.upperBound, upperStretch) }
        if shown < range.lowerBound { return range.lowerBound - unband(range.lowerBound - shown, lowerStretch) }
        return shown
    }

    /// Where on the grid (0 = 00:00 end, 1 = 24:00 end) the point `focal` (from the top of the viewport) is, at this offset and zoom.
    static func anchorFraction(offset: CGFloat, focal: CGFloat, zoom: CGFloat, viewport: CGFloat) -> CGFloat {
        (offset + focal) / max(0.0001, viewport * zoom)
    }

    /// The offset that puts `fraction` of the grid at `focal`, at `zoom`. Not clamped. A moving centre is a change of `focal`, which pans.
    static func offset(keepingFraction fraction: CGFloat, atFocal focal: CGFloat, zoom: CGFloat, viewport: CGFloat) -> CGFloat {
        fraction * viewport * zoom - focal
    }

    /// One step of a pinch: the zoom shown, and the offset to scroll to.
    static func step(startZoom: CGFloat, scale: CGFloat, fraction: CGFloat, focal: CGFloat, viewport: CGFloat) -> (zoom: CGFloat, offset: CGFloat) {
        let zoom = rubberBanded(startZoom * scale)
        return (zoom, clampedOffset(offset(keepingFraction: fraction, atFocal: focal, zoom: zoom, viewport: viewport), zoom: zoom, viewport: viewport))
    }

    /// Where a released pinch comes to rest: the zoom back inside the range, the same time still under the same point as far as the grid allows.
    static func rest(zoom: CGFloat, fraction: CGFloat, focal: CGFloat, viewport: CGFloat) -> (zoom: CGFloat, offset: CGFloat) {
        let target = clamped(zoom)
        return (target, clampedOffset(offset(keepingFraction: fraction, atFocal: focal, zoom: target, viewport: viewport), zoom: target, viewport: viewport))
    }

    /// The scroll position that keeps the same time at the same point when only the zoom changes (a slider, a double tap).
    static func offsetAfterZoom(from old: CGFloat, to new: CGFloat, offset: CGFloat, focal: CGFloat, viewport: CGFloat) -> CGFloat {
        let fraction = anchorFraction(offset: offset, focal: focal, zoom: old, viewport: viewport)
        return clampedOffset(self.offset(keepingFraction: fraction, atFocal: focal, zoom: new, viewport: viewport), zoom: new, viewport: viewport)
    }

    /// Which half-viewport band of the scroll the visible window is in. Content outside a margin around the window is not built; the margin is
    /// a whole viewport each side, and the window is only rebuilt when the band changes, never per scroll frame.
    static func visibleBand(offset: CGFloat, viewport: CGFloat) -> Int { Int((offset / max(1, viewport * 0.5)).rounded(.down)) }

    static func buildWindow(band: Int, viewport: CGFloat) -> ClosedRange<CGFloat> {
        let start = CGFloat(band) * viewport * 0.5
        return (start - viewport)...(start + viewport * 1.5 + viewport)
    }
}
