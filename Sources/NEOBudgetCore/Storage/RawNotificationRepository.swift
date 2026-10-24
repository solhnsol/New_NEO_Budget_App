/// Storage port for original input records. Implementations own their persistence details.
///
/// Insertion must atomically preserve an existing record with the same ID:
/// identical content returns `alreadyStored`; conflicting content throws without changing it.
/// This is record-level idempotency, not financial-transaction deduplication.
/// Calls must be serialized by the owning application layer unless an implementation
/// explicitly provides a stronger concurrency guarantee.
public protocol RawNotificationRepository {
    func notification(withID id: String) throws -> RawNotification?
    mutating func insert(_ notification: RawNotification) throws -> RawNotificationInsertion
}

public enum RawNotificationInsertion: Equatable, Sendable {
    case inserted
    case alreadyStored
}

public enum RawNotificationStorageError: Error, Equatable, Sendable {
    case conflictingRecord(id: String)
}
