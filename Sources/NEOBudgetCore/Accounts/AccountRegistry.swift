/// A ledger target as the user knows it. The binding is the internal identity; `displayName` is only a label
/// and can change without touching identifiers, rules, or ledger history. One target may be reached through
/// several institutions (a bank account is also what a check card settles on), so identifiers are `InstrumentKey`s.
public struct AccountProfile: Codable, Equatable, Sendable {
    public let binding: ResolvedLedgerBinding
    public internal(set) var displayName: String
    /// The institution that holds it, when the user said so. Used to find sibling accounts, never to match.
    public let institution: InstitutionID?
    public internal(set) var keys: [InstrumentKey]
    public internal(set) var isActive: Bool
}

public struct AccountCandidateID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    init(_ key: InstrumentKey) { rawValue = key.institution.rawValue + "|" + key.identifier.canonical }
}

/// An instrument the notifications mention that the user has not accepted yet. Never usable by the ledger.
public struct AccountCandidate: Codable, Equatable, Sendable {
    public enum Status: Codable, Equatable, Sendable {
        case open
        case dismissed
        case linked(ResolvedLedgerBinding)
        case confirmedAsNew(ResolvedLedgerBinding)
    }

    public static let evidenceLimit = 20

    public let id: AccountCandidateID
    public let key: InstrumentKey
    public let kind: InstrumentKind
    public internal(set) var status: Status
    public internal(set) var occurrenceCount: Int
    public internal(set) var firstSeenUnixMilliseconds: Int64
    public internal(set) var lastSeenUnixMilliseconds: Int64
    /// Raw notification IDs only, never text. Oldest first, capped.
    public internal(set) var evidenceNotificationIDs: [String]
}

public struct SourceRuleID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

/// "These messages from this app, about this kind of instrument at this institution, belong to that account."
/// Scoped by message type and instrument, never by app alone. It exists only because the user said so, and it
/// is applied only while it cannot be wrong by construction (see `AccountRegistry.resolve`).
public struct SourceRule: Codable, Equatable, Sendable {
    public let id: SourceRuleID
    public let provider: SourceProviderID
    public let types: Set<NotificationType>
    public let institution: InstitutionID
    public let kind: InstrumentKind
    public let binding: ResolvedLedgerBinding
    public let createdAtUnixMilliseconds: Int64
}

public enum ConfirmationReason: String, Codable, Hashable, Sendable {
    case unrecognizedNotificationType
    /// A message that is not an independent event for an account (a card tap whose card app sends the real one).
    case supplementaryNotification
    /// The message does not name the institution of the instrument.
    case institutionUnknown
    /// The message does not say what kind of instrument it was (an unlisted card product).
    case instrumentKindUnknown
    /// No identifier in the message and no rule from the user.
    case noIdentifier
    /// An identifier was present but too short to bind on, and no rule covers it.
    case weakIdentifier
    /// A rule exists, but another active account could have produced the same message, so the rule alone cannot tell.
    case sourceRuleHasSiblingAccounts
    case conflictingSourceRules
    case identifierMatchesMultipleAccounts
    case matchedAccountInactive
    /// The matched account is the wrong class for the instrument (a check card matched to a card liability).
    case bindingKindMismatch
    /// The other side is named in the message but is not a registered account.
    case counterpartNotRegistered
}

public enum AccountResolutionDecision: Equatable, Sendable {
    public enum Basis: Equatable, Sendable {
        case identifier(AccountIdentifier)
        case exclusiveSourceRule(SourceRuleID)
    }

    /// Safe to bind without asking: the identifier matched exactly one active account of the right class, or the
    /// user's rule is the only possible account for this message type and instrument.
    case resolved(ResolvedLedgerBinding, basis: Basis)
    /// Do not bind. `suggestion` is a hint for a confirmation prompt, never an answer.
    case needsConfirmation(ConfirmationReason, suggestion: ResolvedLedgerBinding?)
    /// A new identifier at a known institution. Recorded as an `AccountCandidate`; nothing is bound.
    case newCandidate(AccountCandidateID)
}

