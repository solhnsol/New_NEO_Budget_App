/// A semantic life area such as 성수, 연남, 신촌, 강남, 샤로수길. It is a shopping/going-out zone people recognize,
/// not an administrative district, address, or coordinate, and nothing here geocodes.
///
/// Future sources (a resolved place, or words in a calendar title) can propose an Area by alias; whether an
/// Area is stored is decided by the same provenance/confidence rules as every other assignment.
public struct Area: Codable, Hashable, Sendable {
    public let id: AreaID
    /// Canonical display name.
    public var displayName: String
    /// Other names people use for the same area. Compared after `NameNormalizer`.
    public var aliases: [String]
    /// A broader area this one belongs to (연남 → 홍대권). Optional; the chain must not loop.
    public var broaderAreaID: AreaID?

    public init(id: AreaID, displayName: String, aliases: [String] = [], broaderAreaID: AreaID? = nil) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.broaderAreaID = broaderAreaID
    }

    /// Display name plus aliases, normalized and de-duplicated, in a stable order.
    var normalizedNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in [displayName] + aliases {
            let normalized = NameNormalizer.normalize(name)
            if !normalized.isEmpty, seen.insert(normalized).inserted { result.append(normalized) }
        }
        return result
    }
}

/// A validated set of areas: unique IDs, no two areas sharing a name or alias, broader areas that exist and
/// never form a cycle. Value type; changes return a new catalog or throw without changing anything.
public struct AreaCatalog: Codable, Equatable, Sendable {
    public private(set) var areasByID: [AreaID: Area]
    private var aliasIndex: [String: AreaID]

    public init() {
        areasByID = [:]
        aliasIndex = [:]
    }

    private enum CodingKeys: String, CodingKey { case areas }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let areas = try values.decode([Area].self, forKey: .areas)
        self.init()
        // Parents may appear after children in stored data, so insert until a pass makes no progress.
        var pending = areas
        while !pending.isEmpty {
            var next: [Area] = []
            for area in pending {
                if let parent = area.broaderAreaID, areasByID[parent] == nil, pending.contains(where: { $0.id == parent }) {
                    next.append(area)
                } else {
                    self = try inserting(area)
                }
            }
            guard next.count < pending.count else {
                throw LifeValidationError.unknownBroaderArea(next[0].broaderAreaID ?? next[0].id)
            }
            pending = next
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(areas, forKey: .areas)
    }

    public static func == (lhs: AreaCatalog, rhs: AreaCatalog) -> Bool { lhs.areasByID == rhs.areasByID }

    public var areas: [Area] { areasByID.values.sorted { $0.id < $1.id } }

    /// Adds or replaces an area. Throws without effect if any rule would be violated.
    public func inserting(_ area: Area) throws -> AreaCatalog {
        guard !area.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "area") }
        let names = area.normalizedNames
        guard !names.isEmpty else { throw LifeValidationError.emptyName(entity: "area") }

        var next = self
        if let existing = next.areasByID[area.id] {
            for name in existing.normalizedNames where next.aliasIndex[name] == area.id { next.aliasIndex[name] = nil }
        }
        for name in names {
            if let owner = next.aliasIndex[name], owner != area.id {
                throw LifeValidationError.duplicateAreaAlias(name)
            }
        }
        if let parent = area.broaderAreaID {
            guard parent != area.id else { throw LifeValidationError.areaCycle(area.id) }
            guard next.areasByID[parent] != nil else { throw LifeValidationError.unknownBroaderArea(parent) }
            var cursor: AreaID? = parent
            var hops = 0
            while let current = cursor {
                if current == area.id { throw LifeValidationError.areaCycle(area.id) }
                cursor = next.areasByID[current]?.broaderAreaID
                hops += 1
                if hops > next.areasByID.count + 1 { throw LifeValidationError.areaCycle(area.id) }
            }
        }
        next.areasByID[area.id] = area
        for name in names { next.aliasIndex[name] = area.id }
        return next
    }

    public func area(_ id: AreaID) -> Area? { areasByID[id] }

    /// The area whose display name or alias equals `text` after normalization. Exact match only; this never guesses.
    public func resolve(alias text: String) -> Area? {
        aliasIndex[NameNormalizer.normalize(text)].flatMap { areasByID[$0] }
    }

    /// Broader areas, nearest first (연남 → [홍대권]).
    public func ancestors(of id: AreaID) -> [Area] {
        var result: [Area] = []
        var cursor = areasByID[id]?.broaderAreaID
        while let current = cursor, let area = areasByID[current], result.count <= areasByID.count {
            result.append(area)
            cursor = area.broaderAreaID
        }
        return result
    }

    /// Whether `id` is `ancestor` itself or lies inside it.
    public func isWithin(_ id: AreaID, ancestor: AreaID) -> Bool {
        id == ancestor || ancestors(of: id).contains { $0.id == ancestor }
    }
}
