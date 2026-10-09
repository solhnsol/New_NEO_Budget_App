import CoreGraphics
import NEOBudgetCalendar

/// Plans a time axis that changes as little as possible when the visible pair of days moves by one.
///
/// The engine shapes the axis from the two days on screen alone, so stepping one day over can reshape it completely. This planner keeps
/// the engine's demands for the two visible days as a *floor* it never goes below, and spends the room above that floor in an order that
/// makes neighbouring windows alike: the main day's detail first, then the secondary day's, then what the days around them would ask
/// for (less the further away they are). Everything is computed on a fixed grid of quarter-hour slots, so:
///
/// - the same input always gives the same axis (nothing depends on the path taken to a day, the clock, or the scroll position);
/// - a day's own demand is computed once and reused by every window that contains it (`AxisDemandCache`);
/// - nothing here builds a view or reads a rendered size.
///
/// This file only plans an axis. Drawing is untouched, and so is the engine, which stays the reference these numbers are compared with.
enum AxisStabilizer {
    static let slotMinutes = 15
    static let slotCount = 24 * 60 / slotMinutes
}

// MARK: Parameters

struct AxisStabilizerParameters: Equatable, Sendable {
    /// Days before the main day and after the secondary day that take part: (1, 1) is the four days D-1...D+2, (2, 2) the trial six.
    var before = 1
    var after = 1
    /// How much of what a day asks for (above the floor) it is given a claim to, by distance in days from the nearest visible day.
    /// A weight only orders and sizes the *extra* room; it never lowers the floor.
    var distanceWeights: [CGFloat] = [0.8, 0.5, 0.3]
    /// The part of the room above the floor the main day's own detail may take first. The rest is shared by the secondary day's detail and
    /// the surroundings, so that a window does not spend everything on one day's content (which is what changes when the window moves).
    var mainDetailShare: CGFloat = 0.5
    /// Of the room left once the main day has what it wants, the part the secondary day's detail may use before the surroundings do.
    /// What the secondary does not use goes on to the surroundings.
    var secondaryShare: CGFloat = 0.5
    /// Extra scroll allowed only for stability, as a fraction of the viewport height.
    var extraScrollAllowance: CGFloat = 0.2
    /// The most a slot may differ in height from the next one when a taller stretch is eased into its surroundings, in points.
    var taperPerSlot: CGFloat = 24
    /// An empty stretch of at most this many slots between two stretches with something in them is kept open at browse size rather than folded.
    var shortGapSlots = 4
    /// Height of a slot kept open at browse size (points per minute at standard text size times the slot length).
    var openSlotHeight: CGFloat = 0.6 * CGFloat(AxisStabilizer.slotMinutes)

    static let twoDayReference = AxisStabilizerParameters(before: 0, after: 0)
    static let fourDay = AxisStabilizerParameters()
    static let sixDay = AxisStabilizerParameters(before: 2, after: 2)
}

// MARK: One day's demand

/// What one day asks of every quarter hour, at three amounts of detail, computed once and reused by every window containing the day.
struct DayDemandProfile: Equatable, Sendable {
    let day: LocalDate
    /// Identifies the content, the sizes and the text scale this was computed for. A different one is a different profile.
    let signature: Int
    let minimum: [CGFloat]
    let preferred: [CGFloat]
    let expanded: [CGFloat]
    /// A slot with an event or a transaction in it.
    let occupied: [Bool]
    let heights: AdaptiveLayoutEngine.DemandHeights

    static func make(_ day: AllocationDay, parameters: AllocationParameters, textScale: CGFloat) -> DayDemandProfile {
        let axes = AdaptiveLayoutEngine.soloAxes(of: day, parameters: parameters, textScale: textScale)
        var occupied = [Bool](repeating: false, count: AxisStabilizer.slotCount)
        func mark(_ start: Int, _ end: Int) {
            let first = max(0, start / AxisStabilizer.slotMinutes)
            let last = min(AxisStabilizer.slotCount - 1, max(start, end - 1) / AxisStabilizer.slotMinutes)
            if first <= last { for slot in first...last { occupied[slot] = true } }
        }
        for event in day.events { mark(event.startMinute, event.effectiveEnd) }
        for transaction in day.transactions where transaction.dayOffset == 0 { mark(transaction.minute, transaction.minute + 1) }
        return DayDemandProfile(
            day: day.day, signature: signature(of: day, parameters: parameters, textScale: textScale),
            minimum: slotHeights(axes.minimum), preferred: slotHeights(axes.preferred), expanded: slotHeights(axes.expanded),
            occupied: occupied, heights: AdaptiveLayoutEngine.demandHeights(of: day, parameters: parameters, textScale: textScale)
        )
    }

