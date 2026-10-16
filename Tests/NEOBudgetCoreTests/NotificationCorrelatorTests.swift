import Foundation
import Testing
import NEOBudgetCore

private let woori = AccountID(rawValue: "woori")
private let tossBank = AccountID(rawValue: "toss-bank")
private let kakao = AccountID(rawValue: "kakao-wallet")
private let hyundaiMM = CreditInstrumentID(rawValue: "hyundai-mm")
private let base: Int64 = 1_790_000_000_000

private func observation(
    _ id: String, _ kind: DraftEventKind, _ direction: TransactionDirection, _ amount: Int64, at seconds: Int64,
    binding: ResolvedLedgerBinding?, counterpart: AccountID? = nil, source: String, merchant: String? = nil,
    evidence: [DraftEvidence] = []
) throws -> CorrelationObservation {
    let draft = try TransactionCandidateDraft(
        rawNotificationID: "raw-\(id)", parserID: "test", parserVersion: "1", ruleID: kind.rawValue, kind: kind, direction: direction,
        amount: Money(minorUnits: amount, currency: "KRW"),
        occurredAt: ObservedTimestamp(unixMilliseconds: base + seconds * 1000, precision: .second, source: .notificationTime),
        counterparty: direction == .outflow ? DraftCounterparty(merchantRaw: merchant) : DraftCounterparty(payeeRaw: merchant),
        evidence: evidence, confidence: .high
    )
    return CorrelationObservation(candidateID: TransactionCandidateID(rawValue: id), draft: draft, binding: binding,
                                  transferCounterpart: counterpart, source: source)
}

/// Applies each decision the way the processing layer will, so that whole arrival orders can be compared.
private struct Simulation {
    var records: [CorrelationRecord] = []
    var decisions: [String: CorrelationDecision] = [:]
    let correlator = NotificationCorrelator()

    mutating func receive(_ incoming: CorrelationObservation) {
        let decision = correlator.decide(incoming, against: records)
        decisions[incoming.candidateID.rawValue] = decision
        switch decision {
        case let .corroborates(match):
            records.append(CorrelationRecord(observation: incoming, corroborates: match))
        case .suggests:
            records.append(CorrelationRecord(observation: incoming))
        case let .newAct(act):
            for closed in act.closes + [act.replacesIncome].compactMap({ $0 }) {
                if let index = records.firstIndex(where: { $0.candidateID == closed.candidateID }) {
                    let old = records[index]
                    records[index] = CorrelationRecord(
                        observation: CorrelationObservation(candidateID: old.candidateID, draft: old.draft, binding: old.binding,
                                                            transferCounterpart: old.transferCounterpart, source: old.source),
                        corroborates: CorrelationMatch(candidateID: incoming.candidateID, rule: closed.rule)
                    )
                }
            }
            let kind = incoming.draft.kind
            if kind == .withdrawal, act.transferCounterpart == nil, act.closes.isEmpty {
                records.append(CorrelationRecord(observation: incoming))       // Q3: an unmatched withdrawal waits for review
            } else {
                let income = [.deposit, .transferIn].contains(kind) && act.transferCounterpart == nil
                records.append(CorrelationRecord(observation: incoming, entryID: LedgerEntryID(rawValue: "entry-\(incoming.candidateID.rawValue)"),
                                                 recordedAsIncome: income))
            }
        }
    }

    /// Each act as the set of notifications behind it; what waits for review, separately.
    var acts: Set<Set<String>> {
        var groups: [String: Set<String>] = [:]
        for record in records where record.entryID != nil { groups[record.candidateID.rawValue, default: []].insert(record.candidateID.rawValue) }
        for record in records {
            guard let target = record.corroborates?.rawValue else { continue }
            var root = target
            while let next = records.first(where: { $0.candidateID.rawValue == root })?.corroborates?.rawValue { root = next }
            groups[root, default: [root]].insert(record.candidateID.rawValue)
        }
        return Set(groups.values)
    }
    var waiting: Set<String> { Set(records.filter { $0.entryID == nil && $0.corroborates == nil }.map(\.candidateID.rawValue)) }
}

private func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    return items.indices.flatMap { index -> [[T]] in
        var rest = items
        let head = rest.remove(at: index)
        return permutations(rest).map { [head] + $0 }
    }
}

private func everyOrder(_ items: [CorrelationObservation]) -> [Simulation] {
    permutations(items).map { order in
        var simulation = Simulation()
        order.forEach { simulation.receive($0) }
        return simulation
    }
}

