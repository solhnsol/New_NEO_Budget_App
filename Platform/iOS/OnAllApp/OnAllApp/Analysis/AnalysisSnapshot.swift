import Foundation
import NEOBudgetCalendar
import NEOBudgetCore

/// Everything the analysis screens read, taken once from the ledger and the life state, so a screen sums and groups without waiting on either.
/// Read-only: nothing here changes the ledger, the life state or the overrides.
struct AnalysisSnapshot {
    var entriesByID: [LedgerEntryID: LedgerListEntry] = [:]
    var rows: [AnalysisTransaction] = []
    var recurringInputs: [RecurringInput] = []
    var people: [PersonID: String] = [:]
    var me: PersonID?
    /// Tags on events (not editable here), with how many events carry each.
    var eventTags: [(name: String, count: Int)] = []
    var today: LocalDate

    init(today: LocalDate) { self.today = today }

    @MainActor static func load(_ model: AppModel) async -> AnalysisSnapshot? {
        guard let sections = await model.ledgerSections() else { return nil }
        let life = await model.lifeState() ?? .empty
        let entries = sections.flatMap(\.entries)
        var snapshot = AnalysisSnapshot(today: model.dayZone.localDate(of: model.nowMilliseconds))
        snapshot.entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        snapshot.rows = AnalysisInput.transactions(entries, life: life, zone: model.dayZone, recurring: model.recurringDecisions)
        snapshot.recurringInputs = AnalysisInput.recurringInputs(entries, zone: model.dayZone)
        snapshot.people = life.persons.mapValues(\.displayName)
        snapshot.me = life.persons.values.first(where: \.isSelf)?.id
        var counts: [String: Int] = [:]
        for activity in life.activities.values {
            for assignment in activity.tags { if let tag = life.tags[assignment.tagID], !tag.isArchived { counts[tag.name, default: 0] += 1 } }
        }
        snapshot.eventTags = counts.map { ($0.key, $0.value) }.sorted { ($0.1, $1.0) > ($1.1, $0.0) }
        return snapshot
    }

    func period(year: Int, month: Int) -> AnalysisPeriod? { try? AnalysisPeriod.month(year: year, month: month) }

    func suggestions(_ decisions: RecurringDecisions) -> [RecurringSeries] { RecurringDetector.suggestions(recurringInputs, decisions: decisions) }
}

/// A calendar month the analysis shows.
struct AnalysisMonth: Hashable {
    var year: Int
    var month: Int

    init(year: Int, month: Int) { self.year = year; self.month = month }
    init(_ date: LocalDate) { year = date.year; month = date.month }

    func moved(by months: Int) -> AnalysisMonth {
        let index = year * 12 + (month - 1) + months
        return AnalysisMonth(year: index / 12, month: index % 12 + 1)
    }

    var title: String { "\(year)년 \(month)월" }
    var shortTitle: String { "\(month)월" }
}

enum AnalysisText {
    static func won(_ minorUnits: Int64) -> String { Formatting.money(minorUnits, currency: AnalysisInput.currency) }

    /// "지난달 같은 날까지보다 12,000원 더 썼어요".
    static func comparison(current: Int64, earlier: Int64) -> String {
        let gap = current - earlier
        if abs(gap) < max(1_000, abs(earlier) / 50) { return "지난달 같은 날까지와 비슷하게 썼어요" }
        return "지난달 같은 날까지보다 \(won(abs(gap))) \(gap > 0 ? "더" : "덜") 썼어요"
    }

    static func category(_ id: CanonicalCategoryID?) -> String { CategoryIcon.name(for: id) ?? "분류 없음" }
    static func categorySymbol(_ id: CanonicalCategoryID?) -> String { CategoryIcon.symbol(for: id) ?? "questionmark" }
}
