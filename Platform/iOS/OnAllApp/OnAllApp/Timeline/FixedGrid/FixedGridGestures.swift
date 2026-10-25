import CoreGraphics
import NEOBudgetCalendar

/// Who owns a touch on the fixed grid: decided once, where the touch begins, from what is under it and the mode the grid is in. Pure, so it is tested; the
/// scroll view's coordinator asks it from its recognizer delegate (`PinchZoomScrollView`), and the only state machine of a day move stays `DayMoveModel`.
///
/// All the grid's recognizers are UIKit ones on the same container, so UIKit arbitrates them: no SwiftUI tap or long-press gesture sits under them.
///
/// | begins on | browse | editing (an event chosen) |
/// |---|---|---|
/// | a handle of the chosen event | — | handle pan (drag), handle tap; nothing else |
/// | the chosen event's title | — | tap: rename; scroll, pinch |
/// | an event, line, overflow card | tap: select (details), long press (an event: opens a session and lifts it at once; a line: picks up its transaction), date swipe, scroll, pinch | tap: choose another; scroll, pinch |
/// | the chosen event's body | — | tap: lets a handle go; long press: lifts the event; scroll, pinch |
/// | anywhere, an event in the hand (`lifting`) | — | the other hand: scroll, date swipe |
/// | empty grid | long press (create: a new event follows the finger), date swipe, scroll, pinch | tap: end editing; scroll, pinch |
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
        /// An event is in the hand (long pressed, and carried by the finger until it lifts): the other hand may scroll and move the days.
        case lifting

        var target: EditTarget? { if case let .editing(target) = self { target } else { nil } }
    }

    /// What is under the point a touch begins at.
    enum Start: Equatable {
        case gutter
        case empty
        case content(DayRenderPlan.Hit)
        case handle(EditHit)
        /// The body of the chosen event while editing (where its card is drawn now, which may be where the plan has nothing: it was moved).
        case chosen
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
        if let target = mode.target, !target.frame.isNull, target.frame.contains(point) { return .chosen }
        let found = hit()
        return found == .nothing ? .empty : .content(found)
    }

    /// Whether a one-touch recognizer takes a touch that begins at `start` (asked at touch-down, so one that does not take it never makes another wait).
    static func receives(_ recognizer: Recognizer, start: Start, mode: Mode) -> Bool {
        switch (mode, start) {
        case (.lifting, _): return recognizer == .scroll || recognizer == .dateSwipe               // the other hand
        case (.editing, .handle): return recognizer == .handlePan || recognizer == .tap
        case (.editing, .chosen): return [.scroll, .pinch, .tap, .longPress].contains(recognizer)
        case (_, .handle): return false                                         // no handles outside editing
        case (.browse, .gutter): return [.dateSwipe, .scroll, .pinch].contains(recognizer)
        case (.browse, .empty): return recognizer != .tap && recognizer != .handlePan
        case (.browse, .content): return recognizer != .handlePan
        case (.editing, .gutter): return [.scroll, .pinch].contains(recognizer)
        case (.editing, .empty): return [.scroll, .pinch, .tap].contains(recognizer)
        case (.editing, .content): return [.scroll, .pinch, .tap].contains(recognizer)
        case (.browse, .chosen): return false
        }
    }

    /// What a running recognizer keeps from beginning until every finger is up (the recognizers it switches off; switching one off cancels it).
    static func suppressed(while active: Recognizer, lifting: Bool = false) -> Set<Recognizer> {
        switch active {
        case .pinch: return [.dateSwipe, .scroll, .tap, .longPress, .handlePan]
        case .longPress: return lifting ? [.tap, .pinch] : [.dateSwipe, .scroll, .tap]
        case .handlePan: return [.dateSwipe, .scroll, .pinch, .tap, .longPress]
        case .dateSwipe: return [.scroll, .tap, .longPress, .handlePan]
        case .scroll, .tap: return []
        }
    }

    /// What a tap means. Taps count only with the days at rest (a finger on moving days stops them instead).
    enum TapMeaning: Equatable {
        case none
        /// Browse: what was touched; its details open.
        case select(DayRenderPlan.Hit)
        /// The time bubble for that end.
        case handle(EditHit)
        /// The chosen event's title: rename it (the second step after the tap that chose it).
        case title
        /// The chosen event's body: a chosen handle is let go (nothing else).
        case chosenBody
        /// Another event becomes the chosen one (the chosen one's body lets a handle go).
        case chooseOther(DayRenderPlan.Hit)
        case endEditing
    }

    /// The part of a chosen card a tap renames at: its title line across the card (the whole of a card too short for more). Handles still win where they are.
    static func titleBand(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(frame.height, titleBandHeight))
    }

    static let titleBandHeight: CGFloat = 30

    /// `point`: where the tap is, for the chosen card's title (the card is where the draft has it, so the plan's hit there may be another thing or none).
    static func tap(start: Start, mode: Mode, daysAtRest: Bool, point: CGPoint = CGPoint(x: -1, y: -1)) -> TapMeaning {
        guard daysAtRest else { return .none }
        if let target = mode.target, !target.frame.isNull, start != .gutter, titleBand(of: target.frame).contains(point) {
            if case .handle = start {} else { return .title }
        }
        switch (mode, start) {
        case (.editing, .handle(let hit)): return .handle(hit)
        case (.editing, .chosen): return .chosenBody
        case (.browse, .content(let hit)): return .select(hit)
        case (.editing, .content(let hit)): return .chooseOther(hit)
        case (.editing, .empty): return .endEditing
        default: return .none
        }
    }

    /// What a long press means. On empty grid in browse it picks up a new event (`FixedGridCreatePlacement`: the card follows the finger until it lifts, then
    /// an edit session opens on it to name it, choose its calendar and change its length); on an event it opens the event's details (to become a zoom onto
    /// it); on anything else it only draws attention to the line that says what the grid does.
    enum LongPressMeaning: Equatable {
        case none
        case notice
        /// A new event picked up on empty grid.
        case createDraft
        /// A transaction picked up from its line, to be put down on an event (`FixedGridTransactionCarry`). The line's id is the transaction's.
        case pickUpTransaction(String)
        /// An event long pressed in browse: an edit session opens on it and the event is lifted at once (an event that cannot be edited here opens its details).
        case edit(BlockID)
        /// The chosen event long pressed while editing: lifted, to be put down at another time or on another day.
        case liftChosen
    }

    static func longPress(start: Start, mode: Mode) -> LongPressMeaning {
        switch (mode, start) {
        case (.browse, .empty): return .createDraft
        case (.browse, .content(.event(let id))): return .edit(id)
        case (.editing, .chosen): return .liftChosen
        case (.browse, .content(.line(let id))): return .pickUpTransaction(id)
        case (.browse, .content(.choose(let candidates))):
            // Where touch areas meet (a line beside a card, two lines close together) a tap asks which is meant; a long press picks up the one
            // transaction line among them, since nothing else there can be carried.
            let lines = candidates.compactMap { candidate -> String? in if case let .line(id) = candidate { id } else { nil } }
            return lines.count == 1 ? .pickUpTransaction(lines[0]) : .notice
        case (.browse, .content): return .notice
        default: return .none
        }
    }
}
