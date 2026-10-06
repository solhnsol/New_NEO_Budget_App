import Foundation
import Testing
import NEOBudgetCore
import NEOBudgetInMemoryStorage

private let parserBankID = AccountID(rawValue: "bank-main")
private let parserSavingsID = AccountID(rawValue: "bank-savings")
private let parserCardID = CreditInstrumentID(rawValue: "card-main")

private func parserMonth(_ month: Int = 10) throws -> BudgetMonth {
    try BudgetMonth(year: 2026, month: month)
}

private func parserWon(_ value: Int64) throws -> Money {
    try Money(minorUnits: value, currency: "KRW")
}

private func parserContext(
    binding: NotificationLedgerBinding? = .account(parserBankID),
    destination: AccountID? = nil,
    paymentInstrument: CreditInstrumentID? = nil,
    originals: [String: AdjustmentOriginal] = [:]
) throws -> NotificationParsingContext {
    try NotificationParsingContext(
        binding: binding,
        transferDestinationAccountID: destination,
        cardPaymentInstrumentID: paymentInstrument,
        adjustmentOriginalsByProviderReference: originals,
        currentBudgetMonth: parserMonth(),
        currency: "KRW",
        policyVersion: "korean-financial-v1"
    )
}

private func rawNotification(
    id: String = "raw-1",
    applicationIdentifier: String = "fixture.finance.app",
    notificationTime: Int64? = 1_780_000_000_000,
    title: String? = nil,
    subtitle: String? = nil,
    body: String? = nil
) -> RawNotification {
    RawNotification(
        id: id,
        source: NotificationSource(applicationIdentifier: applicationIdentifier),
        capturedAtUnixMilliseconds: 1_780_000_001_000,
        notificationAtUnixMilliseconds: notificationTime,
        title: title,
        subtitle: subtitle,
        body: body
    )
}

@Test func explicitBankApprovalBecomesReadyCashExpenseCandidate() throws {
    let raw = rawNotification(
        title: "승인",
        subtitle: "5,000원",
        body: "테스트상호\n승인번호 TX-001\n잔액 95,000원"
    )
    let candidate = try KoreanFinancialNotificationParser().parse(
        raw,
        context: parserContext()
    )
    let entry = try #require(candidate.proposedEntry)
    let minusFiveThousand = try parserWon(-5_000)
    let fiveThousand = try parserWon(5_000)
    let october = try parserMonth()

    #expect(candidate.status == .ready)
    #expect(candidate.evidenceIDs == [raw.id])
    #expect(entry.kind == .expense)
    #expect(entry.postings == [Posting(accountID: parserBankID, delta: minusFiveThousand)])
    #expect(entry.liabilityChanges.isEmpty)
    #expect(entry.budgetImpact?.amount == fiveThousand)
    #expect(entry.budgetImpact?.attributedMonth == october)
}

@Test func explicitCardApprovalCreatesLiabilityWithoutCashPosting() throws {
    let raw = rawNotification(
        title: "카드 사용 승인",
        body: "20,000원\n승인번호 CARD-001\n테스트상호"
    )
    let context = try parserContext(binding: .creditInstrument(parserCardID))
    let candidate = try KoreanFinancialNotificationParser().parse(raw, context: context)
    let entry = try #require(candidate.proposedEntry)
    let twentyThousand = try parserWon(20_000)

    #expect(candidate.status == .ready)
    #expect(entry.postings.isEmpty)
    #expect(entry.liabilityChanges == [LiabilityChange(
        instrumentID: parserCardID,
        delta: twentyThousand
    )])
    #expect(entry.budgetImpact?.amount == twentyThousand)
}

@Test func missingStrongFinancialIdentityRequiresReview() throws {
    let raw = rawNotification(title: "승인", subtitle: "5,000원", body: "테스트상호")
    let candidate = try KoreanFinancialNotificationParser().parse(raw, context: parserContext())

    #expect(candidate.status == .needsReview)
    #expect(candidate.issues == [.ambiguousWithoutStrongIdentity])
    #expect(candidate.proposedEntry?.kind == .expense)
}

@Test func missingTransactionTimeAndUnboundSourceStayOutOfReadyState() throws {
    let noTime = rawNotification(
        notificationTime: nil,
        title: "승인",
        body: "5,000원\n승인번호 TX-001"
    )
    let missingTime = try KoreanFinancialNotificationParser().parse(
        noTime,
        context: parserContext()
    )
    #expect(missingTime.status == .needsReview)
    #expect(missingTime.issues == [.missingTransactionTime])
    #expect(missingTime.proposedEntry == nil)

    let unbound = try KoreanFinancialNotificationParser().parse(
        rawNotification(title: "승인", body: "5,000원\n승인번호 TX-002"),
        context: parserContext(binding: nil)
    )
    #expect(unbound.status == .needsReview)
    #expect(unbound.issues == [.unboundSource])
    #expect(unbound.proposedEntry == nil)
}

@Test func sameProviderTransactionInDifferentRawLayoutsHasStableIdentity() throws {
    let first = rawNotification(
        id: "raw-bank-style",
        title: "승인 5,000원",
        body: "거래번호 SHARED-001\n테스트상호"
    )
    let second = rawNotification(
        id: "raw-wallet-style",
        title: "테스트상호",
        body: "거래번호 SHARED-001\n5,000원 결제"
    )
    let parser = KoreanFinancialNotificationParser()
    let context = try parserContext()
    let firstCandidate = try parser.parse(first, context: context)
    let secondCandidate = try parser.parse(second, context: context)

    #expect(firstCandidate.id == secondCandidate.id)
    #expect(firstCandidate.proposedEntry?.id == secondCandidate.proposedEntry?.id)
    #expect(firstCandidate.evidenceIDs == [first.id])
    #expect(secondCandidate.evidenceIDs == [second.id])
}

