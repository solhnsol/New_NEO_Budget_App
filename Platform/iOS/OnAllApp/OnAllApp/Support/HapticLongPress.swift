import SwiftUI
import UIKit

/// A long press the way the iPhone's own Haptic Touch feels. Haptic Touch does not measure pressure (no iPhone has had a force sensor since the 11); it is
/// a short hold, and what makes it land is: the tap engine is made ready the moment the finger touches (so the tick comes at once when the hold is
/// recognised, not a beat later), the thing under the finger answers the touch while it is held (`isPressing`), and a finger that drifts a little
/// does not cancel it. The hold is `Theme.Motion.longPressSeconds` (the design's 350 ms), a drift past 10pt hands the touch to scrolling.
@available(iOS 18.0, *)
struct HapticLongPress: UIGestureRecognizerRepresentable {
    var duration: TimeInterval = Theme.Motion.longPressSeconds
    /// The finger is down (true) or has left, moved off or been recognised (false): for the press-in look.
    var isPressing: (Bool) -> Void = { _ in }
    /// The hold was recognised, with where the finger is in the view's own space.
    let perform: (CGPoint) -> Void

    /// When a hold was last recognised: the tap that the same finger's lift can still produce is to be ignored (`wasJustHeld`).
    nonisolated(unsafe) static var lastRecognised = Date.distantPast

    final class Recognizer: UILongPressGestureRecognizer {
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        var touchDown: () -> Void = {}
        var touchUp: () -> Void = {}

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            feedback.prepare()
            touchDown()
            super.touchesBegan(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesEnded(touches, with: event)
            touchUp()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesCancelled(touches, with: event)
            touchUp()
        }
    }

    func makeUIGestureRecognizer(context: Context) -> Recognizer {
        let recognizer = Recognizer()
        recognizer.minimumPressDuration = duration
        recognizer.allowableMovement = 10
        recognizer.touchDown = { isPressing(true) }
        recognizer.touchUp = { isPressing(false) }
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        guard recognizer.state == .began else { return }
        recognizer.feedback.impactOccurred()
        HapticLongPress.lastRecognised = Date()
        isPressing(false)
        perform(context.converter.localLocation)
    }
}

/// Whether a hold was recognised a moment ago: the tap that the same finger's lift can still produce is to be ignored.
enum HapticHold {
    /// The row a hold was last recognised on, so only the lift of that same finger on that same row is ignored (a quick tap on another row is not).
    nonisolated(unsafe) static var heldID: String?
    static func justHeld(_ id: String) -> Bool { heldID == id && Date().timeIntervalSince(lastRecognisedAt) < 0.5 }
    nonisolated(unsafe) static var lastRecognisedAt: Date {
        get { if #available(iOS 18.0, *) { HapticLongPress.lastRecognised } else { .distantPast } }
        set { if #available(iOS 18.0, *) { HapticLongPress.lastRecognised = newValue } }
    }
}

extension View {
    /// Where on the view a Haptic Touch landed (in the view's own space); before iOS 18 an ordinary long press then drag.
    @ViewBuilder
    func hapticLongPress(at perform: @escaping (CGPoint) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            gesture(HapticLongPress { perform($0) })
        } else {
            gesture(
                LongPressGesture(minimumDuration: Theme.Motion.longPressSeconds, maximumDistance: 8)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { value in
                        guard case let .second(true, drag?) = value else { return }
                        perform(drag.location)
                    }
            )
        }
    }

    /// A row (or any view) that answers a Haptic Touch: it dips a little while it is held, ticks when the hold is recognised, then calls `perform`.
    /// `enabled` false drops the hold altogether (selection mode: the row only takes taps).
    func hapticLongPress(id: String, enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        modifier(HapticLongPressRow(id: id, enabled: enabled, perform: perform))
    }
}

private struct HapticLongPressRow: ViewModifier {
    let id: String
    let enabled: Bool
    let perform: () -> Void
    @State private var pressing = false

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if #available(iOS 18.0, *) {
            content
                .scaleEffect(pressing ? 0.97 : 1)
                .animation(.easeOut(duration: 0.18), value: pressing)
                .gesture(HapticLongPress(isPressing: { pressing = $0 }, perform: { _ in HapticHold.heldID = id; perform() }))
        } else {
            content.onLongPressGesture(minimumDuration: Theme.Motion.longPressSeconds, maximumDistance: 8) { HapticHold.heldID = id; perform() }
        }
    }
}