// MARK: Check card approval and bank withdrawal (Q1)

@Test func aCheckCardApprovalAndItsWithdrawalAreOneActInEitherOrder() throws {
    let approval = try observation("approval", .purchase, .outflow, 12_000, at: 0, binding: .account(woori), source: "hyundai", merchant: "가상상점")
    let withdrawal = try observation("withdrawal", .withdrawal, .outflow, 12_000, at: 2, binding: .account(woori), source: "woori")
    for simulation in everyOrder([approval, withdrawal]) {
        #expect(simulation.acts == [["approval", "withdrawal"]])
        #expect(simulation.waiting.isEmpty)
    }
}

@Test func aWithdrawalWithoutItsApprovalWaitsForReviewThenTheLateApprovalClosesIt() throws {
    var simulation = Simulation()
    simulation.receive(try observation("withdrawal", .withdrawal, .outflow, 12_000, at: 0, binding: .account(woori), source: "woori"))
    #expect(simulation.waiting == ["withdrawal"])
    simulation.receive(try observation("approval", .purchase, .outflow, 12_000, at: 240, binding: .account(woori), source: "hyundai"))
    #expect(simulation.decisions["approval"] == .newAct(NewAct(closes: [CorrelationMatch(candidateID: TransactionCandidateID(rawValue: "withdrawal"), rule: .cardWithdrawal)])))
    #expect(simulation.waiting.isEmpty)
    #expect(simulation.acts == [["approval", "withdrawal"]])
}

@Test func twoRealPaymentsOfTheSameAmountStayTwoActsAndEachTakesOneWithdrawal() throws {
    let items = [
        try observation("a1", .purchase, .outflow, 5_000, at: 0, binding: .account(woori), source: "hyundai"),
        try observation("w1", .withdrawal, .outflow, 5_000, at: 2, binding: .account(woori), source: "woori"),
        try observation("a2", .purchase, .outflow, 5_000, at: 30, binding: .account(woori), source: "hyundai"),
        try observation("w2", .withdrawal, .outflow, 5_000, at: 32, binding: .account(woori), source: "woori")
    ]
    for simulation in everyOrder(items) {
        #expect(simulation.acts.count == 2)
        #expect(simulation.acts.allSatisfy { $0.count == 2 })
        #expect(simulation.waiting.isEmpty)
    }
}

@Test func aWithdrawalFromAnotherAccountOrOfAnotherAmountIsNotMatched() throws {
    let approval = try observation("approval", .purchase, .outflow, 12_000, at: 0, binding: .account(woori), source: "hyundai")
    for other in [
        try observation("w", .withdrawal, .outflow, 12_000, at: 2, binding: .account(tossBank), source: "toss"),
        try observation("w", .withdrawal, .outflow, 12_500, at: 2, binding: .account(woori), source: "woori"),
        try observation("w", .withdrawal, .outflow, 12_000, at: 3_600, binding: .account(woori), source: "woori")
    ] {
        var simulation = Simulation()
        simulation.receive(approval)
        simulation.receive(other)
        #expect(simulation.waiting == ["w"])
    }
}

// MARK: Two apps reporting one payment

