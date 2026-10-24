/// Sums amounts without losing how uncertain they are. Analysis can show "외식 120,000 ~ 130,000" instead of a
/// falsely precise total. Totals are kept per currency; currencies are never mixed.
public struct AmountAggregate: Hashable, Sendable {
    public let currency: String
    /// Sum of `exact` components.
    public let exactMinorUnits: Int64
    /// Sum of `inferred` components, kept apart from exact ones.
    public let inferredMinorUnits: Int64
    /// Sum of `estimated` components. Soft values only; they do not bound anything.
    public let estimatedMinorUnits: Int64
    /// The least the total can be, from hard knowledge only (exact, inferred, range minimums).
    public let lowerBoundMinorUnits: Int64
    /// The most the total can be. `nil` when any component has no hard upper limit (unknown or estimated).
    public let upperBoundMinorUnits: Int64?
    /// Components that are neither exact nor inferred.
    public let unresolvedCount: Int
    public let componentCount: Int

    /// Exact plus inferred: everything that is actually settled.
    public var knownMinorUnits: Int64 { exactMinorUnits + inferredMinorUnits }
    public var isFullyKnown: Bool { unresolvedCount == 0 }

    /// Summarizes components per currency, ordered by currency code.
    public static func summarize(_ components: [(currency: String, knowledge: AmountKnowledge)]) -> [AmountAggregate] {
        var grouped: [String: [AmountKnowledge]] = [:]
        for component in components { grouped[component.currency, default: []].append(component.knowledge) }
        return grouped.keys.sorted().map { currency in
            let items = grouped[currency] ?? []
            var exact: Int64 = 0, inferred: Int64 = 0, estimated: Int64 = 0, lower: Int64 = 0
            var upper: Int64? = 0
            var unresolved = 0
            for item in items {
                switch item {
                case let .exact(value): exact += value
                case let .inferred(value, _): inferred += value
                case let .estimated(value): estimated += value
                default: break
                }
                if !item.isKnown { unresolved += 1 }
                let bounds = item.bounds
                lower += bounds.lower
                if let current = upper, let itemUpper = bounds.upper { upper = current + itemUpper } else { upper = nil }
            }
            return AmountAggregate(
                currency: currency, exactMinorUnits: exact, inferredMinorUnits: inferred, estimatedMinorUnits: estimated,
                lowerBoundMinorUnits: lower, upperBoundMinorUnits: upper, unresolvedCount: unresolved, componentCount: items.count
            )
        }
    }
}
