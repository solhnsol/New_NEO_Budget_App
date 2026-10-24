import CoreGraphics
import Foundation
import NEOBudgetCalendar

/// The days a partition is planned for: the main day D and its neighbours, as in the four-day smoothing (D-1, D, D+1, D+2).
struct TemporalWindow {
    let days: [AllocationDay]
    let mainIndex: Int
}

/// A claim of a window with its weight. `preference` claims are multiplied by their day's weight; `presence` is not.
struct WeightedTemporalClaim: Equatable, Sendable {
    let claim: TemporalClaim
    let weight: Double
    let dayOffset: Int
}

/// What a plan cost, split by what it paid for. `modelCost` is the number the search minimised (claims are attributed to cells in
/// proportion to the time they overlap); `exactClaimCost` charges the same claims by their true height on the finished partition.
/// The difference between the two is the limit of the approximation.
struct TemporalPlanBreakdown: Equatable, Sendable {
    var claimCostByKind: [TemporalClaimKind: Double] = [:]
    var crowd = 0.0
    var roundness = 0.0
    var imbalance = 0.0
    var alignmentReward = 0.0
    var modelCost = 0.0
    var exactClaimCost = 0.0
}

struct TemporalGridPlan: Equatable, Sendable {
    let partition: TemporalGridPartition
    let breakdown: TemporalPlanBreakdown
    /// The constraints had no solution (`slotCount * minSlot > 1440` or `slotCount * maxSlot < 1440`) and were relaxed to the nearest feasible.
    let constraintsRelaxed: Bool
    let effectiveMinSlotMinutes: Int
    let effectiveMaxSlotMinutes: Int
    let claimCount: Int
    /// Claims that cannot be met even at the tallest cell (`need / length` beyond what the shortest cell gives); they take no part in the search.
    let unservableClaimCount: Int
    let candidateCount: Int
}

/// Cuts the day into `slotCount` cells of equal height and chooses how much time each stands for.
///
/// A dynamic programme over the candidate boundaries (multiples of `candidateStepMinutes`) and the length class of the last cell:
/// `cost[k][j][c]` is the least cost of covering 0 ... j with k cells whose last one is in length class c. The cost of a cell is looked up
/// in a table computed once per plan (cell cost depends only on where it starts and how long it is), and the price of a change of length
/// class is folded in by taking, for every next class, the best earlier class first; so the work is `slotCount * positions * (classes² +
/// lengths)`, about a million steps, never an enumeration of partitions. Ties resolve in a fixed order, so the same input gives the same plan.
///
/// Which cells are good is decided by claims (see `TemporalDemandProfile`): the height a stretch of time gets must reach what the thing in it
/// needs. A claim that spans cells is charged to each cell in proportion to its overlap using that cell's scale, which over-charges a claim
/// that straddles a boundary between a tall and a short cell (the cost of `max(0, ·)` is convex); the breakdown reports both numbers.
enum TemporalGridPlanner {
    static let lengthClasses = 12

    static func plan(window: TemporalWindow, parameters: TemporalGridParameters) -> TemporalGridPlan {
        let profiles = window.days.map { TemporalDemandProfile.make($0, parameters: parameters) }
        return plan(profiles: profiles, mainIndex: window.mainIndex, parameters: parameters)
    }

    static func plan(profiles: [TemporalDemandProfile], mainIndex: Int, parameters: TemporalGridParameters) -> TemporalGridPlan {
        let weighted = weightedClaims(profiles: profiles, mainIndex: mainIndex, parameters: parameters)
        let mass = windowMass(profiles: profiles, mainIndex: mainIndex, parameters: parameters)
        let alignment = alignmentRewards(profiles: profiles, mainIndex: mainIndex, parameters: parameters)
        return search(claims: weighted, mass: mass, alignment: alignment, parameters: parameters)
    }

    // MARK: Window

