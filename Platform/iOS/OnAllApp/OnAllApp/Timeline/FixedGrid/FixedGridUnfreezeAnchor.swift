import CoreGraphics
import NEOBudgetCalendar

/// The time an unfreeze keeps where it is on screen while the axis eases from the frozen partition to the planned one (`FixedGridBrowseModel.unfreeze`).
/// After a save it is the edited edge: the edge was drawn at its saved time on the frozen axis when the finger left it, and it stays at that height on every
/// frame of the easing, so the event does not jump away from where it was put. Otherwise (and when that edge is not on screen) it is the time at the middle
/// of the screen, as before. Pure, so it is tested.
struct FixedGridUnfreezeAnchor: Equatable {
    /// Wall-clock minute of the axis (what a partition's times are).
    let time: Double
    /// From the top of the viewport.
    let focal: CGFloat
    let isEdge: Bool

    /// Resolves `request` against what is on screen as the session ends: the frozen partition (unzoomed, as `shared` returns it), the zoom, the viewport
    /// and the scroll offset. An edge further than `margin` outside the viewport falls back to the middle.
    static func resolve(
        _ request: FixedGridEditInteraction.AnchorRequest, frozen: TemporalGridPartition, projection: (LocalDate) -> WallClockProjection,
        zoom: CGFloat, viewport: CGFloat, offset: CGFloat, margin: CGFloat = 0
    ) -> FixedGridUnfreezeAnchor {
        let middle = FixedGridUnfreezeAnchor(
            time: ContinuousDayAxis.time(atOffset: offset, partition: frozen, zoom: zoom, viewport: viewport, focal: viewport / 2), focal: viewport / 2, isEdge: false
        )
        guard case let .edge(handle, day, minute) = request else { return middle }
        let time = wallTime(of: handle, minute: minute, projection: projection(day))
        let focal = frozen.zoomed(viewportHeight: viewport, zoomScale: zoom).timeToY(time) - offset
        guard focal >= -margin, focal <= viewport + margin else { return middle }
        return FixedGridUnfreezeAnchor(time: time, focal: focal, isEdge: true)
    }

    /// An edge's elapsed minute as a time of the axis: a start is the wall minute it begins at, an end the wall minute it ends before (the same rule the
    /// card is drawn with, `ElapsedMinuteAxisMapping.y(endMinute:)`).
    static func wallTime(of handle: FixedGridEditInteraction.Handle, minute: Int, projection: WallClockProjection) -> Double {
        Double(handle == .start ? projection.clock.wallMinute(forElapsed: minute) : projection.clock.exclusiveEndWall(forElapsed: minute))
    }

    /// The scroll offset that keeps the anchor at its height on `partition` (the frame's shared, unzoomed partition).
    func offset(on partition: TemporalGridPartition, zoom: CGFloat, viewport: CGFloat) -> ContinuousDayAxis.AnchoredOffset {
        ContinuousDayAxis.anchoredOffset(time: time, partition: partition, zoom: zoom, viewport: viewport, focal: focal)
    }

    /// How far (points) the anchored time is from its height at `offset` on `partition` (DEBUG probe and tests).
    func drift(on partition: TemporalGridPartition, zoom: CGFloat, viewport: CGFloat, offset: CGFloat) -> CGFloat {
        partition.zoomed(viewportHeight: viewport, zoomScale: zoom).timeToY(time) - offset - focal
    }
}
