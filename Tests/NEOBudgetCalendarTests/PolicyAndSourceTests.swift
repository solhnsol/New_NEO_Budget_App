import Testing
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryCalendar
import NEOBudgetInMemoryStorage

// MARK: Assignment policy and category hook

@Test func automatedAssignmentsNeedEnoughConfidenceAndUsersAreAlwaysAccepted() {
    let policy = AssignmentPolicy()
    #expect(policy.accepts(userProvenance()))
    #expect(policy.accepts(autoProvenance(0.85)))
    #expect(policy.accepts(autoProvenance(1.0)))
    #expect(!policy.accepts(autoProvenance(0.84)))
    #expect(!policy.accepts(autoProvenance(nil)))              // no confidence is not trusted
    #expect(!policy.accepts(autoProvenance(Double.nan)))
    #expect(!policy.accepts(autoProvenance(1.2)))
    #expect(AssignmentPolicy(minimumAutomatedConfidence: 0.5).accepts(autoProvenance(0.6)))
}

@Test func lowConfidenceCategoryStaysUnclassifiedInsteadOfGuessing() {
    let policy = AssignmentPolicy()
    let food = CanonicalCategoryID(rawValue: "food")
    #expect(CategoryAssignment.initial == .unclassified(.notYetEvaluated))
    #expect(policy.classification(proposing: food, provenance: autoProvenance(0.4)) == .unclassified(.ambiguous))
    #expect(policy.classification(proposing: food, provenance: autoProvenance(nil)) == .unclassified(.ambiguous))
    let accepted = policy.classification(proposing: food, provenance: autoProvenance(0.95))
    #expect(accepted.categoryID == food)
}

@Test func aUserCategoryIsNeverReplacedByAutomation() {
    let policy = AssignmentPolicy()
    let food = CanonicalCategoryID(rawValue: "food")
    let transport = CanonicalCategoryID(rawValue: "transport")
    let userChoice = policy.classification(proposing: food, provenance: userProvenance())
    #expect(userChoice.categoryID == food)
    #expect(policy.classification(proposing: transport, provenance: autoProvenance(0.99), replacing: userChoice) == userChoice)
    // A weak automated proposal never downgrades an existing category either.
    let auto = policy.classification(proposing: food, provenance: autoProvenance(0.9))
    #expect(policy.classification(proposing: transport, provenance: autoProvenance(0.2), replacing: auto) == auto)
    // A user can replace an automated category.
    #expect(policy.classification(proposing: transport, provenance: userProvenance(), replacing: auto).categoryID == transport)
}

// MARK: Reconciliation

private let lecture = event("lecture", title: "강의", from: at(today, 10), to: at(today, 11))
private let nextMonth = event("later", title: "다음 달", from: at(today.adding(days: 30), 10), to: at(today.adding(days: 30), 11))
private let activityOne = ActivityID(rawValue: "a1")
private let activityTwo = ActivityID(rawValue: "a2")

private func reconcileState(_ events: [CalendarEvent]) throws -> LifeState {
    try LifeState.empty.applying(zip(events, [activityOne, activityTwo]).map { .createActivity(Activity.materialized(from: $0.0, id: $0.1, at: 1)) })
}

private func reconcile(_ life: LifeState, fetched: [CalendarEvent], calendars: Set<CalendarID>? = nil) -> [LifeChange] {
    let bounds = (from: seoul.startOfDay(today), to: seoul.startOfDay(today.adding(days: 7)))
    return CalendarReconciler.reconcile(life: life, fetched: fetched, window: bounds, queriedCalendarIDs: calendars, timeZone: seoul, now: 1_000)
}

@Test func anEventMissingFromTheWindowMarksItsActivityMissing() throws {
    let life = try reconcileState([lecture])
    let changes = reconcile(life, fetched: [])
    guard case let .updateAssociation(id, association)? = changes.first, changes.count == 1 else {
        Issue.record("expected one association update, got \(changes)")
        return
    }
    #expect(id == activityOne)
    #expect(association.status == .missing(sinceUnixMilliseconds: 1_000))
    #expect(association.lastKnown.title == "강의")
    let applied = try life.applying(changes)
    #expect(applied.activities[activityOne]?.isEventMissing == true)
}

