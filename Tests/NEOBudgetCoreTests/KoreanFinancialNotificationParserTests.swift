import Foundation
import Testing
import NEOBudgetCore

private let parserBankID = AccountID(rawValue: "bank-main")
private let parserSavingsID = AccountID(rawValue: "bank-savings")
private let parserCardID = CreditInstrumentID(rawValue: "card-main")

private func parserWon(_ value: Int64) throws -> Money { try Money(minorUnits: value, currency: "KRW") }
private func parserMonth(_ month: Int = 10) throws -> BudgetMonth { try BudgetMonth(year: 2026, month: month) }
private func parserContext() throws -> NotificationParsingContext {
    try NotificationParsingContext(
        timeZoneIdentifier: "Asia/Seoul",
        referenceTimeUnixMilliseconds: 1_800_000_000_000,
        parserID: "korean-financial",
        parserVersion: "2"
    )
}
private func assemblyContext(
    counterpart: AccountID? = nil,
    card: CreditInstrumentID? = nil,
    originals: [String: AdjustmentOriginal] = [:]
) throws -> CandidateAssemblyContext {
    try CandidateAssemblyContext(
        timeZoneIdentifier: "Asia/Seoul",
        transferCounterpartAccountID: counterpart,
        cardPaymentInstrumentID: card,
        adjustmentOriginalsByEvidenceValue: originals,
        policyVersion: "assembly-v1"
    )
}
private func rawNotification(
    id: String = "raw-1",
    deliveryID: String? = nil,
    notificationTime: Int64? = 1_780_000_000_000,
    title: String? = nil,
    subtitle: String? = nil,
    body: String? = nil
) -> RawNotification {
    RawNotification(
        id: id,
        source: NotificationSource(applicationIdentifier: "fixture.finance.app"),
        sourceDeliveryID: deliveryID,
        capturedAtUnixMilliseconds: 1_780_000_001_000,
        notificationAtUnixMilliseconds: notificationTime,
        title: title,
        subtitle: subtitle,
        body: body
    )
}
private func parsedDraft(_ raw: RawNotification) throws -> TransactionCandidateDraft {
    let outcome = try KoreanFinancialNotificationParser().parse(raw, context: parserContext())
    guard case let .candidate(draft) = outcome else {
        Issue.record("Expected candidate draft, got \(outcome)")
        throw NotificationParseFailure.amountUnparseable
    }
    return draft
}

@Test func parserProducesObservedDraftWithoutAccountBinding() throws {
    let draft = try parsedDraft(rawNotification(
        title: "승인",
        subtitle: "5,000원",
        body: "테스트상호\n승인번호 TX-001\n잔액 95,000원"
    ))
    let fiveThousand = try parserWon(5_000)
    #expect(draft.kind == .purchase)
    #expect(draft.amount == fiveThousand)
    #expect(draft.rawNotificationID == "raw-1")
    #expect(draft.occurredAt.source == .notificationTime)
    #expect(draft.evidence.contains { $0.kind == .approvalNumber && $0.strength == .scoped })
}

@Test func missingStrongIdentityAndMerchantAreSoftAndCanStillAssembleReady() throws {
    let draft = try parsedDraft(rawNotification(title: "승인", body: "5,000원"))
    #expect(!draft.evidence.contains { $0.strength == .strong })
    #expect(draft.issues.contains(.merchantMissing))
    #expect(!draft.hasHardIssues)

    let candidate = try DefaultTransactionCandidateAssembler().assemble(
        draft,
        resolution: .resolved(.account(parserBankID)),
        context: assemblyContext()
    )
    let minusFiveThousand = try parserWon(-5_000)
    #expect(candidate.status == .ready)
    #expect(candidate.issues.isEmpty)
    #expect(candidate.proposedEntry?.postings == [Posting(accountID: parserBankID, delta: minusFiveThousand)])
}

