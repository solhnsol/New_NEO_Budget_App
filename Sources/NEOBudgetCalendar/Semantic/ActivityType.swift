import Foundation

/// Normalization used to compare user-visible names (tags, aliases). NFC, trimmed, single-spaced, case-folded.
public enum NameNormalizer {
    public static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}

/// What kind of real-life activity something is: 데이트, 친구·사교, 학업, 운동, 동아리 …
///
/// This is a separate axis from the Calendar an event lives in. Presets ship with stable IDs so data stays
/// valid if their display names change; users can add their own types and archive any of them.
public struct ActivityTypeDefinition: Codable, Hashable, Sendable {
    public let id: ActivityTypeID
    public var displayName: String
    public let isPreset: Bool
    public var isArchived: Bool

    public init(id: ActivityTypeID, displayName: String, isPreset: Bool = false, isArchived: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isPreset = isPreset
        self.isArchived = isArchived
    }
}

extension ActivityTypeID {
    public static let date = ActivityTypeID(rawValue: "preset.date")
    public static let social = ActivityTypeID(rawValue: "preset.social")
    public static let exercise = ActivityTypeID(rawValue: "preset.exercise")
    public static let work = ActivityTypeID(rawValue: "preset.work")
    public static let study = ActivityTypeID(rawValue: "preset.study")
    public static let family = ActivityTypeID(rawValue: "preset.family")
    public static let leisure = ActivityTypeID(rawValue: "preset.leisure")
    public static let errands = ActivityTypeID(rawValue: "preset.errands")
    public static let club = ActivityTypeID(rawValue: "preset.club")
    public static let other = ActivityTypeID(rawValue: "preset.other")
}

extension ActivityTypeDefinition {
    /// The built-in starting set. Not exhaustive and not a closed list: users add their own.
    public static let presets: [ActivityTypeDefinition] = [
        ActivityTypeDefinition(id: .date, displayName: "데이트", isPreset: true),
        ActivityTypeDefinition(id: .social, displayName: "친구·사교", isPreset: true),
        ActivityTypeDefinition(id: .exercise, displayName: "운동", isPreset: true),
        ActivityTypeDefinition(id: .work, displayName: "업무", isPreset: true),
        ActivityTypeDefinition(id: .study, displayName: "학업", isPreset: true),
        ActivityTypeDefinition(id: .family, displayName: "가족", isPreset: true),
        ActivityTypeDefinition(id: .leisure, displayName: "여가", isPreset: true),
        ActivityTypeDefinition(id: .errands, displayName: "볼일", isPreset: true),
        ActivityTypeDefinition(id: .club, displayName: "동아리", isPreset: true),
        ActivityTypeDefinition(id: .other, displayName: "기타", isPreset: true)
    ]
}
