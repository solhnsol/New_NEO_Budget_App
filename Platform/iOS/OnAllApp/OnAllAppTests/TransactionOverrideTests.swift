import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()

private func marker(_ id: String, minute: Int, won: Int64) throws -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: minute),
        amount: try Money(minorUnits: won, currency: "KRW"), flow: .spend, title: "테스트 \(id)"
    )
}

@Test func overridesRenameRecategorizeAndTag() throws {
    let t = try marker("o", minute: 600, won: 5_000)
    let o = TransactionOverride(title: "점심", category: CanonicalCategoryID(rawValue: "food"), memo: nil, tags: TransactionOverride.parseTags("#데이트 모임, #데이트"))
    #expect(o.tags == ["데이트", "모임"])
    let sections = LedgerList.sections([t], life: .empty, zone: zone, overrides: [t.id: o])
    let entry = try #require(sections.first?.entries.first)
    #expect(entry.transaction.title == "점심")
    #expect(entry.categoryID?.rawValue == "food")
    var store = TransactionOverrideStore()
    store[t.id] = o
    store[t.id] = TransactionOverride()
    #expect(store.lookup.isEmpty)
}

@Test func aTypedInTransactionIsListedBesideTheLedgerAndSurvivesSaving() throws {
    var store = TransactionOverrideStore()
    store.manual.append(.init(id: ManualTransaction.idPrefix + "1", title: "현금 점심", amount: 8_000, isRefund: false, occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: 700)))
    let decoded = try JSONDecoder().decode(TransactionOverrideStore.self, from: JSONEncoder().encode(store))
    #expect(decoded == store)
    let markers = decoded.manualMarkers
    #expect(markers.map(\.title) == ["현금 점심"])
    #expect(markers.first?.timePrecision == .exact)
    #expect(LedgerList.sections(markers, life: .empty, zone: zone).first?.totals == [LedgerTotal(currency: "KRW", minorUnits: 8_000)])
    // A file saved before typed-in transactions existed still reads.
    let old = try JSONDecoder().decode(TransactionOverrideStore.self, from: Data(#"{"byTransaction":{}}"#.utf8))
    #expect(old.manual.isEmpty)
}

// MARK: - rules

private func rule(_ id: String, _ mode: TransactionRule.MatchMode, _ pattern: String, _ actions: [TransactionRule.Action], at: Int64 = 0) -> TransactionRule {
    TransactionRule(id: id, label: nil, mode: mode, pattern: pattern, actions: actions, createdAtUnixMilliseconds: at)
}

private let transit = CanonicalCategoryID(rawValue: "transport")

@Test func anExactRuleIgnoresCaseAndSpacingButNotOtherNames() {
    let r = rule("a", .exact, "Metro", [.setCategory(transit)])
    #expect(r.matches("metro") && r.matches("  METRO ") && r.matches("Me tro") == false)
    #expect(r.matches("Metro Card") == false)
    #expect(rule("b", .contains, "bus", [.setCategory(transit)]).matches("서울 BUS 1번"))
}

@Test func aRegexRuleAndAnInvalidRegex() {
    #expect(rule("a", .regex, "^(Metro|Bus)\\b", [.setCategory(transit)]).matches("bus 402"))
    let broken = rule("b", .regex, "([", [.setCategory(transit)])
    #expect(!broken.isValid && !broken.matches("(["))
    #expect(!rule("c", .exact, "  ", [.setCategory(transit)]).isValid)
    #expect(!rule("d", .exact, "x", [.replace(find: "(", with: "", isRegex: true)]).isValid)
}

@Test func replaceActionsEditTheNameStepByStep() {
    // The branch name is dropped by a regex; a plain swap works too; the name never ends up empty.
    let set = TransactionRuleSet(rules: [
        rule("a", .contains, "스타벅스", [.replace(find: " \\S+점$", with: "", isRegex: true)]),
        rule("b", .contains, "스타벅스", [.replace(find: "스타벅스", with: "스벅", isRegex: false)], at: 1)
    ])
    #expect(set.outcome(forOriginalTitle: "스타벅스 미아사거리역점")?.title == "스벅")
    let groups = TransactionRuleSet(rules: [rule("c", .regex, "^(\\w+)\\*(\\w+)$", [.replace(find: "^(\\w+)\\*(\\w+)$", with: "$2 $1", isRegex: true)])])
    #expect(groups.outcome(forOriginalTitle: "ab*cd")?.title == "cd ab")
    let wipe = TransactionRuleSet(rules: [rule("d", .exact, "점", [.replace(find: "점", with: "", isRegex: false)])])
    #expect(wipe.outcome(forOriginalTitle: "점") == nil)
}

@Test func theMoreSpecificRuleHasTheLastWord() {
    let set = TransactionRuleSet(rules: [
        rule("contains", .contains, "metro", [.setCategory(CanonicalCategoryID(rawValue: "other")), .addTags(["지하철"])], at: 5),
        rule("exact", .exact, "Metro", [.setCategory(transit), .setTitle("지하철"), .addTags(["#출퇴근", "지하철"])], at: 1)
    ])
    let outcome = set.outcome(forOriginalTitle: "Metro")
    #expect(outcome == RuleOutcome(title: "지하철", category: transit, tags: ["지하철", "출퇴근"]))
    #expect(set.outcome(forOriginalTitle: "Metro Pass")?.category?.rawValue == "other")
    #expect(set.outcome(forOriginalTitle: "Taxi") == nil)
    var off = set
    off.rules[1].isEnabled = false
    #expect(off.outcome(forOriginalTitle: "Metro")?.category?.rawValue == "other")
}

@Test func rulesApplyToEveryMatchingTransactionAndTheUsersOwnEditWinsFieldByField() throws {
    let a = try marker("a", minute: 600, won: 1_500), b = try marker("b", minute: 700, won: 1_500), c = try marker("c", minute: 800, won: 9_000)
    func named(_ t: TransactionMarker, _ title: String) -> TransactionMarker {
        TransactionMarker(id: t.id, occurredAtUnixMilliseconds: t.occurredAtUnixMilliseconds, amount: t.amount, flow: t.flow, title: title, timePrecision: t.timePrecision)
    }
    let ts = [named(a, "Metro"), named(b, "Metro"), named(c, "Cafe")]
    let rules = TransactionRuleSet(rules: [rule("m", .exact, "Metro", [.setCategory(transit), .setTitle("지하철"), .addTags(["교통"])])])
    let mine = TransactionOverride(title: nil, category: CanonicalCategoryID(rawValue: "food"), memo: "메모", tags: ["내태그"])
    let entries = LedgerList.sections(ts, life: .empty, zone: zone, overrides: [b.id: mine], rules: rules).flatMap(\.entries)
    let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id.rawValue, $0) })
    #expect(byID["a"]?.transaction.title == "지하철" && byID["a"]?.categoryID == transit && byID["a"]?.originalTitle == "Metro")
    #expect(byID["b"]?.transaction.title == "지하철")                       // the rule still names it
    #expect(byID["b"]?.categoryID?.rawValue == "food")                       // but the user's category wins
    #expect(byID["b"]?.categoryWithoutEdit == transit)
    #expect(byID["b"]?.tags == ["교통", "내태그"])
    #expect(byID["c"]?.transaction.title == "Cafe" && byID["c"]?.rule == nil)
}

