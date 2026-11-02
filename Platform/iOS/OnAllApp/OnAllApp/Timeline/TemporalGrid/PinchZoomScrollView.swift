import SwiftUI
import UIKit

/// The zoom and what the screen reads about it. The hosted content observes this; the screen around it does not, so a pinch redraws only the grid.
@MainActor
final class PinchZoomModel: ObservableObject {
    @Published var zoom: CGFloat
    /// Which half-viewport band of the scroll is on screen (changes rarely; the content built for it reaches a viewport beyond each side).
    @Published var band = 0
    @Published var isInteracting = false
    /// While a pinch that ended past 1× or 8× eases back inside: the zoom it comes to rest at. What is planned for the zoom is planned for this, not for the
    /// frames of the easing. `nil` otherwise.
    @Published var settlingZoom: CGFloat?
    /// DEBUG scripts: plays a pinch through the same steps as the recognizer (state, scale since it began, focal y from the top of the viewport).
    var drivePinch: ((UIGestureRecognizer.State, CGFloat, CGFloat) -> Void)?
    @Published var viewportHeight: CGFloat = 0
    init(zoom: CGFloat = 1) { self.zoom = PinchZoomMath.clamped(zoom) }
    /// Set by the scroll view: change the zoom keeping the time at `focal` (from the top of the viewport) where it is.
    var setZoom: ((CGFloat, CGFloat) -> Void)?
    /// Set by the scroll view: the scroll offset now, and a way to put it somewhere (the days moving under a zoomed view keep the time at the middle).
    var currentOffset: (() -> CGFloat)?
    /// Returns false when the offset was not applied because the person has the scroll in hand.
    var setOffset: ((CGFloat) -> Bool)?
    /// How much of the bottom of the viewport something drawn over the grid covers (an edit bar, the keyboard): the scroll may go that much further, so the
    /// end of the day can be brought above it. Not published: it changes the scroll, not what is drawn.
    var bottomInset: CGFloat = 0 { didSet { if abs(oldValue - bottomInset) > 0.5 { applyBottomInset?() } } }
    var applyBottomInset: (() -> Void)?
    /// How far the content shows above the top edge of the scroll view (the header drawn over the grid is translucent). Does not move anything.
    var topOverhang: CGFloat = 0
    /// Set by the scroll view: eases the scroll to an offset over a duration (the zoom stays). Ignored while the person has the scroll in hand.
    var scrollTo: ((CGFloat, CFTimeInterval) -> Void)?
    /// The offsets the scroll can rest at now (with `bottomInset`).
    func offsetRange(zoom: CGFloat) -> ClosedRange<CGFloat> {
        let base = PinchZoomMath.offsetRange(zoom: zoom, viewport: viewportHeight)
        return base.lowerBound...(base.upperBound + bottomInset)
    }
    /// Whether the person scrolled or pinched since the last time this was read. The move reads it to take a new anchor.
    private(set) var userMoved = false
    func markUserMoved() { userMoved = true }
    func consumeUserMoved() -> Bool { defer { userMoved = false }; return userMoved }
    /// Frame pacing of a move (a swipe and the settle after it), the same display-link meter the pinch uses.
    var startPace: (() -> Void)?
    var stopPace: (() -> Void)?
    // Measurements of the content's own build (the SwiftUI tree for one frame), in milliseconds.
    private(set) var buildSamples: [Double] = []
    private(set) var lastBuildCount = 0
    func recordBuild(_ milliseconds: Double) { buildSamples.append(milliseconds); if buildSamples.count > 600 { buildSamples.removeFirst() } }
    /// Display-link intervals during the last pinch (ms): how long the main thread kept each frame waiting.
    var paceSummary = "—"
    func resetBuildSamples() { buildSamples.removeAll() }
    var buildSummary: String {
        guard !buildSamples.isEmpty else { return "—" }
        let sorted = buildSamples.sorted()
        return String(format: "%.2f/%.2f/%.2f ms (n=%d)", buildSamples.reduce(0, +) / Double(buildSamples.count), sorted[sorted.count / 2], sorted.last ?? 0, buildSamples.count)
    }
}

/// The grid's hosting controller, with its layout pass measured (`BrowseProbe.Kind.hostLayout`): SwiftUI laying out the grid inside UIKit's layout.
final class ProbedHostingController: UIHostingController<AnyView> {
    private var layoutProbe: BrowseProbe.Token?
    override func viewWillLayoutSubviews() {
        layoutProbe = BrowseProbe.begin(.hostLayout)
        super.viewWillLayoutSubviews()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        BrowseProbe.end(layoutProbe)
        layoutProbe = nil
    }
}

