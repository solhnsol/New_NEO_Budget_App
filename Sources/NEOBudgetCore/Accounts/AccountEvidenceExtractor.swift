import Foundation

/// Reads `AccountEvidence` from a raw notification. Independent of the transaction parser, which keeps its own
/// contract and never sees accounts. Patterns follow message shapes observed in real notifications; a shape that is
/// not recognised yields `.unrecognized`, never a guess.
public struct AccountEvidenceExtractor: Sendable {
    public let providers: ProviderCatalog
    public let banks: BankNameCatalog
    /// Card products whose settlement is known. A product not listed here is kept as an identifier but its kind
    /// stays unknown, so it can never bind silently.
    public let cardProducts: [String: InstrumentKind]

    public init(
        providers: ProviderCatalog = .standard,
        banks: BankNameCatalog = .korean,
        cardProducts: [String: InstrumentKind] = ["MM": .creditCard, "체크": .debitCard]
    ) {
        self.providers = providers
        self.banks = banks
        self.cardProducts = cardProducts
    }

    public func evidence(from notification: RawNotification) -> AccountEvidence {
        let provider = providers.provider(for: notification.source)
        let text = NotificationText.joined(notification)
        let subtitle = NotificationText.normalize(notification.subtitle ?? "")
        let body = NotificationText.normalize(notification.body ?? "")
        let title = NotificationText.normalize(notification.title ?? "")

        switch provider {
        case ProviderCatalog.woori: return woori(text, provider)
        case ProviderCatalog.hyundaiCard: return hyundaiCard(text, provider)
        case ProviderCatalog.toss: return toss(title: title, body: body, text, provider)
        case ProviderCatalog.kakaoPay: return kakaoPay(text, provider)
        case ProviderCatalog.wallet: return wallet(title: title, subtitle: subtitle, body: body, provider)
        default: return AccountEvidence(provider: provider, type: .unrecognized, instrument: .unknown)
        }
    }

    // MARK: Woori

    private static let maskedAccount = regex(#"(?<![\d*-])\d{2,6}(?:-[\d*]{2,8}){1,3}(?![\d*-])"#)
    private static let balance = regex(#"잔액\s*([\d,]+)\s*원"#)

    private func woori(_ text: String, _ provider: SourceProviderID?) -> AccountEvidence {
        var identifier: AccountIdentifier?
        var weak = false
        for match in Self.maskedAccount.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), text[range].contains("*"),
                  let number = MaskedNumber(String(text[range])) else { continue }
            let candidate = AccountIdentifier.accountNumber(number)
            if candidate.isStrong { identifier = candidate } else { weak = true }
            break
        }
        let balance = Self.capture(Self.balance, in: text).flatMap(Self.won)
        guard identifier != nil || weak || balance != nil else {
            return AccountEvidence(provider: provider, type: .unrecognized, instrument: .unknown)
        }
        return AccountEvidence(
            provider: provider, type: .bankTransaction,
            instrument: FinancialInstrumentHint(institution: .woori, kind: .bankAccount, identifier: identifier, hasWeakIdentifier: weak),
            balanceMinorUnits: balance
        )
    }

    // MARK: Hyundai Card

