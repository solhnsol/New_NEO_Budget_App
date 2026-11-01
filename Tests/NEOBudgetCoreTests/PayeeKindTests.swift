import Testing
import NEOBudgetCore

private func draft(
    _ kind: DraftEventKind, _ direction: TransactionDirection = .outflow, merchant: String? = nil, payee: String? = nil,
    instrument: InstrumentHintKind = .bankAccount
) throws -> TransactionCandidateDraft {
    try TransactionCandidateDraft(
        rawNotificationID: "raw", parserID: "test", parserVersion: "1", ruleID: kind.rawValue, kind: kind, direction: direction,
        amount: Money(minorUnits: 15_000, currency: "KRW"),
        occurredAt: ObservedTimestamp(unixMilliseconds: 1_790_000_000_000, precision: .second, source: .text),
        instrument: InstrumentHint(kind: instrument), counterparty: DraftCounterparty(merchantRaw: merchant, payeeRaw: payee), confidence: .high
    )
}

@Test func aMaskedPersonNameOnATransferIsAPerson() throws {
    try #expect(PayeeKind.classify(try draft(.transferOut, payee: "홍*동")) == .person)
    try #expect(PayeeKind.classify(try draft(.transferOut, payee: "김가나")) == .person)
    try #expect(PayeeKind.classify(try draft(.transferIn, .inflow, payee: "이*")) == .person)
}

@Test func businessesAndPurchasesAreMerchants() throws {
    try #expect(PayeeKind.classify(try draft(.transferOut, payee: "스타벅스커피")) == .merchant)
    try #expect(PayeeKind.classify(try draft(.transferOut, payee: "가게E")) == .merchant)
    try #expect(PayeeKind.classify(try draft(.transferOut, payee: "홍길동 상회")) == .merchant)
    // A purchase at a shop named like a person is still a purchase.
    try #expect(PayeeKind.classify(try draft(.purchase, merchant: "홍*동")) == .merchant)
}

@Test func transitNeedsATransitCardOrAKnownOperator() throws {
    try #expect(!CategoryEvidencePolicy.canSuggestTransit(try draft(.purchase, merchant: "안국역점", instrument: .creditCard)))
    try #expect(CategoryEvidencePolicy.canSuggestTransit(try draft(.purchase, merchant: "티머니", instrument: .creditCard)))
    try #expect(CategoryEvidencePolicy.canSuggestTransit(try draft(.purchase, merchant: "안국", instrument: .transitCard)))
    try #expect(!CategoryEvidencePolicy.canSuggestTransit(try draft(.transferOut, payee: "홍*동", instrument: .transitCard)))
}

@Test func depositsAndPeopleAreNeverAutoCategorized() throws {
    try #expect(!CategoryEvidencePolicy.canAutoCategorize(try draft(.deposit, .inflow, payee: "회사")))
    try #expect(!CategoryEvidencePolicy.canAutoCategorize(try draft(.transferOut, payee: "홍*동")))
    try #expect(CategoryEvidencePolicy.canAutoCategorize(try draft(.purchase, merchant: "가게E", instrument: .creditCard)))
}
