import NEOBudgetCore

public struct LifeSnapshot: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let state: LifeState

    public init(revision: UInt64, state: LifeState) {
        self.revision = revision
        self.state = state
    }
}

public enum LifeCommitResult: Equatable, Sendable {
    case committed(revision: UInt64)
}

public enum LifeStorageError: Error, Equatable, Sendable {
    case staleRevision(expected: UInt64, actual: UInt64)
    case invalid(LifeValidationError)
    case revisionOverflow
}

/// Atomic storage boundary for OnAll-owned life state, in the same style as `LedgerRepository`: a failed
/// commit leaves both the revision and the state unchanged.
public protocol LifeRepository: Sendable {
    func snapshot() throws -> LifeSnapshot
    mutating func commit(_ changes: [LifeChange], expectedRevision: UInt64) throws -> LifeCommitResult
}

/// Read-only view of transactions for the calendar side. Calendar code never writes to the ledger.
public enum TransactionFlow: String, Codable, Hashable, Sendable {
    case spend
    case refund
}

public enum TimePrecision: String, Codable, Hashable, Sendable {
    case exact
    /// The recorded time is when something was observed (for example a notification), not necessarily when
    /// the payment happened.
    case approximate
}

/// A transaction as the calendar and timeline need to see it.
public struct TransactionMarker: Codable, Hashable, Sendable {
    public let id: LedgerEntryID
    public let occurredAtUnixMilliseconds: Int64
    /// Always a positive magnitude; `flow` carries the direction.
    public let amount: Money
    public let flow: TransactionFlow
    public let title: String?
    public let timePrecision: TimePrecision

    public init(
        id: LedgerEntryID,
        occurredAtUnixMilliseconds: Int64,
        amount: Money,
        flow: TransactionFlow,
        title: String? = nil,
        timePrecision: TimePrecision = .approximate
    ) {
        self.id = id
        self.occurredAtUnixMilliseconds = occurredAtUnixMilliseconds
        self.amount = amount
        self.flow = flow
        self.title = title
        self.timePrecision = timePrecision
    }

    /// Spend counts positive and refund negative, so sums are net spending.
    public var signedMinorUnits: Int64 {
        flow == .spend ? amount.minorUnits : -amount.minorUnits
    }
}

public protocol TransactionSource: Sendable {
    func transaction(_ id: LedgerEntryID) -> TransactionMarker?
    func transactions(withIDs ids: Set<LedgerEntryID>) -> [TransactionMarker]
    /// Transactions with `from <= occurredAt < to`.
    func transactions(occurringFrom from: Int64, to: Int64) -> [TransactionMarker]
}

/// Reads markers from a ledger snapshot through `LedgerTimelineProjection`, the single place that decides which ledger
/// entries are consumption: only expenses and refunds, never income, transfers or card-bill payments.
public struct LedgerTransactionSource: TransactionSource {
    private let markers: [LedgerEntryID: TransactionMarker]

    /// `timePrecision` applies to every entry; use `init(processing:)` to take it per entry from the promoted candidates.
    public init(
        snapshot: LedgerSnapshot,
        titles: [LedgerEntryID: String] = [:],
        timePrecision: TimePrecision = .approximate
    ) {
        let precisions = Dictionary(snapshot.entries.map { ($0.id, timePrecision) }, uniquingKeysWith: { first, _ in first })
        self.init(markers: LedgerTimelineProjection.transactions(
            in: snapshot, details: LedgerTimelineProjection.EntryDetails(titles: titles, timePrecisions: precisions)
        ))
    }

    /// Titles and per-entry time precision come from the promoted candidates.
    public init(processing snapshot: CandidateProcessingSnapshot) {
        self.init(markers: LedgerTimelineProjection.transactions(in: snapshot))
    }

    private init(markers: [TransactionMarker]) {
        self.markers = Dictionary(markers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func transaction(_ id: LedgerEntryID) -> TransactionMarker? { markers[id] }

    public func transactions(withIDs ids: Set<LedgerEntryID>) -> [TransactionMarker] {
        ids.compactMap { markers[$0] }.sorted(by: Self.order)
    }

    public func transactions(occurringFrom from: Int64, to: Int64) -> [TransactionMarker] {
        markers.values.filter { $0.occurredAtUnixMilliseconds >= from && $0.occurredAtUnixMilliseconds < to }.sorted(by: Self.order)
    }

    private static func order(_ lhs: TransactionMarker, _ rhs: TransactionMarker) -> Bool {
        (lhs.occurredAtUnixMilliseconds, lhs.id.rawValue) < (rhs.occurredAtUnixMilliseconds, rhs.id.rawValue)
    }
}