    private static let hyundaiApproval = regex(#"현대\s*([A-Za-z가-힣0-9]+)\s*(승인|취소)"#)

    private func hyundaiCard(_ text: String, _ provider: SourceProviderID?) -> AccountEvidence {
        guard let parts = Self.captures(Self.hyundaiApproval, in: text), parts.count == 2 else {
            return AccountEvidence(provider: provider, type: .unrecognized, instrument: .unknown)
        }
        let type: NotificationType = parts[1] == "취소" ? .cardCancellation : .cardApproval
        return AccountEvidence(provider: provider, type: type, instrument: cardInstrument(product: parts[0]))
    }

    private func cardInstrument(product raw: String) -> FinancialInstrumentHint {
        let product = raw.uppercased()
        return FinancialInstrumentHint(
            institution: .hyundaiCard,
            kind: cardProducts[product] ?? .unknown,
            identifier: .cardProduct(product)
        )
    }

    // MARK: Toss (a hub: the app is never the account)

    private static let tossCardMethod = regex(#"현대카드\s*([A-Za-z0-9]+|체크)"#)
    private static let leadingBank = regex(#"^\s*([가-힣]+)\s*[・·]"#)
    private static let depositBank = regex(#"([가-힣]+)\s*계좌(?:로|에)\s*입금"#)

    private func toss(title: String, body: String, _ text: String, _ provider: SourceProviderID?) -> AccountEvidence {
        if text.contains("→"), text.contains("통장"), text.contains("입금") || text.contains("출금") {
            return AccountEvidence(provider: provider, type: .tossBankTransfer,
                                   instrument: FinancialInstrumentHint(institution: .tossBank, kind: .bankAccount))
        }
        if text.contains("이자"), text.contains("통장") {
            return AccountEvidence(provider: provider, type: .tossBankInterest,
                                   instrument: FinancialInstrumentHint(institution: .tossBank, kind: .bankAccount))
        }
        if let bank = Self.capture(Self.depositBank, in: text) {
            // Only the bank is named; which of the user's accounts there is not in the message.
            return AccountEvidence(provider: provider, type: .tossPersonDeposit,
                                   instrument: FinancialInstrumentHint(institution: banks.institution(named: bank), kind: .bankAccount))
        }
        if title.contains("결제") || body.contains("결제") {
            if let product = Self.capture(Self.tossCardMethod, in: text) {
                return AccountEvidence(provider: provider, type: .tossPayment, instrument: cardInstrument(product: product))
            }
            if let word = Self.capture(Self.leadingBank, in: body), let bank = banks.institution(named: word) {
                return AccountEvidence(provider: provider, type: .tossPayment,
                                       instrument: FinancialInstrumentHint(institution: bank, kind: .bankAccount))
            }
            return AccountEvidence(provider: provider, type: .tossPayment, instrument: .unknown)
        }
        return AccountEvidence(provider: provider, type: .unrecognized, instrument: .unknown)
    }

    // MARK: Kakao Pay (the wallet is the instrument; the bank account is the other side)

    private static let chargeSource = regex(#"충전계좌\s*:\s*(\S+)\s+(\d{4})"#)
    private static let sendRecipient = regex(#"(\S+)\s+(\d{4})\s*\("#)

    private func kakaoPay(_ text: String, _ provider: SourceProviderID?) -> AccountEvidence {
        let wallet = FinancialInstrumentHint(institution: .kakaoPay, kind: .prepaidWallet)
        if text.contains("충전"), let parts = Self.captures(Self.chargeSource, in: text), parts.count == 2 {
            return AccountEvidence(provider: provider, type: .kakaoCharge, instrument: wallet, counterpart: tailHint(bank: parts[0], tail: parts[1]))
        }
        if text.contains("송금했"), let parts = Self.captures(Self.sendRecipient, in: text), parts.count == 2 {
            return AccountEvidence(provider: provider, type: .kakaoSend, instrument: wallet, counterpart: tailHint(bank: parts[0], tail: parts[1]))
        }
        if text.contains("보냈") {
            return AccountEvidence(provider: provider, type: .kakaoReceive, instrument: wallet)
        }
        return AccountEvidence(provider: provider, type: .unrecognized, instrument: .unknown)
    }

    private func tailHint(bank word: String, tail: String) -> FinancialInstrumentHint {
        guard let bank = banks.institution(named: word) else { return .unknown }
        return FinancialInstrumentHint(institution: bank, kind: .bankAccount, identifier: .accountTail(tail))
    }

    // MARK: Wallet transit card (fare in the subtitle, balance in the body)

    private static let transitFare = regex(#"^\s*₩([\d,]+)\s+for\s"#)
    private static let transitBalance = regex(#"balance is ₩([\d,]+)"#)
    private static let amountOnly = regex(#"^\s*₩[\d,]+\s*$"#)

    private func wallet(title: String, subtitle: String, body: String, _ provider: SourceProviderID?) -> AccountEvidence {
        let transit = FinancialInstrumentHint(institution: .transit, kind: .transitCard)
        let balance = Self.capture(Self.transitBalance, in: body).flatMap(Self.won)
        if let fare = Self.capture(Self.transitFare, in: subtitle).flatMap(Self.won), balance != nil {
            return AccountEvidence(provider: provider, type: .transitFare, instrument: transit,
                                   balanceMinorUnits: balance, textAmountMinorUnits: fare)
        }
        if let balance {
            let type: NotificationType = body.lowercased().contains("no charge") ? .transitNoCharge : .transitBalanceOnly
            return AccountEvidence(provider: provider, type: type, instrument: transit, balanceMinorUnits: balance)
        }
        if Self.amountOnly.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil, title.contains("카드") {
            let issuer: FinancialInstrumentHint = title.contains("현대카드")
                ? FinancialInstrumentHint(institution: .hyundaiCard, kind: .unknown) : .unknown
            return AccountEvidence(provider: provider, type: .walletCardTap, instrument: issuer)
        }
        return AccountEvidence(provider: provider, type: .unrecognized, instrument: .unknown)
    }

    // MARK: Helpers

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }

    private static func captures(_ regex: NSRegularExpression, in text: String) -> [String]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    private static func capture(_ regex: NSRegularExpression, in text: String) -> String? { captures(regex, in: text)?.first }

    private static func won(_ text: String) -> Int64? { Int64(text.replacingOccurrences(of: ",", with: "")) }
}
