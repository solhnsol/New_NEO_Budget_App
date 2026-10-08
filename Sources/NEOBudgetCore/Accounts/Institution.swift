/// Stable key of a financial institution or financial app family. Two apps of one institution share an ID.
public struct InstitutionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Maps notification sources to institutions. Institution is taken from the source only (app name, provider
/// hint, bundle identifier), never guessed from the message text: a Toss message that mentions another bank
/// is still a Toss message.
public struct InstitutionCatalog: Sendable {
    public struct Entry: Sendable {
        public let id: InstitutionID
        public let aliases: [String]
        /// What an institution's notifications are about when the text does not say (a card company only has cards).
        public let defaultInstrument: InstrumentClass

        public init(id: InstitutionID, aliases: [String], defaultInstrument: InstrumentClass = .unknown) {
            self.id = id
            self.defaultInstrument = defaultInstrument
            self.aliases = aliases.map(InstitutionCatalog.fold)
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// Deliberately small. Unknown sources stay unknown rather than being forced into a family.
    public static let korean = InstitutionCatalog(entries: [
        Entry(id: InstitutionID(rawValue: "woori"), aliases: ["우리은행", "우리won뱅킹", "우리뱅킹", "woori"]),
        Entry(id: InstitutionID(rawValue: "hyundaicard"), aliases: ["현대카드", "hyundaicard"], defaultInstrument: .card),
        Entry(id: InstitutionID(rawValue: "tossbank"), aliases: ["토스뱅크", "tossbank"], defaultInstrument: .account),
        Entry(id: InstitutionID(rawValue: "toss"), aliases: ["toss", "토스", "viva.republica"]),
        Entry(id: InstitutionID(rawValue: "kakaobank"), aliases: ["카카오뱅크", "kakaobank"], defaultInstrument: .account),
        Entry(id: InstitutionID(rawValue: "kakaopay"), aliases: ["카카오페이", "kakaopay"]),
        Entry(id: InstitutionID(rawValue: "wallet"), aliases: ["wallet", "passkit"]),
        Entry(id: InstitutionID(rawValue: "tmoney"), aliases: ["교통카드", "티머니", "tmoney"]),
        Entry(id: InstitutionID(rawValue: "shinhan"), aliases: ["신한", "shinhan"]),
        Entry(id: InstitutionID(rawValue: "kb"), aliases: ["국민은행", "kb국민", "kbstar"]),
        Entry(id: InstitutionID(rawValue: "nh"), aliases: ["농협", "nhbank"]),
        Entry(id: InstitutionID(rawValue: "hana"), aliases: ["하나은행", "하나카드", "hana"])
    ])

    /// Fields are tried in order; the first one that names an institution decides. A field that names two
    /// different institutions equally well decides nothing.
    public func institution(for source: NotificationSource) -> InstitutionID? {
        for field in [source.displayName, source.providerHint, source.applicationIdentifier] {
            guard let field, !field.isEmpty else { continue }
            if let found = match(Self.fold(field)) { return found }
        }
        return nil
    }

    public func defaultInstrument(for institution: InstitutionID) -> InstrumentClass {
        entries.first { $0.id == institution }?.defaultInstrument ?? .unknown
    }

    private func match(_ field: String) -> InstitutionID? {
        var best = 0
        var winners = Set<InstitutionID>()
        for entry in entries {
            for alias in entry.aliases where !alias.isEmpty && field.contains(alias) {
                if alias.count > best {
                    best = alias.count
                    winners = [entry.id]
                } else if alias.count == best {
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
