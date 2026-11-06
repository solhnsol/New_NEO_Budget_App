import Foundation

/// 읽기 사전: 공식 항목 + 사용자 항목 + 공용 읽기 설정. 알림 처리의 첫 단계에서 값을 읽는 규칙은 전부 여기 데이터에 있다.
public struct ReadingDictionary: Codable, Equatable, Sendable {
    /// 공식 항목(수정되지 않은 것).
    public var officialEntries: [ReadingEntry]
    /// 사용자가 직접 만든 항목.
    public var userEntries: [ReadingEntry]
    /// 목록에서 끈 공식 항목.
    public var disabledOfficialIDs: Set<String>
    /// 사용자가 고친 공식 항목(`공식 · 수정됨`). 되돌리면 지운다. 키는 공식 항목 id.
    public var officialOverrides: [String: ReadingEntry]
    public var settings: ReadingReaderSettings

    public init(
        officialEntries: [ReadingEntry] = OfficialReadingEntries.all,
        userEntries: [ReadingEntry] = [],
        disabledOfficialIDs: Set<String> = [],
        officialOverrides: [String: ReadingEntry] = [:],
        settings: ReadingReaderSettings = .official
    ) {
        self.officialEntries = officialEntries
        self.userEntries = userEntries
        self.disabledOfficialIDs = disabledOfficialIDs
        self.officialOverrides = officialOverrides
        self.settings = settings
    }

    public static let official = ReadingDictionary()

    /// 실제로 쓰는 항목을 우선순위대로. 내 항목 > 공식, 앱을 지정한 항목 > 모든 앱, 고정 표현이 많은 항목 > 적은 항목,
    /// 같으면 공식 순서(rank).
    public var effectiveEntries: [ReadingEntry] {
        let official: [ReadingEntry] = officialEntries.compactMap { entry in
            if disabledOfficialIDs.contains(entry.id) { return nil }
            return officialOverrides[entry.id] ?? entry
        }
        return (userEntries + official).filter(\.enabled).sorted { a, b in
            let ka = Self.sortKey(a), kb = Self.sortKey(b)
            if ka != kb { return ka.lexicographicallyPrecedes(kb) }
            return a.id < b.id
        }
    }

    private static func sortKey(_ entry: ReadingEntry) -> [Int] {
        if entry.origin == .user {
            return [0, entry.applicationIdentifier == nil ? 1 : 0, -entry.specificity, entry.rank]
        }
        // 공식 항목은 정해 둔 순서(rank)만 따른다. 앞 항목이 뒤 항목을 가리는 관계를 사람이 정했기 때문이다.
        return [1, 0, 0, entry.rank]
    }
}
