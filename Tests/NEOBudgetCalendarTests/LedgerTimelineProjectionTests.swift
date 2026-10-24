import Testing
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryStorage

// The projection is exercised through the real pipeline (draft -> assembler -> atomic promotion -> ledger), so
// "what counts as spending" is whatever the ledger itself decided, not what a test fabricated.

private let bank = AccountID(rawValue: "bank")
private let savings = AccountID(rawValue: "savings")
private let card = CreditInstrumentID(rawValue: "card")
private let zone = "Asia/Seoul"

private struct Ledger {
    var repository: InMemoryCandidateProcessingRepository

    init() throws {
        repository = try InMemoryCandidateProcessingRepository(configuration: LedgerConfiguration(
            accounts: [
                Account(id: bank, name: "생활비", kind: .bank, openingBalance: won(1_000_000)),
                Account(id: savings, name: "저축", kind: .bank, openingBalance: won(0)),
            ],
            creditInstruments: [try CreditInstrument(id: card, name: "카드", currency: "KRW")]
        ))
    }

    /// Feeds one event and returns its ledger entry id, or `nil` if it did not become a ledger fact.
    @discardableResult
    mutating func feed(
        _ id: String,
        _ kind: DraftEventKind,
        _ direction: TransactionDirection,
        _ amount: Int64,
        at instant: Int64,
        merchant: String? = nil,
        binding: ResolvedLedgerBinding = .account(bank),
        precision: TimestampPrecision = .minute,
        source: TimestampSource = .text,
        originalApproval: (reference: String, entry: LedgerEntryID, month: BudgetMonth)? = nil
    ) throws -> LedgerEntryID? {
        let draft = try TransactionCandidateDraft(
            rawNotificationID: id, parserID: "test", parserVersion: "1", ruleID: id,
            kind: kind, direction: direction, amount: won(amount),
            occurredAt: ObservedTimestamp(unixMilliseconds: instant, precision: precision, source: source),
            counterparty: DraftCounterparty(merchantRaw: merchant),
            evidence: originalApproval.map { [DraftEvidence(kind: .originalApprovalReference, strength: .relation, value: $0.reference)] } ?? [],
            confidence: .high
        )
        let context = try CandidateAssemblyContext(
            timeZoneIdentifier: zone,
            transferCounterpartAccountID: savings,
            cardPaymentInstrumentID: card,
            adjustmentOriginalsByEvidenceValue: originalApproval.map { [$0.reference: AdjustmentOriginal(entryID: $0.entry, budgetMonth: $0.month)] } ?? [:],
            policyVersion: "test"
        )
        let candidate = try DefaultTransactionCandidateAssembler().assemble(draft, resolution: .resolved(binding), context: context)
        let snapshot = try repository.processingSnapshot()
        _ = try repository.process(candidate, expectedCandidateRevision: snapshot.candidateRevision, expectedLedgerRevision: snapshot.ledger.revision)
        return try repository.processingSnapshot().candidates[candidate.id]?.promotedEntryID
    }

    func markers() throws -> [TransactionMarker] {
        LedgerTimelineProjection.transactions(in: try repository.processingSnapshot())
    }
}

private let month = try! BudgetMonth(year: 2026, month: 10)

/// A realistic day: bank purchase, card purchase, then every kind of money movement that is not consumption.
private func representativeLedger() throws -> (ledger: Ledger, bankPurchase: LedgerEntryID, cardPurchase: LedgerEntryID, refund: LedgerEntryID) {
    var ledger = try Ledger()
    let bankPurchase = try #require(try ledger.feed("p1", .purchase, .outflow, 12_000, at: at(today, 12, 20), merchant: "성수 식당"))
    let cardPurchase = try #require(try ledger.feed(
        "p2", .purchase, .outflow, 30_000, at: at(today, 14, 5), merchant: "카페", binding: .creditInstrument(card), source: .notificationTime))
    _ = try ledger.feed("m1", .cardBillPayment, .outflow, 30_000, at: at(today, 18))
    _ = try ledger.feed("m2", .transferOut, .outflow, 100_000, at: at(today, 15))
    _ = try ledger.feed("m3", .cashWithdrawal, .outflow, 50_000, at: at(today, 16))
    _ = try ledger.feed("m4", .walletTopUp, .outflow, 20_000, at: at(today, 17))
    _ = try ledger.feed("m5", .deposit, .inflow, 2_000_000, at: at(today, 9))
    let refund = try #require(try ledger.feed(
        "r1", .refund, .inflow, 5_000, at: at(today, 20, 10), binding: .account(bank),
        originalApproval: ("ref-1", bankPurchase, month)))
    return (ledger, bankPurchase, cardPurchase, refund)
}