@Test func rulesAndTheEditLogSurviveSavingAndOldFilesStillRead() throws {
    var store = TransactionOverrideStore()
    store.rules = [rule("a", .regex, "^Bus", [.replace(find: "x", with: "", isRegex: false), .setCategory(transit), .addTags(["교통"])])]
    store.record(.init(id: "e1", transactionID: "t", originalTitle: "Metro", title: "지하철", category: transit, memo: nil, tags: [], atUnixMilliseconds: 1))
    let decoded = try JSONDecoder().decode(TransactionOverrideStore.self, from: JSONEncoder().encode(store))
    #expect(decoded == store)
    let old = try JSONDecoder().decode(TransactionOverrideStore.self, from: Data(#"{"byTransaction":{}}"#.utf8))
    #expect(old.rules.isEmpty && old.edits.isEmpty)
    for i in 0..<(TransactionOverrideStore.editLogLimit + 5) {
        store.record(.init(id: "\(i)", transactionID: "t", originalTitle: nil, title: nil, category: nil, memo: nil, atUnixMilliseconds: Int64(i)))
    }
    #expect(store.edits.count == TransactionOverrideStore.editLogLimit)
}

@Test func matchCountCountsTheNamesARuleWouldCatch() {
    let r = rule("a", .contains, "metro", [.setCategory(transit)])
    #expect(TransactionRuleSet.matchCount(r, in: ["Metro", "metro card", "Taxi"]) == 2)
}

@Test func theCalendarResolvesNamesAndCategoriesLikeTheLedgerList() {
    var store = TransactionOverrideStore()
    store.rules = [rule("m", .exact, "Metro", [.setCategory(transit), .setTitle("지하철")])]
    let a = LedgerEntryID(rawValue: "a"), b = LedgerEntryID(rawValue: "b")
    store[b] = TransactionOverride(title: nil, category: CanonicalCategoryID(rawValue: "food"), memo: nil, tags: [])
    let ruled = store.display(a, title: "Metro", category: nil)
    #expect(ruled.title == "지하철" && ruled.category == transit)                         // rule over original
    let edited = store.display(b, title: "Metro", category: nil)
    #expect(edited.title == "지하철" && edited.category?.rawValue == "food")              // the user's edit wins, field by field
    let plain = store.display(a, title: "Cafe", category: CanonicalCategoryID(rawValue: "x"))
    #expect(plain.title == "Cafe" && plain.category?.rawValue == "x")                    // nothing matched: untouched
}
