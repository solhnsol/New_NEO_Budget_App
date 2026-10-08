public enum ResolvedLedgerBinding: Codable, Hashable, Sendable {
    case account(AccountID)
    case creditInstrument(CreditInstrumentID)
}

public enum AccountResolution: Equatable, Sendable {
    case resolved(ResolvedLedgerBinding)
    case unresolved(CandidateIssue)
}

/// Owns provider/instrument-to-ledger identity mapping. Parsers never implement this contract.
public protocol TransactionAccountResolver {
    func resolve(_ draft: TransactionCandidateDraft) throws -> AccountResolution
}

public struct AdjustmentOriginal: Codable, Equatable, Sendable {
    public let entryID: LedgerEntryID
    public let budgetMonth: BudgetMonth

    public init(entryID: LedgerEntryID, budgetMonth: BudgetMonth) {
        self.entryID = entryID
        self.budgetMonth = budgetMonth
    }
}

public struct CandidateAssemblyContext: Codable, Equatable, Sendable {
    public let timeZoneIdentifier: String
    public let transferCounterpartAccountID: AccountID?
    public let cardPaymentInstrumentID: CreditInstrumentID?
    public let adjustmentOriginalsByEvidenceValue: [String: AdjustmentOriginal]
    public let policyVersion: String

    public init(
        timeZoneIdentifier: String,
        transferCounterpartAccountID: AccountID? = nil,
        cardPaymentInstrumentID: CreditInstrumentID? = nil,
        adjustmentOriginalsByEvidenceValue: [String: AdjustmentOriginal] = [:],
        policyVersion: String
    ) throws {
        guard !policyVersion.isEmpty else { throw CandidateValidationError.emptyPolicyVersion }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw CandidateAssemblyError.invalidTimeZone(timeZoneIdentifier)
        }
        self.timeZoneIdentifier = timeZoneIdentifier
        self.transferCounterpartAccountID = transferCounterpartAccountID
        self.cardPaymentInstrumentID = cardPaymentInstrumentID
        self.adjustmentOriginalsByEvidenceValue = adjustmentOriginalsByEvidenceValue
        self.policyVersion = policyVersion
    }
}

public protocol TransactionCandidateAssembler {
    func assemble(
        _ draft: TransactionCandidateDraft,
        resolution: AccountResolution,
        context: CandidateAssemblyContext
    ) throws -> TransactionCandidate
}

public enum CandidateAssemblyError: Error, Equatable, Sendable {
    case invalidTimeZone(String)
}

/// Binds identities and constructs a proposed entry, but does not persist it.
public struct DefaultTransactionCandidateAssembler: TransactionCandidateAssembler, Sendable {
    public init() {}

    public func assemble(
        _ draft: TransactionCandidateDraft,
        resolution: AccountResolution,
        context: CandidateAssemblyContext
    ) throws -> TransactionCandidate {
        let candidateID = TransactionCandidateID(rawValue: identity("candidate", draft))
        let evidenceIDs = [draft.rawNotificationID]
        if draft.hasHardIssues {
            return try review(candidateID, draft, evidenceIDs, .parserUncertain, context)
        }
        guard case let .resolved(binding) = resolution else {
            guard case let .unresolved(issue) = resolution else { preconditionFailure() }
            return try review(candidateID, draft, evidenceIDs, issue, context)
        }

        let entryID = LedgerEntryID(rawValue: identity("entry", draft))
        let entry: LedgerEntry
        switch draft.kind {
        case .purchase, .feeCharge:
            entry = try expense(entryID, draft, binding, context, evidenceIDs)
        case .deposit:
            guard case let .account(accountID) = binding else {
                return try review(candidateID, draft, evidenceIDs, .unknownAccount, context)
            }
            entry = LedgerEntry(
                id: entryID,
                kind: .income,
                occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds,
                postings: [Posting(accountID: accountID, delta: draft.amount)],
                evidenceIDs: evidenceIDs
            )
        case .cancellation, .refund:
            guard let original = original(for: draft, in: context) else {
                return try review(candidateID, draft, evidenceIDs, .missingOriginalEntry, context)
            }
            entry = try adjustment(entryID, draft, binding, original, evidenceIDs)
        case .transferOut, .transferIn, .cashWithdrawal, .walletTopUp:
            guard case let .account(accountID) = binding,
                  let counterpart = context.transferCounterpartAccountID else {
                return try review(candidateID, draft, evidenceIDs, .incompleteTransfer, context)
            }
            let outgoing = draft.direction == .outflow
            entry = LedgerEntry(
                id: entryID,
                kind: .transfer,
                occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds,
                postings: [
                    Posting(accountID: accountID, delta: outgoing ? try draft.amount.negated() : draft.amount),
                    Posting(accountID: counterpart, delta: outgoing ? draft.amount : try draft.amount.negated())
                ],
                evidenceIDs: evidenceIDs
            )
        case .cardBillPayment:
            guard case let .account(accountID) = binding,
                  let instrumentID = context.cardPaymentInstrumentID else {
                return try review(candidateID, draft, evidenceIDs, .unknownAccount, context)
            }
            entry = LedgerEntry(
                id: entryID,
                kind: .cardPayment,
                occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds,
                postings: [Posting(accountID: accountID, delta: try draft.amount.negated())],
                liabilityChanges: [LiabilityChange(instrumentID: instrumentID, delta: try draft.amount.negated())],
                evidenceIDs: evidenceIDs
            )
        case .withdrawal, .purchaseSettlementNotice:
            return try review(candidateID, draft, evidenceIDs, .unsupportedEvent, context)
        }

        return try TransactionCandidate(
            id: candidateID,
            evidenceIDs: evidenceIDs,
            status: .ready,
            proposedEntry: entry,
            policyVersion: context.policyVersion,
            sourceDraft: draft
        )
    }

