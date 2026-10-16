import CoreGraphics
import NEOBudgetCalendar

/// A new event picked up by a long press on empty grid and carried by the finger, the way the system calendar does it: the card (an hour long) is under the
/// finger from the moment the press is recognised and follows it, its start on the 15-minute lines, and the column under the finger is its day. Where it would
/// land is outlined and its start is written on the hour axis. When the finger lifts, an edit session opens on it (`FixedGridEditInteraction.Target.new`):
/// it is named, its calendar chosen and its length changed there, and it is created in the calendar on done. Pure, so it is tested.
struct FixedGridCreatePlacement: Equatable {
    /// How long a new event is when it is picked up (the length is changed by its handles afterwards).
    static let defaultMinutes = 60
    static let stepMinutes = EditDraft.stepMinutes

    private(set) var day: LocalDate
    private(set) var startMinute: Int
    let durationMinutes: Int
    /// The day's elapsed minutes (1380 or 1500 on a clock-change day).
    private(set) var dayMinutes: Int
    /// How far (points) the card's top is from the finger: kept from the pick-up, so the card moves with the finger instead of jumping under it.
    let grabOffset: CGFloat

    var endMinute: Int { startMinute + durationMinutes }

    /// Picked up at `fingerMinute` of `day`: the card starts at the 15-minute line at or before the finger (the finger is on the card), and stays inside the day.
    /// `grabOffset`: the card's top minus the finger's height, on the axis drawn now.
    init(day: LocalDate, fingerMinute: Int, dayMinutes: Int, durationMinutes: Int = defaultMinutes, grabOffset: (_ startMinute: Int) -> CGFloat) {
        let duration = max(Self.stepMinutes, min(durationMinutes, dayMinutes))
        let floored = Int((Double(fingerMinute) / Double(Self.stepMinutes)).rounded(.down)) * Self.stepMinutes
        let start = Self.clamped(floored, dayMinutes: dayMinutes, duration: duration)
        self.day = day
        self.startMinute = start
        self.durationMinutes = duration
        self.dayMinutes = dayMinutes
        self.grabOffset = grabOffset(start)
    }

    /// The finger moved: `minute` is the elapsed minute of `day` at the card's top (the finger's height plus `grabOffset`). The start goes to the nearest
    /// 15-minute line inside the day. Returns whether the card moved (a step: a haptic).
    @discardableResult
    mutating func move(to day: LocalDate, minute: Int, dayMinutes: Int) -> Bool {
        let rounded = Int((Double(minute) / Double(Self.stepMinutes)).rounded()) * Self.stepMinutes
        let start = Self.clamped(rounded, dayMinutes: dayMinutes, duration: durationMinutes)
        guard day != self.day || start != startMinute else { return false }
        self.day = day
        self.dayMinutes = dayMinutes
        startMinute = start
        return true
    }

    /// The edit session's target for the event where it was put down.
    var target: FixedGridEditInteraction.Target { .new(day: day, startMinute: startMinute, endMinute: endMinute) }

    private static func clamped(_ start: Int, dayMinutes: Int, duration: Int) -> Int {
        min(max(0, start), max(0, dayMinutes - duration))
    }
}
