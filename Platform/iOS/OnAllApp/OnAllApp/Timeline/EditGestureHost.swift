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
/// Lets the grid read where the enclosing scroll view is and how far it can go, which the scroll view itself is the only one to know.
@MainActor
final class ScrollProbe {
    fileprivate(set) weak var scrollView: UIScrollView?

    /// The part of the grid that is on screen now, in grid coordinates (the grid is inset by `gridInset` inside the scroll content).
    func visibleGridRange(gridInset: CGFloat) -> ClosedRange<CGFloat>? {
        guard let scrollView else { return nil }
        let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top - gridInset
        let height = scrollView.bounds.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom
        return top...(top + height)
    }

    /// How far the content can still move by, for a layout whose content is `contentHeight` tall: down to the top edge and up to
    /// the bottom edge. A shift outside this is refused by the scroll view, and would show as a jump when the change ends.
    func shiftRange(contentHeight: CGFloat) -> ClosedRange<CGFloat>? {
        guard let scrollView else { return nil }
        let top = -scrollView.adjustedContentInset.top
        let bottom = max(top, contentHeight + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
        let offset = scrollView.contentOffset.y
        return (top - offset)...(bottom - offset)
    }
}

struct EditGestureHost: UIViewRepresentable {
    enum Phase { case began, moved, ended }

    let probe: ScrollProbe
    var panEnabled: Bool
    /// The scroll view moving by this much at once, when a change of shape ends. The content shift that held the anchor still
    /// until then is dropped in the same update, so what is on screen does not change.
    var scrollCommit: TimelineEditor.ScrollCommit?
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
        private var lastScrollCommit: UUID?
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
            // A commit that was already there when this view came into being was applied (or not needed) before it existed.
            if self.configuration == nil { lastScrollCommit = configuration.scrollCommit?.id }
            self.configuration = configuration
            pan.isEnabled = configuration.panEnabled         // a disabled recognizer never delays scrolling
            if let commit = configuration.scrollCommit, commit.id != lastScrollCommit {
                lastScrollCommit = commit.id
                scrollView?.contentOffset.y += commit.delta
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
                configuration?.probe.scrollView = found
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
            case .began:
                // A pan is recognised only after the finger has already moved a little (more, the faster it goes), so its
                // location is no longer where the touch landed. The drag starts from the touch-down point, which is what was
                // hit-tested, and then catches up to the finger.
                configuration?.pan(.began, touchDown)
                configuration?.pan(.moved, point)
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
