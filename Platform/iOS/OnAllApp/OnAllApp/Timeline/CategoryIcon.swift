import NEOBudgetCalendar

/// The small icon a classified spending category is drawn with. Categories come from the canonical taxonomy and are never guessed
/// here: a transaction whose category is not (yet) classified has no icon and keeps its plain dot. The match is on the category's id,
/// by the words a taxonomy id is made of, in either language; a classified category that matches nothing gets a generic tag.
enum CategoryIcon {
    private static let table: [(keys: [String], symbol: String)] = [
        (["cafe", "coffee", "카페", "커피"], "cup.and.saucer"),
        (["food", "meal", "dining", "restaurant", "grocer", "식비", "식사", "외식", "식당", "마트"], "fork.knife"),
        (["transport", "taxi", "bus", "subway", "fuel", "교통", "택시", "주유"], "car"),
        (["shop", "retail", "cloth", "쇼핑", "의류"], "bag"),
        (["health", "medical", "pharmacy", "의료", "병원", "약국", "건강"], "cross.case"),
        (["entertain", "leisure", "culture", "movie", "문화", "여가", "영화"], "ticket"),
        (["home", "housing", "rent", "utility", "주거", "월세", "공과금", "생활"], "house"),
        (["educat", "study", "book", "교육", "학원", "도서"], "book"),
        (["travel", "trip", "hotel", "여행", "숙박"], "airplane"),
        (["gift", "social", "경조", "선물", "모임"], "gift"),
        (["subscription", "telecom", "phone", "구독", "통신"], "antenna.radiowaves.left.and.right"),
    ]

    /// `nil` when there is no classified category.
    static func symbol(for category: CanonicalCategoryID?) -> String? {
        guard let category else { return nil }
        let id = category.rawValue.lowercased()
        for entry in table where entry.keys.contains(where: { id.contains($0) }) { return entry.symbol }
        return "tag"
    }
}