    static func signature(of day: AllocationDay, parameters: AllocationParameters, textScale: CGFloat) -> Int {
        var hasher = Hasher()
        hasher.combine(day.day.daysSinceUnixEpoch)
        hasher.combine(day.totalMinutes)
        for event in day.events { hasher.combine(event) }
        for transaction in day.transactions { hasher.combine(transaction) }
        // The sizes the demand depends on, rounded so that a change too small to matter is not a different day.
        for value in [parameters.titleRow, parameters.linkedRow, parameters.transactionRow, parameters.lineGap, parameters.overflowCard, parameters.browseScale, textScale] {
            hasher.combine(Int((value * 100).rounded()))
        }
        hasher.combine(parameters.padding)
        hasher.combine(parameters.longEventMinutes)
        hasher.combine(parameters.transactionWindowMinutes)
        return hasher.finalize()
    }
}

/// Heights of the 96 quarter-hour slots of an axis.
func slotHeights(_ axis: TimelineAxis) -> [CGFloat] {
    (0..<AxisStabilizer.slotCount).map { slot in
        let start = slot * AxisStabilizer.slotMinutes
        return axis.y(minute: min(start + AxisStabilizer.slotMinutes, axis.totalMinutes)) - axis.y(minute: min(start, axis.totalMinutes))
    }
}

// MARK: Cache

/// Remembers a day's demand profile and the floor of a pair of days. Entries are found by what they were computed from, so a changed
/// day (or text size, or sizes) finds nothing and is recomputed; the oldest entries go when the limit is reached.
final class AxisDemandCache {
    private(set) var hits = 0
    private(set) var misses = 0
    let limit: Int
    private var profiles: [Int: DayDemandProfile] = [:]
    private var floors: [Int: [CGFloat]] = [:]
    private var order: [Int] = []

    init(limit: Int = 64) { self.limit = max(1, limit) }

    var count: Int { profiles.count + floors.count }
    var hitRate: Double { hits + misses == 0 ? 0 : Double(hits) / Double(hits + misses) }
    func resetCounters() { hits = 0; misses = 0 }

    func profile(for day: AllocationDay, parameters: AllocationParameters, textScale: CGFloat) -> DayDemandProfile {
        let key = DayDemandProfile.signature(of: day, parameters: parameters, textScale: textScale)
        if let found = profiles[key] { hits += 1; return found }
        misses += 1
        let made = DayDemandProfile.make(day, parameters: parameters, textScale: textScale)
        store(key) { self.profiles[key] = made }
        return made
    }

    /// The floor of a pair of days (main, secondary). The pair is found by the two days' own signatures.
    func floor(main: DayDemandProfile, secondary: DayDemandProfile?, mainDay: AllocationDay, secondaryDay: AllocationDay?, parameters: AllocationParameters, textScale: CGFloat) -> [CGFloat] {
        var hasher = Hasher()
        hasher.combine(main.signature)
        hasher.combine(secondary?.signature ?? 0)
        hasher.combine(0x464C52)
        let key = hasher.finalize()
        if let found = floors[key] { hits += 1; return found }
        misses += 1
        let made = slotHeights(AdaptiveLayoutEngine.floorAxis(main: mainDay, secondary: secondaryDay, parameters: parameters, textScale: textScale))
        store(key) { self.floors[key] = made }
        return made
    }

    private func store(_ key: Int, _ write: () -> Void) {
        write()
        order.append(key)
        while order.count > limit {
            let oldest = order.removeFirst()
            profiles[oldest] = nil
            floors[oldest] = nil
        }
    }
}

// MARK: The planned axis

struct PlannedAxis: Equatable {
    let axis: TimelineAxis
    let slots: [CGFloat]
    /// What the visible days cannot do without (the floor), and what was added on top of it, and for what.
    let floorHeight: CGFloat
    let mainDetailHeight: CGFloat
    let secondaryDetailHeight: CGFloat
    let stabilizerHeight: CGFloat
    let viewportHeight: CGFloat

    var height: CGFloat { slots.reduce(0, +) }
    /// Scroll that exists because the visible days' smallest forms do not fit the screen.
    var requiredScroll: CGFloat { max(0, floorHeight - viewportHeight) }
    /// Scroll that exists only because of the extra room spent on stability.
    var stabilizationScroll: CGFloat { max(0, height - max(viewportHeight, floorHeight)) }
}

