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

/// A clue to which instrument a notification is about. Every identifier is only meaningful together with an
/// institution (`InstrumentKey`); none is globally unique.
public enum AccountIdentifier: Codable, Hashable, Sendable {
    /// Masked account number as a bank prints it, e.g. the first ten digits and `***`.
    case accountNumber(MaskedNumber)
    /// Last digits of an account as a third party prints them (a transfer app naming the other bank account).
    /// A different scheme from `accountNumber`: the two cannot be compared, so the user links each once.
    case accountTail(String)
    /// Exactly the four digits a card notification shows.
    case cardTail(String)
    /// The card product printed in an approval (e.g. a credit product or a check card). A clue to which card, not
    /// proof of it: two cards of one product look the same.
    case cardProduct(String)

    /// Fewer visible digits than this say too little to bind money to an account.
    public static let minimumAccountDigits = 6

    public var isStrong: Bool {
        switch self {
        case let .accountNumber(number): number.visibleDigitCount >= Self.minimumAccountDigits
        case let .accountTail(tail), let .cardTail(tail): tail.count == 4 && tail.allSatisfy { $0.isASCII && $0.isNumber }
        case let .cardProduct(product): !product.isEmpty
        }
    }

    public func matches(_ other: AccountIdentifier) -> Bool {
        switch (self, other) {
        case let (.accountNumber(a), .accountNumber(b)): a.isCompatible(with: b)
        case let (.accountTail(a), .accountTail(b)): a == b
        case let (.cardTail(a), .cardTail(b)): a == b
        case let (.cardProduct(a), .cardProduct(b)): a == b
        default: false
        }
    }

    /// Stable text used inside candidate IDs.
    var canonical: String {
        switch self {
        case let .accountNumber(number): "acct:" + number.pattern
        case let .accountTail(tail): "tail:" + tail
        case let .cardTail(tail): "card:" + tail
        case let .cardProduct(product): "product:" + product
        }
    }
}

/// An identifier scoped to the institution that issued it.
public struct InstrumentKey: Codable, Hashable, Sendable {
    public let institution: InstitutionID
    public let identifier: AccountIdentifier

    public init(institution: InstitutionID, identifier: AccountIdentifier) {
        self.institution = institution
        self.identifier = identifier
    }

    func matches(_ other: InstrumentKey) -> Bool {
        institution == other.institution && identifier.matches(other.identifier)
    }
}
