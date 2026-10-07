/// A pointer to a person in some outside system (contacts, an OnAll account, …). It is stored, never resolved
/// here: OnAll works fully for people who do not use OnAll, and nothing in the domain requires an account.
public struct ExternalIdentity: Codable, Hashable, Sendable {
    public let kind: String
    public let value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// A person in the user's own world: someone they do things with and settle money with.
///
/// Identity is OnAll's own and stable. A calendar attendee is not assumed to be the same person; mapping
/// attendees to people is a later adapter's job. The user themselves is the (single) person with `isSelf`.
public struct Person: Codable, Hashable, Sendable {
    public let id: PersonID
    public var displayName: String
    public var isSelf: Bool
    public var externalIdentity: ExternalIdentity?
    /// How the user describes this person ("친구", "가족" …). Only the user can set it: the domain never
    /// infers a relationship, no matter how often two people appear together.
    public var relationshipLabel: Assigned<String>?

    public init(
        id: PersonID,
        displayName: String,
        isSelf: Bool = false,
        externalIdentity: ExternalIdentity? = nil,
        relationshipLabel: Assigned<String>? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isSelf = isSelf
        self.externalIdentity = externalIdentity
        self.relationshipLabel = relationshipLabel
    }
}

/// A person taking part in an Activity, with who said so.
public struct ParticipantAssignment: Codable, Hashable, Sendable {
    public let personID: PersonID
    public let provenance: AssignmentProvenance

    public init(personID: PersonID, provenance: AssignmentProvenance) {
        self.personID = personID
        self.provenance = provenance
    }
}
