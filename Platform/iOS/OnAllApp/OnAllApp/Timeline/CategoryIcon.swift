import NEOBudgetCalendar

/// The small icon a classified spending category is drawn with. Categories come from the canonical taxonomy and are never guessed
/// here: a transaction whose category is not (yet) classified has no icon and keeps its plain dot. The match is on the category's id,
/// by the words a taxonomy id is made of, in either language; a classified category that matches nothing gets a generic tag.
enum CategoryIcon {
    private static let table: [(keys: [String], symbol: String, name: String)] = [
        (["cafe", "coffee", "카페", "커피"], "cup.and.saucer", "카페"),
        (["food", "meal", "dining", "restaurant", "grocer", "식비", "식사", "외식", "식당", "마트"], "fork.knife", "식비"),
        (["transport", "taxi", "bus", "subway", "fuel", "교통", "택시", "주유"], "car", "교통"),
        (["shop", "retail", "cloth", "쇼핑", "의류"], "bag", "쇼핑"),
        (["health", "medical", "pharmacy", "의료", "병원", "약국", "건강"], "cross.case", "의료·건강"),
        (["entertain", "leisure", "culture", "movie", "문화", "여가", "영화"], "ticket", "문화·여가"),
        (["home", "housing", "rent", "utility", "주거", "월세", "공과금", "생활"], "house", "주거·생활"),
        (["educat", "study", "book", "교육", "학원", "도서"], "book", "교육"),
        (["travel", "trip", "hotel", "여행", "숙박"], "airplane", "여행"),
        (["gift", "social", "경조", "선물", "모임"], "gift", "선물·모임"),
        (["subscription", "telecom", "phone", "구독", "통신"], "antenna.radiowaves.left.and.right", "구독·통신"),
    ]

    /// `nil` when there is no classified category.
    static func symbol(for category: CanonicalCategoryID?) -> String? {
        guard let category else { return nil }
        let id = category.rawValue.lowercased()
        for entry in table where entry.keys.contains(where: { id.contains($0) }) { return entry.symbol }
        return "tag"
    }

    /// The category's name as the user reads it (`food` → `식비`); an id already in Korean, or one that matches nothing, is shown as it is.
    /// `nil` when unclassified.
    static func name(for category: CanonicalCategoryID?) -> String? {
        guard let category else { return nil }
        if category.rawValue.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) { return category.rawValue }
        let id = category.rawValue.lowercased()
        for entry in table where entry.keys.contains(where: { id.contains($0) }) { return entry.name }
        return category.rawValue
    }
}
