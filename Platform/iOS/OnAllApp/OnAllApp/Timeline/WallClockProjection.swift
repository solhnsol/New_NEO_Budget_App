import CoreGraphics
import NEOBudgetCalendar

/// The adapter between a day's **elapsed minutes** (what `DayTimeline`, every event block, the transactions' positions and the layout engine's input use) and
/// the **wall-clock minutes** of the axis the fixed grid is drawn on (0:00 ... 24:00 on every day). The rules are `DayWallClock`'s; this type applies them to what a
/// day holds and to the axis.
///
/// ### The contract
/// 1. **Nothing here changes a time.** Elapsed minutes keep their meaning; `EventBlock`, `TransactionMarker`, `AllocationItem` and the EventKit instants are read, never
///    rewritten. What this produces is positions, not instants.
/// 2. **Forward is exact, backward is for display only.** Going from a time to a position (`wallRange`, `wallMinute`, `projected`, `ElapsedMinuteAxisMapping.y`) is
///    always defined. Going from a position back to a time (`displayElapsed`, `ElapsedMinuteAxisMapping.minute(atY:)`) names the **first** occurrence of a repeated wall
///    minute and the first real minute after a skipped one. That loses which occurrence was meant, so **it must never be the source of a saved time**: moving,
///    resizing and creating refuse an axis whose `preservesInstantIdentity` is `false` (`TimelineEditPlanner`), and the inverse here returns a `DisplayOnlyMinute`, a type
///    that is not an instant and that nothing in the save path accepts.
/// 3. **One minute domain per layout.** `DayRenderPlan` and the engine's `AllocationDay` use whatever domain they are given. `ElapsedMinuteAxisMapping` keeps the plan in
///    elapsed minutes (so blocks, markers and an engine layout made from elapsed minutes agree) and converts at the last step, the y. For a day the engine laid out on the
///    wall-clock axis, use `projected(_:)` for its input and an unwrapped mapping for the plan; do not mix the two on one day. On a day with a daylight-saving transition
///    the engine cannot lay out an elapsed-minute day on a wall-clock axis (the axis would need a jump), so such a day is drawn **without an engine layout**
///    (`DayRenderPlan(layout: nil)`: every transaction a line, presentation by height), which `DayRenderPlan` supports.
struct WallClockProjection: Equatable {
    let clock: DayWallClock

    init(clock: DayWallClock) { self.clock = clock }
    init(day: LocalDate, zone: DisplayTimeZone) { clock = DayWallClock(day: day, zone: zone) }

    /// An ordinary day: elapsed and wall minutes are the same, and the adapter is the identity.
    var isIdentity: Bool { clock.kind == .regular }

    // MARK: Forward (exact)

    func wallMinute(ofElapsed elapsed: Int) -> Int { clock.wallMinute(forElapsed: elapsed) }

    /// Where an event's real span is on the wall-clock axis (`DayWallClock.wallRange`, rule 3).
    func wallRange(of block: EventBlock) -> (top: Int, bottom: Int) {
        clock.wallRange(startElapsed: block.startMinute, endElapsed: block.endMinute)
    }

    func wallMinute(of marker: TransactionMarkerItem) -> Int { clock.wallMinute(forElapsed: marker.positionMinute) }

