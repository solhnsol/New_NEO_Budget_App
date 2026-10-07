/// Something whose amount can be part of a group constraint.
public enum AmountMemberRef: Codable, Hashable, Comparable, Sendable {
    case obligation(ObligationID)
    case allocation(AllocationID)

    public static func < (lhs: AmountMemberRef, rhs: AmountMemberRef) -> Bool {
        switch (lhs, rhs) {
        case let (.obligation(a), .obligation(b)): return a < b
        case let (.allocation(a), .allocation(b)): return a < b
        case (.obligation, .allocation): return true
        case (.allocation, .obligation): return false
        }
    }
}

public enum AmountGroupError: Error, Hashable, Sendable {
    case tooFewMembers
    case duplicateMember(AmountMemberRef)
    case totalNotKnown
    case currencyMismatch
}

/// "These amounts add up to this total", kept as a constraint instead of being split arbitrarily.
///
/// Example: a date settlement of 31,000 won whose lunch, cafe, and taxi shares are each unknown. The only
/// fact is `lunch + cafe + taxi = 31,000`. The group preserves that fact so that later evidence can narrow
/// the members or resolve one of them, while nothing is ever assigned by guessing. "복합" is therefore an
/// unresolved allocation state, never a category.
public struct AmountGroup: Codable, Hashable, Sendable {
    public let id: AmountGroupID
    public let currency: String
    /// The group total. Must be settled knowledge: exact (user-confirmed or observed) or inferred.
    public let total: AmountEntry
    public let members: [AmountMemberRef]
    public let createdAtUnixMilliseconds: Int64

    public init(id: AmountGroupID, total: AmountEntry, members: [AmountMemberRef], createdAtUnixMilliseconds: Int64) throws {
        guard members.count >= 2 else { throw AmountGroupError.tooFewMembers }
        var seen = Set<AmountMemberRef>()
        for member in members where !seen.insert(member).inserted { throw AmountGroupError.duplicateMember(member) }
        guard total.knowledge.isKnown else { throw AmountGroupError.totalNotKnown }
        self.id = id
        self.currency = total.currency
        self.total = total
        self.members = members.sorted()
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey { case id, total, members, createdAtUnixMilliseconds }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(AmountGroupID.self, forKey: .id),
            total: values.decode(AmountEntry.self, forKey: .total),
            members: values.decode([AmountMemberRef].self, forKey: .members),
            createdAtUnixMilliseconds: values.decode(Int64.self, forKey: .createdAtUnixMilliseconds)
        )
    }

    public var totalMinorUnits: Int64 { total.knowledge.knownValue ?? 0 }
}

public enum AmountGroupContradiction: Hashable, Sendable {
    /// All members are known but their sum is not the total.
    case knownSumMismatch
    case knownSumExceedsTotal
    /// The members' hard bounds make the total unreachable.
    case boundsCannotReachTotal
    case solutionOutsideMemberBounds(AmountMemberRef)
}

public struct UnderdeterminedGroup: Hashable, Sendable {
    public let unresolved: [AmountMemberRef]
    /// What is left of the total after the settled members, to be shared by the unresolved ones.
    public let remainingMinorUnits: Int64
    /// The tightest range each unresolved member can still take, derived only from the constraint.
    public let narrowed: [AmountMemberRef: AmountBounds]
}

public enum AmountGroupAnalysis: Equatable, Sendable {
    /// Every member is settled and they add up to the total.
    case satisfied
    /// Exactly one member is unresolved, so its value is forced. The only case automation may promote.
    case uniqueSolution(member: AmountMemberRef, minorUnits: Int64)
    /// Several members are unresolved. Many solutions fit; none may be chosen automatically.
    case underdetermined(UnderdeterminedGroup)
    case contradiction(AmountGroupContradiction)
}

/// Pure analysis of a group constraint against what is currently known about its members.
public enum AmountGroupSolver {
    public static func analyze(totalMinorUnits total: Int64, members: [AmountMemberRef: AmountKnowledge]) -> AmountGroupAnalysis {
        let known = members.compactMapValues { $0.knownValue }
        let unresolved = members.keys.filter { known[$0] == nil }.sorted()
        let knownSum = known.values.reduce(0, +)

        if unresolved.isEmpty {
            return knownSum == total ? .satisfied : .contradiction(.knownSumMismatch)
        }
        if knownSum > total { return .contradiction(.knownSumExceedsTotal) }

        let remaining = total - knownSum

        // One unresolved member: the constraint forces its value, which must be a real (positive) amount that
        // fits whatever is already known about it.
        if unresolved.count == 1, let only = unresolved.first {
            guard remaining >= 1 else { return .contradiction(.boundsCannotReachTotal) }
            guard members[only]?.bounds.contains(remaining) ?? false else {
                return .contradiction(.solutionOutsideMemberBounds(only))
            }
            return .uniqueSolution(member: only, minorUnits: remaining)
        }
        // Every unresolved member is a real amount, so each is at least 1 and at least its own lower bound.
        func lowestPossible(_ ref: AmountMemberRef) -> Int64 { max(members[ref]?.bounds.lower ?? 0, 1) }
        func highestPossible(_ ref: AmountMemberRef) -> Int64? { members[ref]?.bounds.upper }

        let lowestSum = unresolved.map(lowestPossible).reduce(0, +)
        if lowestSum > remaining { return .contradiction(.boundsCannotReachTotal) }
        let ceilings = unresolved.map(highestPossible)
        if !ceilings.contains(where: { $0 == nil }), ceilings.compactMap({ $0 }).reduce(0, +) < remaining {
            return .contradiction(.boundsCannotReachTotal)
        }

        var narrowed: [AmountMemberRef: AmountBounds] = [:]
        for ref in unresolved {
            let others = unresolved.filter { $0 != ref }
            var lower = lowestPossible(ref)
            let otherCeilings = others.map(highestPossible)
            if !otherCeilings.contains(where: { $0 == nil }) {
                lower = max(lower, remaining - otherCeilings.compactMap { $0 }.reduce(0, +))
            }
            var upper = remaining - others.map(lowestPossible).reduce(0, +)
            if let own = highestPossible(ref) { upper = min(upper, own) }
            narrowed[ref] = AmountBounds(lower: lower, upper: upper)
        }
        return .underdetermined(UnderdeterminedGroup(unresolved: unresolved, remainingMinorUnits: remaining, narrowed: narrowed))
    }
}
