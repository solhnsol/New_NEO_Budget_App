import CoreGraphics
import NEOBudgetCalendar

/// Plans a time axis that changes as little as possible when the visible pair of days moves by one, and lays the days out on it.
///
/// The axis is the **floor** (what the two visible days need in their smallest form, exactly as the engine computes it, minute for
/// minute) plus **extra height** on a grid of quarter-hour slots. Extra height is only ever added, and it is a running total over time, so
/// any two minutes are at least as far apart as on the floor: nothing the floor guarantees can be lost, and no demand of a visible day is
/// ever weakened by averaging or weighting.
///
/// The extra is spent in the order of the display priorities, and always as whole *claims* (two neighbouring transactions kept apart as
/// lines, an event given room for its first rows): a claim is given all the room it needs or none, because half the room changes nothing
/// that is shown and only moves the axis:
/// - P1  the main day's transactions kept apart as lines of their own (its independent transactions stay readable);
/// - P3  the main day's first rows, then the secondary day's lines and rows (what it will ask for as the main day of the next window);
/// - P2  stability: the same claims of the days around the pair, nearest first and weighted by distance, from what is left and from a
///       separately limited extra scroll, so that the next window looks like this one;
/// - the scroll for P1, the scroll for P2 and the scroll the floor itself needs are three separate amounts.
///
/// The same input gives the same axis (no clock, path, cache state or scroll position takes part), and a day's demand is computed once
/// and reused by every window that contains it. The engine takes the planned axis as it is (`AllocationInput.fixedAxis`) and decides what is
/// shown from the room it gives, so the axis and what is drawn on it cannot disagree.
enum AxisStabilizer {
    static let slotMinutes = 15
    static let slotCount = 24 * 60 / slotMinutes
}

// MARK: Parameters

struct AxisStabilizerParameters: Equatable, Sendable {
    /// Days before the main day and after the secondary day that take part: (1, 1) is the four days D-1...D+2, (2, 2) the trial six.
    var before = 1
    var after = 1
    /// How much of the stability room the claims of the days at each distance (1, 2, 3 from the nearest visible day) may use.
    var distanceWeights: [CGFloat] = [0.8, 0.5, 0.3]
    /// Scroll allowed for P1, as a fraction of the viewport: height beyond the screen that keeps the main day's independent transactions
    /// apart as lines of their own. It is separate from the scroll the floor needs and from the scroll allowed for stability.
    var mainLinesScrollAllowance: CGFloat = 0.25
    /// The part of the room above the floor (after the main day's lines) the main day's first rows may take.
    var mainDetailShare: CGFloat = 1
    /// Of what is left, the part the secondary day's detail may use; the rest goes on to the surroundings.
    var secondaryShare: CGFloat = 1
    /// Extra scroll allowed only for stability, as a fraction of the viewport height.
    var extraScrollAllowance: CGFloat = 0.1
    /// The most a slot may differ from the next one when a taller stretch is eased into its surroundings, in points. 0 turns it off.
    var taperPerSlot: CGFloat = 0
    /// An empty stretch of at most this many slots between stretches with something in them is kept open at browse size. 0 turns it off.
    var shortGapSlots = 4
    /// Height of a slot kept open at browse size.
    var openSlotHeight: CGFloat = 0.6 * CGFloat(AxisStabilizer.slotMinutes)
    /// The part of the stability room the shape of the neighbours' smallest forms may take before their claims are considered.
    var shapeShare: CGFloat = 0
    /// Whether the secondary day's transactions may also be kept apart with the scroll allowed for P1 (they will be the main day's next).
    var secondaryLinesUseReadabilityScroll = true
    /// Switches for measuring what each part of the plan is worth (they are all on in use).
    var spendsOnMainRows = true
    var spendsOnSecondary = true
    var spendsOnSurroundings = true

    static let fourDay = AxisStabilizerParameters()
    static let sixDay = AxisStabilizerParameters(before: 2, after: 2)
}

// MARK: One day's demand

/// One thing a day can be given room for: a stretch of time that must be at least `need` points tall for it to be shown in the form that
/// asks for. Both kinds are the engine's own: two neighbouring transactions kept apart need a row and a gap between them, an event needs
/// the height of its first rows over its minutes.
struct DemandClaim: Equatable, Sendable {
    let start: Int
    let end: Int
    let need: CGFloat
    let id: String
}