public enum AccountRegistryError: Error, Equatable, Sendable {
    case emptyDisplayName
    case unknownBinding(ResolvedLedgerBinding)
    case duplicateBinding(ResolvedLedgerBinding)
    case unknownCandidate(AccountCandidateID)
    case candidateNotOpen(AccountCandidateID)
    case identifierAlreadyBound(AccountIdentifier, to: ResolvedLedgerBinding)
    case weakIdentifier
    case kindMismatch
    case ruleScopeIncomplete
    case ruleAlreadyExists(SourceRuleID)
    case siblingsExist([ResolvedLedgerBinding])
    case unknownRule(SourceRuleID)
}

/// What the caller must now persist in the ledger after confirming a candidate as a new account.
public enum NewLedgerTarget: Equatable, Sendable {
    case account(Account)
    case creditInstrument(CreditInstrument)

    public var binding: ResolvedLedgerBinding {
        switch self {
        case let .account(account): .account(account.id)
        case let .creditInstrument(instrument): .creditInstrument(instrument.id)
        }
    }
}

public enum NewTargetKind: Equatable, Sendable {
    case account(Account.Kind, openingBalance: Money)
    case creditInstrument(currency: String)
}

/// Pure account identity state: which keys belong to which ledger target, which instruments are merely suspected,
/// and which explicit user rules exist. It owns no ledger data and performs no I/O.
public struct AccountRegistry: Codable, Equatable, Sendable {
    public private(set) var profiles: [AccountProfile]
    public private(set) var candidates: [AccountCandidate]
    public private(set) var rules: [SourceRule]

    public init(profiles: [AccountProfile] = [], candidates: [AccountCandidate] = [], rules: [SourceRule] = []) {
        self.profiles = profiles
        self.candidates = candidates
        self.rules = rules
    }

    public func profile(_ binding: ResolvedLedgerBinding) -> AccountProfile? {
        profiles.first { $0.binding == binding }
    }

    public func candidate(_ id: AccountCandidateID) -> AccountCandidate? {
        candidates.first { $0.id == id }
    }

    public var openCandidates: [AccountCandidate] { candidates.filter { $0.status == .open } }

    // MARK: Resolution

    /// Decides without changing anything.
    ///
    /// A strong key is authoritative: if it matches nothing it becomes a candidate and never falls through to a
    /// rule, so a new card can't be absorbed by the rule of an old one. Without a key, a rule applies only while
    /// its target is the only active account that could have produced the message. The app that sent the message
    /// plays no part in which account it is, except as one part of a rule's scope.
    public func resolve(_ evidence: AccountEvidence) -> AccountResolutionDecision {
        guard evidence.type != .unrecognized else { return .needsConfirmation(.unrecognizedNotificationType, suggestion: nil) }
        guard !evidence.type.isSupplementary else { return .needsConfirmation(.supplementaryNotification, suggestion: nil) }
        let hint = evidence.instrument
        guard let institution = hint.institution else { return .needsConfirmation(.institutionUnknown, suggestion: nil) }
        guard hint.kind != .unknown else { return .needsConfirmation(.instrumentKindUnknown, suggestion: nil) }

        if let key = hint.key {
            let matches = profiles.filter { profile in profile.keys.contains { $0.matches(key) } }
            switch matches.count {
            case 0: return .newCandidate(AccountCandidateID(key))
            case 1:
                let match = matches[0]
                guard match.isActive else { return .needsConfirmation(.matchedAccountInactive, suggestion: match.binding) }
                guard Self.fits(match.binding, hint.kind) else { return .needsConfirmation(.bindingKindMismatch, suggestion: match.binding) }
                return .resolved(match.binding, basis: .identifier(key.identifier))
            default: return .needsConfirmation(.identifierMatchesMultipleAccounts, suggestion: nil)
            }
        }

        let applicable = rules.filter {
            $0.provider == evidence.provider && $0.types.contains(evidence.type)
                && $0.institution == institution && $0.kind == hint.kind
        }
        let targets = Set(applicable.map(\.binding))
        guard let first = applicable.first else {
            return .needsConfirmation(hint.hasWeakIdentifier ? .weakIdentifier : .noIdentifier, suggestion: nil)
        }
        guard targets.count == 1 else { return .needsConfirmation(.conflictingSourceRules, suggestion: nil) }
        guard let target = profile(first.binding), target.isActive else {
            return .needsConfirmation(.matchedAccountInactive, suggestion: first.binding)
        }
        guard Self.fits(target.binding, hint.kind) else { return .needsConfirmation(.bindingKindMismatch, suggestion: target.binding) }
        if pool(institution: institution, kind: hint.kind, excluding: target.binding).isEmpty {
            return .resolved(target.binding, basis: .exclusiveSourceRule(first.id))
        }
        return .needsConfirmation(.sourceRuleHasSiblingAccounts, suggestion: target.binding)
    }

