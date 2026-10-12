import QuartzCore
import SwiftUI

/// The precision bubble placed next to its handle. Lay it over the grid's scroll view, filling it exactly (`.overlay` on `PinchZoomScrollView`), so its
/// space is the viewport's: `anchor` is the handle's centre in the viewport (content point minus the scroll offset; `PrecisionAnchorTracker` keeps it current
/// through scrolls and pinches).
///
/// Only the bubble takes touches; everywhere else they fall through to the grid's recognizers. It follows the anchor without animation (it must not trail the
/// handle); it appears and disappears with a short fade. Hidden while `input` or `anchor` is `nil`.
struct PrecisionBubbleOverlay: View {
    let input: PrecisionBubbleInput?
    let anchor: CGPoint?
    /// What the bubble keeps clear of at the viewport's edges (the hour gutter may be covered; a header or toolbar drawn over the grid should be here).
    var margins = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    var clearance: CGFloat = EditHit.handleRadius
    let onAction: (PrecisionBubbleAction) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var height: CGFloat = 0
    @State private var side: PrecisionBubbleLayout.Side?

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(
                x: margins.leading, y: margins.top,
                width: proxy.size.width - margins.leading - margins.trailing, height: proxy.size.height - margins.top - margins.bottom
            )
            ZStack(alignment: .topLeading) {
                if let input, let anchor, bounds.width > 0, bounds.height > 0 {
                    let drawnSize = typeSize > PrecisionBubbleMetrics.largestSize ? PrecisionBubbleMetrics.largestSize : typeSize
                    let width = PrecisionBubbleMetrics.width(drawnSize, available: bounds.width)
                    let placement = PrecisionBubbleLayout.place(
                        anchor: anchor, edge: input.edge, size: CGSize(width: width, height: max(height, 1)), bounds: bounds, clearance: clearance, previous: side
                    )
                    bubble(input, placement: placement, width: width)
                        .dynamicTypeSize(...PrecisionBubbleMetrics.largestSize)
                        .opacity(height > 0 ? 1 : 0)                                    // measured before it is shown
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: unitAnchor(placement.side))))
                        .onChange(of: placement.side, initial: true) { _, new in side = new }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(.easeOut(duration: 0.15), value: input?.edge)
            .animation(.easeOut(duration: 0.15), value: input == nil || anchor == nil)
            .onChange(of: input?.edge) { side = nil }                                   // a new edge starts from its own preference
        }
    }

    private func bubble(_ input: PrecisionBubbleInput, placement: PrecisionBubbleLayout.Placement, width: CGFloat) -> some View {
        let frame = placement.frame
        return ZStack(alignment: .topLeading) {
            // One fill for body and arrow, shadowed together.
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: PrecisionBubbleLayout.cornerRadius, style: .continuous)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                if let tip = placement.arrowTip {
                    PrecisionBubbleArrow(tip: tip, side: placement.side)
                }
            }
            .foregroundStyle(Color(uiColor: .tertiarySystemBackground))
            .compositingGroup()
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)

            PrecisionEditBubble(input: input, offscreen: placement.anchorVisible ? nil : placement.side, onAction: onAction)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .offset(x: frame.minX, y: frame.minY)
        }
        // Follows the handle frame by frame: no implicit animation of where it is.
        .transaction { $0.animation = nil }
    }

    private func unitAnchor(_ side: PrecisionBubbleLayout.Side) -> UnitPoint {
        switch side {
        case .above, .pinnedBottom: .bottom
        case .below, .pinnedTop: .top
        case .leading: .trailing
        case .trailing: .leading
        case .clamped: .center
        }
    }
}

/// The arrow from the bubble's body to its handle: a triangle with its tip at `tip`, its base on the body's facing edge.
struct PrecisionBubbleArrow: Shape {
    let tip: CGPoint
    let side: PrecisionBubbleLayout.Side

