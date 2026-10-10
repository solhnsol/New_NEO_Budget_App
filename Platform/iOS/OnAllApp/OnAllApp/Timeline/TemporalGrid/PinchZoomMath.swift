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