    static func weightedClaims(profiles: [TemporalDemandProfile], mainIndex: Int, parameters: TemporalGridParameters) -> [WeightedTemporalClaim] {
        var result: [WeightedTemporalClaim] = []
        let w = parameters.weights
        for (index, profile) in profiles.enumerated() {
            let offset = index - mainIndex
            let dayWeight = parameters.dayWeight(offsetFromMain: offset)
            guard dayWeight > 0 else { continue }
            for claim in profile.claims {
                let base: Double
                var weight: Double
                switch claim.kind {
                case .eventIdentity: base = w.eventIdentity; weight = base * dayWeight
                case .longEventEdge: base = w.longEventEdge; weight = base * dayWeight
                case .insideTransaction: base = w.insideTransaction; weight = base * dayWeight
                case .transactionLine: base = w.transactionLine; weight = base * dayWeight
                // Never multiplied by a day weight: no day's events are allowed to vanish to make room for another's.
                case .presence: weight = w.presence
                }
                result.append(WeightedTemporalClaim(claim: claim, weight: weight, dayOffset: offset))
            }
        }
        return result
    }

    static func windowMass(profiles: [TemporalDemandProfile], mainIndex: Int, parameters: TemporalGridParameters) -> [Double] {
        var mass = [Double](repeating: 0, count: TemporalGridPartition.minutesPerDay)
        for (index, profile) in profiles.enumerated() {
            let weight = parameters.dayWeight(offsetFromMain: index - mainIndex)
            guard weight > 0 else { continue }
            for minute in 0..<mass.count where profile.mass[minute] != 0 { mass[minute] += weight * profile.mass[minute] }
        }
        return mass
    }

    static func alignmentRewards(profiles: [TemporalDemandProfile], mainIndex: Int, parameters: TemporalGridParameters) -> [Double] {
        var reward = [Double](repeating: 0, count: TemporalGridPartition.minutesPerDay + 1)
        for (index, profile) in profiles.enumerated() {
            let weight = parameters.dayWeight(offsetFromMain: index - mainIndex)
            guard weight > 0 else { continue }
            for edge in profile.eventEdges where edge > 0 && edge < TemporalGridPartition.minutesPerDay {
                reward[edge] += parameters.weights.edgeAlignment * weight
            }
        }
        return reward
    }

    // MARK: Search

    /// Length class of a cell: half-octaves above the minimum, so 10 min is 0 and 8 h is 11.
    static func lengthClass(minutes: Int, minimum: Int) -> Int {
        let ratio = Double(max(minutes, 1)) / Double(max(minimum, 1))
        return min(lengthClasses - 1, max(0, Int((log2(max(ratio, 1)) * 2).rounded())))
    }