@Test func onlyConsumptionAndRefundsBecomeTimelineTransactions() throws {
    let fixture = try representativeLedger()
    let markers = try fixture.ledger.markers()
    #expect(markers.map(\.id) == [fixture.bankPurchase, fixture.cardPurchase, fixture.refund])
    #expect(markers.map(\.flow) == [.spend, .spend, .refund])
    #expect(markers.map(\.amount.minorUnits) == [12_000, 30_000, 5_000])
    // transfer, cash withdrawal, wallet top-up, card bill payment and income are real ledger entries that stay out
    #expect(try fixture.ledger.repository.processingSnapshot().ledger.entries.count == 8)
}

@Test func aCardPurchaseAppearsWhenTheCardIsUsedAndTheBillPaymentAddsNothing() throws {
    let fixture = try representativeLedger()
    let markers = try fixture.ledger.markers()
    let purchase = try #require(markers.first { $0.id == fixture.cardPurchase })
    #expect(purchase.occurredAtUnixMilliseconds == at(today, 14, 5))
    #expect(markers.filter { $0.amount.minorUnits == 30_000 }.count == 1)       // not counted again when the bill is paid
}

@Test func theDaySummaryCountsConsumptionOnlyAndNetsTheRefund() throws {
    let fixture = try representativeLedger()
    let result = DayTimelineBuilder.build(DayTimelineInput(
        day: today, timeZone: seoul, events: [], life: .empty, transactions: try fixture.ledger.markers()))
    let totals = try #require(result.summary.totals.first)
    #expect(totals.unlinkedNetMinorUnits == 12_000 + 30_000 - 5_000)
    #expect(totals.linkedNetMinorUnits == 0 && totals.uncertainNetMinorUnits == 0)
    #expect(result.summary.unlinkedTransactionCount == 3)
    #expect(result.markers.count == 3)
}

@Test func aRefundIsShownWhereTheMoneyCameBackAndBorrowsTheOriginalName() throws {
    var ledger = try Ledger()
    let purchase = try #require(try ledger.feed("p1", .purchase, .outflow, 12_000, at: at(today, 12, 20), merchant: "성수 식당"))
    let nextDay = today.adding(days: 1)
    let refund = try #require(try ledger.feed(
        "r1", .refund, .inflow, 12_000, at: at(nextDay, 10), originalApproval: ("ref-1", purchase, month)))
    let markers = try ledger.markers()
    let returned = try #require(markers.first { $0.id == refund })
    #expect(returned.flow == .refund && returned.occurredAtUnixMilliseconds == at(nextDay, 10))
    #expect(returned.title == "성수 식당")
    let spendDay = DayTimelineBuilder.build(DayTimelineInput(day: today, timeZone: seoul, events: [], life: .empty, transactions: markers))
    let refundDay = DayTimelineBuilder.build(DayTimelineInput(day: nextDay, timeZone: seoul, events: [], life: .empty, transactions: markers))
    #expect(spendDay.summary.totals.first?.unlinkedNetMinorUnits == 12_000)
    #expect(refundDay.summary.totals.first?.unlinkedNetMinorUnits == -12_000)
}

@Test func timePrecisionIsExactOnlyWhenTheNotificationTextStatesTheTime() throws {
    var ledger = try Ledger()
    let exactMinute = try #require(try ledger.feed("a", .purchase, .outflow, 1_000, at: at(today, 9), precision: .minute, source: .text))
    let exactSecond = try #require(try ledger.feed("b", .purchase, .outflow, 2_000, at: at(today, 10), precision: .second, source: .text))
    let dayOnly = try #require(try ledger.feed("c", .purchase, .outflow, 3_000, at: at(today, 11), precision: .day, source: .text))
    let arrival = try #require(try ledger.feed("d", .purchase, .outflow, 4_000, at: at(today, 12), precision: .second, source: .notificationTime))
    let captured = try #require(try ledger.feed("e", .purchase, .outflow, 5_000, at: at(today, 13), precision: .second, source: .captureTime))
    let precision = Dictionary(uniqueKeysWithValues: try ledger.markers().map { ($0.id, $0.timePrecision) })
    #expect(precision[exactMinute] == .exact && precision[exactSecond] == .exact)
    #expect(precision[dayOnly] == .approximate && precision[arrival] == .approximate && precision[captured] == .approximate)
}

@Test func withoutCandidateDetailsTheLedgerAloneNeverClaimsAnExactTime() throws {
    let ledger = try representativeLedger().ledger
    let snapshot = try ledger.repository.processingSnapshot().ledger
    let markers = LedgerTimelineProjection.transactions(in: snapshot)
    #expect(markers.count == 3)
    #expect(markers.allSatisfy { $0.timePrecision == .approximate && $0.title == nil })
}

