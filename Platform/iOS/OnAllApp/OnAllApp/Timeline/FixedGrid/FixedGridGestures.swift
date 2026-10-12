import CoreGraphics
import NEOBudgetCalendar

/// Who owns a touch on the fixed grid: decided once, where the touch begins, from what is under it and the mode the grid is in. Pure, so it is tested; the
/// scroll view's coordinator asks it from its recognizer delegate (`PinchZoomScrollView`), and the only state machine of a day move stays `DayMoveModel`.
///
/// All the grid's recognizers are UIKit ones on the same container, so UIKit arbitrates them: no SwiftUI tap or long-press gesture sits under them.
///
/// | begins on | browse | editing (an event chosen; future) |
/// |---|---|---|
/// | a handle of the chosen event | — | handle pan (drag), handle tap; nothing else |
/// | an event, line, overflow card | tap: select (at rest), long press, date swipe, scroll, pinch | tap: (future) choose another; scroll, pinch |
/// | empty grid | long press, date swipe, scroll, pinch | tap: (future) end editing; long press (future: create); scroll, pinch |
/// | the hour gutter | date swipe, scroll, pinch | scroll, pinch |
///
/// In editing the days never move (the time partition is frozen for the session) and a drag from a handle is never a scroll or a date swipe. While a pinch
/// is under way, and after it until every finger is up, nothing one-fingered begins; a long press that has begun keeps the finger (no scroll, no swipe) until
/// it lifts; a second finger on a long press makes it a pinch.
enum FixedGridGestures {
    /// The chosen event while editing: where its card is (content coordinates of the grid, the space taps are in) and which ends may move.
    struct EditTarget: Equatable {
        let epoch: Int
        let blockID: BlockID
        let frame: CGRect
        let canResizeStart: Bool
        let canResizeEnd: Bool
    }

    enum Mode: Equatable {
        case browse
        case editing(EditTarget)

        var target: EditTarget? { if case let .editing(target) = self { target } else { nil } }
    }

    /// What is under the point a touch begins at.
    enum Start: Equatable {
        case gutter
        case empty
        case content(DayRenderPlan.Hit)
        case handle(EditHit)
    }

    enum Recognizer: Hashable, CaseIterable {
        case dateSwipe, scroll, pinch, tap, longPress, handlePan
    }

    /// What is under `point`, given what the plan of that day says (`hit`) and the mode (only the chosen event has handles, and only while editing).
    static func start(at point: CGPoint, gutter: CGFloat, mode: Mode, hit: () -> DayRenderPlan.Hit) -> Start {
        if let target = mode.target,
           let handle = EditHit.handle(at: point, frame: target.frame, canResizeStart: target.canResizeStart, canResizeEnd: target.canResizeEnd) {
            return .handle(handle)
        }
        guard point.x >= gutter else { return .gutter }
        let found = hit()
        return found == .nothing ? .empty : .content(found)
    }

    /// Whether a one-touch recognizer takes a touch that begins at `start` (asked at touch-down, so one that does not take it never makes another wait).
    static func receives(_ recognizer: Recognizer, start: Start, mode: Mode) -> Bool {
        switch (mode, start) {
        case (.editing, .handle): return recognizer == .handlePan || recognizer == .tap
        case (_, .handle): return false                                         // no handles outside editing
        case (.browse, .gutter): return [.dateSwipe, .scroll, .pinch].contains(recognizer)
        case (.browse, .empty): return recognizer != .tap && recognizer != .handlePan
        case (.browse, .content): return recognizer != .handlePan
        case (.editing, .gutter): return [.scroll, .pinch].contains(recognizer)
        case (.editing, .empty): return [.scroll, .pinch, .tap, .longPress].contains(recognizer)
        case (.editing, .content): return [.scroll, .pinch, .tap].contains(recognizer)
        }
    }

    /// What a running recognizer keeps from beginning until every finger is up (the recognizers it switches off; switching one off cancels it).
    static func suppressed(while active: Recognizer) -> Set<Recognizer> {
        switch active {
        case .pinch: return [.dateSwipe, .scroll, .tap, .longPress, .handlePan]
        case .longPress: return [.dateSwipe, .scroll, .tap]
        case .handlePan: return [.dateSwipe, .scroll, .pinch, .tap, .longPress]
        case .dateSwipe: return [.scroll, .tap, .longPress, .handlePan]
        case .scroll, .tap: return []
        }
    }

    /// What a tap means. Taps count only with the days at rest (a finger on moving days stops them instead).
    enum TapMeaning: Equatable {
        case none
        case select(DayRenderPlan.Hit)
        /// Future: the 15-minute time bubble for that end.
        case handle(EditHit)
        /// Future: another event becomes the chosen one.
        case chooseOther(DayRenderPlan.Hit)
        /// Future: editing ends.
        case endEditing
    }

    static func tap(start: Start, mode: Mode, daysAtRest: Bool) -> TapMeaning {
        guard daysAtRest else { return .none }
        switch (mode, start) {
        case (.editing, .handle(let hit)): return .handle(hit)
        case (.browse, .content(let hit)): return .select(hit)
        case (.editing, .content(let hit)): return .chooseOther(hit)
        case (.editing, .empty): return .endEditing
        default: return .none
        }
    }

    /// What a long press means. In browse it only draws attention to the line that says editing is not here yet; what it will mean is named.
    enum LongPressMeaning: Equatable {
        case none
        /// `future`: what it will mean once editing is here (`nil`: nothing planned for it, a transaction).
        case notice(future: Future?)
        /// Future, editing: a new event dragged out on empty grid.
        case createDraft

        enum Future: Equatable { case createDraft, edit(BlockID) }
    }

    static func longPress(start: Start, mode: Mode) -> LongPressMeaning {
        switch (mode, start) {
        case (.browse, .empty): return .notice(future: .createDraft)
        case (.browse, .content(.event(let id))): return .notice(future: .edit(id))
        case (.browse, .content): return .notice(future: nil)
        case (.editing, .empty): return .createDraft
        default: return .none
        }
    }
}
