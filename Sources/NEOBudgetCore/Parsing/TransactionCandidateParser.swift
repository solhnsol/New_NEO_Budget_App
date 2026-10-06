public enum NotificationLedgerBinding: Codable, Equatable, Sendable {
    case account(AccountID)
    case creditInstrument(CreditInstrumentID)
}

public struct AdjustmentOriginal: Codable, Equatable, Sendable {
    public let entryID: LedgerEntryID
    public let budgetMonth: BudgetMonth

    public init(entryID: LedgerEntryID, budgetMonth: BudgetMonth) {
        self.entryID = entryID
        self.budgetMonth = budgetMonth
    }
}

/// Deterministic application-owned facts required to turn parsed text into a candidate.
/// The parser never looks up a repository, clock, locale, or OS account object.
public struct NotificationParsingContext: Codable, Equatable, Sendable {
    public let binding: NotificationLedgerBinding?
    public let transferDestinationAccountID: AccountID?
    public let cardPaymentInstrumentID: CreditInstrumentID?
    public let adjustmentOriginalsByProviderReference: [String: AdjustmentOriginal]
    public let currentBudgetMonth: BudgetMonth
    public let currency: String
    public let policyVersion: String

    public init(
        binding: NotificationLedgerBinding?,
        transferDestinationAccountID: AccountID? = nil,
        cardPaymentInstrumentID: CreditInstrumentID? = nil,
        adjustmentOriginalsByProviderReference: [String: AdjustmentOriginal] = [:],
        currentBudgetMonth: BudgetMonth,
        currency: String,
        policyVersion: String
    ) throws {
        _ = try Money(minorUnits: 0, currency: currency)
        guard !policyVersion.isEmpty else { throw CandidateValidationError.emptyPolicyVersion }
        self.binding = binding
        self.transferDestinationAccountID = transferDestinationAccountID
        self.cardPaymentInstrumentID = cardPaymentInstrumentID
        self.adjustmentOriginalsByProviderReference = adjustmentOriginalsByProviderReference
        self.currentBudgetMonth = currentBudgetMonth
        self.currency = currency
        self.policyVersion = policyVersion
    }

    private enum CodingKeys: String, CodingKey {
        case binding
        case transferDestinationAccountID
        case cardPaymentInstrumentID
        case adjustmentOriginalsByProviderReference
        case currentBudgetMonth
        case currency
        case policyVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            binding: values.decodeIfPresent(NotificationLedgerBinding.self, forKey: .binding),
            transferDestinationAccountID: values.decodeIfPresent(
                AccountID.self,
                forKey: .transferDestinationAccountID
            ),
            cardPaymentInstrumentID: values.decodeIfPresent(
                CreditInstrumentID.self,
                forKey: .cardPaymentInstrumentID
            ),
            adjustmentOriginalsByProviderReference: values.decode(
                [String: AdjustmentOriginal].self,
                forKey: .adjustmentOriginalsByProviderReference
            ),
            currentBudgetMonth: values.decode(BudgetMonth.self, forKey: .currentBudgetMonth),
            currency: values.decode(String.self, forKey: .currency),
            policyVersion: values.decode(String.self, forKey: .policyVersion)
        )
    }
}

public enum TransactionCandidateParserError: Error, Equatable, Sendable {
    case invalidRawNotificationID
    case amountOverflow
}

/// Parser boundary: implementations may only convert one immutable raw notification into a
/// candidate. They receive no ledger or storage port and cannot persist or promote anything.
public protocol TransactionCandidateParser {
    func parse(
        _ notification: RawNotification,
        context: NotificationParsingContext
    ) throws -> TransactionCandidate
}
