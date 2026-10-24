import CoreGraphics
import NEOBudgetCalendar

/// What kind of information a claim protects. The letters are the product's A ... F.
enum TemporalClaimKind: Int, Sendable, CaseIterable {
    /// A, B: a short event is identified by its title.
    case eventIdentity
    /// A, C: the start and the end of a long event are readable; its middle asks for nothing.
    case longEventEdge
    /// E: transactions inside an event have rows of their own.
    case insideTransaction
    /// D: two neighbouring independent transactions are far enough apart to both be written.
    case transactionLine
    /// P0: an event is never invisible, whatever day it is on.
    case presence
}

/// A stretch of time that must be at least `need` points tall for something to be shown in the form that asks for. The height is that of the
/// stretch on the partition (the y of its end minus the y of its start), not a guess about text.
struct TemporalClaim: Equatable, Sendable {
    let kind: TemporalClaimKind
    let start: Int
    let end: Int
    let need: CGFloat
    let id: String
    var length: Int { max(1, end - start) }
}

/// One day's static demand: what it would ask of the time axis, computed once from the day's content and reused by every window that
/// contains the day. Independent of where the day is in a window (the day weights come in when windows are put together).
struct TemporalDemandProfile: Equatable, Sendable {
    let day: LocalDate
    /// Identifies the content, the sizes and the text scale. A different one is a different profile.
    let signature: Int
    let claims: [TemporalClaim]
    /// Items per minute of the day (1440 values): event edges, independent transactions and inside transactions, each with its own mass.
    let mass: [Double]
    /// The minutes at which an event starts or ends (for the small reward for a boundary that lands on one).
    let eventEdges: [Int]
    let eventCount: Int
    let transactionCount: Int
    var isEmpty: Bool { eventCount == 0 && transactionCount == 0 }

    static func make(_ day: AllocationDay, parameters: TemporalGridParameters) -> TemporalDemandProfile {
        let weights = parameters.weights
        let scale = max(0.5, parameters.textScale)
        let heights = AdaptiveLayoutEngine.demandHeights(of: day, parameters: parameters.allocation, textScale: scale)
        let metrics = EventPresentation.Metrics.standard(scale: scale)
        var claims: [TemporalClaim] = []
        var mass = [Double](repeating: 0, count: TemporalGridPartition.minutesPerDay)
        var edges: [Int] = []
        var transactionCount = 0
        func add(_ minute: Int, _ value: Double) { mass[min(max(minute, 0), mass.count - 1)] += value }

        for event in day.events.sorted(by: { ($0.startMinute, $0.endMinute, $0.id) < ($1.startMinute, $1.endMinute, $1.id) }) {
            let start = event.startMinute, end = event.effectiveEnd
            // The height at which `EventPresentation` writes the whole title: the renderer's own threshold, not the engine's estimate of a
            // title row (which is smaller, so a claim met by it would still draw a half-faded title).
            let title = metrics.titleNeed + metrics.ramp
            edges.append(start)
            edges.append(end)
            // P0: every event keeps at least a line.
            claims.append(TemporalClaim(kind: .presence, start: start, end: end, need: metrics.lineHeight, id: event.id))
            if end - start <= weights.longEventMinutes {
                claims.append(TemporalClaim(kind: .eventIdentity, start: start, end: end, need: title, id: event.id))
                add(start, 1)
            } else {
                // A long event is not given resolution for being long. Its two edges are where its information is.
                let window = min(weights.edgeWindowMinutes, (end - start) / 2)
                claims.append(TemporalClaim(kind: .longEventEdge, start: start, end: start + window, need: title, id: event.id + "#start"))
                claims.append(TemporalClaim(kind: .longEventEdge, start: end - window, end: end, need: title, id: event.id + "#end"))
                add(start, 1)
                add(end - 1, 1)
            }
            let inside = event.insideRange.map(\.minute).sorted()
            for minute in inside { add(minute, weights.insideTransactionMass) }
            for (first, second) in zip(inside, inside.dropFirst()) where second > first {
                claims.append(TemporalClaim(kind: .insideTransaction, start: first, end: second, need: metrics.rowHeight, id: "\(event.id)@\(first)"))
            }
            transactionCount += event.linked.count
            // A linked transaction outside the event's time is a line of its own.
            for outside in event.outsideRange where outside.dayOffset == 0 { add(outside.minute, weights.independentTransactionMass) }
        }
        for transaction in day.transactions where transaction.dayOffset == 0 { add(transaction.minute, weights.independentTransactionMass) }
        transactionCount += day.transactions.count

        for link in heights.mergeableLinks where link.second > link.first {
            claims.append(TemporalClaim(kind: .transactionLine, start: link.first, end: link.second, need: heights.pitch, id: link.key))
        }
        claims.sort { ($0.start, $0.end, $0.kind.rawValue, $0.id) < ($1.start, $1.end, $1.kind.rawValue, $1.id) }
        return TemporalDemandProfile(
            day: day.day, signature: signature(of: day, parameters: parameters), claims: claims, mass: mass,
            eventEdges: edges.sorted(), eventCount: day.events.count, transactionCount: transactionCount
        )
    }

    /// What the profile depends on: the day's content and the sizes behind its claims. Not the slot count, not the day weights.
    static func signature(of day: AllocationDay, parameters: TemporalGridParameters) -> Int {
        var hasher = Hasher()
        hasher.combine(day.day.daysSinceUnixEpoch)
        hasher.combine(day.totalMinutes)
        for event in day.events { hasher.combine(event) }
        for transaction in day.transactions { hasher.combine(transaction) }
        let a = parameters.allocation
        for value in [a.titleRow, a.linkedRow, a.transactionRow, a.lineGap, a.overflowCard, a.browseScale, parameters.textScale] {
            hasher.combine(Int((value * 100).rounded()))
        }
        hasher.combine(a.padding); hasher.combine(a.longEventMinutes); hasher.combine(a.transactionWindowMinutes)
        hasher.combine(a.minimumFoldMinutes); hasher.combine(a.previewLinkedRows)
        hasher.combine(parameters.weights.longEventMinutes); hasher.combine(parameters.weights.edgeWindowMinutes)
        hasher.combine(Int(parameters.weights.independentTransactionMass * 1000)); hasher.combine(Int(parameters.weights.insideTransactionMass * 1000))
        return hasher.finalize()
    }

    /// Bytes the profile holds, roughly (for the cache report).
    var approximateBytes: Int { mass.count * 8 + claims.count * 64 + eventEdges.count * 8 }
}