@Test func refundUsesActualOccurrenceTimeAndOriginalBudgetMonth() throws {
    let original = AdjustmentOriginal(
        entryID: LedgerEntryID(rawValue: "entry-original"),
        budgetMonth: try parserMonth(9)
    )
    let raw = rawNotification(
        notificationTime: 1_790_000_000_000,
        title: "환불",
        body: "15,000원\n거래번호 REFUND-001\n원거래번호 ORIGINAL-001"
    )
    let candidate = try KoreanFinancialNotificationParser().parse(
        raw,
        context: parserContext(originals: ["ORIGINAL-001": original])
    )
    let entry = try #require(candidate.proposedEntry)
    let fifteenThousand = try parserWon(15_000)

    #expect(candidate.status == .ready)
    #expect(entry.occurredAtUnixMilliseconds == 1_790_000_000_000)
    #expect(entry.postings == [Posting(accountID: parserBankID, delta: fifteenThousand)])
    #expect(entry.budgetImpact?.kind == .return)
    #expect(entry.budgetImpact?.attributedMonth == original.budgetMonth)
    #expect(entry.adjustment?.originalEntryID == original.entryID)
}

@Test func transferAndCardPaymentProduceNonBudgetEntries() throws {
    let parser = KoreanFinancialNotificationParser()
    let transferRaw = rawNotification(
        id: "raw-transfer",
        title: "이체",
        body: "10,000원\n거래번호 TRANSFER-001"
    )
    let transfer = try parser.parse(
        transferRaw,
        context: parserContext(destination: parserSavingsID)
    )
    let transferEntry = try #require(transfer.proposedEntry)
    #expect(transfer.status == .ready)
    #expect(transferEntry.kind == .transfer)
    #expect(transferEntry.budgetImpact == nil)
    #expect(transferEntry.postings.count == 2)

    let paymentRaw = rawNotification(
        id: "raw-card-payment",
        title: "카드대금 출금",
        body: "30,000원\n거래번호 PAYMENT-001"
    )
    let payment = try parser.parse(
        paymentRaw,
        context: parserContext(paymentInstrument: parserCardID)
    )
    let paymentEntry = try #require(payment.proposedEntry)
    let minusThirtyThousand = try parserWon(-30_000)
    #expect(payment.status == .ready)
    #expect(paymentEntry.kind == .cardPayment)
    #expect(paymentEntry.budgetImpact == nil)
    #expect(paymentEntry.liabilityChanges == [LiabilityChange(
        instrumentID: parserCardID,
        delta: minusThirtyThousand
    )])
}

@Test func incompleteTransferAndUnknownOriginalRequireReview() throws {
    let parser = KoreanFinancialNotificationParser()
    let transfer = try parser.parse(
        rawNotification(title: "이체", body: "10,000원\n거래번호 TRANSFER-001"),
        context: parserContext()
    )
    #expect(transfer.status == .needsReview)
    #expect(transfer.issues == [.incompleteTransfer])

    let refund = try parser.parse(
        rawNotification(title: "취소", body: "10,000원\n거래번호 CANCEL-001\n원승인번호 OLD-001"),
        context: parserContext()
    )
    #expect(refund.status == .needsReview)
    #expect(refund.issues == [.missingOriginalEntry])
}

@Test func unsupportedOrAmountlessNotificationCannotBecomeReady() throws {
    let parser = KoreanFinancialNotificationParser()
    let unsupported = try parser.parse(
        rawNotification(title: "이번 달 혜택 안내", body: "광고 알림"),
        context: parserContext()
    )
    #expect(unsupported.status == .rejected)
    #expect(unsupported.issues == [.unsupportedEvent])

    let amountless = try parser.parse(
        rawNotification(title: "승인", body: "승인번호 TX-001"),
        context: parserContext()
    )
    #expect(amountless.status == .needsReview)
    #expect(amountless.issues == [.missingAmount])
}

@Test func parserNeedsReviewOutputCannotMutateLedgerThroughProcessor() throws {
    let candidate = try KoreanFinancialNotificationParser().parse(
        rawNotification(title: "승인", body: "5,000원"),
        context: parserContext()
    )
    var repository = try InMemoryCandidateProcessingRepository(configuration: LedgerConfiguration(
        accounts: [Account(
            id: parserBankID,
            name: "생활비",
            kind: .bank,
            openingBalance: parserWon(100_000)
        )]
    ))
    _ = try repository.process(
        candidate,
        expectedCandidateRevision: 0,
        expectedLedgerRevision: 0
    )

    let snapshot = try repository.processingSnapshot()
    #expect(snapshot.candidates[candidate.id]?.candidate.status == .needsReview)
    #expect(snapshot.ledger.entries.isEmpty)
    #expect(snapshot.ledger.revision == 0)
}

@Test func parserRejectsOverflowingAmountAndDecodedInvalidContext() throws {
    let overflowing = rawNotification(
        title: "승인",
        body: "99,999,999,999,999,999,999원\n승인번호 TX-OVERFLOW"
    )
    #expect(throws: TransactionCandidateParserError.amountOverflow) {
        try KoreanFinancialNotificationParser().parse(
            overflowing,
            context: parserContext()
        )
    }

    let encoded = try JSONEncoder().encode(try parserContext())
    let json = try #require(String(data: encoded, encoding: .utf8))
    let invalid = Data(json.replacingOccurrences(of: "KRW", with: "krw").utf8)
    #expect(throws: MoneyError.invalidCurrency("krw")) {
        try JSONDecoder().decode(NotificationParsingContext.self, from: invalid)
    }
}
