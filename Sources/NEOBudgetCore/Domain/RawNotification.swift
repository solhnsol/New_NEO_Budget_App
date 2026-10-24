/// Immutable input produced by a platform adapter, a file importer, or a test.
/// No OS notification object, database entity, or parser result belongs here.
public struct RawNotification: Codable, Equatable, Sendable {
    public let id: String
    public let source: NotificationSource
    /// Stable across retries only when the source can actually provide that guarantee.
    /// Scoped to `source.applicationIdentifier`; absence must remain explicit.
    public let sourceDeliveryID: String?
    /// Time the adapter captured this input, not an inferred financial transaction time.
    public let capturedAtUnixMilliseconds: Int64
    public let notificationAtUnixMilliseconds: Int64?
    public let title: String?
    public let subtitle: String?
    public let body: String?
    /// Original serialized payload, if available. It is not normalized or executed.
    public let rawPayload: String?

    public init(
        id: String,
        source: NotificationSource,
        sourceDeliveryID: String? = nil,
        capturedAtUnixMilliseconds: Int64,
        notificationAtUnixMilliseconds: Int64? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        body: String? = nil,
        rawPayload: String? = nil
    ) {
        self.id = id
        self.source = source
        self.sourceDeliveryID = sourceDeliveryID
        self.capturedAtUnixMilliseconds = capturedAtUnixMilliseconds
        self.notificationAtUnixMilliseconds = notificationAtUnixMilliseconds
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.rawPayload = rawPayload
    }
}

/// App identifiers differ across platforms; configured aliases can later resolve providers.
/// A hint is not a verified provider or an account binding.
public struct NotificationSource: Codable, Equatable, Sendable {
    public let applicationIdentifier: String
    public let displayName: String?
    public let providerHint: String?

    public init(applicationIdentifier: String, displayName: String? = nil, providerHint: String? = nil) {
        self.applicationIdentifier = applicationIdentifier
        self.displayName = displayName
        self.providerHint = providerHint
    }
}
