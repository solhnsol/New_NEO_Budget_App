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
    static func totals(of transactions: [AllocationTransaction]) -> [AmountSum] {
        var sums: [AmountSum] = []
        for transaction in transactions {
            if let index = sums.firstIndex(where: { $0.kind == transaction.kind && $0.currency == transaction.currency }) {
                sums[index].count += 1
                if let value = transaction.minorUnits { sums[index].minorUnits += value } else { sums[index].unknownCount += 1 }
            } else {
                sums.append(AmountSum(
                    kind: transaction.kind, currency: transaction.currency, minorUnits: transaction.minorUnits ?? 0,
                    count: 1, unknownCount: transaction.minorUnits == nil ? 1 : 0
                ))
            }
        }
        return sums.sorted { ($0.kind, $0.currency) < ($1.kind, $1.currency) }
    }
}

struct AllocationTransaction: Equatable, Hashable, Sendable {
    let id: String
    /// Minutes from the start of its day. Only used to place a transaction that is not inside an event.
    let minute: Int
    let kind: AmountKind
    let currency: String
    /// The magnitude, or `nil` when it has no settled amount.
    let minorUnits: Int64?
    /// Some of it is linked to an event and some is not; the unlinked part is what is drawn on its own.
    var isPartlyLinked = false
}

struct AllocationEvent: Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let startMinute: Int
    let endMinute: Int
    /// Transactions linked to this event. They are drawn inside it, wherever in time they happened.
    let linked: [AllocationTransaction]
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
    enum Kind: Int, Hashable, Sendable { case event, transactionGroup }
    let role: DayRole
    let kind: Kind
    let id: String
}

enum DisplayMode: Equatable, Sendable {
    case browse
    /// An event is being edited: the layout that was on screen is kept exactly as it is.
    case editing(frozen: AdaptiveLayout)
}

/// Every size the engine works with, in points at standard text size. They scale together with `AllocationInput.textScale`.
struct AllocationParameters: Equatable, Sendable {
    var titleRow: CGFloat = 22
    var linkedRow: CGFloat = 15
    var transactionRow: CGFloat = 24
    var clusterCard: CGFloat = 28
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
    /// The minutes a single transaction row is drawn around.
    var transactionWindowMinutes = 20
    /// Transactions this close in time form a chain, which is clustered when it has `minimumClusterSize` or more.
    var clusterGapMinutes = 20
    var minimumClusterSize = 3
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
    var parameters = AllocationParameters()
}

/// How much of an event is shown. Each step needs more height.
enum EventLevel: Int, Comparable, Sendable {
    /// The title alone (the summary form).
    case title
    /// The title and the first linked transactions, the rest as "+N".
    case preview
    /// The title and every linked transaction.
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
    /// Three or more overlapping: boundaries cannot all be shown, so each shows as a title in a summary.
    let summarisesTitles: Bool
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
    let shownLinkedRows: Int
    let hiddenLinkedCount: Int
    /// Linked transactions summed per kind and currency.
    let linkedTotals: [AmountSum]
    let overlap: EventOverlap
}

struct TransactionGroup: Equatable, Sendable {
    enum Presentation: Int, Equatable, Sendable {
        /// One small card for the whole group.
        case cluster
        /// One line per transaction.
        case rows
    }
    let key: ItemKey
    let role: DayRole
    /// Every transaction in time order: the way to reach each one is kept whichever way it is drawn.
    let transactionIDs: [String]
    let startMinute: Int
    let endMinute: Int
    let presentation: Presentation
    /// Per kind and currency. Never one number for different kinds.
    let totals: [AmountSum]
    let requiredHeight: CGFloat
}

struct AdaptiveLayout: Equatable, Sendable {
    /// One minute-to-height mapping for both days.
    let axis: TimelineAxis
    let events: [EventPlacement]
    let groups: [TransactionGroup]
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    /// True only when even the smallest representation does not fit.
    let requiresScroll: Bool
    var scrollableHeight: CGFloat { max(0, contentHeight - viewportHeight) }
    /// The chosen detail per item, to be passed back as `AllocationInput.previous`.
    let state: [ItemKey: Int]
}