    /// The account on the other side, when the message names it. Key lookup only: a counterpart is often someone
    /// else's account, so it never creates a candidate and never uses a rule.
    public func resolveCounterpart(_ evidence: AccountEvidence) -> AccountResolutionDecision? {
        guard let counterpart = evidence.counterpart else { return nil }
        guard let key = counterpart.key else { return .needsConfirmation(.counterpartNotRegistered, suggestion: nil) }
        let matches = profiles.filter { $0.isActive && $0.keys.contains { $0.matches(key) } }
        guard matches.count == 1, let match = matches.first else {
            return .needsConfirmation(matches.isEmpty ? .counterpartNotRegistered : .identifierMatchesMultipleAccounts, suggestion: nil)
        }
        return .resolved(match.binding, basis: .identifier(key.identifier))
    }

    /// `resolve`, plus recording a new key as a candidate.
    @discardableResult
    public mutating func observe(
        _ evidence: AccountEvidence,
        notificationID: String,
        capturedAtUnixMilliseconds: Int64
    ) -> AccountResolutionDecision {
        let decision = resolve(evidence)
        guard case let .newCandidate(id) = decision, let key = evidence.instrument.key else { return decision }
        if let index = candidates.firstIndex(where: { $0.id == id }) {
            var existing = candidates[index]
            guard !existing.evidenceNotificationIDs.contains(notificationID) else { return decision }
            existing.occurrenceCount += 1
            existing.firstSeenUnixMilliseconds = min(existing.firstSeenUnixMilliseconds, capturedAtUnixMilliseconds)
            existing.lastSeenUnixMilliseconds = max(existing.lastSeenUnixMilliseconds, capturedAtUnixMilliseconds)
            if existing.evidenceNotificationIDs.count < AccountCandidate.evidenceLimit {
                existing.evidenceNotificationIDs.append(notificationID)
            }
            candidates[index] = existing
        } else {
            candidates.append(AccountCandidate(
                id: id, key: key, kind: evidence.instrument.kind, status: .open, occurrenceCount: 1,
                firstSeenUnixMilliseconds: capturedAtUnixMilliseconds, lastSeenUnixMilliseconds: capturedAtUnixMilliseconds,
                evidenceNotificationIDs: [notificationID]
            ))
        }
        return decision
    }

    // MARK: User decisions on candidates

    /// The user says this candidate is an account we already have.
    public mutating func link(_ id: AccountCandidateID, to binding: ResolvedLedgerBinding) throws {
        let (index, candidate) = try openCandidate(id)
        guard profile(binding) != nil else { throw AccountRegistryError.unknownBinding(binding) }
        guard Self.fits(binding, candidate.kind) else { throw AccountRegistryError.kindMismatch }
        try attach(candidate.key, to: binding)
        candidates[index].status = .linked(binding)
    }

