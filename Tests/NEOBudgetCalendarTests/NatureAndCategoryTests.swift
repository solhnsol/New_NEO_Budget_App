import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private func failure(_ block: () throws -> Void) -> LifeValidationError? {
    do { try block(); return nil } catch let error as LifeValidationError { return error } catch { return nil }
}

private let foodDining = CanonicalCategoryID(rawValue: "food.dining")
private let rent = CanonicalCategoryID(rawValue: "housing.rent")
private let phone = CanonicalCategoryID(rawValue: "shopping.electronics")
private let jeju = ActivityID(rawValue: "jeju")
private let lunch = ActivityID(rawValue: "lunch")

private func classified(_ id: CanonicalCategoryID, by provenance: AssignmentProvenance = userProvenance()) -> CategoryAssignment {
    .classified(id, provenance)
}

private func nature(_ value: SpendingNature, by provenance: AssignmentProvenance = userProvenance()) -> Assigned<SpendingNature> {
    Assigned(value, provenance: provenance)
}

/// A trip and an ordinary lunch, plus the tags and types the signals can hang on.
private func tripLife(extra: [LifeChange] = []) -> LifeState {
    let trip = Activity.materialized(from: event("jeju", title: "제주 여행", from: at(today, 9), to: at(today.adding(days: 3), 18)), id: jeju, at: 1)
    let meal = Activity.materialized(from: event("lunch", title: "점심", from: at(today, 12), to: at(today, 13)), id: lunch, at: 1)
    return lifeWithPeople([], extra: [.createActivity(trip), .createActivity(meal)] + extra)
}

private func spend(
    _ transaction: String, to activity: ActivityID?, _ amount: AmountKnowledge, total: Int64? = nil,
    category: CategoryAssignment = .initial, flow: TransactionFlow = .spend, id: String? = nil
) -> LifeChange {
    let value: Int64 = total ?? amount.knownValue ?? 100_000
    return .upsertAllocation(
        TransactionAllocation(
            id: AllocationID(rawValue: id ?? "alloc-\(transaction)"), transactionID: txID(transaction), activityID: activity,
            amount: entry(amount), category: category, provenance: userProvenance(), createdAtUnixMilliseconds: 1
        ),
        transactionTotal: won(value), flow: flow
    )
}

private func allocationID(_ transaction: String) -> AllocationID { AllocationID(rawValue: "alloc-\(transaction)") }