@Test func aPayAppAndTheCardItChargedAreOneActButTheSameAppTwiceIsTwo() throws {
    let toss = try observation("toss", .purchase, .outflow, 8_000, at: 0, binding: .creditInstrument(hyundaiMM), source: "toss")
    let card = try observation("card", .purchase, .outflow, 8_000, at: 3, binding: .creditInstrument(hyundaiMM), source: "hyundai")
    for simulation in everyOrder([toss, card]) { #expect(simulation.acts == [["toss", "card"]]) }

    var twice = Simulation()
    twice.receive(card)
    twice.receive(try observation("card2", .purchase, .outflow, 8_000, at: 30, binding: .creditInstrument(hyundaiMM), source: "hyundai"))
    #expect(twice.acts == [["card"], ["card2"]])
}

@Test func threeAppsReportingOneCheckCardPaymentAreOneAct() throws {
    let items = [
        try observation("toss", .purchase, .outflow, 9_900, at: 0, binding: .account(woori), source: "toss"),
        try observation("card", .purchase, .outflow, 9_900, at: 1, binding: .account(woori), source: "hyundai"),
        try observation("bank", .withdrawal, .outflow, 9_900, at: 3, binding: .account(woori), source: "woori")
    ]
    for simulation in everyOrder(items) {
        #expect(simulation.acts == [["toss", "card", "bank"]])
        #expect(simulation.waiting.isEmpty)
    }
}

// MARK: Transfers between own accounts (Q4)

@Test func oneLegNamingARegisteredAccountIsATransferAndTheLateOtherLegJoinsIt() throws {
    var simulation = Simulation()
    simulation.receive(try observation("out", .transferOut, .outflow, 50_000, at: 0, binding: .account(woori), counterpart: tossBank, source: "woori"))
    #expect(simulation.decisions["out"] == .newAct(NewAct(transferCounterpart: tossBank)))
    simulation.receive(try observation("in", .transferIn, .inflow, 50_000, at: 300, binding: .account(tossBank), source: "toss"))
    #expect(simulation.decisions["in"] == .corroborates(CorrelationMatch(candidateID: TransactionCandidateID(rawValue: "out"), rule: .transferLegs)))
    #expect(simulation.acts == [["out", "in"]])
}

@Test func anIncomeRecordedBeforeItsOutgoingLegIsReplacedByTheTransfer() throws {
    var simulation = Simulation()
    simulation.receive(try observation("in", .deposit, .inflow, 50_000, at: 0, binding: .account(tossBank), source: "toss"))
    #expect(simulation.records.first?.recordedAsIncome == true)
    simulation.receive(try observation("out", .transferOut, .outflow, 50_000, at: 2, binding: .account(woori), counterpart: tossBank, source: "woori"))
    #expect(simulation.decisions["out"] == .newAct(NewAct(
        transferCounterpart: tossBank,
        replacesIncome: CorrelationMatch(candidateID: TransactionCandidateID(rawValue: "in"), rule: .transferLegs)
    )))
    #expect(simulation.acts == [["out", "in"]])
}

@Test func aKakaoChargeAndTheBankWithdrawalItNamesAreOneTransferInEitherOrder() throws {
    let charge = try observation("charge", .walletTopUp, .inflow, 30_000, at: 0, binding: .account(kakao), counterpart: woori, source: "kakaopay")
    let withdrawal = try observation("withdrawal", .withdrawal, .outflow, 30_000, at: 1, binding: .account(woori), source: "woori")
    for simulation in everyOrder([charge, withdrawal]) {
        #expect(simulation.acts == [["charge", "withdrawal"]])
        #expect(simulation.waiting.isEmpty)
    }
}

@Test func aDepositFromSomeoneElseStaysIncome() throws {
    var simulation = Simulation()
    simulation.receive(try observation("in", .deposit, .inflow, 20_000, at: 0, binding: .account(woori), source: "woori", merchant: "홍길동"))
    #expect(simulation.decisions["in"] == .newAct(NewAct()))
    #expect(simulation.records.first?.recordedAsIncome == true)
}

// MARK: Refunds without an original reference (Q5)

@Test func aRefundWithoutAnOriginalReferenceOnlySuggestsRecentPurchasesOfTheSameName() throws {
    var simulation = Simulation()
    simulation.receive(try observation("old", .purchase, .outflow, 30_000, at: 0, binding: .account(woori), source: "hyundai", merchant: "가상 상점"))
    simulation.receive(try observation("new", .purchase, .outflow, 15_000, at: 100, binding: .account(woori), source: "hyundai", merchant: "가상상점"))
    simulation.receive(try observation("other", .purchase, .outflow, 15_000, at: 200, binding: .account(woori), source: "hyundai", merchant: "다른상점"))
    let refund = try observation("refund", .refund, .inflow, 15_000, at: 86_400, binding: .account(woori), source: "hyundai", merchant: "가상상점")
    #expect(NotificationCorrelator().decide(refund, against: simulation.records) == .suggests([
        CorrelationMatch(candidateID: TransactionCandidateID(rawValue: "new"), rule: .refundSuggestion),
        CorrelationMatch(candidateID: TransactionCandidateID(rawValue: "old"), rule: .refundSuggestion)
    ]))

    let referenced = try observation("refund", .refund, .inflow, 15_000, at: 86_400, binding: .account(woori), source: "hyundai", merchant: "가상상점",
                                     evidence: [DraftEvidence(kind: .originalApprovalReference, strength: .relation, value: "A1")])
    #expect(NotificationCorrelator().decide(referenced, against: simulation.records) == .newAct(NewAct()))
}