    /// The day as the layout engine takes it, with every minute a wall-clock minute (ids, titles, amounts and links untouched). Transactions of another day (a linked one
    /// that happened the day before or after) have no minute on this day's clock and keep theirs.
    func projected(_ day: AllocationDay) -> AllocationDay {
        guard !isIdentity else { return day }
        func map(_ transaction: AllocationTransaction) -> AllocationTransaction {
            guard transaction.dayOffset == 0 else { return transaction }
            var copy = AllocationTransaction(id: transaction.id, minute: clock.wallMinute(forElapsed: transaction.minute), kind: transaction.kind, currency: transaction.currency, minorUnits: transaction.minorUnits)
            copy.allocatedMinorUnits = transaction.allocatedMinorUnits
            copy.isPartlyLinked = transaction.isPartlyLinked
            copy.dayOffset = transaction.dayOffset
            return copy
        }
        let events = day.events.map { event -> AllocationEvent in
            let range = clock.wallRange(startElapsed: event.startMinute, endElapsed: event.endMinute)
            return AllocationEvent(id: event.id, title: event.title, startMinute: range.top, endMinute: range.bottom, linked: event.linked.map(map))
        }
        return AllocationDay(day: day.day, totalMinutes: DayWallClock.wallMinutesPerDay, events: events, transactions: day.transactions.map(map))
    }

    // MARK: Backward (display only)

    /// A minute of the elapsed domain found from a wall-clock minute, for **display and hit-testing only**. It is not an instant and cannot be given to anything that saves.
    struct DisplayOnlyMinute: Equatable {
        let minute: Int
        /// False when the wall minute is in the skipped hour (it stands for the next real minute) or in the repeated hour (it stands for the first of two).
        let isUnambiguous: Bool
    }

    func displayElapsed(forWall wall: Int) -> DisplayOnlyMinute {
        let clamped = min(max(wall, 0), DayWallClock.wallMinutesPerDay)
        let ambiguous = (clock.skippedWall?.contains(clamped) ?? false) || (clock.repeatedWall?.contains(clamped) ?? false)
        return DisplayOnlyMinute(minute: clock.elapsedMinute(forWall: clamped), isUnambiguous: !ambiguous)
    }
}

/// A wall-clock axis (the fixed grid) seen in a day's elapsed minutes. `y(minute:)` of an elapsed minute is the axis' y of its wall-clock minute; `y(endMinute:)` of the
/// exclusive end of a span is the axis' y of the end of the last minute it covers. On an ordinary day both are exactly the inner axis' own `y`.
struct ElapsedMinuteAxisMapping: TimeAxisMapping {
    let inner: any TimeAxisMapping
    let projection: WallClockProjection

    init(inner: any TimeAxisMapping, projection: WallClockProjection) {
        self.inner = inner
        self.projection = projection
    }

    var totalMinutes: Int { projection.clock.totalMinutes }
    var contentHeight: CGFloat { inner.contentHeight }
    var gutterWidth: CGFloat { inner.gutterWidth }
    var trailingPadding: CGFloat { inner.trailingPadding }
    var columnSpacing: CGFloat { inner.columnSpacing }
    var minimumBlockHeight: CGFloat { inner.minimumBlockHeight }

    func y(minute: Int) -> CGFloat { inner.y(exactMinute: Double(projection.clock.wallMinute(forElapsed: minute))) }
    func y(endMinute minute: Int) -> CGFloat { inner.y(exactMinute: Double(projection.clock.exclusiveEndWall(forElapsed: minute))) }
    func y(bottomOfSpanFrom start: Int, to end: Int) -> CGFloat { inner.y(exactMinute: Double(projection.clock.wallRange(startElapsed: start, endElapsed: end).bottom)) }
    func y(exactMinute minute: Double) -> CGFloat {
        let whole = Int(minute.rounded(.down))
        let fraction = minute - Double(whole)
        let low = y(minute: whole)
        return fraction == 0 ? low : low + CGFloat(fraction) * (y(minute: whole + 1) - low)
    }

    /// For display and hit-testing: the elapsed minute of the first occurrence of the nearest wall-clock minute (see `WallClockProjection`'s contract).
    func minute(atY y: CGFloat) -> Int { projection.displayElapsed(forWall: inner.minute(atY: y)).minute }
    func exactMinute(atY y: CGFloat) -> Double { Double(minute(atY: y)) }

    /// The repeated hour of a fall-back day makes two instants share a position.
    var preservesInstantIdentity: Bool { projection.clock.repeatedWall == nil && inner.preservesInstantIdentity }
}