    /// The user says this is a new account. Returns what the caller must create in the ledger; the registry
    /// binds the key to it. The ID comes from `makeID`, never from the name.
    public mutating func confirmAsNew(
        _ id: AccountCandidateID,
        displayName: String,
        kind: NewTargetKind,
        makeID: () -> String
    ) throws -> NewLedgerTarget {
        let (index, candidate) = try openCandidate(id)
        let target = try newTarget(displayName: displayName, kind: kind, instrument: candidate.kind, makeID: makeID)
        try register(target: target, displayName: displayName, institution: candidate.key.institution, keys: [candidate.key])
        candidates[index].status = .confirmedAsNew(target.binding)
        return target
    }

    public mutating func dismiss(_ id: AccountCandidateID) throws {
        let (index, _) = try openCandidate(id)
        candidates[index].status = .dismissed
    }

    // MARK: Direct management

    /// Brings a ledger target that already exists under registry control.
    public mutating func adopt(
        _ binding: ResolvedLedgerBinding,
        displayName: String,
        institution: InstitutionID?,
        keys: [InstrumentKey] = []
    ) throws {
        guard profile(binding) == nil else { throw AccountRegistryError.duplicateBinding(binding) }
        let name = try Self.validName(displayName)
        for key in keys { try checkAttachable(key, to: nil) }
        profiles.append(AccountProfile(binding: binding, displayName: name, institution: institution, keys: keys, isActive: true))
    }

    /// The user adds an account by hand; keys are optional and can be added later.
    public mutating func addAccount(
        displayName: String,
        institution: InstitutionID?,
        kind: NewTargetKind,
        keys: [InstrumentKey] = [],
        makeID: () -> String
    ) throws -> NewLedgerTarget {
        let target = try newTarget(displayName: displayName, kind: kind, instrument: nil, makeID: makeID)
        try register(target: target, displayName: displayName, institution: institution, keys: keys)
        return target
    }

    /// Renaming never changes the binding or anything that points at it.
    public mutating func rename(_ binding: ResolvedLedgerBinding, to displayName: String) throws {
        let name = try Self.validName(displayName)
        guard let index = profiles.firstIndex(where: { $0.binding == binding }) else {
            throw AccountRegistryError.unknownBinding(binding)
        }
        profiles[index].displayName = name
    }

    public mutating func addKey(_ key: InstrumentKey, to binding: ResolvedLedgerBinding) throws {
        try attach(key, to: binding)
    }

    public mutating func setActive(_ binding: ResolvedLedgerBinding, _ isActive: Bool) throws {
        guard let index = profiles.firstIndex(where: { $0.binding == binding }) else {
            throw AccountRegistryError.unknownBinding(binding)
        }
        profiles[index].isActive = isActive
    }

    // MARK: Explicit rules for messages without an identifier

    /// Creates the user's rule. If another active account could have produced the same message the rule would be
    /// a guess, so it needs `acknowledgingSiblings`. Even then it only suggests while the siblings exist.
    public mutating func addSourceRule(
        id: SourceRuleID,
        provider: SourceProviderID,
        types: Set<NotificationType>,
        institution: InstitutionID,
        kind: InstrumentKind,
        binding: ResolvedLedgerBinding,
        acknowledgingSiblings: Bool = false,
        createdAtUnixMilliseconds: Int64
    ) throws {
        let usable = types.filter { $0 != .unrecognized && !$0.isSupplementary }
        guard kind != .unknown, !usable.isEmpty, usable.count == types.count else { throw AccountRegistryError.ruleScopeIncomplete }
        guard profile(binding) != nil else { throw AccountRegistryError.unknownBinding(binding) }
        guard Self.fits(binding, kind) else { throw AccountRegistryError.kindMismatch }
        guard !rules.contains(where: { $0.id == id }) else { throw AccountRegistryError.ruleAlreadyExists(id) }
        let others = pool(institution: institution, kind: kind, excluding: binding)
        if !others.isEmpty, !acknowledgingSiblings { throw AccountRegistryError.siblingsExist(others.map(\.binding)) }
        rules.append(SourceRule(id: id, provider: provider, types: types, institution: institution, kind: kind,
                                binding: binding, createdAtUnixMilliseconds: createdAtUnixMilliseconds))
    }

