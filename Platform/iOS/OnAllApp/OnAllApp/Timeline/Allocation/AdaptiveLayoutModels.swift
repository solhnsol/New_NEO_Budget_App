import CoreGraphics
import NEOBudgetCalendar

// Adaptive Space Allocation: the pure data the layout engine reads and returns. Nothing here knows about SwiftUI, scrolling or the
// ledger's rules; amounts are carried and summed per kind and currency, never converted or mixed.

/// What an amount is. Sums are kept per kind, so income, spending, refunds and transfers are never added into one number.
enum AmountKind: Int, Hashable, Comparable, Sendable {
    case spend, income, refund, transfer
    static func < (lhs: AmountKind, rhs: AmountKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A total of one kind in one currency. `unknownCount` transactions have no settled amount and are counted, never guessed at.
struct AmountSum: Equatable, Hashable, Sendable {
    let kind: AmountKind
    let currency: String
    var minorUnits: Int64
    var count: Int
    var unknownCount: Int

    /// Totals per (kind, currency), in a fixed order. The only place amounts are added, and never across kinds or currencies.
    /// `allocated` sums the part linked to an event where one is known (what an event shows for itself); otherwise the amount of the
    /// transaction (what the ledger counts).
    static func totals(of transactions: [AllocationTransaction], allocated: Bool = false) -> [AmountSum] {
        var sums: [AmountSum] = []
        for transaction in transactions {
            let amount = allocated ? (transaction.allocatedMinorUnits ?? transaction.minorUnits) : transaction.minorUnits
            if let index = sums.firstIndex(where: { $0.kind == transaction.kind && $0.currency == transaction.currency }) {
                sums[index].count += 1
                if let value = amount { sums[index].minorUnits += value } else { sums[index].unknownCount += 1 }
            } else {
                sums.append(AmountSum(kind: transaction.kind, currency: transaction.currency, minorUnits: amount ?? 0, count: 1, unknownCount: amount == nil ? 1 : 0))
            }
        }
        return sums.sorted { ($0.kind, $0.currency) < ($1.kind, $1.currency) }
    }
}

struct AllocationTransaction: Equatable, Hashable, Sendable {
    let id: String
    /// Minutes from the start of its day: when it really happened. Never changed to fit an event.
    let minute: Int
    let kind: AmountKind
    let currency: String
    /// The amount of the transaction itself (what the ledger counts), or `nil` when it has no settled amount.
    let minorUnits: Int64?
    /// The part of it linked to an event, when that is not all of it. Only used to show what an event holds.
    var allocatedMinorUnits: Int64?
    /// Some of it is linked to an event and some is not; the unlinked part is what is drawn on its own.
    var isPartlyLinked = false
    /// How many days after the event's day it happened (0: the same day, which is the only case that gets a line on that day).
    var dayOffset = 0
}

struct AllocationEvent: Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let startMinute: Int
    let endMinute: Int
    /// Transactions linked to this event, wherever in time they happened. Whether one is drawn inside the event or on its own line
    /// depends only on whether it happened within the event's time; the link itself is always kept.
    let linked: [AllocationTransaction]

    var effectiveEnd: Int { max(endMinute, startMinute + 1) }
    func contains(_ transaction: AllocationTransaction) -> Bool {
        transaction.dayOffset == 0 && transaction.minute >= startMinute && transaction.minute < effectiveEnd
    }
    var insideRange: [AllocationTransaction] { linked.filter(contains) }
    var outsideRange: [AllocationTransaction] { linked.filter { !contains($0) } }
}

struct AllocationDay: Equatable, Sendable {
    let day: LocalDate
    let totalMinutes: Int
    let events: [AllocationEvent]
    /// Transactions linked to no event (and the unlinked part of partly linked ones). Being inside an event's time does not link them.
    let transactions: [AllocationTransaction]
}

/// Which of the two days an item is on. A display priority, not a judgement about the events or their importance.
enum DayRole: Int, Hashable, Comparable, Sendable {
    case main, secondary
    static func < (lhs: DayRole, rhs: DayRole) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ItemKey: Hashable, Sendable {
    enum Kind: Int, Hashable, Sendable { case event, transactionLink }
    let role: DayRole
    let kind: Kind
    let id: String
}

// MARK: Focus

/// What is brought into focus. Events and overflows share this one model.
enum FocusTarget: Equatable, Hashable, Sendable {
    case event(eventID: String)
    case overflow(overflowID: String, transactionIDs: [String])
}

/// What is needed to leave focus and be exactly where the user was.
struct FocusRestore: Equatable, Sendable {
    let mainDay: LocalDate
    let secondaryDay: LocalDate?
    /// The minute at the reference point of the screen (its centre) before focus began.
    let anchorMinute: Int
    /// The detail levels the two-day layout had, to be passed back as `AllocationInput.previous`.
    let layoutState: [ItemKey: Int]
}

struct FocusRequest: Equatable, Sendable {
    let target: FocusTarget
    let restore: FocusRestore
}

/// How the other day is shown while one thing is in focus.
enum SecondaryPresentation: Equatable, Sendable {
    case none
    /// Reduced to its date header.
    case headerOnly(height: CGFloat)
}

struct FocusDetailRow: Equatable, Sendable {
    enum Relation: Equatable, Sendable {
        /// A transaction linked to the event that happened within its time.
        case insideEventRange
        /// Linked to the event but it happened outside the event's time: shown with its own time and the link kept.
        case outsideEventRange
        /// A transaction an overflow stands for.
        case overflowMember
    }
    let transactionID: String
    let minute: Int
    let dayOffset: Int
    let kind: AmountKind
    let currency: String
    let minorUnits: Int64?
    let relation: Relation
}

struct FocusLayout: Equatable, Sendable {
    let target: FocusTarget
    /// The selected item's day is the main day while it is in focus.
    let mainDay: LocalDate
    let secondaryDay: LocalDate?
    let secondary: SecondaryPresentation
    let rows: [FocusDetailRow]
    /// The height the detail needs, the height it has, and what is left to scroll *inside* it. The timeline is not stretched for it.
    let detailHeightNeeded: CGFloat
    let detailHeightAvailable: CGFloat
    var detailNeedsInternalScroll: Bool { detailHeightNeeded > detailHeightAvailable + 0.5 }
    var detailScrollableHeight: CGFloat { max(0, detailHeightNeeded - detailHeightAvailable) }
    let restore: FocusRestore
}

// MARK: Parameters and input

enum DisplayMode: Equatable, Sendable {
    case browse
    /// An event is being edited: the layout that was on screen is kept exactly as it is.
    case editing(frozen: AdaptiveLayout)
}

/// Every size the engine works with, in points at standard text size. They scale together with `AllocationInput.textScale`.
struct AllocationParameters: Equatable, Sendable {
    var titleRow: CGFloat = 22
    var linkedRow: CGFloat = 15
    /// A transaction's own line, and the clear space kept between two lines for them to stay readable.
    var transactionRow: CGFloat = 24
    var lineGap: CGFloat = 2
    /// The row an overflow is written on (it is text, not a card).
    var overflowCard: CGFloat = 20
    /// The height of the header an event may have above its start.
    var headerRow: CGFloat = 16
    var detailRow: CGFloat = 20
    var secondaryHeader: CGFloat = 28
    /// The part of the screen the timeline keeps while something is in focus.
    var focusContext: CGFloat = 80
    var minimumTouchHeight: CGFloat = 44
    /// How much of the day column an independent transaction line takes (right-aligned), and the least it can be.
    var lineWidthShare: CGFloat = 0.62
    var minimumLineWidth: CGFloat = 112
    var minimumTitleWidth: CGFloat = 40
    var indentStep: CGFloat = 16
    /// Linked transactions an event shows before it summarises the rest in one "+N" row.
    var previewLinkedRows = 2
    var browseScale: CGFloat = 0.6
    var foldedScale: CGFloat = 0.06
    var minimumFoldedHeight: CGFloat = 18
    var minimumFoldMinutes = 60
    /// Minutes kept at browse size around the main day's items.
    var padding = 30
    var emptyDayFocus: ClosedRange<Int> = (9 * 60)...(18 * 60)
    /// Events longer than this keep their middle compressed and their two edges readable.
    var longEventMinutes = 120
    /// The minutes a single transaction line is drawn around.
    var transactionWindowMinutes = 20
    /// A change of detail needs this much spare height to go up, so a small change of data does not flip many items.
    var hysteresisMargin: CGFloat = 16
}

struct AllocationInput: Sendable {
    var main: AllocationDay
    var secondary: AllocationDay?
    /// The height the layout may use before it needs to scroll. The scroll position is deliberately not an input: scrolling alone
    /// never changes a layout.
    var viewportHeight: CGFloat
    var contentWidth: CGFloat
    /// Dynamic Type: 1 is the standard size.
    var textScale: CGFloat = 1
    var mode: DisplayMode = .browse
    /// The detail levels of the layout this one replaces, so small changes of data keep what was already chosen.
    var previous: [ItemKey: Int]?
    var focus: FocusRequest?
    /// Real widths of event titles at the current font and Dynamic Type, by title text, measured by the caller (once per change of
    /// content or text size, never per frame). A title missing here is estimated from its characters.
    var titleWidths: [String: CGFloat] = [:]
    var parameters = AllocationParameters()
}

// MARK: Output

/// How much of an event is shown. Each step needs more height.
enum EventLevel: Int, Comparable, Sendable {
    /// The title alone (the summary form).
    case title
    /// The title and the first inside transactions, the rest as "+N".
    case preview
    /// The title and every inside transaction.
    case full
    static func < (lhs: EventLevel, rhs: EventLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How an event relates to the others it overlaps. Never a column of its own: a card keeps the full width and is indented by at most one step.
struct EventOverlap: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case none
        /// Wholly inside another event: an inner card, indented once on the left and pulled in on the right.
        case contained(in: String)
        /// Starts or ends inside another event: indented once, keeping its own start and end.
        case partial(with: String)
    }
    let role: Role
    /// 0 or 1. Never more.
    let indent: Int
    let pullsInOnRight: Bool
    /// The events that overlap one another (directly or through a chain) share a group.
    let groupSize: Int
    /// Which group of the day (0, 1, ...), so the renderer can find the events that summarise their titles together.
    var groupIndex: Int = 0
    /// Three or more overlapping: boundaries cannot all be shown, so each shows as a title in a summary.
    let summarisesTitles: Bool
}

/// A header attached above an event's start boundary, outside its time range. It shares the event's id and changes no time.
struct EventHeader: Equatable, Sendable {
    let eventID: String
    let height: CGFloat
    /// The event's own start, which the header is attached to. The header is *above* it and is not part of the event's time.
    let attachedToMinute: Int
}

/// What was done about an event's title and a transaction line wanting the same place.
enum TitleResolution: Equatable, Sendable {
    case none
    /// The title moves to a header above the event.
    case externalHeader
    /// The title is shortened to this width so both fit.
    case abbreviated(maxWidth: CGFloat)
    /// The stretch above the first line is enlarged until the title has its own height (the axis changes; no time does).
    case expandedRange
    /// Nothing else fitted: the title is cut to this width and may still touch the line.
    case cramped(width: CGFloat)
}

struct EventPlacement: Equatable, Sendable {
    let key: ItemKey
    let id: String
    let startMinute: Int
    let endMinute: Int
    let level: EventLevel
    /// The heights of the three levels, in points.
    let minimumHeight: CGFloat
    let preferredHeight: CGFloat
    let expandedHeight: CGFloat
    /// The height this level needs.
    let requiredHeight: CGFloat
    /// Transactions drawn inside the event (linked, and within its time).
    let shownInsideRows: Int
    let hiddenInsideCount: Int
    /// Every transaction linked to the event, inside its time or not, summed per kind and currency.
    let linkedTotals: [AmountSum]
    /// How many linked transactions happened outside the event's time and are therefore lines of their own.
    let outsideLinkedCount: Int
    let overlap: EventOverlap
    let titleResolution: TitleResolution
    let header: EventHeader?
}

/// How a transaction line relates to an event, for drawing the link (colour, label, dashes) without changing the line itself.
struct LinkMetadata: Equatable, Sendable {
    let eventID: String
    /// Always true for a line: a linked transaction inside its event's time is drawn in the event instead.
    let happenedOutsideEventRange: Bool
}

/// One transaction on its own line, at the time it really happened.
struct TransactionLine: Equatable, Sendable {
    let key: ItemKey
    let role: DayRole
    let transactionID: String
    let minute: Int
    let kind: AmountKind
    let currency: String
    let minorUnits: Int64?
    /// `nil` for a transaction linked to nothing.
    let link: LinkMetadata?
    let isPartlyLinked: Bool
}

struct OverflowMember: Equatable, Sendable {
    let transactionID: String
    let minute: Int
    let kind: AmountKind
    let currency: String
    let minorUnits: Int64?
    let link: LinkMetadata?
}

struct KindCount: Equatable, Sendable {
    let kind: AmountKind
    let count: Int
}

/// Several transaction lines that cannot all be drawn without touching, drawn as one small card. A statement about lack of room,
/// not a group of related transactions: nothing says they belong together.
struct TransactionOverflow: Equatable, Sendable {
    let id: String
    let role: DayRole
    /// Every transaction it stands for, in time order, each with its own time, kind and amount: reachable, none dropped.
    let members: [OverflowMember]
    var transactionIDs: [String] { members.map(\.transactionID) }
    let startMinute: Int
    let endMinute: Int
    /// The default summary: how many, and of what kind.
    let countsByKind: [KindCount]
    /// Sums per kind and currency. Offered as the summary only when `showsAmountTotal` (one kind in one currency).
    let amountTotals: [AmountSum]
    let showsAmountTotal: Bool
    let requiredHeight: CGFloat
}

/// What can be touched, and how big the touchable area is: never smaller than a finger needs, even where the drawn item is.
struct TouchTarget: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case event, transaction, overflow }
    let id: String
    let kind: Kind
    let role: DayRole
    let visualMinY: CGFloat
    let visualMaxY: CGFloat
    let touchMinY: CGFloat
    let touchMaxY: CGFloat
}