    static func search(claims: [WeightedTemporalClaim], mass: [Double], alignment: [Double], parameters: TemporalGridParameters) -> TemporalGridPlan {
        let day = TemporalGridPartition.minutesPerDay
        var step = max(1, parameters.candidateStepMinutes)
        if 60 % step != 0 { step = 5 }
        let n = max(1, parameters.slotCount)
        let positions = day / step
        var minSteps = max(1, Int((Double(parameters.minSlotMinutes) / Double(step)).rounded(.up)))
        var maxSteps = max(minSteps, parameters.maxSlotMinutes / step)
        // No solution: relax to the nearest feasible rather than fail. A day always gets its n cells.
        var relaxed = false
        if n * minSteps > positions { minSteps = max(1, positions / n); relaxed = true }
        if n * maxSteps < positions { maxSteps = (positions + n - 1) / n; relaxed = true }
        maxSteps = max(maxSteps, minSteps)
        let stride = maxSteps + 1
        let slotHeight = parameters.slotHeight
        let maxPointsPerMinute = slotHeight / CGFloat(minSteps * step)

        // Claims no cell can meet take no part in the search (they would only add the same cost to every partition).
        var servable: [WeightedTemporalClaim] = []
        var unservable = 0
        for weighted in claims {
            if weighted.claim.need / CGFloat(weighted.claim.length) > maxPointsPerMinute {
                unservable += 1
                if parameters.keepsPartlyServableClaims { servable.append(weighted) }
            } else {
                servable.append(weighted)
            }
        }

        // cellCost[a / step * stride + steps] = cost of a cell starting at a and `steps` candidates long, from claims and crowding.
        var cellCost = [Double](repeating: 0, count: (positions + 1) * stride)
        for weighted in servable {
            let claim = weighted.claim
            let start = claim.start, end = claim.end
            let length = Double(claim.length)
            for steps in minSteps...maxSteps {
                let minutes = steps * step
                let pointsPerMinute = slotHeight / CGFloat(minutes)
                let shortfall = max(0, 1 - Double(CGFloat(length) * pointsPerMinute / claim.need))
                if shortfall == 0 { continue }
                let coefficient = weighted.weight * shortfall / length
                let lowest = max(0, start - minutes + 1)
                let first = (lowest + step - 1) / step * step
                let last = min(end - 1, day - minutes) / step * step
                guard first <= last else { continue }
                var a = first
                while a <= last {
                    let overlap = min(a + minutes, end) - max(a, start)
                    if overlap > 0 { cellCost[a / step * stride + steps] += coefficient * Double(overlap) }
                    a += step
                }
            }
        }
        var prefix = [Double](repeating: 0, count: day + 1)
        for minute in 0..<day { prefix[minute + 1] = prefix[minute] + mass[minute] }
        for index in 0..<positions {
            let a = index * step
            for steps in minSteps...maxSteps where a + steps * step <= day {
                let m = prefix[a + steps * step] - prefix[a]
                cellCost[index * stride + steps] += parameters.weights.crowd * m * m
            }
        }
        let boundaryCost: [Double] = (0...positions).map { index in
            let minute = index * step
            if index == 0 || index == positions { return 0 }
            return parameters.roundness.cost(ofMinute: minute) - alignment[minute]
        }
        let classOfSteps: [Int] = (0...maxSteps).map { $0 == 0 ? 0 : lengthClass(minutes: $0 * step, minimum: minSteps * step) }
        let classes = lengthClasses
        // The price of moving from one length class to another, looked up (never computed) inside the search.
        var imbalanceTable = [Double](repeating: 0, count: classes * classes)
        for from in 0..<classes {
            for to in 0..<classes {
                let d = min(max(0, abs(from - to) - 1), parameters.imbalance.capSteps)
                imbalanceTable[from * classes + to] = parameters.imbalance.perStepSquared * Double(d * d)
            }
        }

        // cost[k][j][c]; back[k][j][c] = the earlier boundary; fromClass[k][i][c'] = the best earlier class when the next cell is class c'.
        let infinity = Double.infinity
        let layer = (positions + 1) * classes
        var cost = [Double](repeating: infinity, count: (n + 1) * layer)
        var back = [Int32](repeating: -1, count: (n + 1) * layer)
        var fromClass = [Int8](repeating: -1, count: (n + 1) * layer)
        var bestEarlier = [Double](repeating: infinity, count: (n + 1) * layer)

        cost.withUnsafeMutableBufferPointer { cost in
        back.withUnsafeMutableBufferPointer { back in
        fromClass.withUnsafeMutableBufferPointer { fromClass in
        bestEarlier.withUnsafeMutableBufferPointer { bestEarlier in
        imbalanceTable.withUnsafeBufferPointer { imbalanceTable in
        cellCost.withUnsafeBufferPointer { cellCost in
        classOfSteps.withUnsafeBufferPointer { classOfSteps in
        boundaryCost.withUnsafeBufferPointer { boundaryCost in
            for k in 1...n {
                // Best total cost to arrive at boundary i after k-1 cells and then start a cell of class c'.
                if k >= 2 {
                    let base = (k - 1) * layer
                    // Only boundaries that k-1 cells can reach hold a finite cost.
                    for i in ((k - 1) * minSteps)...min(positions, (k - 1) * maxSteps) {
                        let row = base + i * classes
                        var reachable = false
                        for previous in 0..<classes where cost[row + previous] != infinity { reachable = true; break }
                        if !reachable { continue }
                        for next in 0..<classes {
                            var best = infinity, bestClass = -1
                            for previous in 0..<classes {
                                let value = cost[row + previous]
                                if value == infinity { continue }
                                let total = value + imbalanceTable[previous * classes + next]
                                if total < best { best = total; bestClass = previous }
                            }
                            bestEarlier[row + next] = best
                            fromClass[row + next] = Int8(bestClass)
                        }
                    }
                }
                let remaining = n - k
                let lowest = k * minSteps
                let highest = min(positions - remaining * minSteps, k * maxSteps)
                guard lowest <= highest else { continue }
                for j in lowest...highest {
                    if k == n && j != positions { continue }
                    if k < n && j == positions { continue }
                    if positions - j > remaining * maxSteps { continue }
                    let boundary = k < n ? boundaryCost[j] : 0
                    // The first cell starts at 00:00, so it is exactly j candidates long.
                    let first = k == 1 ? j : minSteps, last = k == 1 ? min(j, maxSteps) : maxSteps
                    guard first >= minSteps, first <= last else { continue }
                    for steps in first...last {
                        let i = j - steps
                        if i < 0 { break }
                        let c = classOfSteps[steps]
                        let earlier: Double
                        if k == 1 { earlier = i == 0 ? 0 : infinity } else { earlier = bestEarlier[(k - 1) * layer + i * classes + c] }
                        if earlier == infinity { continue }
                        let total = earlier + cellCost[i * stride + steps] + boundary
                        let index = k * layer + j * classes + c
                        if total < cost[index] { cost[index] = total; back[index] = Int32(i) }
                    }
                }
            }
        }}}}}}}}

        // Read the best plan back.
        var bestClass = -1
        var bestTotal = infinity
        for c in 0..<classes where cost[n * layer + positions * classes + c] < bestTotal {
            bestTotal = cost[n * layer + positions * classes + c]
            bestClass = c
        }
        guard bestClass >= 0 else {
            // Cannot happen after relaxing, but a day always gets a partition.
            let uniform = TemporalGridPartition.uniform(slotCount: n, totalHeight: parameters.viewportHeight)
            return TemporalGridPlan(
                partition: uniform, breakdown: TemporalPlanBreakdown(), constraintsRelaxed: true, effectiveMinSlotMinutes: minSteps * step,
                effectiveMaxSlotMinutes: maxSteps * step, claimCount: claims.count, unservableClaimCount: unservable, candidateCount: positions + 1
            )
        }
        var boundariesInSteps = [positions]
        var j = positions, c = bestClass, k = n
        while k >= 1 {
            let i = Int(back[k * layer + j * classes + c])
            boundariesInSteps.append(i)
            if k >= 2 { c = Int(fromClass[(k - 1) * layer + i * classes + c]) }
            j = i
            k -= 1
        }
        let minutes = boundariesInSteps.reversed().map { $0 * step }
        let partition = TemporalGridPartition(wholeMinutes: minutes, totalHeight: parameters.viewportHeight)!
        let breakdown = evaluate(
            partition: partition, claims: servable, mass: mass, alignment: alignment, parameters: parameters, modelCost: bestTotal, minimumSlotMinutes: minSteps * step
        )
        return TemporalGridPlan(
            partition: partition, breakdown: breakdown, constraintsRelaxed: relaxed, effectiveMinSlotMinutes: minSteps * step,
            effectiveMaxSlotMinutes: maxSteps * step, claimCount: claims.count, unservableClaimCount: unservable, candidateCount: positions + 1
        )
    }

