/// What kind of message a provider sent. Provider-specific because one app sends unrelated kinds of message about
/// different instruments (Toss: a card payment, a bank transfer, a person's deposit).
public enum NotificationType: String, Codable, Hashable, Sendable {
    // Woori
    case bankTransaction
    // Hyundai Card
    case cardApproval, cardCancellation
    // Toss
    case tossPayment, tossBankTransfer, tossBankInterest, tossPersonDeposit
    // Kakao Pay
    case kakaoCharge, kakaoSend, kakaoReceive
    // Wallet transit card
    case transitFare, transitBalanceOnly, transitNoCharge
    /// A Wallet card tap. The card's own app sends the authoritative message for the same payment.
    case walletCardTap
    case unrecognized

    /// True when this message is not an independent financial event for an account.
    public var isSupplementary: Bool { self == .walletCardTap || self == .transitNoCharge }
}

/// What the money moved on, in the ledger's terms. `debitCard` settles on a bank account and binds to an
/// account; only `creditCard` binds to a card liability.
public enum InstrumentKind: String, Codable, Hashable, Sendable {
    case bankAccount, debitCard, creditCard, prepaidWallet, transitCard, unknown

    public var bindsToCreditInstrument: Bool { self == .creditCard }
}

/// What a notification says about one instrument. Not a binding: nothing here names a ledger account.
public struct FinancialInstrumentHint: Equatable, Sendable {
    public let institution: InstitutionID?
    public let kind: InstrumentKind
    public let identifier: AccountIdentifier?
    /// An identifier was found but is too short to bind on.
    public let hasWeakIdentifier: Bool

    public init(
        institution: InstitutionID?,
        kind: InstrumentKind,
        identifier: AccountIdentifier? = nil,
        hasWeakIdentifier: Bool = false
    ) {
        self.institution = institution
        self.kind = kind
        self.identifier = identifier
        self.hasWeakIdentifier = hasWeakIdentifier
    }

    public static let unknown = FinancialInstrumentHint(institution: nil, kind: .unknown)

    public var key: InstrumentKey? {
        guard let institution, let identifier, identifier.isStrong else { return nil }
        return InstrumentKey(institution: institution, identifier: identifier)
    }
}

/// Everything the account layer takes from one notification, kept apart: who sent it (`provider`), what kind of
/// message it is (`type`), and which instruments it names (`instrument`, and `counterpart` when the text names the
/// other side). Amounts and balances found in text are carried as observations, not as ledger facts.
public struct AccountEvidence: Equatable, Sendable {
    public let provider: SourceProviderID?
    public let type: NotificationType
    /// The instrument the notification is about: the side its own amount posts to.
    public let instrument: FinancialInstrumentHint
    /// The other side when the text names it (the account behind a wallet top-up, the recipient of a send).
    public let counterpart: FinancialInstrumentHint?
    public let balanceMinorUnits: Int64?
    /// An amount read from a field the parser does not read (e.g. a transit fare in the subtitle).
    public let textAmountMinorUnits: Int64?

    public init(
        provider: SourceProviderID?,
        type: NotificationType,
        instrument: FinancialInstrumentHint,
        counterpart: FinancialInstrumentHint? = nil,
        balanceMinorUnits: Int64? = nil,
        textAmountMinorUnits: Int64? = nil
    ) {
        self.provider = provider
        self.type = type
        self.instrument = instrument
        self.counterpart = counterpart
        self.balanceMinorUnits = balanceMinorUnits
        self.textAmountMinorUnits = textAmountMinorUnits
    }
}
