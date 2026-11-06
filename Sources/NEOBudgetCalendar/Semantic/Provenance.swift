/// Who decided an assignment. A user decision is never overwritten by an automated one.
public enum AssignmentSource: String, Codable, Hashable, Sendable {
    case user
    case automated
}

public struct AssignmentProvenance: Codable, Hashable, Sendable {
    public let source: AssignmentSource
    /// For automated sources, an identifier of the rule or model version that produced it. Informational.
    public let origin: String?
    /// 0...1. Meaningful for automated sources; a user decision needs none.
    public let confidence: Double?
    public let assignedAtUnixMilliseconds: Int64
    /// How recent the newest evidence was that this decision looked at (a version counter or the time the
    /// evidence was observed). A user's "I do not know" is only reopened by evidence newer than this; an
    /// automated reclassification must state the evidence it used. `nil` means not stated.
    public let evidenceVersion: Int64?

    public init(
        source: AssignmentSource, origin: String? = nil, confidence: Double? = nil, assignedAtUnixMilliseconds: Int64,
        evidenceVersion: Int64? = nil
    ) {
        self.source = source
        self.origin = origin
        self.confidence = confidence
        self.assignedAtUnixMilliseconds = assignedAtUnixMilliseconds
        self.evidenceVersion = evidenceVersion
    }

    public static func user(at unixMilliseconds: Int64, evidenceVersion: Int64? = nil) -> AssignmentProvenance {
        AssignmentProvenance(source: .user, assignedAtUnixMilliseconds: unixMilliseconds, evidenceVersion: evidenceVersion)
    }

    public static func automated(origin: String, confidence: Double?, at unixMilliseconds: Int64, evidenceVersion: Int64? = nil) -> AssignmentProvenance {
        AssignmentProvenance(
            source: .automated, origin: origin, confidence: confidence, assignedAtUnixMilliseconds: unixMilliseconds,
            evidenceVersion: evidenceVersion
        )
    }

    public var hasValidConfidence: Bool {
        guard let confidence else { return true }
        return confidence.isFinite && confidence >= 0 && confidence <= 1
    }

    /// An automated assignment may replace another automated one, but never a user decision.
    public func mayReplace(_ existing: AssignmentProvenance) -> Bool {
        !(existing.source == .user && source == .automated)
    }
}

/// A value together with who assigned it.
public struct Assigned<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let value: Value
    public let provenance: AssignmentProvenance

    public init(_ value: Value, provenance: AssignmentProvenance) {
        self.value = value
        self.provenance = provenance
    }
}

/// When an automated assignment is good enough to store. Wrong automation is worse than no assignment,
/// so anything below the threshold, or without a confidence at all, is not stored.
public struct AssignmentPolicy: Equatable, Sendable {
    public let minimumAutomatedConfidence: Double

    public init(minimumAutomatedConfidence: Double = 0.85) {
        self.minimumAutomatedConfidence = minimumAutomatedConfidence
    }

    public func accepts(_ provenance: AssignmentProvenance) -> Bool {
        guard provenance.hasValidConfidence else { return false }
        switch provenance.source {
        case .user:
            return true
        case .automated:
            guard let confidence = provenance.confidence else { return false }
            return confidence >= minimumAutomatedConfidence
        }
    }
}