@Test func missingTextTimeFallsBackWithProvenance() throws {
    let draft = try parsedDraft(rawNotification(
        notificationTime: nil,
        title: "승인",
        body: "5,000원\n승인번호 TX-002"
    ))
    #expect(draft.occurredAt.unixMilliseconds == 1_780_000_001_000)
    #expect(draft.occurredAt.source == .captureTime)
    #expect(draft.issues.contains(.timeAbsentFallback))
}

@Test func approvalNumberIsScopedEvidenceAndNeverGlobalCandidateIdentity() throws {
    let first = try parsedDraft(rawNotification(id: "raw-a", title: "승인", body: "5,000원\n승인번호 SAME"))
    let second = try parsedDraft(rawNotification(id: "raw-b", title: "승인", body: "5,000원\n승인번호 SAME"))
    let assembler = DefaultTransactionCandidateAssembler()
    let firstCandidate = try assembler.assemble(first, resolution: .resolved(.account(parserBankID)), context: assemblyContext())
    let secondCandidate = try assembler.assemble(second, resolution: .resolved(.account(parserBankID)), context: assemblyContext())
    #expect(firstCandidate.id != secondCandidate.id)
    #expect(first.evidence.first { $0.kind == .approvalNumber }?.strength == .scoped)
}

@Test func similarRawFormsWithoutStrongIdentityBecomeAmbiguousOnlyAtDedup() throws {
    let assembler = DefaultTransactionCandidateAssembler()
    let firstDraft = try parsedDraft(rawNotification(
        id: "raw-layout-a", title: "승인", body: "5,000원\n승인번호 SAME"
    ))
    let secondDraft = try parsedDraft(rawNotification(
        id: "raw-layout-b", title: "결제", body: "5,000원\n승인번호 SAME"
    ))
    let first = try assembler.assemble(firstDraft, resolution: .resolved(.account(parserBankID)), context: assemblyContext())
    let second = try assembler.assemble(secondDraft, resolution: .resolved(.account(parserBankID)), context: assemblyContext())
    #expect(first.status == .ready)
    #expect(second.status == .ready)

    let result = try DefaultCandidateDeduplicationValidator().validate(second, against: [first])
    guard case let .needsReview(review) = result else {
        Issue.record("Expected ambiguous dedup review, got \(result)")
        return
    }
    #expect(review.issues == [.ambiguousWithoutStrongIdentity])
    #expect(review.proposedEntry == nil)
}

@Test func sameScopedStrongEvidenceIsRecognizedAsDuplicate() throws {
    let assembler = DefaultTransactionCandidateAssembler()
    let firstDraft = try parsedDraft(rawNotification(
        id: "raw-strong-a", deliveryID: "delivery-1", title: "승인", body: "5,000원"
    ))
    let secondDraft = try parsedDraft(rawNotification(
        id: "raw-strong-b", deliveryID: "delivery-1", title: "결제", body: "5,000원"
    ))
    let first = try assembler.assemble(firstDraft, resolution: .resolved(.account(parserBankID)), context: assemblyContext())
    let second = try assembler.assemble(secondDraft, resolution: .resolved(.account(parserBankID)), context: assemblyContext())
    #expect(try DefaultCandidateDeduplicationValidator().validate(second, against: [first]) ==
            .duplicate(existingCandidateID: first.id))
}

@Test func similarFactsBoundToDifferentAccountsDoNotCollide() throws {
    let assembler = DefaultTransactionCandidateAssembler()
    let firstDraft = try parsedDraft(rawNotification(id: "raw-account-a", title: "승인", body: "5,000원"))
    let secondDraft = try parsedDraft(rawNotification(id: "raw-account-b", title: "결제", body: "5,000원"))
    let first = try assembler.assemble(firstDraft, resolution: .resolved(.account(parserBankID)), context: assemblyContext())
    let second = try assembler.assemble(secondDraft, resolution: .resolved(.account(parserSavingsID)), context: assemblyContext())
    #expect(try DefaultCandidateDeduplicationValidator().validate(second, against: [first]) == .accepted(second))
}