/// The fixed grid's own touches, taken by UIKit recognizers on the same container as the pinch, the day swipe and the scroll, so UIKit arbitrates them all
/// (`FixedGridGestures` says which may take a touch). Locations are in the grid's content coordinates (the hosted SwiftUI content's).
struct GridGestureHooks {
    enum Phase: Equatable { case began, moved, ended, cancelled }
    /// What is under a point (asked once per touch, at touch-down).
    var start: (CGPoint) -> FixedGridGestures.Start
    var mode: () -> FixedGridGestures.Mode
    var tap: (CGPoint, FixedGridGestures.Start) -> Void
    var longPress: (Phase, CGPoint, FixedGridGestures.Start) -> Void
    /// A drag that began on a handle of the chosen event (editing only).
    var handlePan: (Phase, CGPoint, EditHit) -> Void
}

/// What a horizontal drag across the days is doing (the day move of the prototype).
enum DateDragPhase {
    /// A finger came down while the days were still moving: they stop under it (it may be a swipe, a scroll, a pinch or a tap).
    case touchDown
    /// The finger has gone far enough sideways to be a swipe.
    case began
    case changed(translationX: CGFloat)
    case ended(velocityX: CGFloat)
    case cancelled
    /// Every finger is up and none made a swipe: whatever was moving carries on to where it was going.
    case touchUp
}

/// A vertical scroll view whose content is a SwiftUI grid, with a two-finger pinch that zooms the whole grid continuously (1 ... 8×) and keeps the
/// time under the centre of the fingers under the centre of the fingers (a centre that moves pans). One finger scrolls (UIKit's own inertia and
/// edge bounce); a pinch past 1× or 8× stretches a little and comes back; a horizontal drag moves the days.
///
/// While two fingers are down no scroll and no day move can begin, and after a pinch they stay off until every finger is up, so the finger left
/// on the glass cannot start one. The cells and what they stand for are not touched here: the zoom is a number and the content is drawn from it.
struct PinchZoomScrollView<Content: View>: UIViewRepresentable {
    let model: PinchZoomModel
    var onDateDrag: (DateDragPhase) -> Void
    /// The grid's taps, long presses and handle drags; `nil` for none (the DEBUG prototype grid).
    var gestures: GridGestureHooks? = nil
    @ViewBuilder var content: (_ zoom: CGFloat, _ viewport: CGFloat, _ window: ClosedRange<CGFloat>) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> Container {
        let container = Container()
        context.coordinator.hooks = gestures
        if ProbeExperiment.stableRoot {
            let box = ContentBox(build: content)
            context.coordinator.box = box
            context.coordinator.attach(to: container, root: AnyView(BoxHost(model: model, box: box)))
        } else {
            context.coordinator.attach(to: container, root: AnyView(host()))
        }
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        context.coordinator.onDateDrag = onDateDrag
        context.coordinator.hooks = gestures
        if let box = context.coordinator.box as? ContentBox {
            box.build = content
            box.objectWillChange.send()
        } else {
            context.coordinator.hosting?.rootView = AnyView(host())
        }
    }

    private func host() -> some View { Host(model: model, build: content) }

    /// The experiment `-probe-h3-stable-root`: the content of the latest update, reached by the one root view through observation instead of a new root view.
    @MainActor final class ContentBox: ObservableObject {
        var build: (CGFloat, CGFloat, ClosedRange<CGFloat>) -> Content
        init(build: @escaping (CGFloat, CGFloat, ClosedRange<CGFloat>) -> Content) { self.build = build }
    }

    struct BoxHost: View {
        @ObservedObject var model: PinchZoomModel
        @ObservedObject var box: ContentBox
        var body: some View { Host(model: model, build: box.build) }
    }

