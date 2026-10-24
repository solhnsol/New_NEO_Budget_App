import Foundation
import NEOBudgetCore

/// A transaction source whose contents are replaced as new notifications reach the ledger, so a command service made
/// once keeps seeing the current ledger. Reads and replacements are serialized by a lock.
public final class UpdatableTransactionSource: TransactionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: any TransactionSource

    public init(_ initial: any TransactionSource) {
        current = initial
    }

    public func replace(with source: any TransactionSource) {
        lock.lock()
        current = source
        lock.unlock()
    }

    public func transaction(_ id: LedgerEntryID) -> TransactionMarker? { read().transaction(id) }

    public func transactions(withIDs ids: Set<LedgerEntryID>) -> [TransactionMarker] { read().transactions(withIDs: ids) }

    public func transactions(occurringFrom from: Int64, to: Int64) -> [TransactionMarker] {
        read().transactions(occurringFrom: from, to: to)
    }

    private func read() -> any TransactionSource {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}