/// Targets whose touch areas run into each other. Returned as the candidates to choose between, never silently resolved.
struct TouchConflict: Equatable, Sendable {
    let candidates: [String]
    let minY: CGFloat
    let maxY: CGFloat
}

struct AdaptiveLayout: Equatable, Sendable {
    /// One minute-to-height mapping for both days.
    let axis: TimelineAxis
    let events: [EventPlacement]
    /// Transactions drawn on their own line.
    let lines: [TransactionLine]
    /// Transactions that could not be drawn on their own line for lack of room.
    let overflows: [TransactionOverflow]
    let touchTargets: [TouchTarget]
    let touchConflicts: [TouchConflict]
    /// What the ledger counts for the days shown: every transaction once, however many places refer to it.
    let ledgerTotals: [AmountSum]
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    /// True only when even the smallest form does not fit.
    let requiresScroll: Bool
    var scrollableHeight: CGFloat { max(0, contentHeight - viewportHeight) }
    /// The chosen detail per item, to be passed back as `AllocationInput.previous`.
    let state: [ItemKey: Int]
    let focus: FocusLayout?

    /// Every transaction id that can be reached from the layout: inside an event, on a line, or in an overflow.
    var reachableTransactionIDs: Set<String> {
        Set(lines.map(\.transactionID)).union(overflows.flatMap(\.transactionIDs))
    }
}
