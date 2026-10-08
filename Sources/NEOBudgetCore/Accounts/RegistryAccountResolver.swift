/// Adapts the registry to the existing `TransactionAccountResolver` contract without changing it.
/// Parsers still never see accounts: hints are read from the raw notification by a separate extractor and
/// looked up by `rawNotificationID`.
public struct RegistryAccountResolver: TransactionAccountResolver {
    public let registry: AccountRegistry
    private let hintsForNotification: @Sendable (String) -> AccountHints?

    public init(registry: AccountRegistry, hintsForNotification: @escaping @Sendable (String) -> AccountHints?) {
        self.registry = registry
        self.hintsForNotification = hintsForNotification
    }

    public func resolve(_ draft: TransactionCandidateDraft) throws -> AccountResolution {
        guard let hints = hintsForNotification(draft.rawNotificationID) else { return .unresolved(.unboundSource) }
        switch registry.resolve(hints) {
        case let .resolved(binding, _): return .resolved(binding)
        case .newCandidate: return .unresolved(.unknownAccount)
        case .needsConfirmation: return .unresolved(.unboundSource)
        }
    }
}
