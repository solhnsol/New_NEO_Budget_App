import SwiftUI
import UIKit

/// The timeline's touch handling, attached to the enclosing `UIScrollView` so UIKit arbitrates it against scrolling:
/// - **long press**: the owner decides what it means (enter edit mode, pick up the selected event, start a new one).
///   Moving before the press time scrolls as usual.
/// - **pan**: only in edit mode, and only for touches that start on a handle. The recogniser does not even receive any other
///   touch, so the scroll view never waits for it: a plain drag scrolls from the first point of movement.
///
/// SwiftUI's `LongPressGesture.sequenced(before: DragGesture)` and drags on child views swallow scrolling, so they are
/// not used here. Locations are in the scrolled content's coordinate space.
struct EditGestureHost: UIViewRepresentable {
    enum Phase { case began, moved, ended }

    var panEnabled: Bool
    var scrollRequest: TimelineEditor.ScrollRequest?
    /// Brings this rectangle (content coordinates) into view, with a little margin. Used after a long press so the whole
    /// selected event is visible even if it grew upward past the screen edge.
    var reveal: RevealRequest?
    var longPress: (Phase, CGPoint) -> Void
    var panStartsAt: (CGPoint) -> Bool
    var pan: (Phase, CGPoint) -> Void

    struct RevealRequest: Equatable {
        let id = UUID()
        let rect: CGRect
        static func == (lhs: RevealRequest, rhs: RevealRequest) -> Bool { lhs.id == rhs.id }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.update(self)
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.update(self)
    }

    final class HostView: UIView, UIGestureRecognizerDelegate {
        private var configuration: EditGestureHost?
        private let longPress = UILongPressGestureRecognizer()
        private let pan = UIPanGestureRecognizer()
        private weak var scrollView: UIScrollView?
        private var touchDown: CGPoint = .zero
        private var lastScrollRequest: UUID?
        private var lastReveal: UUID?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false          // touches belong to the views above; only the recognizers listen
            longPress.addTarget(self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.3
            longPress.allowableMovement = 10
            longPress.cancelsTouchesInView = false
            longPress.delegate = self
            pan.addTarget(self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            pan.delegate = self
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

        func update(_ configuration: EditGestureHost) {
            self.configuration = configuration
            pan.isEnabled = configuration.panEnabled         // a disabled recognizer never delays scrolling
            if let request = configuration.scrollRequest, request.id != lastScrollRequest {
                lastScrollRequest = request.id
                scroll(by: request.delta)
            }
            if let reveal = configuration.reveal, reveal.id != lastReveal {
                lastReveal = reveal.id
                // The host sits inside the padded content, so its coordinates are not the scroll view's.
                if let scrollView { scrollView.scrollRectToVisible(convert(reveal.rect, to: scrollView).insetBy(dx: 0, dy: -24), animated: true) }
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scrollView {
                scrollView.removeGestureRecognizer(longPress)
                scrollView.removeGestureRecognizer(pan)
            }
            scrollView = nil
            guard window != nil else { return }
            var ancestor = superview
            while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
            if let found = ancestor as? UIScrollView {
                found.addGestureRecognizer(longPress)
                found.addGestureRecognizer(pan)
                scrollView = found
            }
        }

        /// Moves the content so what the user is looking at stays put while the axis changes size.
        private func scroll(by delta: CGFloat) {
            guard let scrollView else { return }
            UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
                scrollView.contentOffset.y += delta
            }
        }

        // MARK: Recognizers

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: self)
            switch recognizer.state {
            case .began: configuration?.longPress(.began, point)
            case .changed: configuration?.longPress(.moved, point)
            case .ended, .cancelled, .failed: configuration?.longPress(.ended, point)
            default: break
            }
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let point = recognizer.location(in: self)
            switch recognizer.state {
            case .began: configuration?.pan(.began, point)
            case .changed: configuration?.pan(.moved, point)
            case .ended, .cancelled, .failed: configuration?.pan(.ended, point)
            default: break
            }
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchDown = touch.location(in: self)
            // The pan takes only touches that begin on a handle. Declining the rest at touch-down (rather than failing after
            // some movement) is what lets the scroll view start immediately.
            guard gestureRecognizer === pan else { return true }
            guard let configuration, configuration.panEnabled else { return false }
            return configuration.panStartsAt(touchDown)
        }

        /// The scroll view's pan waits for ours to decide.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            gestureRecognizer === pan && other === scrollView?.panGestureRecognizer
        }
    }
}