    func path(in rect: CGRect) -> Path {
        let length = PrecisionBubbleLayout.arrowLength + 1                               // 1pt into the body so no seam shows
        let half = PrecisionBubbleLayout.arrowHalfWidth
        var path = Path()
        path.move(to: tip)
        switch side {
        case .above:
            path.addLine(to: CGPoint(x: tip.x - half, y: tip.y - length)); path.addLine(to: CGPoint(x: tip.x + half, y: tip.y - length))
        case .below:
            path.addLine(to: CGPoint(x: tip.x + half, y: tip.y + length)); path.addLine(to: CGPoint(x: tip.x - half, y: tip.y + length))
        case .leading:
            path.addLine(to: CGPoint(x: tip.x - length, y: tip.y + half)); path.addLine(to: CGPoint(x: tip.x - length, y: tip.y - half))
        case .trailing:
            path.addLine(to: CGPoint(x: tip.x + length, y: tip.y - half)); path.addLine(to: CGPoint(x: tip.x + length, y: tip.y + half))
        case .pinnedTop, .pinnedBottom, .clamped:
            return Path()
        }
        path.closeSubpath()
        return path
    }
}

/// Keeps a precision bubble's anchor current while the grid scrolls and zooms, without the scroll view telling anyone: once a display frame it asks `source`
/// for the handle's point in the viewport and publishes it when it moved. Only a view observing this (the overlay) is redrawn; the grid is not.
///
/// `source` is cheap and reads what is current: typically `contentPoint(…)` of the handle at `pinch.zoom` minus `pinch.currentOffset()`
/// (`viewportPoint(content:offset:)`). A scroll view that can say when it moved may call `refresh()` from there too (then no frame is a step behind).
@MainActor
final class PrecisionAnchorTracker: ObservableObject {
    @Published private(set) var anchor: CGPoint?
    private var source: (() -> CGPoint?)?
    private var link: CADisplayLink?
    private(set) var publishCount = 0

    /// Starts following `source` (replacing any earlier one) and reads it at once.
    func track(_ source: @escaping () -> CGPoint?) {
        self.source = source
        if link == nil {
            let link = CADisplayLink(target: Tick(self), selector: #selector(Tick.fire))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        refresh()
    }

    /// Stops following and hides the anchor.
    func stop() {
        link?.invalidate()
        link = nil
        source = nil
        if anchor != nil { anchor = nil }
    }

    /// Reads the source now; publishes only a change of a tenth of a point or more (or to / from `nil`).
    func refresh() {
        let next = source?()
        if Self.moved(from: anchor, to: next) {
            anchor = next
            publishCount += 1
        }
    }

    static func moved(from old: CGPoint?, to new: CGPoint?) -> Bool {
        switch (old, new) {
        case (nil, nil): false
        case let (old?, new?): abs(old.x - new.x) >= 0.1 || abs(old.y - new.y) >= 0.1
        default: true
        }
    }

    /// A point of the grid's content, in the viewport scrolled to `offset` (the content scrolls only vertically).
    nonisolated static func viewportPoint(content: CGPoint, offset: CGFloat) -> CGPoint { CGPoint(x: content.x, y: content.y - offset) }

    /// A point of the grid's content at `zoom`, from where it is at 1× (the content is the viewport's height times the zoom and every y scales with it;
    /// x does not). For a handle whose 1× point is known, this follows a pinch without asking the plan again.
    nonisolated static func contentPoint(atUnitZoom point: CGPoint, zoom: CGFloat) -> CGPoint { CGPoint(x: point.x, y: point.y * zoom) }

    /// The display link holds this, not the tracker, so a tracker that goes away stops its link.
    private final class Tick: NSObject {
        weak var tracker: PrecisionAnchorTracker?
        init(_ tracker: PrecisionAnchorTracker) { self.tracker = tracker }
        @MainActor @objc func fire(_ link: CADisplayLink) {
            guard let tracker else { link.invalidate(); return }
            tracker.refresh()
        }
    }
}

/// `PrecisionBubbleOverlay` with its anchor from a tracker: the only view redrawn while the anchor moves.
struct TrackedPrecisionBubbleOverlay: View {
    let input: PrecisionBubbleInput?
    @ObservedObject var tracker: PrecisionAnchorTracker
    var margins = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    let onAction: (PrecisionBubbleAction) -> Void

    var body: some View {
        PrecisionBubbleOverlay(input: input, anchor: tracker.anchor, margins: margins, onAction: onAction)
            // A step moves the handle in the same update as the time: read the anchor now rather than at the next display frame.
            .onChange(of: input) { tracker.refresh() }
    }
}