/// What one day would ask for beyond its smallest form, and where it has something at all, computed once and reused by every window
/// containing the day.
struct DayDemandProfile: Equatable, Sendable {
    let day: LocalDate
    /// Identifies the content, the sizes and the text scale this was computed for. A different one is a different profile.
    let signature: Int
    /// Two neighbouring transactions kept apart as lines of their own.
    let lineClaims: [DemandClaim]
    /// An event shown with its first rows.
    let rowClaims: [DemandClaim]
    /// A slot with an event or a transaction in it.
    let occupied: [Bool]
    /// What the day asks of each quarter hour in its smallest form, on its own.
    let minimum: [CGFloat]
    let heights: AdaptiveLayoutEngine.DemandHeights

    static func make(_ day: AllocationDay, parameters: AllocationParameters, textScale: CGFloat) -> DayDemandProfile {
        var occupied = [Bool](repeating: false, count: AxisStabilizer.slotCount)
        func mark(_ start: Int, _ end: Int) {
            let first = max(0, start / AxisStabilizer.slotMinutes)
            let last = min(AxisStabilizer.slotCount - 1, max(start, end - 1) / AxisStabilizer.slotMinutes)
            if first <= last { for slot in first...last { occupied[slot] = true } }
        }
        for event in day.events { mark(event.startMinute, event.effectiveEnd) }
        for transaction in day.transactions where transaction.dayOffset == 0 { mark(transaction.minute, transaction.minute + 1) }
        let heights = AdaptiveLayoutEngine.demandHeights(of: day, parameters: parameters, textScale: textScale)
        let lines = heights.mergeableLinks.map { DemandClaim(start: $0.first, end: $0.second, need: heights.pitch, id: $0.key) }
        let rows = day.events.compactMap { event -> DemandClaim? in
            guard let needs = heights.events[event.id], needs.preview > needs.title else { return nil }
            return DemandClaim(start: event.startMinute, end: event.effectiveEnd, need: needs.preview, id: event.id)
        }
        return DayDemandProfile(
            day: day.day, signature: signature(of: day, parameters: parameters, textScale: textScale),
            lineClaims: lines, rowClaims: rows, occupied: occupied,
            minimum: slotHeights(AdaptiveLayoutEngine.soloAxes(of: day, parameters: parameters, textScale: textScale).minimum), heights: heights
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
        hasher.combine(parameters.minimumFoldMinutes)
        hasher.combine(parameters.previewLinkedRows)
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
    private var floors: [Int: TimelineAxis] = [:]
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

    /// The floor axis of a pair of days (main, secondary), found by the two days' own signatures.
    func floor(main: DayDemandProfile, secondary: DayDemandProfile?, mainDay: AllocationDay, secondaryDay: AllocationDay?, parameters: AllocationParameters, textScale: CGFloat) -> TimelineAxis {
        var hasher = Hasher()
        hasher.combine(main.signature)
        hasher.combine(secondary?.signature ?? 0)
        hasher.combine(0x464C52)
        let key = hasher.finalize()
        if let found = floors[key] { hits += 1; return found }
        misses += 1
        let made = AdaptiveLayoutEngine.floorAxis(main: mainDay, secondary: secondaryDay, parameters: parameters, textScale: textScale)
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
    let mainLinesHeight: CGFloat
    let mainRowsHeight: CGFloat
    let secondaryHeight: CGFloat
    let surroundingsHeight: CGFloat
    let openGapHeight: CGFloat
    let taperHeight: CGFloat
    /// Of the extra height, how much went beyond the screen under the P1 allowance: for the main day's lines, and for the secondary day's
    /// (kept apart ahead of time because it will be the main day next).
    let readabilityScroll: CGFloat
    let prepaidScroll: CGFloat
    let viewportHeight: CGFloat

    var height: CGFloat { axis.height }
    /// Height spent for stability alone: the surroundings, the kept-open gaps and the easing.
    var stabilizerHeight: CGFloat { surroundingsHeight + openGapHeight + taperHeight }
    /// Scroll that exists because the visible days' smallest forms do not fit the screen.
    var requiredScroll: CGFloat { max(0, floorHeight - viewportHeight) }
    /// Scroll that exists only because of the extra room spent on stability (not the floor's, and not the P1 allowance's).
    var stabilizationScroll: CGFloat { max(0, height - max(viewportHeight, floorHeight) - readabilityScroll - prepaidScroll) }
}

extension AxisStabilizer {
    /// The axis planned for the pair (`window[mainIndex]`, `window[mainIndex + 1]`), the days around them taking part as `parameters` says.
    static func plan(
        window: [DayDemandProfile], mainIndex: Int, floorAxis: TimelineAxis, viewport: CGFloat, parameters: AxisStabilizerParameters
    ) -> PlannedAxis {
        let count = slotCount
        let floor = slotHeights(floorAxis)
        var heights = floor
        let floorTotal = floorAxis.height
        let room = max(0, viewport - floorTotal)
        let mainProfile = window[mainIndex]
        let secondaryProfile = mainIndex + 1 < window.count ? window[mainIndex + 1] : nil

        func currentAxis() -> TimelineAxis { axis(floorAxis: floorAxis, extra: zip(heights, floor).map { $0 - $1 }) }

        /// Gives claims the room they need, the cheapest first, each wholly or not at all, while `budget` lasts. Returns what was spent.
        func grant(_ claims: [DemandClaim], budget: CGFloat) -> CGFloat {
            guard budget > 0, !claims.isEmpty else { return 0 }
            let base = currentAxis()
            let ordered = claims.filter { $0.end > $0.start }.map { claim in
                (claim, claim.need - (base.y(minute: claim.end) - base.y(minute: claim.start)))
            }.sorted { ($0.1, $0.0.start, $0.0.id) < ($1.1, $1.0.start, $1.0.id) }
            var spent: CGFloat = 0
            for (claim, _) in ordered {
                let now = currentAxis()
                let have = now.y(minute: claim.end) - now.y(minute: claim.start)
                guard have + 0.5 < claim.need else { continue }
                // The same density added over every slot the claim touches, which gives the claim exactly the room it lacks.
                let perMinute = (claim.need - have) / CGFloat(claim.end - claim.start)
                let slots = (claim.start / slotMinutes)...((claim.end - 1) / slotMinutes)
                let cost = perMinute * CGFloat(slotMinutes) * CGFloat(slots.count)
                guard spent + cost <= budget else { continue }
                for slot in slots { heights[slot] += perMinute * CGFloat(slotMinutes) }
                spent += cost
            }
            return spent
        }

        // P1: the main day's transactions kept apart as lines of their own. Beyond the screen this has its own scroll allowance.
        let linesSpent = grant(mainProfile.lineClaims, budget: room + parameters.mainLinesScrollAllowance * viewport)
        var left = max(0, room - linesSpent)
        // P3: the main day's first rows, then the secondary day's lines and rows (what it will ask for as the main day of the next
        // window), each within its share of what is left.
        var rowsSpent: CGFloat = 0
        if parameters.spendsOnMainRows {
            rowsSpent = grant(mainProfile.rowClaims, budget: left * parameters.mainDetailShare)
            left -= rowsSpent
        }
        var secondarySpent: CGFloat = 0
        let readabilityScroll = max(0, linesSpent - room)
        var readabilityLeft = max(0, parameters.mainLinesScrollAllowance * viewport - readabilityScroll)
        var prepaidScroll: CGFloat = 0
        if parameters.spendsOnSecondary, let secondaryProfile {
            if parameters.secondaryLinesUseReadabilityScroll {
                // Its lines come first and may reach into the scroll allowed for P1 (what the main day gets next time).
                let spentOnLines = grant(secondaryProfile.lineClaims, budget: left * parameters.secondaryShare + readabilityLeft)
                secondarySpent += spentOnLines
                let fromRoom = min(spentOnLines, left)
                left -= fromRoom
                prepaidScroll = max(0, spentOnLines - fromRoom)
                readabilityLeft -= prepaidScroll
                let rows = grant(secondaryProfile.rowClaims, budget: left * parameters.secondaryShare)
                secondarySpent += rows
                left -= rows
            } else {
                secondarySpent = grant(secondaryProfile.lineClaims + secondaryProfile.rowClaims, budget: left * parameters.secondaryShare)
                left -= secondarySpent
            }
        }
        // P2: the same claims of the days around, nearest first and each distance within its weight of the stability room (what is left
        // plus the extra scroll allowed for stability, which exists only where everything above fits the screen), and short empty
        // stretches between busy ones kept open (not folded and unfolded as the window moves).
        let allowance = floorTotal + linesSpent + prepaidScroll <= viewport ? parameters.extraScrollAllowance * viewport : 0
        let stabilizing = parameters.before + parameters.after > 0
        let stabilityRoom = left + allowance
        var surroundingsSpent: CGFloat = 0
        var gapSpent: CGFloat = 0
        if stabilizing {
            if parameters.spendsOnSurroundings {
                // What the days around ask of each quarter hour in their smallest form, by distance: the shape of the axis the next
                // window will have, taken up before any detail is. Continuous: it moves boundaries and shows nothing different.
                var shape = [CGFloat](repeating: 0, count: count)
                for index in window.indices {
                    let profile = window[index]
                    guard profile.day != mainProfile.day, profile.day != secondaryProfile?.day else { continue }
                    let distance = index < mainIndex ? mainIndex - index : index - (mainIndex + 1)
                    let weight = parameters.distanceWeights[min(max(distance - 1, 0), parameters.distanceWeights.count - 1)]
                    for slot in 0..<count { shape[slot] = max(shape[slot], profile.minimum[slot] * weight) }
                }
                let gaps = (0..<count).map { max(0, shape[$0] - heights[$0]) }
                let needed = gaps.reduce(0, +)
                let budget = max(0, stabilityRoom * parameters.shapeShare)
                if needed > 0, budget > 0 {
                    let share = min(1, budget / needed)
                    for slot in 0..<count { heights[slot] += gaps[slot] * share }
                    surroundingsSpent += needed * share
                }
                let distances = Set(window.indices.compactMap { index -> Int? in
                    let profile = window[index]
                    guard profile.day != mainProfile.day, profile.day != secondaryProfile?.day else { return nil }
                    return index < mainIndex ? mainIndex - index : index - (mainIndex + 1)
                }).sorted()
                for distance in distances {
                    let weight = parameters.distanceWeights[min(max(distance - 1, 0), parameters.distanceWeights.count - 1)]
                    let claims = window.indices.filter { index in
                        let profile = window[index]
                        guard profile.day != mainProfile.day, profile.day != secondaryProfile?.day else { return false }
                        return (index < mainIndex ? mainIndex - index : index - (mainIndex + 1)) == distance
                    }.flatMap { window[$0].lineClaims + window[$0].rowClaims }
                    surroundingsSpent += grant(claims, budget: min(stabilityRoom - surroundingsSpent, stabilityRoom * weight))
                }
            }
            if parameters.shortGapSlots > 0 {
                var openGap = [CGFloat](repeating: 0, count: count)
                let union = (0..<count).map { slot in window.contains { $0.occupied[slot] } }
                var slot = 0
                while slot < count {
                    if union[slot] { slot += 1; continue }
                    var end = slot
                    while end < count, !union[end] { end += 1 }
                    if slot > 0, end < count, end - slot <= parameters.shortGapSlots { for gap in slot..<end { openGap[gap] = parameters.openSlotHeight } }
                    slot = end
                }
                let budget = max(0, stabilityRoom - surroundingsSpent)
                let gaps = (0..<count).map { max(0, openGap[$0] - heights[$0]) }
                let needed = gaps.reduce(0, +)
                if needed > 0, budget > 0 {
                    let share = min(1, budget / needed)
                    for slot in 0..<count { heights[slot] += gaps[slot] * share }
                    gapSpent = needed * share
                }
            }
        }

        // Ease the taller stretches into their surroundings so that a change of window moves the boundaries gently, as far as the extra
        // room allows; with less room the easing is halved until it fits, then dropped.
        var eased = heights
        var taperSpent: CGFloat = 0
        if stabilizing, parameters.taperPerSlot > 0 {
            let ceiling = max(viewport, floorTotal + linesSpent) + allowance
            var limit = parameters.taperPerSlot
            while limit > 0.5 {
                let candidate = taper(heights, limit: limit, floor: floor)
                if candidate.reduce(0, +) <= max(ceiling, heights.reduce(0, +)) + 0.01 { eased = candidate; break }
                limit /= 2
            }
            taperSpent = eased.reduce(0, +) - heights.reduce(0, +)
        }
        let built = axis(floorAxis: floorAxis, extra: zip(eased, floor).map { $0 - $1 })
        return PlannedAxis(
            axis: built, slots: slotHeights(built), floorHeight: floorTotal, mainLinesHeight: linesSpent, mainRowsHeight: rowsSpent,
            secondaryHeight: secondarySpent, surroundingsHeight: surroundingsSpent, openGapHeight: gapSpent, taperHeight: taperSpent,
            readabilityScroll: readabilityScroll, prepaidScroll: prepaidScroll, viewportHeight: viewport
        )
    }

    /// No slot is lower than the tallest slot near it less `limit` for every slot of distance, and none is lower than its floor.
    static func taper(_ heights: [CGFloat], limit: CGFloat, floor: [CGFloat]) -> [CGFloat] {
        var result = heights
        for slot in 1..<heights.count { result[slot] = max(result[slot], result[slot - 1] - limit) }
        for slot in stride(from: heights.count - 2, through: 0, by: -1) { result[slot] = max(result[slot], result[slot + 1] - limit) }
        return zip(result, floor).map { max($0, $1) }
    }

    /// The floor axis with `extra` (never negative) added to every quarter hour, spread evenly over its minutes. Every piece of the floor
    /// keeps its own scale and is only made taller, so two times are at least as far apart as on the floor, however close they are.
    static func axis(floorAxis: TimelineAxis, extra: [CGFloat]) -> TimelineAxis {
        var segments: [TimelineAxis.Segment] = []
        for segment in floorAxis.segments {
            var start = segment.startMinute
            while start < segment.endMinute {
                let slot = min(slotCount - 1, start / slotMinutes)
                let end = min(segment.endMinute, (slot + 1) * slotMinutes)
                let minutes = end - start
                let added = max(0, extra[slot]) * CGFloat(minutes) / CGFloat(slotMinutes)
                let height = segment.height * CGFloat(minutes) / CGFloat(segment.minutes) + added
                // A folded stretch given real extra height is no longer folded.
                let folded = segment.isFolded && added < 1
                segments.append(TimelineAxis.Segment(startMinute: start, endMinute: end, pointsPerMinute: height / CGFloat(minutes), height: height, isFolded: folded))
                start = end
            }
        }
        // Neighbouring pieces with the same scale and fold state are one stretch again.
        var merged: [TimelineAxis.Segment] = []
        for segment in segments {
            if let last = merged.last, !last.isFolded, !segment.isFolded, abs(last.pointsPerMinute - segment.pointsPerMinute) < 1e-6 {
                merged[merged.count - 1] = TimelineAxis.Segment(
                    startMinute: last.startMinute, endMinute: segment.endMinute, pointsPerMinute: last.pointsPerMinute,
                    height: last.height + segment.height, isFolded: false
                )
            } else {
                merged.append(segment)
            }
        }
        return TimelineAxis(totalMinutes: floorAxis.totalMinutes, segments: merged)
    }
}

// MARK: Layout on the planned axis

/// The layout of a pair of days on the planned axis, with the plan it came from.
struct StabilizedLayout {
    let plan: PlannedAxis
    let layout: AdaptiveLayout

    /// Lays out `days[mainIndex]` and the day after it. `days` are consecutive and hold the days around the pair as `stabilizer` says.
    static func make(
        days: [AllocationDay], mainIndex: Int, viewport: CGFloat, contentWidth: CGFloat, textScale: CGFloat = 1,
        titleWidths: [String: CGFloat] = [:], parameters: AllocationParameters = AllocationParameters(),
        stabilizer: AxisStabilizerParameters = .fourDay, cache: AxisDemandCache = AxisDemandCache()
    ) -> StabilizedLayout {
        let profiles = days.map { cache.profile(for: $0, parameters: parameters, textScale: textScale) }
        let secondary = mainIndex + 1 < days.count ? days[mainIndex + 1] : nil
        let floor = cache.floor(
            main: profiles[mainIndex], secondary: mainIndex + 1 < days.count ? profiles[mainIndex + 1] : nil,
            mainDay: days[mainIndex], secondaryDay: secondary, parameters: parameters, textScale: textScale
        )
        let plan = AxisStabilizer.plan(window: profiles, mainIndex: mainIndex, floorAxis: floor, viewport: viewport, parameters: stabilizer)
        var input = AllocationInput(
            main: days[mainIndex], secondary: secondary, viewportHeight: viewport, contentWidth: contentWidth, textScale: textScale, parameters: parameters
        )
        input.titleWidths = titleWidths
        input.fixedAxis = plan.axis
        return StabilizedLayout(plan: plan, layout: AdaptiveLayoutEngine.layout(input))
    }
}
