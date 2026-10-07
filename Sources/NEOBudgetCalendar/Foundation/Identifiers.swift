// Opaque identifiers. The calendar domain never parses or interprets the contents; an adapter or the
// application decides how they are produced. All are plain strings so they stay stable across processes.

/// Identifies one calendar (a container such as "학교" or "약속"). Issued by the calendar provider.
public struct CalendarID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: CalendarID, rhs: CalendarID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identifies one event instance **as the provider presents it** within a calendar.
///
/// The domain treats this as an opaque token. How a provider encodes a recurring occurrence, and whether
/// the token survives provider-side changes, is provider-specific and intentionally not assumed here.
public struct CalendarEventID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: CalendarEventID, rhs: CalendarEventID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// OnAll-owned stable identity of an Activity. Never derived from an external calendar identifier.
public struct ActivityID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: ActivityID, rhs: ActivityID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identifies an activity type definition (a preset or a user-defined type).
public struct ActivityTypeID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: ActivityTypeID, rhs: ActivityTypeID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identifies a user-owned tag.
public struct TagID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: TagID, rhs: TagID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identifies a semantic life area (성수, 연남, 신촌 …), not an administrative region or coordinate.
public struct AreaID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: AreaID, rhs: AreaID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identifies an entry of the canonical category taxonomy. The taxonomy itself is defined elsewhere;
/// categories are never free-form user text.
public struct CanonicalCategoryID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: CanonicalCategoryID, rhs: CanonicalCategoryID) -> Bool { lhs.rawValue < rhs.rawValue }
}