@Test func unresolvedAccountCreatesReviewOnlyAfterAssembly() throws {
    let draft = try parsedDraft(rawNotification(title: "승인", body: "5,000원\n승인번호 TX-003"))
    let candidate = try DefaultTransactionCandidateAssembler().assemble(
        draft,
        resolution: .unresolved(.unknownAccount),
        context: assemblyContext()
    )
    #expect(candidate.status == .needsReview)
    #expect(candidate.issues == [.unknownAccount])
    #expect(candidate.proposedEntry == nil)
}

@Test func assemblerBuildsRefundTransferAndCardPaymentEntries() throws {
    let assembler = DefaultTransactionCandidateAssembler()
    let september = try parserMonth(9)
    let original = AdjustmentOriginal(entryID: LedgerEntryID(rawValue: "entry-original"), budgetMonth: september)
    let refundDraft = try parsedDraft(rawNotification(
        id: "raw-refund",
        title: "환불",
        body: "15,000원\n거래번호 REFUND-1\n원승인번호 ORIGINAL-1"
    ))
    let refund = try assembler.assemble(
        refundDraft,
        resolution: .resolved(.account(parserBankID)),
        context: assemblyContext(originals: ["ORIGINAL-1": original])
    )
    #expect(refund.proposedEntry?.kind == .adjustment)
    #expect(refund.proposedEntry?.budgetImpact?.attributedMonth == september)

    let transferDraft = try TransactionCandidateDraft(
        rawNotificationID: "raw-transfer",
        parserID: "test", parserVersion: "1", ruleID: "transfer",
        kind: .transferOut, direction: .outflow, amount: parserWon(10_000),
        occurredAt: ObservedTimestamp(unixMilliseconds: 1, precision: .second, source: .text),
        confidence: .high
    )
    let transfer = try assembler.assemble(
        transferDraft,
        resolution: .resolved(.account(parserBankID)),
        context: assemblyContext(counterpart: parserSavingsID)
    )
    #expect(transfer.proposedEntry?.kind == .transfer)
    #expect(transfer.proposedEntry?.postings.count == 2)

    let paymentDraft = try TransactionCandidateDraft(
        rawNotificationID: "raw-card-payment",
        parserID: "test", parserVersion: "1", ruleID: "card-payment",
        kind: .cardBillPayment, direction: .outflow, amount: parserWon(30_000),
        occurredAt: ObservedTimestamp(unixMilliseconds: 2, precision: .second, source: .text),
        confidence: .high
    )
    let payment = try assembler.assemble(
        paymentDraft,
        resolution: .resolved(.account(parserBankID)),
        context: assemblyContext(card: parserCardID)
    )
    let minusThirtyThousand = try parserWon(-30_000)
    #expect(payment.proposedEntry?.kind == .cardPayment)
    #expect(payment.proposedEntry?.liabilityChanges == [LiabilityChange(instrumentID: parserCardID, delta: minusThirtyThousand)])
}

@Test func nonTransactionAndAmountFailureNeverCreateDraft() throws {
    let parser = KoreanFinancialNotificationParser()
    #expect(try parser.parse(
        rawNotification(title: "이번 달 혜택 안내", body: "광고 알림"), context: parserContext()
    ) == .notTransaction(.promotion))
    #expect(try parser.parse(
        rawNotification(title: "승인", body: "승인번호 TX-005"), context: parserContext()
    ) == .failed(.amountMissing))
}

@Test func parserRejectsOverflowAndInvalidContext() throws {
    #expect(try KoreanFinancialNotificationParser().parse(
        rawNotification(title: "승인", body: "99,999,999,999,999,999,999원"), context: parserContext()
    ) == .failed(.amountUnparseable))
    #expect(throws: NotificationParserContractError.emptyContextValue) {
        try NotificationParsingContext(
            timeZoneIdentifier: "", referenceTimeUnixMilliseconds: 0, parserID: "parser", parserVersion: "1"
        )
    }
}
