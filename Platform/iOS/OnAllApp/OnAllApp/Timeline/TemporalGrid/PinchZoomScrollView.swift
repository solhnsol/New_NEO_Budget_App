import SwiftUI
import UIKit

#if DEBUG
/// The zoom and what the screen reads about it. The hosted content observes this; the screen around it does not, so a pinch redraws only the grid.
@MainActor
final class PinchZoomModel: ObservableObject {
    @Published var zoom: CGFloat
    /// Which half-viewport band of the scroll is on screen (changes rarely; the content built for it reaches a viewport beyond each side).
    @Published var band = 0
    @Published var isInteracting = false
    var viewportHeight: CGFloat = 0
    init(zoom: CGFloat = 1) { self.zoom = PinchZoomMath.clamped(zoom) }
    /// Set by the scroll view: change the zoom keeping the time at `focal` (from the top of the viewport) where it is.
    var setZoom: ((CGFloat, CGFloat) -> Void)?
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

/// What a horizontal drag across the days is doing (the day move of the prototype).
enum DateDragPhase {
    case changed(translationX: CGFloat)
    case ended(velocityX: CGFloat)
    case cancelled
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
    @ViewBuilder var content: (_ zoom: CGFloat, _ viewport: CGFloat, _ window: ClosedRange<CGFloat>) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> Container {
        let container = Container()
        context.coordinator.attach(to: container, root: AnyView(host()))
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        context.coordinator.onDateDrag = onDateDrag
        context.coordinator.hosting?.rootView = AnyView(host())
    }

    private func host() -> some View { Host(model: model, build: content) }