private func resolved(_ life: LifeState, _ transaction: String) throws -> ResolvedSpendingNature {
    SpendingNatureResolver.resolve(allocation: try #require(life.allocation(allocationID(transaction))), in: life)
}

// MARK: Scenario M — a trip meal is irregular, not living

@Test func scenarioMATripMealKeepsItsCategoryButCountsAsIrregular() throws {
    let life = try tripLife(extra: [
        .setSpendingNature(.category(foodDining), nature(.living, by: autoProvenance(1.0))),   // category default
        .setSpendingNature(.activity(jeju), nature(.irregular)),                                // this trip
        spend("trip-meal", to: jeju, .exact(60_000), category: classified(foodDining)),
        spend("office-lunch", to: lunch, .exact(8_000), category: classified(foodDining))
    ])
    let tripMeal = try resolved(life, "trip-meal")
    #expect(tripMeal.nature == .irregular && tripMeal.source == .activity)
    let ordinary = try resolved(life, "office-lunch")
    #expect(ordinary.nature == .living && ordinary.source == .category)

    // The category did not change: both are 식비 > 외식. Only the budget meaning differs.
    let items = SpendingAnalytics.items(in: life)
    #expect(Set(items.compactMap(\.category.categoryID)) == [foodDining])
    let breakdown = try #require(SpendingAnalytics.byNature(items).first)
    #expect(breakdown.irregular?.exactMinorUnits == 60_000)
    #expect(breakdown.living?.exactMinorUnits == 8_000)
    #expect(breakdown.unspecified == nil && breakdown.discretionary == nil)
    #expect(breakdown.total.exactMinorUnits == 68_000)
}

@Test func theLivingBudgetIsNotDistortedByOneBigPurchase() throws {
    // 총 지출 1,500,000 = 생활비 700,000 + 비정기 700,000 + 선택 100,000.
    let life = try tripLife(extra: [
        .setSpendingNature(.category(rent), nature(.living, by: autoProvenance(1.0))),
        .setSpendingNature(.category(phone), nature(.irregular, by: autoProvenance(1.0))),
        .setSpendingNature(.category(foodDining), nature(.discretionary, by: autoProvenance(1.0))),
        spend("rent", to: nil, .exact(700_000), category: classified(rent)),
        spend("iphone", to: nil, .exact(700_000), category: classified(phone)),
        spend("dining", to: nil, .exact(100_000), category: classified(foodDining))
    ])
    let breakdown = try #require(life.spendingByNature().first)
    #expect(breakdown.currency == "KRW")
    #expect(breakdown.total.exactMinorUnits == 1_500_000)
    #expect(breakdown.aggregate(for: .living)?.exactMinorUnits == 700_000)
    #expect(breakdown.aggregate(for: .irregular)?.exactMinorUnits == 700_000)
    #expect(breakdown.aggregate(for: .discretionary)?.exactMinorUnits == 100_000)
    // Budgeting against living costs alone no longer sees the phone.
    #expect((breakdown.living?.exactMinorUnits ?? 0) + (breakdown.discretionary?.exactMinorUnits ?? 0) == 800_000)
}

@Test func natureIsResolvedFromTheMostSpecificStatement() throws {
    let tag = TagID(rawValue: "trip-tag")
    let base = try tripLife(extra: [
        .upsertTag(OnAllTag(id: tag, name: "여행")),
        .setActivityTag(jeju, TagAssignment(tagID: tag, provenance: userProvenance())),
        spend("meal", to: jeju, .exact(10_000), category: classified(foodDining))
    ])
    // Only a category default: living.
    let withCategory = try base.applying([.setSpendingNature(.category(foodDining), nature(.living, by: autoProvenance(1.0)))])
    #expect(try resolved(withCategory, "meal").source == .category)
    // An activity type beats the category.
    let typeID = ActivityTypeID(rawValue: "travel")
    let withType = try withCategory.applying([
        .upsertActivityType(ActivityTypeDefinition(id: typeID, displayName: "여행", isPreset: false)),
        .setActivityType(jeju, Assigned(typeID, provenance: userProvenance())),
        .setSpendingNature(.activityType(typeID), nature(.irregular))
    ])
    #expect(try resolved(withType, "meal") == ResolvedSpendingNature(nature: .irregular, source: .activityType))
    // A tag beats the type.
    let withTag = try withType.applying([.setSpendingNature(.tag(tag), nature(.discretionary))])
    #expect(try resolved(withTag, "meal") == ResolvedSpendingNature(nature: .discretionary, source: .tag))
    // The activity itself beats the tag.
    let withActivity = try withTag.applying([.setSpendingNature(.activity(jeju), nature(.living))])
    #expect(try resolved(withActivity, "meal") == ResolvedSpendingNature(nature: .living, source: .activity))
    // The transaction beats the activity, and the allocation beats the transaction.
    let withTransaction = try withActivity.applying([.setSpendingNature(.transaction(txID("meal")), nature(.irregular))])
    #expect(try resolved(withTransaction, "meal") == ResolvedSpendingNature(nature: .irregular, source: .transaction))
    let withAllocation = try withTransaction.applying([.setSpendingNature(.allocation(allocationID("meal")), nature(.discretionary))])
    #expect(try resolved(withAllocation, "meal") == ResolvedSpendingNature(nature: .discretionary, source: .allocation))
    // Clearing the narrowest statement falls back to the next one.
    let cleared = try withAllocation.applying([.clearSpendingNature(.allocation(allocationID("meal")), by: userProvenance())])
    #expect(try resolved(cleared, "meal").source == .transaction)
}

@Test func nothingStatedMeansUnspecifiedNeverLiving() throws {
    let life = try tripLife(extra: [spend("mystery", to: nil, .exact(5_000))])
    #expect(try resolved(life, "mystery") == ResolvedSpendingNature(nature: nil, source: .none))
    let breakdown = try #require(life.spendingByNature().first)
    #expect(breakdown.unspecified?.exactMinorUnits == 5_000)
    #expect(breakdown.living == nil)
}

@Test func tagsThatDisagreeCountAsNoStatement() throws {
    let a = TagID(rawValue: "a"), b = TagID(rawValue: "b")
    let life = try tripLife(extra: [
        .upsertTag(OnAllTag(id: a, name: "경조사")), .upsertTag(OnAllTag(id: b, name: "정기")),
        .setActivityTag(jeju, TagAssignment(tagID: a, provenance: userProvenance())),
        .setActivityTag(jeju, TagAssignment(tagID: b, provenance: userProvenance())),
        .setSpendingNature(.tag(a), nature(.irregular)), .setSpendingNature(.tag(b), nature(.living)),
        .setSpendingNature(.category(foodDining), nature(.discretionary, by: autoProvenance(1.0))),
        spend("meal", to: jeju, .exact(10_000), category: classified(foodDining))
    ])
    #expect(try resolved(life, "meal") == ResolvedSpendingNature(nature: .discretionary, source: .category))
}

@Test func aUserNatureIsNeverOverwrittenByAutomation() throws {
    let life = try tripLife(extra: [
        .setSpendingNature(.activity(jeju), nature(.irregular)),
        .setSpendingNature(.category(foodDining), nature(.living, by: autoProvenance(1.0)))
    ])
    #expect(failure { _ = try life.applying([.setSpendingNature(.activity(jeju), nature(.living, by: autoProvenance(1.0)))]) } == .userAssignmentProtected)
    #expect(failure { _ = try life.applying([.clearSpendingNature(.activity(jeju), by: autoProvenance(1.0))]) } == .userAssignmentProtected)
    // Automation may revise its own earlier guess, and the user may replace anything.
    #expect((try life.applying([.setSpendingNature(.category(foodDining), nature(.discretionary, by: autoProvenance(0.9, 5)))])).natureSignals[.category(foodDining)]?.value == .discretionary)
    #expect((try life.applying([.setSpendingNature(.activity(jeju), nature(.living))])).natureSignals[.activity(jeju)]?.value == .living)
    #expect(failure { _ = try life.applying([.setSpendingNature(.activity(jeju), nature(.living, by: autoProvenance(Double.nan)))]) } == .invalidConfidence)
}

@Test func natureTargetsMustExistAndTheirSignalsGoWhenTheyDo() throws {
    let life = tripLife()
    #expect(failure { _ = try life.applying([.setSpendingNature(.activity(ActivityID(rawValue: "x")), nature(.living))]) } == .unknownNatureTarget(.activity(ActivityID(rawValue: "x"))))
    #expect(failure { _ = try life.applying([.setSpendingNature(.tag(TagID(rawValue: "x")), nature(.living))]) } == .unknownNatureTarget(.tag(TagID(rawValue: "x"))))
    #expect(failure { _ = try life.applying([.setSpendingNature(.allocation(AllocationID(rawValue: "x")), nature(.living))]) } == .unknownNatureTarget(.allocation(AllocationID(rawValue: "x"))))
    #expect(failure { _ = try life.applying([.setSpendingNature(.activityType(ActivityTypeID(rawValue: "x")), nature(.living))]) } == .unknownNatureTarget(.activityType(ActivityTypeID(rawValue: "x"))))

    let withSignals = try life.applying([
        spend("meal", to: nil, .exact(1_000)),
        .setSpendingNature(.allocation(allocationID("meal")), nature(.irregular)),
        .setSpendingNature(.activity(lunch), nature(.discretionary))
    ])
    let removed = try withSignals.applying([.removeAllocation(allocationID("meal"), by: userProvenance()), .removeActivity(lunch)])
    #expect(removed.natureSignals.isEmpty)
}

@Test func refundsAreNotMixedIntoSpendingByNature() throws {
    let life = try tripLife(extra: [
        spend("buy", to: nil, .exact(50_000)),
        spend("back", to: nil, .exact(20_000), flow: .refund)
    ])
    #expect(try #require(life.spendingByNature().first).total.exactMinorUnits == 50_000)
    #expect(try #require(life.spendingByNature(flow: .refund).first).total.exactMinorUnits == 20_000)
}

@Test func uncertainAmountsStayUncertainInTheNatureBreakdown() throws {
    let life = try tripLife(extra: [
        .setSpendingNature(.activity(jeju), nature(.irregular)),
        spend("hotel", to: jeju, .exact(300_000)),
        spend("food", to: jeju, amountRange(100_000, 130_000), total: 200_000),
        spend("misc", to: jeju, .unknown, total: 80_000)
    ])
    let irregular = try #require(life.spendingByNature().first?.irregular)
    #expect(irregular.exactMinorUnits == 300_000)
    #expect(irregular.lowerBoundMinorUnits == 400_000 && irregular.upperBoundMinorUnits == nil)   // an unknown has no ceiling
    #expect(irregular.unresolvedCount == 2)
}

@Test func spendingNatureIsIndependentOfCategoryAndOfAmountKnowledge() throws {
    // Same category, three natures; an unknown amount carries a nature too.
    let life = try tripLife(extra: [
        spend("a", to: nil, .exact(1_000), category: classified(foodDining)),
        spend("b", to: nil, .unknown, total: 2_000, category: classified(foodDining)),
        .setSpendingNature(.allocation(allocationID("a")), nature(.living)),
        .setSpendingNature(.allocation(allocationID("b")), nature(.irregular))
    ])
    #expect(try resolved(life, "a").nature == .living && (try resolved(life, "b").nature == .irregular))
    #expect(life.allocation(allocationID("a"))?.category == life.allocation(allocationID("b"))?.category)
}

@Test func componentsResolveTheirNatureFromTheirActivityToo() throws {
    let tripComponent = ExpenseComponent(
        id: ExpenseComponentID(rawValue: "c"), activityID: jeju, amount: entry(.exact(90_000)), payerID: myself,
        category: classified(foodDining), provenance: userProvenance(), createdAtUnixMilliseconds: 1
    )
    let life = try tripLife(extra: [
        .setSpendingNature(.category(foodDining), nature(.living, by: autoProvenance(1.0))),
        .upsertExpenseComponent(tripComponent)
    ])
    #expect(SpendingNatureResolver.resolve(component: tripComponent, in: life).source == .category)
    let overridden = try life.applying([.setSpendingNature(.component(tripComponent.id), nature(.irregular))])
    #expect(SpendingNatureResolver.resolve(component: tripComponent, in: overridden) == ResolvedSpendingNature(nature: .irregular, source: .component))
    let items = SpendingAnalytics.items(fromComponentsIn: overridden)
    #expect(try #require(SpendingAnalytics.byNature(items).first).irregular?.exactMinorUnits == 90_000)
}

// MARK: Scenario N — five different category states

private let userUnknown = CategoryAssignment.confirmedUnknown(userProvenance())

@Test func scenarioNTheFiveCategoryStatesAreDistinct() throws {
    let states: [CategoryAssignment] = [
        .classified(foodDining, userProvenance()),
        .other(userProvenance()),
        .unresolved,
        .confirmedUnknown(userProvenance()),
        .unclassified(.notYetEvaluated)
    ]
    // Equality: no two are the same.
    for (i, lhs) in states.enumerated() {
        for (j, rhs) in states.enumerated() where i != j { #expect(lhs != rhs) }
    }
    #expect(Set(states).count == 5)
    #expect(states.map(\.kind) == [.classified, .other, .unresolved, .confirmedUnknown, .unclassified])
    // Same words, different meaning: 모름 and 기타 by the same person at the same time are still not equal.
    #expect(CategoryAssignment.other(userProvenance(5)) != CategoryAssignment.confirmedUnknown(userProvenance(5)))
    #expect(CategoryAssignment.unclassified(.ambiguous) != CategoryAssignment.unclassified(.notYetEvaluated))

    // Serialization keeps them apart.
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    for state in states + [.unclassified(.ambiguous)] {
        #expect(try decoder.decode(CategoryAssignment.self, from: try encoder.encode(state)) == state)
    }
    let encoded = Set(try states.map { String(decoding: try encoder.encode($0), as: UTF8.self) })
    #expect(encoded.count == 5)
}

@Test func scenarioNAnalyticsReportTheFiveStatesSeparately() throws {
    let life = try tripLife(extra: [
        spend("a", to: nil, .exact(10_000), category: classified(foodDining)),
        spend("b", to: nil, .exact(20_000), category: .other(userProvenance())),
        spend("c", to: nil, .exact(30_000), category: .confirmedUnknown(userProvenance())),
        spend("d", to: nil, .exact(40_000), category: .unclassified(.notYetEvaluated)),
        spend("e", to: nil, .exact(50_000), category: .unclassified(.ambiguous)),
        spend("f", to: nil, .exact(60_000), category: .unresolved)
    ])
    let breakdown = try #require(SpendingAnalytics.byCategoryState(SpendingAnalytics.items(in: life)).first)
    #expect(breakdown.classified?.exactMinorUnits == 10_000)
    #expect(breakdown.other?.exactMinorUnits == 20_000)
    #expect(breakdown.confirmedUnknown?.exactMinorUnits == 30_000)
    #expect(breakdown.unresolved?.exactMinorUnits == 60_000)
    #expect(breakdown.unclassified?.exactMinorUnits == 90_000)          // both pending reasons
    #expect(breakdown.total.exactMinorUnits == 210_000)

    // Review order: what only the user can answer first, then conflicts, then plain pending. A confirmed
    // unknown is not asked again on the same evidence.
    let queue = SpendingAnalytics.reviewQueue(SpendingAnalytics.items(in: life)).map(\.id)
    #expect(queue == ["alloc-f", "alloc-e", "alloc-d"])
    #expect(CategoryAssignment.unresolved.reviewPriority > CategoryAssignment.unclassified(.ambiguous).reviewPriority)
    #expect(CategoryAssignment.unclassified(.ambiguous).reviewPriority > CategoryAssignment.unclassified(.notYetEvaluated).reviewPriority)
    #expect(CategoryAssignment.other(userProvenance()).reviewPriority == 0 && classified(foodDining).reviewPriority == 0)
}

@Test func amountUncertaintyAndCategoryUncertaintyAreIndependentAxes() throws {
    // 정산 총액 31,000 is exact; its parts have unknown amounts and different category knowledge.
    let life = try tripLife(extra: [
        spend("settle", to: nil, .exact(10_000), total: 31_000, category: .confirmedUnknown(userProvenance()), id: "exact-unknown"),
        spend("settle", to: lunch, .unknown, total: 31_000, category: classified(foodDining), id: "unknown-classified"),
        spend("settle", to: jeju, .unknown, total: 31_000, category: .confirmedUnknown(userProvenance()), id: "unknown-unknown")
    ])
    let items = SpendingAnalytics.items(in: life)
    func item(_ id: String) throws -> SpendingItem { try #require(items.first { $0.id == id }) }
    #expect(try item("exact-unknown").amount.knowledge == .exact(10_000) && (try item("exact-unknown").category.kind == .confirmedUnknown))
    #expect(try item("unknown-classified").amount.knowledge == .unknown && (try item("unknown-classified").category.kind == .classified))
    #expect(try item("unknown-unknown").amount.knowledge == .unknown && (try item("unknown-unknown").category.kind == .confirmedUnknown))
    // The remainder of the 31,000 is a statement about amounts, not about categories.
    #expect(life.allocationSet(for: txID("settle"))?.remainder == AmountBounds(lower: 0, upper: 21_000))
}

@Test func complexIsNotACategory() {
    // There is no 'complex' value to choose: an amount known only as a sum is an AmountGroup, not a category.
    let all: [CategoryAssignmentKind] = [.classified, .other, .unresolved, .confirmedUnknown, .unclassified]
    #expect(Set(all.map(\.rawValue)) == ["classified", "other", "unresolved", "confirmedUnknown", "unclassified"])
}

// MARK: Provenance and overwrite rules for categories

@Test func aUserCategoryDecisionOfAnyKindIsNeverOverwrittenByAutomation() throws {
    let policy = AssignmentPolicy()
    let confident = autoProvenance(0.99)
    for existing in [classified(foodDining), .other(userProvenance()), .confirmedUnknown(userProvenance())] as [CategoryAssignment] {
        #expect(policy.classification(proposing: phone, provenance: confident, replacing: existing) == existing)
    }
    // And through the state: setting a category is protected the same way.
    let life = try tripLife(extra: [spend("a", to: nil, .exact(1_000), category: .confirmedUnknown(userProvenance()))])
    let id = allocationID("a")
    #expect(failure { _ = try life.applying([.setAllocationCategory(id, .classified(foodDining, confident))]) } == .userAssignmentProtected)
    #expect(failure { _ = try life.applying([.setAllocationCategory(id, .unclassified(.ambiguous))]) } == .userAssignmentProtected)
    #expect((try life.applying([.setAllocationCategory(id, classified(foodDining))])).allocation(id)?.category == classified(foodDining))
}

@Test func aClassifierCannotTurnLackOfInformationIntoACategoryByBeingConfident() {
    let policy = AssignmentPolicy()
    let confirmed = CategoryAssignment.confirmedUnknown(userProvenance(10, evidenceVersion: 100))
    // Confident, but it looked at the same evidence (or did not say which): the user's "I do not know" stays.
    #expect(policy.classification(proposing: foodDining, provenance: autoProvenance(0.99), replacing: confirmed) == confirmed)
    #expect(policy.classification(proposing: foodDining, provenance: .automated(origin: "r", confidence: 0.99, at: 20, evidenceVersion: 100), replacing: confirmed) == confirmed)
    // With newer evidence (a merchant arrived, a receipt was read) it may be classified.
    #expect(policy.classification(proposing: foodDining, provenance: .automated(origin: "r", confidence: 0.99, at: 20, evidenceVersion: 101), replacing: confirmed).categoryID == foodDining)
    // Even then, a weak proposal does not become a category.
    #expect(policy.classification(proposing: foodDining, provenance: .automated(origin: "r", confidence: 0.4, at: 20, evidenceVersion: 101), replacing: confirmed) == confirmed)
    // The user needs no evidence: they can say what it was.
    #expect(policy.classification(proposing: foodDining, provenance: userProvenance(), replacing: confirmed).categoryID == foodDining)
    // 'Pending' is different from 'confirmed unknown': a classifier can fill it, or leave it ambiguous.
    #expect(policy.classification(proposing: foodDining, provenance: autoProvenance(0.99)).categoryID == foodDining)
    #expect(policy.classification(proposing: foodDining, provenance: autoProvenance(0.4)) == .unclassified(.ambiguous))
    #expect(policy.classification(proposing: foodDining, provenance: autoProvenance(0.4), replacing: .unresolved) == .unresolved)
    // A low-confidence proposal never erases a recorded 'other' either.
    let other = CategoryAssignment.other(autoProvenance(1.0))
    #expect(policy.classification(proposing: foodDining, provenance: autoProvenance(0.4), replacing: other) == other)
}

@Test func categoriesCanBeSetOnAllocationsAndComponentsThroughTheService() async throws {
    let life = tripLife(extra: [spend("a", to: nil, .exact(1_000))])
    let h = Harness.make(life: life)
    let target = CategoryTarget.allocation(allocationID("a"))
    #expect(await h.service.perform(.setCategory(SetCategoryInput(target: target, assignment: .classified(foodDining, autoProvenance(0.2)))))
        == .rejected(.provenanceRejected))
    guard case .applied = await h.service.perform(.setCategory(SetCategoryInput(target: target, assignment: .other(userProvenance())))) else {
        Issue.record("expected the user's 기타 to be stored")
        return
    }
    #expect((await h.life()).allocation(allocationID("a"))?.category == .other(userProvenance()))
    #expect(await h.service.perform(.setCategory(SetCategoryInput(target: target, assignment: .classified(foodDining, autoProvenance(0.99)))))
        == .rejected(.userAssignmentProtected))
    #expect(await h.service.perform(.setCategory(SetCategoryInput(target: .component(ExpenseComponentID(rawValue: "ghost")), assignment: .confirmedUnknown(userProvenance()))))
        == .rejected(.lifeValidation(.unknownComponent(ExpenseComponentID(rawValue: "ghost")))))
}