@Test func activitiesOutsideTheFetchedWindowOrCalendarsAreLeftAlone() throws {
    let life = try reconcileState([nextMonth])
    #expect(reconcile(life, fetched: []).isEmpty)                                    // far outside the window
    let inWindow = try reconcileState([lecture])
    #expect(reconcile(inWindow, fetched: [], calendars: [calendarID("school")]).isEmpty)   // a different calendar was queried
    #expect(!reconcile(inWindow, fetched: [], calendars: [calendarID("life")]).isEmpty)
}

@Test func aMissingEventThatReappearsBecomesPresentAgain() throws {
    var life = try reconcileState([lecture])
    life = try life.applying(reconcile(life, fetched: []))
    #expect(life.activities[activityOne]?.isEventMissing == true)
    let back = reconcile(life, fetched: [lecture])
    life = try life.applying(back)
    #expect(life.activities[activityOne]?.isEventMissing == false)
}

@Test func changedTitleOrTimeRefreshesTheLastKnownSummary() throws {
    let life = try reconcileState([lecture])
    let renamed = event("lecture", title: "세미나", from: at(today, 14), to: at(today, 15))
    let changes = reconcile(life, fetched: [renamed])
    let applied = try life.applying(changes)
    #expect(applied.activities[activityOne]?.displayTitle == "세미나")
    #expect(applied.activities[activityOne]?.association?.lastKnown.time == renamed.time)
}

@Test func reconcilingAnUnchangedWorldProducesNoChanges() throws {
    let life = try reconcileState([lecture])
    #expect(reconcile(life, fetched: [lecture]).isEmpty)
    #expect(reconcile(.empty, fetched: [lecture]).isEmpty)       // events without an Activity are never touched
}

@Test func standaloneActivitiesAreNeverJudgedByTheCalendar() throws {
    let info = StandaloneActivityInfo(title: "산책", time: .timed(timed(at(today, 7), at(today, 8))))
    let life = try LifeState.empty.applying([.createActivity(Activity(id: ActivityID(rawValue: "w"), origin: .standalone(info), createdAtUnixMilliseconds: 1))])
    #expect(reconcile(life, fetched: []).isEmpty)
}

// MARK: Ledger-backed transaction source

private func ledgerSnapshot(base: Int64 = 0) throws -> (LedgerSnapshot, LedgerEntryID, LedgerEntryID) {
    let bank = AccountID(rawValue: "bank")
    let savings = AccountID(rawValue: "savings")
    let card = CreditInstrumentID(rawValue: "card")
    var repository = try InMemoryLedgerRepository(configuration: LedgerConfiguration(
        accounts: [
            Account(id: bank, name: "생활비", kind: .bank, openingBalance: won(1_000_000)),
            Account(id: savings, name: "저축", kind: .bank, openingBalance: won(0))
        ],
        creditInstruments: [try CreditInstrument(id: card, name: "카드", currency: "KRW")]
    ))
    let october = try BudgetMonth(year: 2026, month: 10)
    let expense = LedgerEntry(
        id: LedgerEntryID(rawValue: "expense"), kind: .expense, occurredAtUnixMilliseconds: base + 1_000,
        postings: [Posting(accountID: bank, delta: try won(9_500).negated())],
        budgetImpact: BudgetImpact(kind: .expense, amount: won(9_500), attributedMonth: october)
    )
    let refund = LedgerEntry(
        id: LedgerEntryID(rawValue: "refund"), kind: .adjustment, occurredAtUnixMilliseconds: base + 2_000,
        postings: [Posting(accountID: bank, delta: won(3_000))],
        budgetImpact: BudgetImpact(kind: .return, amount: won(3_000), attributedMonth: october),
        adjustment: AdjustmentLink(originalEntryID: expense.id, reason: .refund)
    )
    let income = LedgerEntry(id: LedgerEntryID(rawValue: "income"), kind: .income, occurredAtUnixMilliseconds: base + 3_000, postings: [Posting(accountID: bank, delta: won(500_000))])
    let transfer = LedgerEntry(
        id: LedgerEntryID(rawValue: "transfer"), kind: .transfer, occurredAtUnixMilliseconds: base + 4_000,
        postings: [Posting(accountID: bank, delta: try won(100_000).negated()), Posting(accountID: savings, delta: won(100_000))]
    )
    let cardBill = LedgerEntry(
        id: LedgerEntryID(rawValue: "bill"), kind: .cardPayment, occurredAtUnixMilliseconds: base + 5_000,
        postings: [Posting(accountID: bank, delta: try won(1_000).negated())],
        liabilityChanges: [LiabilityChange(instrumentID: card, delta: try won(1_000).negated())]
    )
    let cardPurchase = LedgerEntry(
        id: LedgerEntryID(rawValue: "card-purchase"), kind: .expense, occurredAtUnixMilliseconds: base + 6_000,
        liabilityChanges: [LiabilityChange(instrumentID: card, delta: won(7_000))],
        budgetImpact: BudgetImpact(kind: .expense, amount: won(7_000), attributedMonth: october)
    )
    var revision: UInt64 = 0
    for entry in [expense, refund, income, transfer, cardPurchase, cardBill] {
        _ = try repository.commit(entry, expectedRevision: revision)
        revision += 1
    }
    return (try repository.snapshot(), expense.id, refund.id)
}

