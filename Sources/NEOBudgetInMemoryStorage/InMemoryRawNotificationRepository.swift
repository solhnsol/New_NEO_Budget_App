import NEOBudgetCore

/// Non-durable reference implementation for tests and local experiments.
/// A copy is an independent snapshot; this value is not a cross-process shared store.
public struct InMemoryRawNotificationRepository: RawNotificationRepository {
    private var notifications: [String: RawNotification] = [:]

    public init() {}

    public func notification(withID id: String) -> RawNotification? {
        notifications[id]
    }

    public mutating func insert(_ notification: RawNotification) throws -> RawNotificationInsertion {
        if let stored = notifications[notification.id] {
            guard stored == notification else {
                throw RawNotificationStorageError.conflictingRecord(id: notification.id)
            }
            return .alreadyStored
        }
        notifications[notification.id] = notification
        return .inserted
    }
}
