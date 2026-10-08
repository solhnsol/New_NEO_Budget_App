/// A ledger target as the user knows it. The binding is the internal identity; `displayName` is only a label
/// and can change without touching identifiers, rules, or ledger history.
public struct AccountProfile: Codable, Equatable, Sendable {
    public let binding: ResolvedLedgerBinding
    public internal(set) var displayName: String
    public let institution: InstitutionID?
    public let instrument: InstrumentClass
    public internal(set) var identifiers: [AccountIdentifier]
    public internal(set) var isActive: Bool
}

public struct AccountCandidateID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    init(institution: InstitutionID, identifier: AccountIdentifier) {
        rawValue = institution.rawValue + "|" + identifier.canonical
    }
}

/// An account the notifications mention that the user has not accepted yet. Never usable by the ledger.
public struct AccountCandidate: Codable, Equatable, Sendable {
    public enum Status: Codable, Equatable, Sendable {
        case open
        case dismissed
        case linked(ResolvedLedgerBinding)
        case confirmedAsNew(ResolvedLedgerBinding)
    }

    public static let evidenceLimit = 20

    public let id: AccountCandidateID
    public let institution: InstitutionID
    public let instrument: InstrumentClass
    public let identifier: AccountIdentifier
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

/// "Notifications of this kind without an identifier belong to that account." It exists only because the user
/// said so, and it is applied only while it cannot be wrong by construction (see `AccountRegistry.resolve`).
public struct SourceRule: Codable, Equatable, Sendable {
    public let id: SourceRuleID
    public let institution: InstitutionID
    public let instrument: InstrumentClass
    /// nil = any app of the institution.
    public let applicationIdentifier: String?
    public let binding: ResolvedLedgerBinding
    public let createdAtUnixMilliseconds: Int64
}

public enum ConfirmationReason: String, Codable, Hashable, Sendable {
    /// The source names no known institution, so even an identifier cannot be scoped.
    case institutionUnknown
    /// No identifier in the notification and no rule from the user.
    case noIdentifier
    /// An identifier was present but too short to bind on, and no rule covers it.
    case weakIdentifier
    /// A rule exists, but the institution has another active account of that kind, so the rule alone cannot tell.
    case sourceRuleHasSiblingAccounts
    case conflictingSourceRules
    case identifierMatchesMultipleAccounts
    case matchedAccountInactive
}

public enum AccountResolutionDecision: Equatable, Sendable {
    public enum Basis: Equatable, Sendable {
        case identifier(AccountIdentifier)
        case exclusiveSourceRule(SourceRuleID)
    }

    /// Safe to bind without asking: the identifier matched exactly one active account, or the user's rule is
    /// the only possible account for this institution and kind.
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
    case institutionMismatch
    case instrumentMismatch
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

/// Pure account identity state: which identifiers belong to which ledger target, which accounts are merely
/// suspected, and which explicit user rules exist. It owns no ledger data and performs no I/O.
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
    /// Order matters. A strong identifier is authoritative: if it matches nothing it becomes a candidate and
    /// never falls through to a source rule, so a new card can't be silently absorbed by the rule of an old one.
    /// A rule applies only when no identifier exists and the institution has no second active account of the
    /// same kind. With a sibling the same message could belong to either, so the user is asked.
    public func resolve(_ hints: AccountHints) -> AccountResolutionDecision {
        guard let institution = hints.institution else {
            return .needsConfirmation(.institutionUnknown, suggestion: nil)
        }
        if let identifier = hints.identifier {
            let matches = profiles.filter { profile in
                profile.institution == institution && profile.identifiers.contains { $0.matches(identifier) }
            }
            switch matches.count {
            case 0: return .newCandidate(AccountCandidateID(institution: institution, identifier: identifier))
            case 1:
                let match = matches[0]
                guard match.isActive else { return .needsConfirmation(.matchedAccountInactive, suggestion: match.binding) }
                return .resolved(match.binding, basis: .identifier(identifier))
            default: return .needsConfirmation(.identifierMatchesMultipleAccounts, suggestion: nil)
            }
        }

        let applicable = rules.filter {
            $0.institution == institution && $0.instrument == hints.instrument
                && ($0.applicationIdentifier == nil || $0.applicationIdentifier == hints.sourceApplication)
        }
        let targets = Set(applicable.map(\.binding))
        guard let first = applicable.first else {
            return .needsConfirmation(hints.hasWeakIdentifier ? .weakIdentifier : .noIdentifier, suggestion: nil)
        }
        guard targets.count == 1 else { return .needsConfirmation(.conflictingSourceRules, suggestion: nil) }
        guard let target = profile(first.binding), target.isActive else {
            return .needsConfirmation(.matchedAccountInactive, suggestion: first.binding)
        }
        if siblings(of: target).isEmpty { return .resolved(target.binding, basis: .exclusiveSourceRule(first.id)) }
        return .needsConfirmation(.sourceRuleHasSiblingAccounts, suggestion: target.binding)
    }