@Test func onlyConsumptionEntriesBecomeTransactionMarkers() throws {
    let (snapshot, expenseID, refundID) = try ledgerSnapshot()
    let source = LedgerTransactionSource(snapshot: snapshot, titles: [expenseID: "점심"])
    let all = source.transactions(occurringFrom: 0, to: 100_000)
    #expect(all.map(\.id.rawValue) == ["expense", "refund", "card-purchase"])      // income, transfer, and the card bill are not consumption
    #expect(source.transaction(expenseID)?.flow == .spend)
    #expect(source.transaction(expenseID)?.title == "점심")
    #expect(source.transaction(expenseID)?.amount == won(9_500))
    #expect(source.transaction(refundID)?.flow == .refund)
    #expect(source.transaction(refundID)?.signedMinorUnits == -3_000)
    #expect(source.transaction(LedgerEntryID(rawValue: "income")) == nil)
    #expect(source.transaction(LedgerEntryID(rawValue: "transfer")) == nil)
    #expect(source.transaction(LedgerEntryID(rawValue: "bill")) == nil)
}

@Test func ledgerMarkersCanBeFilteredByTimeAndFetchedByID() throws {
    let (snapshot, expenseID, refundID) = try ledgerSnapshot()
    let source = LedgerTransactionSource(snapshot: snapshot)
    #expect(source.transactions(occurringFrom: 1_500, to: 6_000).map(\.id.rawValue) == ["refund"])
    #expect(source.transactions(withIDs: [refundID, expenseID, LedgerEntryID(rawValue: "missing")]).map(\.id.rawValue) == ["expense", "refund"])
    #expect(source.transaction(expenseID)?.timePrecision == .approximate)
    #expect(LedgerTransactionSource(snapshot: snapshot, timePrecision: .exact).transaction(expenseID)?.timePrecision == .exact)
}

@Test func aTimelineBuiltFromARealLedgerShowsConsumptionAndOmitsMoneyMovement() throws {
    let (snapshot, expenseID, _) = try ledgerSnapshot(base: at(today, 12))
    let source = LedgerTransactionSource(snapshot: snapshot, titles: [expenseID: "점심"])
    let bounds = seoul.dayBounds(today)
    let markers = source.transactions(occurringFrom: bounds.start, to: bounds.end)
    let timeline = DayTimelineBuilder.build(DayTimelineInput(day: today, timeZone: seoul, events: [], life: .empty, transactions: markers))

    // Expense, refund, and the card purchase are consumption; income, the transfer, and the card bill are not.
    let ids = timeline.markers.map { $0.transactionID.rawValue }
    #expect(ids == ["expense", "refund", "card-purchase"])
    #expect(timeline.markers.first?.title == "점심")
    let flows = timeline.markers.map { $0.flow }
    #expect(flows == [TransactionFlow.spend, TransactionFlow.refund, TransactionFlow.spend])
    let expectedNet: Int64 = 13_500          // 9,500 - 3,000 + 7,000
    let net = timeline.summary.totals.first?.unlinkedNetMinorUnits
    #expect(net == expectedNet)
    #expect(timeline.summary.unlinkedTransactionCount == 3)
}