    struct Host<C: View>: View {
        @ObservedObject var model: PinchZoomModel
        let build: (CGFloat, CGFloat, ClosedRange<CGFloat>) -> C
        var body: some View {
            let start = CFAbsoluteTimeGetCurrent()
            let probe = BrowseProbe.begin(.gridBuild)
            defer { BrowseProbe.end(probe) }
            let view = build(model.zoom, model.viewportHeight, PinchZoomMath.buildWindow(band: model.band, viewport: model.viewportHeight))
            model.recordBuild((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return view
        }
    }

    final class Container: UIView {
        var onLayout: ((CGSize) -> Void)?
        /// How far the content may show above the top edge (under a translucent header drawn over the grid). Only the top is open: the bottom is cut at the
        /// edge as before. The geometry stays the container's own, so the scroll's offsets and the touch points are unchanged.
        var overhang: () -> CGFloat = { 0 }
        private let reach = CAShapeLayer()
        override func layoutSubviews() {
            super.layoutSubviews()
            let top = overhang()
            reach.path = UIBezierPath(rect: CGRect(x: 0, y: -top, width: bounds.width, height: bounds.height + top)).cgPath
            if top > 0 { layer.mask = reach } else { layer.mask = nil }
            onLayout?(bounds.size)
        }
    }

    // MARK: Coordinator

    /// Counts the fingers on the glass, without ever taking part in a gesture.
    final class TouchCounter: UIGestureRecognizer {
        private(set) var count = 0
        var allLifted: (() -> Void)?
        var touchedDown: (() -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { if count == 0 { touchedDown?() }; count += touches.count }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches.count) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches.count) }
        private func lift(_ number: Int) { count = max(0, count - number); if count == 0 { allLifted?() } }
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
        override func reset() { count = 0 }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIScrollViewDelegate {
        let model: PinchZoomModel
        weak var container: Container?
        let scroll = UIScrollView()
        var hosting: ProbedHostingController?
        var onDateDrag: (DateDragPhase) -> Void = { _ in }
        var box: AnyObject?
        private let counter = TouchCounter()
        private var pinch: UIPinchGestureRecognizer!
        private var datePan: DateSwipeRecognizer!
        /// The pinch under way (`nil` when none), and the zoom it would be at with the fingers as they were when it began (or last went on).
        private var pinchStart: PinchZoomMath.Pinch?
        private var pinchBaseZoom: CGFloat = 1
        /// The offset the pinch (or its easing back to rest) has drawn the content at. While they run only they move the scroll: anything else that moves it
        /// (the scroll view putting a cancelled bounce back at its end, or snapping an offset past an end into range) is undone at once, so no frame shows
        /// the content anywhere but under the fingers or on the way to rest. A finger on the scroll takes it back.
        private var pinchOffset: CGFloat?
        /// The scroll is being set here (its own moves are not undone).
        private var applying = false
        private var lastFocal: CGFloat = 0
        private var datePanning = false
        var hooks: GridGestureHooks?
        private var tap: UITapGestureRecognizer?
        private var longPress: UILongPressGestureRecognizer?
        private var handlePan: UIPanGestureRecognizer?
        /// What each running recognizer keeps off (`FixedGridGestures.suppressed`), until it ends or every finger is up.
        private var holds: [FixedGridGestures.Recognizer: Set<FixedGridGestures.Recognizer>] = [:]
        /// What each touch began on, decided once at touch-down.
        private var starts: [ObjectIdentifier: (start: FixedGridGestures.Start, point: CGPoint)] = [:]
        private var tapStart: FixedGridGestures.Start = .empty
        private var longPressStart: FixedGridGestures.Start = .empty
        private var handleStart: (hit: EditHit, point: CGPoint)?
        private var link: CADisplayLink?
        private var meter: CADisplayLink?
        private var meterLast: CFTimeInterval = 0
        private var meterIntervals: [Double] = []
        private var animation: (start: (CGFloat, CGFloat), end: (CGFloat, CGFloat), began: CFTimeInterval, duration: CFTimeInterval)?
        /// A one-finger drag under way: where the finger and the (unbanded) offset were when it began. Past an end it is drawn with the pinch's rubber
        /// band, not UIKit's, so a pull feels the same with one finger or two.
        private var drag: (finger: CGFloat, offset: CGFloat)?
        /// The last offset a fling drew and when, for the speed it reaches an end at.
        private var lastScroll: (offset: CGFloat, time: CFTimeInterval)?
        /// A fling's bounce at an end, drawn here instead of UIKit's (which goes much further): out and back past `edge` (`PinchZoomMath.bounceOffset`).
        private var bounce: (edge: CGFloat, peak: CGFloat, tau: CGFloat, began: CFTimeInterval)?

        init(model: PinchZoomModel) { self.model = model }

        func attach(to container: Container, root: AnyView) {
            self.container = container
            container.clipsToBounds = false
            container.overhang = { [weak self] in self?.model.topOverhang ?? 0 }
            container.backgroundColor = .clear
            scroll.frame = container.bounds
            scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scroll.alwaysBounceVertical = true
            scroll.showsVerticalScrollIndicator = true
            scroll.isDirectionalLockEnabled = true
            scroll.clipsToBounds = false
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.delegate = self
            container.addSubview(scroll)
            let host = ProbedHostingController(rootView: root)
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            scroll.addSubview(host.view)
            hosting = host

            pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            container.addGestureRecognizer(pinch)
            datePan = DateSwipeRecognizer(target: self, action: #selector(handleDatePan(_:)))
            datePan.delegate = self
            datePan.cancelsTouchesInView = false
            container.addGestureRecognizer(datePan)
            counter.cancelsTouchesInView = false
            counter.delaysTouchesBegan = false
            counter.delaysTouchesEnded = false
            counter.allLifted = { [weak self] in self?.fingersUp() }
            counter.touchedDown = { [weak self] in self?.onDateDrag(.touchDown) }
            container.addGestureRecognizer(counter)
            if hooks != nil {
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
                longPress.minimumPressDuration = 0.6
                longPress.allowableMovement = 10
                let handlePan = UIPanGestureRecognizer(target: self, action: #selector(handleHandlePan(_:)))
                handlePan.maximumNumberOfTouches = 1
                for recognizer in [tap, longPress, handlePan] as [UIGestureRecognizer] {
                    recognizer.delegate = self
                    recognizer.cancelsTouchesInView = false
                    container.addGestureRecognizer(recognizer)
                }
                self.tap = tap; self.longPress = longPress; self.handlePan = handlePan
            }

            container.onLayout = { [weak self] size in self?.layout(size) }
            model.setZoom = { [weak self] zoom, focal in self?.setZoom(zoom, focal: focal) }
            model.currentOffset = { [weak self] in self?.scroll.contentOffset.y ?? 0 }
            model.setOffset = { [weak self] offset in
                guard let self, self.pinchStart == nil else { return false }
                // The scroll is in the person's hand (or coasting from it): leave it, and take a new anchor when they let go.
                // (A finger that is merely down on it, swiping the days, is not scrolling.)
                if self.scroll.isDragging || self.scroll.isDecelerating { self.model.markUserMoved(); return false }
                self.stopAnimation()
                self.applyContent(zoom: self.model.zoom, offset: offset)
                return true
            }
            model.applyBottomInset = { [weak self] in self?.applyBottomInset() }
            model.scrollTo = { [weak self] offset, duration in
                guard let self, self.pinchStart == nil, !self.scroll.isDragging, !self.scroll.isDecelerating else { return }
                self.animate(to: (self.model.zoom, offset), duration: duration)
            }
            model.startPace = { [weak self] in self?.startMeter() }
            model.drivePinch = { [weak self] state, scale, focal in self?.pinch(state, scale: scale, focal: focal) }
            model.stopPace = { [weak self] in self?.stopMeter() }
        }

        // MARK: Layout

        private func layout(_ size: CGSize) {
            guard size.height > 0 else { return }
            if abs(model.viewportHeight - size.height) > 0.5 { model.viewportHeight = size.height }
            applyContent(zoom: model.zoom, offset: scroll.contentOffset.y)
        }

        /// Size the content for `zoom` and scroll to `offset`, in one step, so the content and the scroll position never disagree.
        /// `clamps`: false while a pinch draws the scroll past an end (it has rubber-banded the offset itself).
        private func applyContent(zoom: CGFloat, offset: CGFloat?, clamps: Bool = true) {
            guard let host = hosting?.view, let container else { return }
            applying = true
            defer { applying = false; if ownsScroll { pinchOffset = scroll.contentOffset.y } }
            let viewport = container.bounds.height
            let height = viewport * zoom
            let size = CGSize(width: container.bounds.width, height: height)
            if scroll.contentSize != size { scroll.contentSize = size }
            host.frame = CGRect(origin: .zero, size: size)
            if let offset {
                // During a stretch past the ends the content is shorter than the viewport; the offset then is 0. What covers the bottom adds its height.
                let limits = PinchZoomMath.offsetRange(zoom: zoom, viewport: viewport)
                let clamped = clamps ? min(max(offset, limits.lowerBound), limits.upperBound + model.bottomInset) : offset
                if abs(scroll.contentOffset.y - clamped) > 0.0001 { scroll.contentOffset = CGPoint(x: 0, y: clamped) }
            }
            if model.zoom != zoom { model.zoom = zoom }
            let band = PinchZoomMath.visibleBand(offset: scroll.contentOffset.y, viewport: viewport)
            if model.band != band { model.band = band }
        }

        /// The scroll reaches `bottomInset` further; when it shrinks, an offset past the new end comes back to it.
        private func applyBottomInset() {
            guard let container else { return }
            let inset = model.bottomInset
            if scroll.contentInset.bottom != inset { scroll.contentInset.bottom = inset }
            let end = PinchZoomMath.offsetRange(zoom: model.zoom, viewport: container.bounds.height).upperBound + inset
            if scroll.contentOffset.y > end + 0.5, !scroll.isDragging, pinchStart == nil { scroll.setContentOffset(CGPoint(x: 0, y: end), animated: true) }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let container else { return }
            if ownsScroll, pinchStart == nil, scrollView.isDragging { stopAnimation() }             // the person took the scroll during the easing
            if !applying, ownsScroll, let kept = pinchOffset, abs(scrollView.contentOffset.y - kept) > 0.5 {
                applying = true
                scrollView.contentOffset = CGPoint(x: 0, y: kept)
                applying = false
                return
            }
            if !applying, !ownsScroll { bandScroll(scrollView) }
            if scrollView.isDragging || scrollView.isDecelerating { model.markUserMoved() }
            let band = PinchZoomMath.visibleBand(offset: max(0, scrollView.contentOffset.y), viewport: container.bounds.height)
            if model.band != band { model.band = band }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard let container, pinchStart == nil else { return }
            stopAnimation()
            let shown = scrollView.contentOffset.y
            let limit = PinchZoomMath.overscrollLimit(viewport: container.bounds.height)
            drag = (scrollView.panGestureRecognizer.location(in: container).y, PinchZoomMath.unbandedOffset(shown, range: offsetRange(zoom: model.zoom), limit: limit))
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { drag = nil; lastScroll = nil }

        /// One finger past an end: the content follows the finger with the pinch's rubber band. A fling that reaches an end: UIKit's deceleration is
        /// stopped there and the bounce drawn here, no further than a pinch's pull (released past an end, UIKit's own bounce back is kept: it starts
        /// from where the content is).
        private func bandScroll(_ scrollView: UIScrollView) {
            guard let container else { return }
            let y = scrollView.contentOffset.y
            let range = offsetRange(zoom: model.zoom)
            if scrollView.isDragging, let drag {
                let free = drag.offset - (scrollView.panGestureRecognizer.location(in: container).y - drag.finger)
                guard !range.contains(free) || !range.contains(y) else { return }
                let shown = PinchZoomMath.rubberBandedOffset(free, range: range, limit: PinchZoomMath.overscrollLimit(viewport: container.bounds.height))
                if abs(shown - y) > 0.01 { applying = true; scrollView.contentOffset = CGPoint(x: 0, y: shown); applying = false }
                return
            }
            guard scrollView.isDecelerating, !scrollView.isTracking else { lastScroll = nil; return }
            let now = CACurrentMediaTime()
            defer { if bounce == nil { lastScroll = (y, now) } }
            guard let last = lastScroll, range.contains(last.offset), !range.contains(y), now - last.time > 0.001 else { return }
            let velocity = (y - last.offset) / CGFloat(now - last.time)
            let edge = y < range.lowerBound ? range.lowerBound : range.upperBound
            let fling = PinchZoomMath.flingBounce(velocity: velocity, viewport: container.bounds.height)
            // The curve leaves the end at about the fling's speed: it starts where the fling has already gone past it.
            let already = min(fling.tau, abs(y - edge) / max(1, abs(velocity)))
            lastScroll = nil
            bounce = (edge, fling.peak, fling.tau, now - CFTimeInterval(already))
            applyContent(zoom: model.zoom, offset: edge + (PinchZoomMath.bounceOffset(at: already, peak: fling.peak, tau: fling.tau) ?? 0), clamps: false)
            applying = true
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)  // stops UIKit's deceleration where it is
            applying = false
            let link = CADisplayLink(target: self, selector: #selector(bounceTick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func bounceTick() {
            guard let bounce else { stopAnimation(); return }
            let offset = PinchZoomMath.bounceOffset(at: CGFloat(CACurrentMediaTime() - bounce.began), peak: bounce.peak, tau: bounce.tau)
            applyContent(zoom: model.zoom, offset: bounce.edge + (offset ?? 0), clamps: false)
            if offset == nil { stopAnimation() }
        }

        // MARK: Slider / programmatic zoom

        func setZoom(_ zoom: CGFloat, focal: CGFloat) {
            guard let container else { return }
            stopAnimation()
            let viewport = container.bounds.height
            let target = PinchZoomMath.clamped(zoom)
            let offset = PinchZoomMath.offsetAfterZoom(from: model.zoom, to: target, offset: scroll.contentOffset.y, focal: focal, viewport: viewport)
            applyContent(zoom: target, offset: offset)
        }

        // MARK: Pinch

        /// Fingers the pinch had at its last step.
        private var pinchTouches = 0

        /// The focal point is the centre of two fingers. With one lifted the pinch keeps the last centre (the finger left on the glass does not pan or jump the
        /// grid to where it is); when a second finger comes back the pinch goes on from where it is, from the new centre.
        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let container else { return }
            let touches = gesture.numberOfTouches
            let focal = touches >= 2 ? gesture.location(in: container).y : lastFocal
            if gesture.state == .changed, touches >= 2, pinchTouches < 2, pinchStart != nil, gesture.scale > 0 {
                pinchBaseZoom = PinchZoomMath.unbandedZoom(model.zoom) / gesture.scale
                pinchStart?.focal = focal
            }
            pinchTouches = touches
            if gesture.state == .changed, touches < 2 { return }                     // one finger: nothing moves until the second is back or all are up
            pinch(gesture.state, scale: gesture.scale, focal: focal)
        }

        private func pinch(_ state: UIGestureRecognizer.State, scale: CGFloat, focal: CGFloat) {
            guard let container else { return }
            let viewport = container.bounds.height
            switch state {
            case .began:
                BrowseProbe.mark(.pinchBegan)
                stopAnimation()
                // The pinch starts from the content where it is drawn, a scroll's bounce past an end too (it goes on as the pinch's rubber band).
                let current = scroll.contentOffset.y
                pinchBaseZoom = PinchZoomMath.unbandedZoom(model.zoom)
                pinchStart = PinchZoomMath.Pinch(zoom: model.zoom, focal: focal, shown: current, viewport: viewport, inset: model.bottomInset, pulled: scroll.isDragging)
                drag = nil
                pinchOffset = current
                hold(by: .pinch)                                                      // no one-finger gesture until every finger is up (a long press, a scroll under way are cancelled)
                applying = true
                scroll.setContentOffset(CGPoint(x: 0, y: current), animated: false)  // stops any inertia or bounce-back at once, where it was
                applying = false
                if datePanning { datePanning = false; onDateDrag(.cancelled) }
                model.isInteracting = true
                startMeter()
                lastFocal = focal
            case .changed:
                guard let state = pinchStart else { return }
                lastFocal = focal
                model.markUserMoved()
                // The zoom stretches past its ends, and the fingers' centre pulls the scroll past its ends, both with resistance; both come back on release.
                // The zoom alone never draws past an end, and below 1× the grid shrinks around the fingers without scrolling (`PinchZoomMath.Pinch`).
                let next = state.step(zoom: PinchZoomMath.rubberBanded(pinchBaseZoom * scale), focal: focal, viewport: viewport, inset: model.bottomInset)
                pinchStart = next
                BrowseProbe.measure(.pinchStep) { applyContent(zoom: next.zoom, offset: next.shown, clamps: false) }
            case .ended, .cancelled, .failed:
                guard pinchStart != nil else { return }
                BrowseProbe.mark(.pinchEnded)
                pinchStart = nil                                                      // `pinchOffset` stays: the easing to rest goes on from it
                // Where the zoom comes to rest is known now; it is set before the pinch is said to be over, so whoever plans for the rested zoom plans for it.
                // The scroll comes back inside its ends with it (the easing starts from where the content is drawn).
                let zoomTarget = PinchZoomMath.clamped(model.zoom)
                let fraction = PinchZoomMath.anchorFraction(offset: scroll.contentOffset.y, focal: lastFocal, zoom: model.zoom, viewport: viewport)
                let rested = PinchZoomMath.offset(keepingFraction: fraction, atFocal: lastFocal, zoom: zoomTarget, viewport: viewport)
                let range = offsetRange(zoom: zoomTarget)
                let target = (zoom: zoomTarget, offset: min(max(rested, range.lowerBound), range.upperBound))
                let settles = abs(target.zoom - model.zoom) > 0.0005 || abs(target.offset - scroll.contentOffset.y) > 0.5
                if settles { animate(to: target); if abs(target.zoom - model.zoom) > 0.0005 { model.settlingZoom = target.zoom } }
                model.isInteracting = false
                model.markUserMoved()
                stopMeter()
                if !settles { pinchOffset = nil; applyContent(zoom: target.zoom, offset: target.offset) }
                // A finger may still be down: nothing scrolls and no day moves until all are up.
                if counter.count == 0 { fingersUp() } else { scheduleFallback() }
            default: break
            }
        }

        /// The offsets the scroll rests at for `zoom` (with what covers the bottom).
        private func offsetRange(zoom: CGFloat) -> ClosedRange<CGFloat> {
            let base = PinchZoomMath.offsetRange(zoom: zoom, viewport: container?.bounds.height ?? 0)
            return base.lowerBound...(base.upperBound + model.bottomInset)
        }

        private func fingersUp() {
            starts = [:]
            guard pinchStart == nil else { return }
            holds = [:]
            applyHolds()
            if !datePanning { onDateDrag(.touchUp) }
        }

        // MARK: Holds

        private func hold(by recognizer: FixedGridGestures.Recognizer, lifting: Bool = false) {
            holds[recognizer] = FixedGridGestures.suppressed(while: recognizer, lifting: lifting)
            applyHolds()
            // An event in the hand: the finger holding it leaves the scroll and the day swipe (switched off and on again, they take only the touches
            // that come down after), so the other hand can scroll and move the days (the pinch is held off meanwhile).
            if lifting { for recognizer in [scroll.panGestureRecognizer, datePan] as [UIGestureRecognizer] { recognizer.isEnabled = false; recognizer.isEnabled = true } }
        }
        private func release(by recognizer: FixedGridGestures.Recognizer) { holds[recognizer] = nil; applyHolds() }
        private var held: Set<FixedGridGestures.Recognizer> { holds.values.reduce(into: []) { $0.formUnion($1) } }

        /// Switches each recognizer off while something holds it (switching one off cancels what it was doing) and back on after.
        private func applyHolds() {
            let off = held
            func set(_ recognizer: UIGestureRecognizer?, _ kind: FixedGridGestures.Recognizer) {
                guard let recognizer else { return }
                let on = !off.contains(kind)
                if recognizer.isEnabled != on { recognizer.isEnabled = on }
            }
            set(scroll.panGestureRecognizer, .scroll); set(datePan, .dateSwipe); set(pinch, .pinch)
            set(tap, .tap); set(longPress, .longPress); set(handlePan, .handlePan)
        }

        private func kind(of recognizer: UIGestureRecognizer) -> FixedGridGestures.Recognizer? {
            switch recognizer {
            case datePan: .dateSwipe
            case pinch: .pinch
            case tap: .tap
            case longPress: .longPress
            case handlePan: .handlePan
            default: nil
            }
        }

        private func start(of touch: UITouch) -> (start: FixedGridGestures.Start, point: CGPoint) {
            let key = ObjectIdentifier(touch)
            if let found = starts[key] { return found }
            let point = touch.location(in: hosting?.view)
            let made = (hooks?.start(point) ?? .empty, point)
            starts[key] = made
            return made
        }

        // MARK: Taps, long presses, handle drags

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let hooks else { return }
            hooks.tap(gesture.location(in: hosting?.view), tapStart)
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let hooks else { return }
            let point = gesture.location(in: hosting?.view)
            switch gesture.state {
            case .began:
                hooks.longPress(.began, point, longPressStart)
                hold(by: .longPress, lifting: hooks.mode() == .lifting)
            case .changed: hooks.longPress(.moved, point, longPressStart)
            case .ended: release(by: .longPress); hooks.longPress(.ended, point, longPressStart)
            case .cancelled, .failed: release(by: .longPress); hooks.longPress(.cancelled, point, longPressStart)
            default: break
            }
        }

        @objc private func handleHandlePan(_ gesture: UIPanGestureRecognizer) {
            guard let hooks, let start = handleStart else { return }
            let point = gesture.location(in: hosting?.view)
            switch gesture.state {
            case .began:
                hold(by: .handlePan)
                // A pan begins after the finger has moved a little; the drag starts from where it came down (what was hit-tested) and catches up.
                hooks.handlePan(.began, start.point, start.hit)
                hooks.handlePan(.moved, point, start.hit)
            case .changed: hooks.handlePan(.moved, point, start.hit)
            case .ended: release(by: .handlePan); hooks.handlePan(.ended, point, start.hit)
            case .cancelled, .failed: release(by: .handlePan); hooks.handlePan(.cancelled, point, start.hit)
            default: break
            }
        }

        /// If the finger count were ever wrong, gestures still come back.
        private func scheduleFallback() {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.pinchStart == nil, self.holds[.pinch] != nil else { return }
                self.fingersUp()
            }
        }

        // MARK: Frame pacing during a pinch

        private func startMeter() {
            meter?.invalidate()
            meterIntervals = []; meterLast = 0
            model.resetBuildSamples()
            let link = CADisplayLink(target: self, selector: #selector(meterTick(_:)))
            link.add(to: .main, forMode: .common)
            meter = link
        }

        @objc private func meterTick(_ link: CADisplayLink) {
            if meterLast > 0 { meterIntervals.append((link.timestamp - meterLast) * 1000) }
            // A bounce or an easing the pinch took over comes back to the end every frame, whether the fingers move or not.
            if let state = pinchStart, state.returning != 0, meterLast > 0 {
                let next = state.settled(after: CGFloat(link.timestamp - meterLast))
                pinchStart = next
                applyContent(zoom: next.zoom, offset: next.shown, clamps: false)
            }
            meterLast = link.timestamp
        }

        private func stopMeter() {
            meter?.invalidate(); meter = nil
            guard meterIntervals.count > 2 else { return }
            let sorted = meterIntervals.sorted()
            let mean = meterIntervals.reduce(0, +) / Double(meterIntervals.count)
            let nominal = sorted[sorted.count / 2]
            let late = meterIntervals.filter { $0 > nominal * 1.5 }.count
            model.paceSummary = String(format: "프레임 간격 평균 %.1f/중앙 %.1f/최대 %.1f ms, 지연 %d/%d", mean, nominal, sorted.last ?? 0, late, meterIntervals.count)
        }

        // MARK: Easing back inside the range

        private func animate(to target: (zoom: CGFloat, offset: CGFloat), duration: CFTimeInterval = 0.32) {
            stopAnimation()
            animation = (start: (model.zoom, scroll.contentOffset.y), end: (target.zoom, target.offset), began: CACurrentMediaTime(), duration: max(0.05, duration))
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        /// A pinch, its easing back or a fling's bounce is drawing the scroll.
        private var ownsScroll: Bool { pinchStart != nil || animation != nil || bounce != nil }

        private func stopAnimation() {
            link?.invalidate(); link = nil; animation = nil; bounce = nil
            if pinchStart == nil { pinchOffset = nil }
            if model.settlingZoom != nil { model.settlingZoom = nil }
        }

        @objc private func tick() {
            guard let animation else { stopAnimation(); return }
            let t = min(1, (CACurrentMediaTime() - animation.began) / animation.duration)
            let eased = 1 - pow(1 - t, 3)
            let zoom = animation.start.0 + (animation.end.0 - animation.start.0) * CGFloat(eased)
            let offset = animation.start.1 + (animation.end.1 - animation.start.1) * CGFloat(eased)
            applyContent(zoom: zoom, offset: offset, clamps: false)                // from past an end to inside it: every step between is drawn
            if t >= 1 { stopAnimation() }
        }

        // MARK: Moving the days

        @objc private func handleDatePan(_ gesture: DateSwipeRecognizer) {
            switch gesture.state {
            case .began:
                datePanning = true
                hold(by: .dateSwipe)
                model.resetBuildSamples()
                startMeter()
                onDateDrag(.began)
                onDateDrag(.changed(translationX: gesture.translationX))
            case .changed:
                if datePanning { onDateDrag(.changed(translationX: gesture.translationX)) }
            case .ended:
                if datePanning { datePanning = false; onDateDrag(.ended(velocityX: gesture.releaseVelocity)) }
                release(by: .dateSwipe)
            case .cancelled, .failed:
                if datePanning { datePanning = false; onDateDrag(.cancelled) }
                release(by: .dateSwipe)
            default: break
            }
        }

        // MARK: Gesture arbitration

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === datePan { return !held.contains(.dateSwipe) && pinchStart == nil }       // the classifier has already said "mostly sideways"
            if let kind = kind(of: gestureRecognizer) { return !held.contains(kind) }
            return true
        }

        /// Ownership is decided at touch-down (`FixedGridGestures.receives`): a recognizer that may not have a touch never receives it, so it makes nothing wait.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let hooks, let kind = kind(of: gestureRecognizer) else { return true }
            let found = start(of: touch)
            guard FixedGridGestures.receives(kind, start: found.start, mode: hooks.mode()), !held.contains(kind) else { return false }
            switch kind {
            case .tap: tapStart = found.start
            case .longPress: longPressStart = found.start
            case .handlePan: if case let .handle(hit) = found.start { handleStart = (hit, found.point) }
            default: break
            }
            return true
        }

        /// A drag from a handle: the scroll, the day swipe and the pinch wait for the handle pan to decide (it only ever has touches that began on a handle).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let handlePan, gestureRecognizer === handlePan else { return false }
            return other === scroll.panGestureRecognizer || other === datePan || other === pinch
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === counter || other === counter { return true }
            // A second finger on a one-finger scroll or day swipe makes it a pinch: the pinch may begin while they run, and switches them off when it does
            // (`hold(by: .pinch)`). Nothing else runs together.
            let oneFinger: [UIGestureRecognizer] = [scroll.panGestureRecognizer, datePan]
            return (gestureRecognizer === pinch && oneFinger.contains { $0 === other }) || (other === pinch && oneFinger.contains { $0 === gestureRecognizer })
        }
    }
}

