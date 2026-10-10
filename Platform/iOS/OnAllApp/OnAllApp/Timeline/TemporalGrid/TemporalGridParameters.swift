import CoreGraphics

/// Every number the temporal grid's planner reads, in one place. Nothing in the planner has a constant of its own.
///
/// Costs are in one unit: 1.0 is one claim of the main day that gets none of the room it asks for. Day weights multiply only the claims that
/// are *preferences* (how readable a day's items are). The claim that every event keeps at least a visible line (`presence`) is not
/// multiplied by any day weight: a quiet neighbour day does not get its events made invisible, and a busy one does not get more than a line.
struct TemporalGridParameters: Equatable, Sendable {
    /// How many equal-height cells the day is cut into. 10, 12 and 16 are supported; 12 is the prototype's default, not a product decision.
    var slotCount = 12
    /// Candidate boundaries are multiples of this many minutes. It is the resolution of the search only: a time of an event or a transaction
    /// is never rounded to it. Must divide 60.
    var candidateStepMinutes = 5
    var minSlotMinutes = 10
    var maxSlotMinutes = 8 * 60
    /// The height the planner assumes (the viewport at zoom 1). Zooming only scales it, and the partition is not planned again.
    var viewportHeight: CGFloat = 640
    var textScale: CGFloat = 1

    /// Weights of D-1, D, D+1 and D+2 (the existing four-day smoothing). D is the main day.
    var dayWeights: [Double] = [0.25, 1.0, 0.8, 0.25]
    var weights = Weights()
    var roundness = Roundness()
    var imbalance = Imbalance()
    /// The sizes the engine's own demand calculation and the event presentation use.
    var allocation = AllocationParameters()

    struct Weights: Equatable, Sendable {
        /// A short event gets room for its title (P1 for the main day).
        var eventIdentity = 1.0
        /// A long event gets room for its title at its start and at its end; its middle asks for nothing.
        var longEventEdge = 0.6
        /// Events up to this long are identified as a whole; longer ones by their two edges.
        var longEventMinutes = 120
        /// How much of a long event's start and end is asked to be readable.
        var edgeWindowMinutes = 30
        /// A transaction inside an event gets a row of its own, apart from the next inside transaction.
        var insideTransaction = 0.25
        /// Two neighbouring independent transactions are kept far enough apart for both to be written (P2).
        var transactionLine = 0.5
        /// Every event keeps at least the height of a line (E0). Not multiplied by a day weight.
        var presence = 0.3
        /// A cell that holds a lot of items costs more than two that share them: the sum over cells of (weighted items in it) squared.
        var crowd = 0.05
        /// A boundary exactly at the start or end of an event is slightly better than one just beside it (the grid line then says the exact time).
        var edgeAlignment = 0.04
        var independentTransactionMass = 0.5
        var insideTransactionMass = 0.25
    }

    /// The price of a boundary that is not on the hour. Small next to a claim, so a better-readable partition wins over a rounder one.
    struct Roundness: Equatable, Sendable {
        var halfHour = 0.02
        var quarterHour = 0.04
        var other = 0.07
        func cost(ofMinute minute: Int) -> Double {
            if minute % 60 == 0 { return 0 }
            if minute % 30 == 0 { return halfHour }
            if minute % 15 == 0 { return quarterHour }
            return other
        }
    }

    /// The price of a run of cells whose lengths differ a lot. The length classes are half-octaves, so one class apart is free.
    struct Imbalance: Equatable, Sendable {
        var perStepSquared = 0.01
        var capSteps = 6
    }

    func dayWeight(offsetFromMain offset: Int) -> Double {
        let index = offset + 1
        return dayWeights.indices.contains(index) ? dayWeights[index] : 0
    }

    /// A single cell's height at zoom 1.
    var slotHeight: CGFloat { viewportHeight / CGFloat(max(1, slotCount)) }

    static let `default` = TemporalGridParameters()
    static func with(slotCount: Int) -> TemporalGridParameters { var p = TemporalGridParameters(); p.slotCount = slotCount; return p }
}