@Test func natureCanBeSetAndClearedThroughTheService() async throws {
    let h = Harness.make(life: tripLife())
    let target = NatureTarget.activity(jeju)
    #expect(await h.service.perform(.setSpendingNature(SetSpendingNatureInput(target: target, nature: .irregular, provenance: autoProvenance(0.3)))) == .rejected(.provenanceRejected))
    guard case .applied = await h.service.perform(.setSpendingNature(SetSpendingNatureInput(target: target, nature: .irregular, provenance: userProvenance()))) else {
        Issue.record("expected the nature to be stored")
        return
    }
    #expect((await h.life()).natureSignals[target]?.value == .irregular)
    #expect(await h.service.perform(.setSpendingNature(SetSpendingNatureInput(target: target, nature: nil, provenance: autoProvenance(0.99)))) == .rejected(.userAssignmentProtected))
    guard case .applied = await h.service.perform(.setSpendingNature(SetSpendingNatureInput(target: target, nature: nil, provenance: userProvenance()))) else {
        Issue.record("expected the nature to be cleared")
        return
    }
    #expect((await h.life()).natureSignals.isEmpty)
}

@Test func allocationUpsertsCannotSneakPastACategoryProtection() throws {
    let life = try tripLife(extra: [spend("a", to: nil, .exact(1_000), category: classified(foodDining))])
    let existing = try #require(life.allocation(allocationID("a")))
    var sneaky = existing
    sneaky.category = .classified(phone, autoProvenance(0.99))
    #expect(failure { _ = try life.applying([.upsertAllocation(sneaky, transactionTotal: won(1_000), flow: .spend)]) } == .userAssignmentProtected)
    var fine = existing
    fine.category = .classified(phone, userProvenance(5))
    #expect((try life.applying([.upsertAllocation(fine, transactionTotal: won(1_000), flow: .spend)])).allocation(existing.id)?.category.categoryID == phone)
}

@Test func theSpendingBreakdownAndResidualSummaryAreAvailableThroughTheService() async throws {
    let life = tripLife(extra: [
        .setSpendingNature(.category(foodDining), nature(.living, by: autoProvenance(1.0))),
        spend("a", to: nil, .exact(8_000), category: classified(foodDining)),
        spend("b", to: nil, .exact(2_000), category: .confirmedUnknown(userProvenance()))
    ])
    let h = Harness.make(life: life)
    let breakdown = try await h.service.spendingBreakdown()
    #expect(breakdown.nature.first?.living?.exactMinorUnits == 8_000)
    #expect(breakdown.nature.first?.unspecified?.exactMinorUnits == 2_000)
    #expect(breakdown.category.first?.confirmedUnknown?.exactMinorUnits == 2_000)
    #expect(try await h.service.residualSummary().isEmpty)
}
