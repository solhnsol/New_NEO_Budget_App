import Foundation
/// Who delivered the notification (an app). Never the account the money moved on: a Toss message can be about a
/// Woori account or a Hyundai card, and a Wallet message can be about any card in it.
public struct SourceProviderID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

/// App display names change with the device language and with how the notification shortcut names the app, so a
/// provider is recognised through aliases. The internal ID never reaches the user as something to type, and no
/// bundle identifier is assumed to exist.
public struct ProviderCatalog: Sendable {
    public enum AliasKind: String, Sendable {
        /// The app's own name, shown the same way in every language (e.g. a Korean brand).
        case brand
        case english
        case korean
        /// A name a person typed by hand before the shortcut delivered the system name. Kept so old data still
        /// resolves, and reported separately in evaluations.
        case manual
    }

    public struct Alias: Sendable {
        public let text: String
        public let kind: AliasKind

        public init(_ text: String, _ kind: AliasKind) {
            self.text = ProviderCatalog.fold(text)
            self.kind = kind
        }
    }

    public struct Entry: Sendable {
        public let id: SourceProviderID
        public let aliases: [Alias]

        public init(id: SourceProviderID, aliases: [Alias]) {
            self.id = id
            self.aliases = aliases
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public static let woori = SourceProviderID(rawValue: "woori")
    public static let hyundaiCard = SourceProviderID(rawValue: "hyundaicard")
    public static let toss = SourceProviderID(rawValue: "toss")
    public static let kakaoPay = SourceProviderID(rawValue: "kakaopay")
    public static let wallet = SourceProviderID(rawValue: "wallet")

    /// Names seen in real data are English-device names (`Wallet`, `Toss`, `Kakaopay`) and brand names. The
    /// Korean-device forms are expected variants that have not been observed.
    public static let standard = ProviderCatalog(entries: [
        Entry(id: woori, aliases: [Alias("우리WON뱅킹", .brand), Alias("우리은행", .manual), Alias("Woori", .english)]),
        Entry(id: hyundaiCard, aliases: [Alias("현대카드", .brand), Alias("HyundaiCard", .english)]),
        Entry(id: SourceProviderID(rawValue: "tossbank"), aliases: [Alias("토스뱅크", .korean), Alias("TossBank", .english)]),
        Entry(id: toss, aliases: [Alias("Toss", .english), Alias("토스", .korean)]),
        Entry(id: kakaoPay, aliases: [Alias("Kakaopay", .english), Alias("카카오페이", .korean)]),
        Entry(id: wallet, aliases: [Alias("Wallet", .english), Alias("지갑", .korean)])
    ])

    /// Fields are tried in order; the first that names a provider decides. A field that names two providers
    /// equally well decides nothing.
    public func provider(for source: NotificationSource) -> SourceProviderID? {
        for field in [source.displayName, source.providerHint, source.applicationIdentifier] {
            guard let field, !field.isEmpty else { continue }
            if let found = match(Self.fold(field)) { return found }
        }
        return nil
    }

    private func match(_ field: String) -> SourceProviderID? {
        var best = 0
        var winners = Set<SourceProviderID>()
        for entry in entries {
            for alias in entry.aliases where !alias.text.isEmpty && field.contains(alias.text) {
                if alias.text.count > best {
                    best = alias.text.count
                    winners = [entry.id]
                } else if alias.text.count == best {
                    winners.insert(entry.id)
                }
            }
        }
        return winners.count == 1 ? winners.first : nil
    }

    static func fold(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased().filter { !$0.isWhitespace }
    }
}
