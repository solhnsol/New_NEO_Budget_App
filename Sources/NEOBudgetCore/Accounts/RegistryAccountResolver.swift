/// Adapts the registry to the existing `TransactionAccountResolver` contract without changing it.
/// Parsers still never see accounts: evidence is read from the raw notification by a separate extractor and
/// looked up by `rawNotificationID`.
public struct RegistryAccountResolver: TransactionAccountResolver {
    public let registry: AccountRegistry
    private let evidenceForNotification: @Sendable (String) -> AccountEvidence?

    public init(registry: AccountRegistry, evidenceForNotification: @escaping @Sendable (String) -> AccountEvidence?) {
        self.registry = registry
        self.evidenceForNotification = evidenceForNotification
    }

    public func resolve(_ draft: TransactionCandidateDraft) throws -> AccountResolution {
        guard let evidence = evidenceForNotification(draft.rawNotificationID) else { return .unresolved(.unboundSource) }
        switch registry.resolve(evidence) {
        case let .resolved(binding, _): return .resolved(binding)
        case .newCandidate: return .unresolved(.unknownAccount)
        case .needsConfirmation: return .unresolved(.unboundSource)
        }
    }
}
