import NEOBudgetCalendar
import NEOBudgetCore

/// Non-durable reference implementation. Validation runs on a copy; state and revision change only after
/// every change succeeded, so a failed commit is invisible to callers.
public struct InMemoryLifeRepository: LifeRepository {
    private var state: LifeState
    private var revision: UInt64 = 0

    public init(initialState: LifeState = .empty) {
        state = initialState
    }

    public func snapshot() throws -> LifeSnapshot {
        LifeSnapshot(revision: revision, state: state)
    }

    public mutating func commit(_ changes: [LifeChange], expectedRevision: UInt64) throws -> LifeCommitResult {
        guard expectedRevision == revision else {
            throw LifeStorageError.staleRevision(expected: expectedRevision, actual: revision)
        }
        guard revision < UInt64.max else { throw LifeStorageError.revisionOverflow }
        let next: LifeState
        do {
            next = try state.applying(changes)
        } catch let error as LifeValidationError {
            throw LifeStorageError.invalid(error)
        }
        state = next
        revision += 1
        return .committed(revision: revision)
    }
}

/// A fixed list of markers, for tests and local experiments.
public struct InMemoryTransactionSource: TransactionSource {
    private let markers: [LedgerEntryID: TransactionMarker]

    public init(_ markers: [TransactionMarker] = []) {
        self.markers = Dictionary(markers.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
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