    private func expense(
        _ id: LedgerEntryID,
        _ draft: TransactionCandidateDraft,
        _ binding: ResolvedLedgerBinding,
        _ context: CandidateAssemblyContext,
        _ evidenceIDs: [String]
    ) throws -> LedgerEntry {
        let postings: [Posting]
        let liabilities: [LiabilityChange]
        switch binding {
        case let .account(accountID):
            postings = [Posting(accountID: accountID, delta: try draft.amount.negated())]
            liabilities = []
        case let .creditInstrument(instrumentID):
            postings = []
            liabilities = [LiabilityChange(instrumentID: instrumentID, delta: draft.amount)]
        }
        return LedgerEntry(
            id: id,
            kind: .expense,
            occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds,
            postings: postings,
            liabilityChanges: liabilities,
            budgetImpact: BudgetImpact(
                kind: .expense,
                amount: draft.amount,
                attributedMonth: try budgetMonth(for: draft.occurredAt, timeZoneIdentifier: context.timeZoneIdentifier)
            ),
            evidenceIDs: evidenceIDs
        )
    }

    private func adjustment(
        _ id: LedgerEntryID,
        _ draft: TransactionCandidateDraft,
        _ binding: ResolvedLedgerBinding,
        _ original: AdjustmentOriginal,
        _ evidenceIDs: [String]
    ) throws -> LedgerEntry {
        let postings: [Posting]
        let liabilities: [LiabilityChange]
        switch binding {
        case let .account(accountID):
            postings = [Posting(accountID: accountID, delta: draft.amount)]
            liabilities = []
        case let .creditInstrument(instrumentID):
            postings = []
            liabilities = [LiabilityChange(instrumentID: instrumentID, delta: try draft.amount.negated())]
        }
        return LedgerEntry(
            id: id,
            kind: .adjustment,
            occurredAtUnixMilliseconds: draft.occurredAt.unixMilliseconds,
            postings: postings,
            liabilityChanges: liabilities,
            budgetImpact: BudgetImpact(kind: .return, amount: draft.amount, attributedMonth: original.budgetMonth),
            adjustment: AdjustmentLink(
                originalEntryID: original.entryID,
                reason: draft.kind == .cancellation ? .cancellation : .refund
            ),
            evidenceIDs: evidenceIDs
        )
    }

    private func original(for draft: TransactionCandidateDraft, in context: CandidateAssemblyContext) -> AdjustmentOriginal? {
        draft.evidence.lazy
            .filter { $0.kind == .originalApprovalReference }
            .compactMap { context.adjustmentOriginalsByEvidenceValue[$0.value] }
            .first
    }

    private func review(
        _ id: TransactionCandidateID,
        _ draft: TransactionCandidateDraft,
        _ evidenceIDs: [String],
        _ issue: CandidateIssue,
        _ context: CandidateAssemblyContext
    ) throws -> TransactionCandidate {
        try TransactionCandidate(
            id: id,
            evidenceIDs: evidenceIDs,
            status: .needsReview,
            issues: [issue],
            policyVersion: context.policyVersion,
            sourceDraft: draft
        )
    }

    private func budgetMonth(
        for timestamp: ObservedTimestamp,
        timeZoneIdentifier: String
    ) throws -> BudgetMonth {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw CandidateAssemblyError.invalidTimeZone(timeZoneIdentifier)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(timestamp.unixMilliseconds) / 1_000)
        let components = calendar.dateComponents([.year, .month], from: date)
        return try BudgetMonth(year: components.year ?? 0, month: components.month ?? 0)
    }

    private func identity(_ prefix: String, _ draft: TransactionCandidateDraft) -> String {
        [prefix, lengthPrefixed(draft.rawNotificationID), String(draft.eventIndex)].joined(separator: "/")
    }

    private func lengthPrefixed(_ value: String) -> String { "\(value.utf8.count):\(value)" }
}
import Foundation