@Test func candidatesThatNeverBecameLedgerFactsShowNothing() throws {
    var ledger = try Ledger()
    // An unresolved account sends the candidate to review; it is stored but is not a financial fact.
    let draft = try TransactionCandidateDraft(
        rawNotificationID: "review", parserID: "test", parserVersion: "1", ruleID: "r", kind: .purchase, direction: .outflow,
        amount: won(9_000), occurredAt: ObservedTimestamp(unixMilliseconds: at(today, 9), precision: .minute, source: .text),
        confidence: .high)
    let context = try CandidateAssemblyContext(timeZoneIdentifier: zone, policyVersion: "test")
    let candidate = try DefaultTransactionCandidateAssembler().assemble(draft, resolution: .unresolved(.unknownAccount), context: context)
    let snapshot = try ledger.repository.processingSnapshot()
    _ = try ledger.repository.process(candidate, expectedCandidateRevision: snapshot.candidateRevision, expectedLedgerRevision: snapshot.ledger.revision)
    #expect(try ledger.repository.processingSnapshot().candidates.count == 1)
    #expect(try ledger.markers().isEmpty)
}

private let activityEvent = event("eA", title: "점심 약속", from: at(today, 12), to: at(today, 13))

@Test func activityLinkedAndUnlinkedTransactionsKeepTheirMeaningInTheTimeline() throws {
    let fixture = try representativeLedger()
    let markers = try fixture.ledger.markers()
    let state = try LifeState.empty.applying([
        .createActivity(Activity.materialized(from: activityEvent, id: ActivityID(rawValue: "A"), at: 1)),
        wholeAllocation(fixture.bankPurchase.rawValue, to: "A", total: 12_000),
        allocation(fixture.refund.rawValue, to: "A", amount: .exact(5_000), of: 5_000, flow: .refund),
    ])
    let result = DayTimelineBuilder.build(DayTimelineInput(
        day: today, timeZone: seoul, calendars: defaultCalendars, events: [activityEvent], life: state, transactions: markers))

    let block = try #require(result.blocks.first)
    #expect(block.allocatedSpend.first?.exactMinorUnits == 12_000)
    #expect(block.allocatedRefunds.first?.exactMinorUnits == 5_000)
    // The linked purchase and its refund are inside the block; only the unlinked card purchase stays a marker.
    #expect(result.markers.map(\.transactionID) == [fixture.cardPurchase])
    let totals = try #require(result.summary.totals.first)
    #expect(totals.linkedNetMinorUnits == 7_000)
    #expect(totals.unlinkedNetMinorUnits == 30_000)
    #expect(result.summary.unlinkedTransactionCount == 1)
    #expect(state.conservationViolations().isEmpty)
}

@Test func everyKindOfMoneyMovementIsAFactInTheLedgerYetNeverATimelineTransaction() throws {
    var ledger = try Ledger()
    let movements: [(String, DraftEventKind, TransactionDirection, Int64)] = [
        ("t", .transferOut, .outflow, 80_000), ("w", .cashWithdrawal, .outflow, 50_000),
        ("u", .walletTopUp, .outflow, 20_000), ("b", .cardBillPayment, .outflow, 30_000), ("i", .deposit, .inflow, 1_500_000),
    ]
    var ids: [LedgerEntryID] = []
    for (index, movement) in movements.enumerated() {
        ids.append(try #require(try ledger.feed(movement.0, movement.1, movement.2, movement.3, at: at(today, 9 + index))))
    }
    let entries = try ledger.repository.processingSnapshot().ledger.entries
    #expect(Set(entries.map(\.id)) == Set(ids))                       // all five are real ledger entries
    #expect(Set(entries.map(\.kind)) == [.transfer, .cardPayment, .income])
    #expect(try ledger.markers().isEmpty)                             // and none of them is spending
}

@Test func theTransactionSourceAndTheProjectionAgreeBecauseTheSourceUsesTheProjection() throws {
    let fixture = try representativeLedger()
    let snapshot = try fixture.ledger.repository.processingSnapshot()
    let source = LedgerTransactionSource(processing: snapshot)
    let projected = LedgerTimelineProjection.transactions(in: snapshot)
    let sourced = source.transactions(occurringFrom: 0, to: Int64.max)
    #expect(sourced == projected)
    // Per-entry time precision and titles survive, unlike the older single-precision initializer.
    #expect(source.transaction(fixture.bankPurchase)?.timePrecision == .exact)
    #expect(source.transaction(fixture.cardPurchase)?.timePrecision == .approximate)
    #expect(source.transaction(fixture.bankPurchase)?.title == "성수 식당")
    #expect(source.transactions(withIDs: [fixture.refund]).first?.title == "성수 식당")
}
