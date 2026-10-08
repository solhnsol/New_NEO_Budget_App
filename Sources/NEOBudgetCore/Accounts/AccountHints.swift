import Foundation

/// A number as a notification shows it: digits and `*` for masked positions, separators removed.
public struct MaskedNumber: Codable, Hashable, Sendable {
    public let pattern: String

    public init?(_ raw: String) {
        let cleaned = raw.filter { !$0.isWhitespace && $0 != "-" }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0 == "*" || $0.isASCII && $0.isNumber }) else { return nil }
        pattern = cleaned
    }

    public var visibleDigitCount: Int { pattern.filter { $0 != "*" }.count }

    /// Same length and equal wherever both sides show a digit. Two patterns that differ only in masked
    /// positions are compatible, so they can match two accounts at once, and that is reported as a conflict.
    public func isCompatible(with other: MaskedNumber) -> Bool {
        guard pattern.count == other.pattern.count else { return false }
        return zip(pattern, other.pattern).allSatisfy { $0 == $1 || $0 == "*" || $1 == "*" }
    }
}

public enum AccountIdentifier: Codable, Hashable, Sendable {
    case accountNumber(MaskedNumber)
    /// Exactly the four digits a card notification shows.
    case cardTail(String)

    /// Fewer visible digits than this say too little to bind money to an account.
    public static let minimumAccountDigits = 6

    public var isStrong: Bool {
        switch self {
        case let .accountNumber(number): number.visibleDigitCount >= Self.minimumAccountDigits
        case let .cardTail(tail): tail.count == 4 && tail.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    public func matches(_ other: AccountIdentifier) -> Bool {
        switch (self, other) {
        case let (.accountNumber(a), .accountNumber(b)): a.isCompatible(with: b)
        case let (.cardTail(a), .cardTail(b)): a == b
        default: false
        }
    }

    /// Stable text used inside candidate IDs.
    var canonical: String {
        switch self {
        case let .accountNumber(number): "acct:" + number.pattern
        case let .cardTail(tail): "card:" + tail
        }
    }
}

public enum InstrumentClass: String, Codable, Hashable, Sendable {
    case account, card, unknown
}

/// What a notification says about where the money moved. Not a binding: nothing here names a ledger account.
public struct AccountHints: Equatable, Sendable {
    public let institution: InstitutionID?
    public let instrument: InstrumentClass
    public let sourceApplication: String
    /// Present only when a masked or tail identifier was found and is specific enough to bind on.
    public let identifier: AccountIdentifier?
    /// An identifier was found but is too short to bind on.
    public let hasWeakIdentifier: Bool

    public init(
        institution: InstitutionID?,
        instrument: InstrumentClass,
        sourceApplication: String,
        identifier: AccountIdentifier? = nil,
        hasWeakIdentifier: Bool = false
    ) {
        self.institution = institution
        self.instrument = instrument
        self.sourceApplication = sourceApplication
        self.identifier = identifier
        self.hasWeakIdentifier = hasWeakIdentifier
    }
}

/// Reads account hints from a raw notification. Independent of the transaction parser, which keeps its own
/// contract and never sees account identity.
public struct AccountHintExtractor: Sendable {
    public let catalog: InstitutionCatalog

    public init(catalog: InstitutionCatalog = .korean) { self.catalog = catalog }

    public func hints(from notification: RawNotification) -> AccountHints {
        let text = NotificationText.joined(notification)
        let institution = catalog.institution(for: notification.source)
        var identifier: AccountIdentifier?
        var weak = false

        if let number = maskedAccountNumber(in: text) {
            let candidate = AccountIdentifier.accountNumber(number)
            if candidate.isStrong { identifier = candidate } else { weak = true }
        } else if let tail = cardTail(in: text) {
            identifier = .cardTail(tail)
        }

        let instrument: InstrumentClass
        switch identifier {
        case .accountNumber: instrument = .account
        case .cardTail: instrument = .card
        case nil:
            if text.contains("카드") { instrument = .card }
            else if ["계좌", "입금", "출금", "이체"].contains(where: text.contains) { instrument = .account }
            else { instrument = institution.map(catalog.defaultInstrument(for:)) ?? .unknown }
        }
        return AccountHints(
            institution: institution,
            instrument: instrument,
            sourceApplication: notification.source.applicationIdentifier,
            identifier: identifier,
            hasWeakIdentifier: weak
        )
    }

    // Hyphenated groups that contain at least one `*`. Unmasked digit runs are never taken as an account
    // number: dates, phone numbers, and amounts look the same, and a masked group is the only shape that is
    // unambiguously an identifier.
    private static let accountPattern = try! NSRegularExpression(
        pattern: #"(?<![\d*-])\d{2,6}(?:-[\d*]{2,8}){1,3}(?![\d*-])"#
    )
    private static let cardPatterns = [
        try! NSRegularExpression(pattern: #"(?:카드|card)\s*\(?(\d{4})\)?(?!\d)"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\*{2,}\s?(\d{4})(?!\d)"#)
    ]

    private func maskedAccountNumber(in text: String) -> MaskedNumber? {
        let range = NSRange(text.startIndex..., in: text)
        for match in Self.accountPattern.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let raw = String(text[swiftRange])
            guard raw.contains("*") else { continue }
            return MaskedNumber(raw)
        }
        return nil
    }

    private func cardTail(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in Self.cardPatterns {
            if let match = pattern.firstMatch(in: text, range: range),
               let group = Range(match.range(at: 1), in: text) {
                return String(text[group])
            }
        }
        return nil
    }
}