    struct Host<C: View>: View {
        @ObservedObject var model: PinchZoomModel
        let build: (CGFloat, CGFloat, ClosedRange<CGFloat>) -> C
        var body: some View {
            let start = CFAbsoluteTimeGetCurrent()
            let view = build(model.zoom, model.viewportHeight, PinchZoomMath.buildWindow(band: model.band, viewport: model.viewportHeight))
            model.recordBuild((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return view
        }
    }

    final class Container: UIView {
        var onLayout: ((CGSize) -> Void)?
        override func layoutSubviews() { super.layoutSubviews(); onLayout?(bounds.size) }
    }

    // MARK: Coordinator

    /// Counts the fingers on the glass, without ever taking part in a gesture.
    final class TouchCounter: UIGestureRecognizer {
        private(set) var count = 0
        var allLifted: (() -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { count += touches.count }
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
        var hosting: UIHostingController<AnyView>?
        var onDateDrag: (DateDragPhase) -> Void = { _ in }
        private let counter = TouchCounter()
        private var pinch: UIPinchGestureRecognizer!
        private var datePan: UIPanGestureRecognizer!
        private var pinchStart: (zoom: CGFloat, fraction: CGFloat)?
        private var lastFocal: CGFloat = 0
        private var suppressed = false
        private var datePanning = false
        private var link: CADisplayLink?
        private var meter: CADisplayLink?
        private var meterLast: CFTimeInterval = 0
        private var meterIntervals: [Double] = []
        private var animation: (start: (CGFloat, CGFloat), end: (CGFloat, CGFloat), began: CFTimeInterval, duration: CFTimeInterval)?

        init(model: PinchZoomModel) { self.model = model }

        func attach(to container: Container, root: AnyView) {
            self.container = container
            container.clipsToBounds = true
            container.backgroundColor = .clear
            scroll.frame = container.bounds
            scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scroll.alwaysBounceVertical = true
            scroll.showsVerticalScrollIndicator = true
            scroll.isDirectionalLockEnabled = true
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.delegate = self
            container.addSubview(scroll)
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            scroll.addSubview(host.view)
            hosting = host

            pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            container.addGestureRecognizer(pinch)
            datePan = UIPanGestureRecognizer(target: self, action: #selector(handleDatePan(_:)))
            datePan.delegate = self
            datePan.maximumNumberOfTouches = 1
            container.addGestureRecognizer(datePan)
            counter.cancelsTouchesInView = false
            counter.delaysTouchesBegan = false
            counter.delaysTouchesEnded = false
            counter.allLifted = { [weak self] in self?.fingersUp() }
            container.addGestureRecognizer(counter)

            container.onLayout = { [weak self] size in self?.layout(size) }
            model.setZoom = { [weak self] zoom, focal in self?.setZoom(zoom, focal: focal) }
        }

        // MARK: Layout

        private func layout(_ size: CGSize) {
            guard size.height > 0 else { return }
            if abs(model.viewportHeight - size.height) > 0.5 { model.viewportHeight = size.height }
            applyContent(zoom: model.zoom, offset: scroll.contentOffset.y)
        }

        /// Size the content for `zoom` and scroll to `offset`, in one step, so the content and the scroll position never disagree.
        private func applyContent(zoom: CGFloat, offset: CGFloat?) {
            guard let host = hosting?.view, let container else { return }
            let viewport = container.bounds.height
            let height = viewport * zoom
            let size = CGSize(width: container.bounds.width, height: height)
            if scroll.contentSize != size { scroll.contentSize = size }
            host.frame = CGRect(origin: .zero, size: size)
            if let offset {
                // During a stretch past the ends the content is shorter than the viewport; the offset then is 0.
                let limits = PinchZoomMath.offsetRange(zoom: zoom, viewport: viewport)
                let clamped = min(max(offset, limits.lowerBound), limits.upperBound)
                if abs(scroll.contentOffset.y - clamped) > 0.0001 { scroll.contentOffset = CGPoint(x: 0, y: clamped) }
            }
            if model.zoom != zoom { model.zoom = zoom }
            let band = PinchZoomMath.visibleBand(offset: scroll.contentOffset.y, viewport: viewport)
            if model.band != band { model.band = band }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let container else { return }
            let band = PinchZoomMath.visibleBand(offset: max(0, scrollView.contentOffset.y), viewport: container.bounds.height)
            if model.band != band { model.band = band }
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

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let container else { return }
            let viewport = container.bounds.height
            let focal = gesture.numberOfTouches > 0 ? gesture.location(in: container).y : lastFocal
            switch gesture.state {
            case .began:
                stopAnimation()
                scroll.setContentOffset(scroll.contentOffset, animated: false)       // stops any inertia at once
                scroll.panGestureRecognizer.isEnabled = false
                datePan.isEnabled = false
                suppressed = true
                if datePanning { datePanning = false; onDateDrag(.cancelled) }
                model.isInteracting = true
                startMeter()
                lastFocal = focal
                pinchStart = (model.zoom, PinchZoomMath.anchorFraction(offset: scroll.contentOffset.y, focal: focal, zoom: model.zoom, viewport: viewport))
            case .changed:
                guard let start = pinchStart else { return }
                lastFocal = focal
                let next = PinchZoomMath.step(startZoom: start.zoom, scale: gesture.scale, fraction: start.fraction, focal: focal, viewport: viewport)
                applyContent(zoom: next.zoom, offset: next.offset)
            case .ended, .cancelled, .failed:
                guard let start = pinchStart else { return }
                pinchStart = nil
                model.isInteracting = false
                stopMeter()
                let target = PinchZoomMath.rest(zoom: model.zoom, fraction: start.fraction, focal: lastFocal, viewport: viewport)
                if abs(target.zoom - model.zoom) > 0.0005 { animate(to: target) } else { applyContent(zoom: target.zoom, offset: target.offset) }
                // A finger may still be down: nothing scrolls and no day moves until all are up.
                if counter.count == 0 { fingersUp() } else { scheduleFallback() }
            default: break
            }
        }

        private func fingersUp() {
            guard pinchStart == nil else { return }
            suppressed = false
            scroll.panGestureRecognizer.isEnabled = true
            datePan.isEnabled = true
        }

        /// If the finger count were ever wrong, gestures still come back.
        private func scheduleFallback() {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.pinchStart == nil, self.suppressed else { return }
                self.fingersUp()
            }
        }

        // MARK: Frame pacing during a pinch

        private func startMeter() {
            meterIntervals = []; meterLast = 0
            model.resetBuildSamples()
            let link = CADisplayLink(target: self, selector: #selector(meterTick(_:)))
            link.add(to: .main, forMode: .common)
            meter = link
        }

        @objc private func meterTick(_ link: CADisplayLink) {
            if meterLast > 0 { meterIntervals.append((link.timestamp - meterLast) * 1000) }
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

        private func animate(to target: (zoom: CGFloat, offset: CGFloat)) {
            stopAnimation()
            animation = (start: (model.zoom, scroll.contentOffset.y), end: (target.zoom, target.offset), began: CACurrentMediaTime(), duration: 0.32)
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        private func stopAnimation() { link?.invalidate(); link = nil; animation = nil }

        @objc private func tick() {
            guard let animation else { stopAnimation(); return }
            let t = min(1, (CACurrentMediaTime() - animation.began) / animation.duration)
            let eased = 1 - pow(1 - t, 3)
            let zoom = animation.start.0 + (animation.end.0 - animation.start.0) * CGFloat(eased)
            let offset = animation.start.1 + (animation.end.1 - animation.start.1) * CGFloat(eased)
            applyContent(zoom: zoom, offset: offset)
            if t >= 1 { stopAnimation() }
        }

        // MARK: Moving the days

        @objc private func handleDatePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                datePanning = true
                scroll.panGestureRecognizer.isEnabled = false
                onDateDrag(.changed(translationX: 0))
            case .changed:
                if datePanning { onDateDrag(.changed(translationX: gesture.translation(in: container).x)) }
            case .ended:
                if datePanning { datePanning = false; onDateDrag(.ended(velocityX: gesture.velocity(in: container).x)) }
                if !suppressed { scroll.panGestureRecognizer.isEnabled = true }
            case .cancelled, .failed:
                if datePanning { datePanning = false; onDateDrag(.cancelled) }
                if !suppressed { scroll.panGestureRecognizer.isEnabled = true }
            default: break
            }
        }

        // MARK: Gesture arbitration

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === datePan {
                guard !suppressed, pinchStart == nil else { return false }
                let velocity = datePan.velocity(in: container)
                return abs(velocity.x) > abs(velocity.y) * 1.6        // a mostly horizontal drag only
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // The scroll view's own pan is switched off while a pinch or a day move runs; nothing else runs together.
            return gestureRecognizer === counter || other === counter
        }
    }
}
#endif