    public mutating func removeSourceRule(_ id: SourceRuleID) throws {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { throw AccountRegistryError.unknownRule(id) }
        rules.remove(at: index)
    }

    // MARK: Internals

    /// Active accounts of the right class that sit at the institution or are reached through it.
    private func pool(institution: InstitutionID, kind: InstrumentKind, excluding binding: ResolvedLedgerBinding) -> [AccountProfile] {
        profiles.filter { profile in
            profile.isActive && profile.binding != binding && Self.fits(profile.binding, kind)
                && (profile.institution == institution || profile.keys.contains { $0.institution == institution })
        }
    }

    /// A credit card binds to a card liability; everything else, including a check card, to an account.
    static func fits(_ binding: ResolvedLedgerBinding, _ kind: InstrumentKind) -> Bool {
        switch binding {
        case .creditInstrument: kind.bindsToCreditInstrument
        case .account: !kind.bindsToCreditInstrument
        }
    }

    private func openCandidate(_ id: AccountCandidateID) throws -> (Int, AccountCandidate) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { throw AccountRegistryError.unknownCandidate(id) }
        guard candidates[index].status == .open else { throw AccountRegistryError.candidateNotOpen(id) }
        return (index, candidates[index])
    }

    private func newTarget(displayName: String, kind: NewTargetKind, instrument: InstrumentKind?, makeID: () -> String) throws -> NewLedgerTarget {
        let name = try Self.validName(displayName)
        switch kind {
        case let .account(accountKind, openingBalance):
            if instrument?.bindsToCreditInstrument == true { throw AccountRegistryError.kindMismatch }
            return .account(Account(id: AccountID(rawValue: makeID()), name: name, kind: accountKind, openingBalance: openingBalance))
        case let .creditInstrument(currency):
            if let instrument, !instrument.bindsToCreditInstrument { throw AccountRegistryError.kindMismatch }
            return .creditInstrument(try CreditInstrument(id: CreditInstrumentID(rawValue: makeID()), name: name, currency: currency))
        }
    }

    private mutating func register(target: NewLedgerTarget, displayName: String, institution: InstitutionID?, keys: [InstrumentKey]) throws {
        guard profile(target.binding) == nil else { throw AccountRegistryError.duplicateBinding(target.binding) }
        let name = try Self.validName(displayName)
        for key in keys { try checkAttachable(key, to: nil) }
        profiles.append(AccountProfile(binding: target.binding, displayName: name, institution: institution, keys: keys, isActive: true))
    }

    private mutating func attach(_ key: InstrumentKey, to binding: ResolvedLedgerBinding) throws {
        guard let index = profiles.firstIndex(where: { $0.binding == binding }) else {
            throw AccountRegistryError.unknownBinding(binding)
        }
        try checkAttachable(key, to: binding)
        if !profiles[index].keys.contains(key) { profiles[index].keys.append(key) }
    }

    /// A key may belong to one target; weak ones can't be bound at all.
    private func checkAttachable(_ key: InstrumentKey, to binding: ResolvedLedgerBinding?) throws {
        guard key.identifier.isStrong else { throw AccountRegistryError.weakIdentifier }
        for other in profiles where other.binding != binding {
            if other.keys.contains(where: { $0.matches(key) }) {
                throw AccountRegistryError.identifierAlreadyBound(key.identifier, to: other.binding)
            }
        }
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountRegistryError.emptyDisplayName }
        return trimmed
    }
}
