import CoreGraphics
import Foundation
import NEOBudgetCalendar

/// Remembers a day's demand profile and a window's partition, with a limit, and counts what it actually computed. A partition is found by
/// what it was computed from (the four days' contents, the sizes, the settings), so a changed day finds nothing and is planned again, and
/// nothing about how the user got there (the order of days visited, an animation, a zoom) is part of the key.
final class TemporalGridStore {
    let limit: Int
    private(set) var planRuns = 0
    private(set) var profileBuilds = 0
    private(set) var hits = 0
    private(set) var misses = 0
    private var profiles: [Int: TemporalDemandProfile] = [:]
    private var plans: [Int: TemporalGridPlan] = [:]
    private var profileOrder: [Int] = []
    private var planOrder: [Int] = []

    init(limit: Int = 32) { self.limit = max(1, limit) }

    var entryCount: Int { profiles.count + plans.count }
    var approximateBytes: Int { profiles.values.reduce(0) { $0 + $1.approximateBytes } + plans.count * 512 }
    var hitRate: Double { hits + misses == 0 ? 0 : Double(hits) / Double(hits + misses) }
    func resetCounters() { planRuns = 0; profileBuilds = 0; hits = 0; misses = 0 }

    func profile(for day: AllocationDay, parameters: TemporalGridParameters) -> TemporalDemandProfile {
        let key = TemporalDemandProfile.signature(of: day, parameters: parameters)
        if let found = profiles[key] { hits += 1; return found }
        misses += 1
        profileBuilds += 1
        let made = TemporalDemandProfile.make(day, parameters: parameters)
        profiles[key] = made
        profileOrder.append(key)
        while profileOrder.count > limit { profiles[profileOrder.removeFirst()] = nil }
        return made
    }

    func plan(window: TemporalWindow, parameters: TemporalGridParameters) -> TemporalGridPlan {
        let found = window.days.map { profile(for: $0, parameters: parameters) }
        let key = Self.key(profiles: found, mainIndex: window.mainIndex, parameters: parameters)
        if let cached = plans[key] { hits += 1; return cached }
        misses += 1
        planRuns += 1
        let made = TemporalGridPlanner.plan(profiles: found, mainIndex: window.mainIndex, parameters: parameters)
        plans[key] = made
        planOrder.append(key)
        while planOrder.count > limit { plans[planOrder.removeFirst()] = nil }
        return made
    }

    /// Everything that can change a plan, and nothing else.
    static func key(profiles: [TemporalDemandProfile], mainIndex: Int, parameters p: TemporalGridParameters) -> Int {
        var hasher = Hasher()
        hasher.combine(mainIndex)
        for profile in profiles { hasher.combine(profile.signature) }
        hasher.combine(p.slotCount); hasher.combine(p.candidateStepMinutes); hasher.combine(p.minSlotMinutes); hasher.combine(p.maxSlotMinutes)
        hasher.combine(Int((p.viewportHeight * 100).rounded())); hasher.combine(Int((p.textScale * 100).rounded()))
        for weight in p.dayWeights { hasher.combine(Int((weight * 1000).rounded())) }
        let w = p.weights
        for value in [w.eventIdentity, w.longEventEdge, w.insideTransaction, w.transactionLine, w.presence, w.crowd, w.edgeAlignment] {
            hasher.combine(Int((value * 10_000).rounded()))
        }
        for value in [p.roundness.halfHour, p.roundness.quarterHour, p.roundness.other, p.imbalance.perStepSquared] { hasher.combine(Int((value * 10_000).rounded())) }
        hasher.combine(p.imbalance.capSteps)
        return hasher.finalize()
    }
}
