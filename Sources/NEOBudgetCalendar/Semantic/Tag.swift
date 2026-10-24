/// A user-owned label for personal analysis context (구독, 뒤풀이, 기념일, 선물, 대회 …).
///
/// Tags are never categories and are never invented by automation. Automation may only *select* from the
/// user's existing, non-archived tags by `TagID`; there is intentionally no API that creates a tag from a
/// suggestion.
public struct Tag: Codable, Hashable, Sendable {
    public let id: TagID
    public var name: String
    public var isArchived: Bool

    public init(id: TagID, name: String, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.isArchived = isArchived
    }
}

/// A tag attached to something, with who attached it.
public struct TagAssignment: Codable, Hashable, Sendable {
    public let tagID: TagID
    public let provenance: AssignmentProvenance

    public init(tagID: TagID, provenance: AssignmentProvenance) {
        self.tagID = tagID
        self.provenance = provenance
    }
}