    /// The cost of a finished partition, claims charged by their true height.
    static func evaluate(
        partition: TemporalGridPartition, claims: [WeightedTemporalClaim], mass: [Double], alignment: [Double], parameters: TemporalGridParameters,
        modelCost: Double = 0, minimumSlotMinutes: Int? = nil
    ) -> TemporalPlanBreakdown {
        var breakdown = TemporalPlanBreakdown()
        breakdown.modelCost = modelCost
        for weighted in claims {
            let claim = weighted.claim
            let height = partition.height(from: Double(claim.start), to: Double(claim.end))
            let shortfall = max(0, 1 - Double(height / claim.need))
            let cost = weighted.weight * shortfall
            breakdown.claimCostByKind[claim.kind, default: 0] += cost
            breakdown.exactClaimCost += cost
        }
        let bounds = partition.wholeMinuteBoundaries ?? partition.boundaries.map { Int($0.rounded()) }
        for slot in 0..<partition.slotCount {
            let a = bounds[slot], b = bounds[slot + 1]
            var m = 0.0
            for minute in a..<b { m += mass[minute] }
            breakdown.crowd += parameters.weights.crowd * m * m
        }
        var classes: [Int] = []
        let minimum = minimumSlotMinutes ?? parameters.minSlotMinutes
        for slot in 0..<partition.slotCount { classes.append(lengthClass(minutes: bounds[slot + 1] - bounds[slot], minimum: minimum)) }
        for (a, b) in zip(classes, classes.dropFirst()) {
            let d = min(max(0, abs(a - b) - 1), parameters.imbalance.capSteps)
            breakdown.imbalance += parameters.imbalance.perStepSquared * Double(d * d)
        }
        for minute in bounds.dropFirst().dropLast() {
            breakdown.roundness += parameters.roundness.cost(ofMinute: minute)
            breakdown.alignmentReward += alignment[minute]
        }
        return breakdown
    }
}
