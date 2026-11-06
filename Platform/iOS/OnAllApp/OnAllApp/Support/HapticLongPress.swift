import SwiftUI
import UIKit

/// A long press the way the iPhone's own Haptic Touch feels. Haptic Touch does not measure pressure (no iPhone has had a force sensor since the 11); it is
/// a short hold, and what makes it land is: the tap engine is made ready the moment the finger touches (so the tick comes at once when the hold is
/// recognised, not a beat later), the thing under the finger answers the touch while it is held (`isPressing`), and a finger that drifts a little
/// does not cancel it. The hold is `Theme.Motion.longPressSeconds` (the design's 350 ms), a drift past 10pt hands the touch to scrolling.
@available(iOS 18.0, *)
struct HapticLongPress: UIGestureRecognizerRepresentable {
    var duration: TimeInterval = Theme.Motion.longPressSeconds
    /// Off (selection mode): the recogniser stays on the view but does not begin. The view's structure never changes, so what is under it keeps animating.
    var isEnabled = true
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
        recognizer.touchDown = {
            isPressing(true)
            // A recogniser that fails (the finger moved off, a scroll began) is not told when the touch ends: the press-in look must not stay.
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25) { isPressing(false) }
        }
        recognizer.touchUp = { isPressing(false) }
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: Recognizer, context: Context) {
        // Only when it changes: setting it during a touch can cancel the hold.
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
    }

    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        guard recognizer.state == .began else { return }
        recognizer.feedback.impactOccurred()
        HapticLongPress.lastRecognised = Date()
        isPressing(false)
        perform(context.converter.localLocation)
    }
}

/// A Haptic-Touch-style hold that then follows the finger: `began` when the hold is recognised (the tick is made then), `moved` as the finger goes on,
/// `ended` when it lets go (`cancelled` when the system took the touch away).
@available(iOS 18.0, *)
struct HapticHoldDrag: UIGestureRecognizerRepresentable {
    var isEnabled = true
    let began: (CGPoint) -> Void
    let moved: (CGPoint) -> Void
    let ended: (CGPoint, _ cancelled: Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> HapticLongPress.Recognizer {
        let recognizer = HapticLongPress.Recognizer()
        recognizer.minimumPressDuration = Theme.Motion.longPressSeconds
        recognizer.allowableMovement = 10
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: HapticLongPress.Recognizer, context: Context) {
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
    }

    func handleUIGestureRecognizerAction(_ recognizer: HapticLongPress.Recognizer, context: Context) {
        let location = context.converter.localLocation
        switch recognizer.state {
        case .began:
            recognizer.feedback.impactOccurred()
            HapticLongPress.lastRecognised = Date()
            began(location)
        case .changed: moved(location)
        case .ended: ended(location, false)
        case .cancelled, .failed: ended(location, true)
        default: break
        }
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
    /// With `pressing` given the view does not dip itself: the caller dips what should (a row's content, not the dot it keeps on the rail).
    func hapticLongPress(id: String, enabled: Bool = true, pressing: Binding<Bool>? = nil, perform: @escaping () -> Void) -> some View {
        modifier(HapticLongPressRow(id: id, enabled: enabled, outerPressing: pressing, perform: perform))
    }
}

private struct HapticLongPressRow: ViewModifier {
    let id: String
    let enabled: Bool
    var outerPressing: Binding<Bool>?
    let perform: () -> Void
    @State private var pressing = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .scaleEffect(outerPressing == nil && pressing ? 0.97 : 1)
                .animation(.easeOut(duration: 0.18), value: pressing)
                .gesture(HapticLongPress(isEnabled: enabled, isPressing: { pressing = $0; outerPressing?.wrappedValue = $0 }, perform: { _ in HapticHold.heldID = id; perform() }))
        } else {
            content.onLongPressGesture(minimumDuration: Theme.Motion.longPressSeconds, maximumDistance: 8) { if enabled { HapticHold.heldID = id; perform() } }
        }
    }
}