extension AxisStabilizer {
    /// The axis planned for the pair (`main`, `secondary`) with the days around them taking part as `parameters` says.
    /// `window` lists the days from the earliest to the latest; `mainIndex` is the main day's place in it.
    static func plan(
        window: [DayDemandProfile], mainIndex: Int, floor: [CGFloat], viewport: CGFloat, parameters: AxisStabilizerParameters
    ) -> PlannedAxis {
        let count = slotCount
        var heights = floor
        let floorTotal = floor.reduce(0, +)
        let room = max(0, viewport - floorTotal)
        let mainProfile = window[mainIndex]
        let secondaryProfile = mainIndex + 1 < window.count ? window[mainIndex + 1] : nil

        /// Raises the slots toward `wanted` by at most `budget` in all, in proportion to how far each is from it.
        func raise(toward wanted: [CGFloat], budget: CGFloat) -> CGFloat {
            guard budget > 0 else { return 0 }
            let gaps = (0..<count).map { max(0, wanted[$0] - heights[$0]) }
            let needed = gaps.reduce(0, +)
            guard needed > 0 else { return 0 }
            let share = min(1, budget / needed)
            for slot in 0..<count { heights[slot] += gaps[slot] * share }
            return needed * share
        }

        // 1. The main day's own detail, then
        let mainSpent = raise(toward: mainProfile.preferred, budget: room * parameters.mainDetailShare)
        let afterMain = room - mainSpent
        // 2. the secondary day's, within its share of what is left,
        var secondarySpent: CGFloat = 0
        if let secondaryProfile {
            secondarySpent = raise(toward: secondaryProfile.preferred, budget: afterMain * parameters.secondaryShare)
        }
        // 3. and what the surroundings would ask for, weighted by how far away they are, from what is still unspent and from the extra
        //    scroll allowed for stability.
        var surroundings = [CGFloat](repeating: 0, count: count)
        for (index, profile) in window.enumerated() where profile.day != mainProfile.day && profile.day != secondaryProfile?.day {
            let distance = index < mainIndex ? mainIndex - index : index - (mainIndex + 1)
            let weight = parameters.distanceWeights[min(max(distance - 1, 0), parameters.distanceWeights.count - 1)]
            for slot in 0..<count { surroundings[slot] = max(surroundings[slot], profile.preferred[slot] * weight) }
        }
        // A short empty stretch between two with something in them stays open at browse size (not folded and unfolded as the window moves).
        let union = (0..<count).map { slot in window.contains { $0.occupied[slot] } }
        var openGap = [CGFloat](repeating: 0, count: count)
        var slot = 0
        while slot < count {
            if union[slot] { slot += 1; continue }
            var end = slot
            while end < count, !union[end] { end += 1 }
            if slot > 0, end < count, end - slot <= parameters.shortGapSlots { for gap in slot..<end { openGap[gap] = parameters.openSlotHeight } }
            slot = end
        }
        let wanted = (0..<count).map { max(surroundings[$0], openGap[$0]) }
        // Extra scroll for stability is only bought where the visible days fit the screen: when they already need scrolling the added
        // height changed little in the measurements and only lengthened the scroll.
        let allowance = floorTotal <= viewport ? parameters.extraScrollAllowance * viewport : 0
        let stabilizerBudget = (afterMain - secondarySpent) + allowance
        let stabilizerSpent = parameters.before + parameters.after > 0 ? raise(toward: wanted, budget: stabilizerBudget) : 0

        // 4. Ease the taller stretches into their surroundings so that a change of window moves the boundaries gently, as far as the extra
        //    room allows; with less room the easing is halved until it fits, then dropped.
        var eased = heights
        var tapered: CGFloat = 0
        if parameters.before + parameters.after > 0 {
            let ceiling = max(viewport, floorTotal) + allowance
            var limit = parameters.taperPerSlot
            while limit > 0.5 {
                let candidate = taper(heights, limit: limit, floor: floor)
                if candidate.reduce(0, +) <= max(ceiling, heights.reduce(0, +)) + 0.01 { eased = candidate; break }
                limit /= 2
            }
            tapered = eased.reduce(0, +) - heights.reduce(0, +)
        }
        return PlannedAxis(
            axis: axis(fromSlots: eased, floor: floor), slots: eased, floorHeight: floorTotal, mainDetailHeight: mainSpent,
            secondaryDetailHeight: secondarySpent, stabilizerHeight: stabilizerSpent + tapered, viewportHeight: viewport
        )
    }

    /// No slot is lower than the tallest slot near it less `limit` for every slot of distance, and none is lower than its floor.
    static func taper(_ heights: [CGFloat], limit: CGFloat, floor: [CGFloat]) -> [CGFloat] {
        var result = heights
        for slot in 1..<heights.count { result[slot] = max(result[slot], result[slot - 1] - limit) }
        for slot in stride(from: heights.count - 2, through: 0, by: -1) { result[slot] = max(result[slot], result[slot + 1] - limit) }
        return zip(result, floor).map { max($0, $1) }
    }

    /// The axis whose slots have these heights. A run of slots that are no taller than the floor's folded ones stays folded.
    static func axis(fromSlots slots: [CGFloat], floor: [CGFloat]) -> TimelineAxis {
        let foldedLimit: CGFloat = 0.06 * CGFloat(slotMinutes) * 1.5
        var segments: [TimelineAxis.Segment] = []
        for (slot, height) in slots.enumerated() {
            let start = slot * slotMinutes, end = start + slotMinutes
            let folded = height <= foldedLimit
            if let last = segments.last, last.isFolded == folded, folded || abs(last.pointsPerMinute - height / CGFloat(slotMinutes)) < 1e-6 {
                let merged = last.height + height
                segments[segments.count - 1] = TimelineAxis.Segment(
                    startMinute: last.startMinute, endMinute: end, pointsPerMinute: merged / CGFloat(end - last.startMinute),
                    height: merged, isFolded: folded
                )
            } else {
                segments.append(TimelineAxis.Segment(startMinute: start, endMinute: end, pointsPerMinute: height / CGFloat(slotMinutes), height: height, isFolded: folded))
            }
        }
        return TimelineAxis(totalMinutes: 24 * 60, segments: segments)
    }
}
