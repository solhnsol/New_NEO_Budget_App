import SwiftUI
import UIKit

/// A long-press-then-drag recognizer attached to the enclosing `UIScrollView`, so UIKit arbitrates it against the
/// scroll pan: moving before the press time scrolls as usual, holding still picks something up. SwiftUI's
/// `LongPressGesture.sequenced(before: DragGesture)` cannot promise that and swallows scrolling.
///
/// Place it as a background of the scrolled content. Locations are in that content's coordinate space.
struct LongPressDragHost: UIViewRepresentable {
    var minimumDuration: TimeInterval = 0.3
    var onBegan: (CGPoint) -> Void
    var onMoved: (CGPoint) -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.configure(minimumDuration: minimumDuration, onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.configure(minimumDuration: minimumDuration, onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
    }

    final class HostView: UIView {
        private var onBegan: (CGPoint) -> Void = { _ in }
        private var onMoved: (CGPoint) -> Void = { _ in }
        private var onEnded: () -> Void = {}
        private let recognizer = UILongPressGestureRecognizer()
        private weak var attachedTo: UIScrollView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false         // touches belong to the views above; only the recognizer listens
            recognizer.addTarget(self, action: #selector(handle(_:)))
            recognizer.allowableMovement = 10
            recognizer.cancelsTouchesInView = false
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

        func configure(minimumDuration: TimeInterval, onBegan: @escaping (CGPoint) -> Void, onMoved: @escaping (CGPoint) -> Void, onEnded: @escaping () -> Void) {
            recognizer.minimumPressDuration = minimumDuration
            self.onBegan = onBegan
            self.onMoved = onMoved
            self.onEnded = onEnded
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachedTo?.removeGestureRecognizer(recognizer)
            attachedTo = nil
            guard window != nil else { return }
            var ancestor = superview
            while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
            if let scrollView = ancestor as? UIScrollView {
                scrollView.addGestureRecognizer(recognizer)
                attachedTo = scrollView
            }
        }

        @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: self)
            switch recognizer.state {
            case .began: onBegan(point)
            case .changed: onMoved(point)
            case .ended, .cancelled, .failed: onEnded()
            default: break
            }
        }
    }
}