    /// `resolve`, plus recording a new identifier as a candidate.
    @discardableResult
    public mutating func observe(
        _ hints: AccountHints,
        notificationID: String,
        capturedAtUnixMilliseconds: Int64
    ) -> AccountResolutionDecision {
        let decision = resolve(hints)
        guard case let .newCandidate(id) = decision, let institution = hints.institution, let identifier = hints.identifier else {
            return decision
        }
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
                id: id,
                institution: institution,
                instrument: hints.instrument,
                identifier: identifier,
                status: .open,
                occurrenceCount: 1,
                firstSeenUnixMilliseconds: capturedAtUnixMilliseconds,
                lastSeenUnixMilliseconds: capturedAtUnixMilliseconds,
                evidenceNotificationIDs: [notificationID]
            ))
        }
        return decision
    }

    // MARK: User decisions on candidates

    /// The user says this candidate is an account we already have.
    public mutating func link(_ id: AccountCandidateID, to binding: ResolvedLedgerBinding) throws {
        let (index, candidate) = try openCandidate(id)
        guard let target = profile(binding) else { throw AccountRegistryError.unknownBinding(binding) }
        guard target.institution == nil || target.institution == candidate.institution else {
            throw AccountRegistryError.institutionMismatch
        }
        try attach(candidate.identifier, to: binding)
        candidates[index].status = .linked(binding)
    }

    /// The user says this is a new account. Returns what the caller must create in the ledger; the registry
    /// binds the identifier to it. The ID comes from `makeID`, never from the name.
    public mutating func confirmAsNew(
        _ id: AccountCandidateID,
        displayName: String,
        kind: NewTargetKind,
        makeID: () -> String
    ) throws -> NewLedgerTarget {
        let (index, candidate) = try openCandidate(id)
        let name = try Self.validName(displayName)
        let raw = makeID()
        let target: NewLedgerTarget
        switch kind {
        case let .account(accountKind, openingBalance):
            target = .account(Account(id: AccountID(rawValue: raw), name: name, kind: accountKind, openingBalance: openingBalance))
        case let .creditInstrument(currency):
            target = .creditInstrument(try CreditInstrument(id: CreditInstrumentID(rawValue: raw), name: name, currency: currency))
        }
        try register(target: target, displayName: name, institution: candidate.institution,
                     instrument: candidate.instrument, identifiers: [candidate.identifier])
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
        instrument: InstrumentClass,
        identifiers: [AccountIdentifier] = []
    ) throws {
        guard profile(binding) == nil else { throw AccountRegistryError.duplicateBinding(binding) }
        let name = try Self.validName(displayName)
        for identifier in identifiers { try checkAttachable(identifier, institution: institution, to: nil) }
        profiles.append(AccountProfile(binding: binding, displayName: name, institution: institution,
                                       instrument: instrument, identifiers: identifiers, isActive: true))
    }

    /// The user adds an account by hand; identifiers are optional and can be added later.
    public mutating func addAccount(
        displayName: String,
        institution: InstitutionID?,
        instrument: InstrumentClass,
        kind: NewTargetKind,
        identifiers: [AccountIdentifier] = [],
        makeID: () -> String
    ) throws -> NewLedgerTarget {
        let name = try Self.validName(displayName)
        let raw = makeID()
        let target: NewLedgerTarget
        switch kind {
        case let .account(accountKind, openingBalance):
            target = .account(Account(id: AccountID(rawValue: raw), name: name, kind: accountKind, openingBalance: openingBalance))
        case let .creditInstrument(currency):
            target = .creditInstrument(try CreditInstrument(id: CreditInstrumentID(rawValue: raw), name: name, currency: currency))
        }
        try register(target: target, displayName: name, institution: institution, instrument: instrument, identifiers: identifiers)
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

    public mutating func addIdentifier(_ identifier: AccountIdentifier, to binding: ResolvedLedgerBinding) throws {
        try attach(identifier, to: binding)
    }

    public mutating func setActive(_ binding: ResolvedLedgerBinding, _ isActive: Bool) throws {
        guard let index = profiles.firstIndex(where: { $0.binding == binding }) else {
            throw AccountRegistryError.unknownBinding(binding)
        }
        profiles[index].isActive = isActive
    }

    // MARK: Explicit rules for notifications without an identifier

    /// Creates the user's rule "this kind of notification is that account". If the institution already has
    /// another active account of that kind the rule would be a guess, so it needs `acknowledgingSiblings`.
    /// Even then it only suggests while the siblings exist; see `resolve`.
    public mutating func addSourceRule(
        id: SourceRuleID,
        institution: InstitutionID,
        instrument: InstrumentClass,
        applicationIdentifier: String? = nil,
        binding: ResolvedLedgerBinding,
        acknowledgingSiblings: Bool = false,
        createdAtUnixMilliseconds: Int64
    ) throws {
        guard instrument != .unknown else { throw AccountRegistryError.ruleScopeIncomplete }
        guard let target = profile(binding) else { throw AccountRegistryError.unknownBinding(binding) }
        guard target.institution == nil || target.institution == institution else { throw AccountRegistryError.institutionMismatch }
        guard !rules.contains(where: { $0.id == id }) else { throw AccountRegistryError.ruleAlreadyExists(id) }
        let others = siblings(of: target, institution: institution, instrument: instrument)
        if !others.isEmpty, !acknowledgingSiblings { throw AccountRegistryError.siblingsExist(others.map(\.binding)) }
        rules.append(SourceRule(id: id, institution: institution, instrument: instrument,
                                applicationIdentifier: applicationIdentifier, binding: binding,
                                createdAtUnixMilliseconds: createdAtUnixMilliseconds))
    }

    public mutating func removeSourceRule(_ id: SourceRuleID) throws {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { throw AccountRegistryError.unknownRule(id) }
        rules.remove(at: index)
    }

    // MARK: Internals

    private func siblings(of target: AccountProfile, institution: InstitutionID? = nil, instrument: InstrumentClass? = nil) -> [AccountProfile] {
        let institution = institution ?? target.institution
        let instrument = instrument ?? target.instrument
        return profiles.filter {
            $0.isActive && $0.binding != target.binding && $0.institution == institution && $0.instrument == instrument
        }
    }

    private func openCandidate(_ id: AccountCandidateID) throws -> (Int, AccountCandidate) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { throw AccountRegistryError.unknownCandidate(id) }
        guard candidates[index].status == .open else { throw AccountRegistryError.candidateNotOpen(id) }
        return (index, candidates[index])
    }

    private mutating func register(
        target: NewLedgerTarget,
        displayName: String,
        institution: InstitutionID?,
        instrument: InstrumentClass,
        identifiers: [AccountIdentifier]
    ) throws {
        guard profile(target.binding) == nil else { throw AccountRegistryError.duplicateBinding(target.binding) }
        for identifier in identifiers { try checkAttachable(identifier, institution: institution, to: nil) }
        profiles.append(AccountProfile(binding: target.binding, displayName: displayName, institution: institution,
                                       instrument: instrument, identifiers: identifiers, isActive: true))
    }

    private mutating func attach(_ identifier: AccountIdentifier, to binding: ResolvedLedgerBinding) throws {
        guard let index = profiles.firstIndex(where: { $0.binding == binding }) else {
            throw AccountRegistryError.unknownBinding(binding)
        }
        try checkAttachable(identifier, institution: profiles[index].institution, to: binding)
        if !profiles[index].identifiers.contains(identifier) { profiles[index].identifiers.append(identifier) }
    }

    /// An identifier may belong to one target within an institution; weak ones can't be bound at all.
    private func checkAttachable(_ identifier: AccountIdentifier, institution: InstitutionID?, to binding: ResolvedLedgerBinding?) throws {
        guard identifier.isStrong else { throw AccountRegistryError.weakIdentifier }
        for other in profiles where other.binding != binding && other.institution == institution {
            if other.identifiers.contains(where: { $0.matches(identifier) }) {
                throw AccountRegistryError.identifierAlreadyBound(identifier, to: other.binding)
            }
        }
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountRegistryError.emptyDisplayName }
        return trimmed
    }
}