/// One finger going mostly sideways (`HorizontalDragClassifier`): it begins after 4 points, fails on a mostly vertical movement, and is cancelled when a
/// second finger comes down (a pinch). Its translation is from where the finger came down.
final class DateSwipeRecognizer: UIGestureRecognizer {
    private var classifier = HorizontalDragClassifier()
    private var tracked: UITouch?
    private var endedAt: TimeInterval = 0
    var translationX: CGFloat { classifier.translation }
    var releaseVelocity: CGFloat { classifier.velocity(at: endedAt) }

    private func sample(_ touch: UITouch) -> HorizontalDragClassifier.Sample {
        let point = touch.location(in: view)
        return .init(time: touch.timestamp, x: point.x, y: point.y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if tracked == nil, touches.count == 1, event.allTouches?.count == 1, let touch = touches.first {
            tracked = touch
            classifier.begin(sample(touch))
        } else if state == .began || state == .changed {
            state = .cancelled
        } else {
            state = .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        switch classifier.move(sample(tracked)) {
        case .horizontal: state = state == .possible ? .began : .changed
        case .vertical: if state == .possible { state = .failed }
        case .undecided: break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        endedAt = tracked.timestamp
        state = (state == .began || state == .changed) ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        state = (state == .began || state == .changed) ? .cancelled : .failed
    }

    override func reset() { tracked = nil; classifier = HorizontalDragClassifier() }
}
