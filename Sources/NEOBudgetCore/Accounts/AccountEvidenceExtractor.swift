import Foundation

/// Reads `AccountEvidence` from a raw notification. Independent of the transaction parser, which keeps its own
/// contract and never sees accounts. What each app's messages look like is data in the reading dictionary
/// (`ReadingEvidenceEntry`); a shape that no entry recognises yields `.unrecognized`, never a guess.
public struct AccountEvidenceExtractor: Sendable {
    public let providers: ProviderCatalog
    public let banks: BankNameCatalog
    /// Card products whose settlement is known. A product not listed here is kept as an identifier but its kind
    /// stays unknown, so it can never bind silently.
    public let cardProducts: [String: InstrumentKind]
    private let reader: ReadingEvidenceReader

    public init(
        providers: ProviderCatalog = .standard,
        banks: BankNameCatalog = .korean,
        cardProducts: [String: InstrumentKind] = ["MM": .creditCard, "체크": .debitCard],
        evidenceEntries: [ReadingEvidenceEntry] = OfficialEvidenceEntries.all
    ) {
        self.providers = providers
        self.banks = banks
        self.cardProducts = cardProducts
        self.reader = ReadingEvidenceReader(entries: evidenceEntries, providers: providers, banks: banks, cardProducts: cardProducts)
    }

    public func evidence(from notification: RawNotification) -> AccountEvidence { reader.evidence(from: notification) }
}
