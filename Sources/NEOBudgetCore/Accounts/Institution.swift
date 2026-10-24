import Foundation
/// The financial institution that holds an instrument (the bank, the card issuer, the wallet). It is what an
/// identifier is scoped to. It is not the app that delivered the notification: see `SourceProviderID`.
public struct InstitutionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let woori = InstitutionID(rawValue: "woori")
    public static let hyundaiCard = InstitutionID(rawValue: "hyundaicard")
    public static let tossBank = InstitutionID(rawValue: "tossbank")
    public static let kakaoPay = InstitutionID(rawValue: "kakaopay")
    public static let transit = InstitutionID(rawValue: "transit")
}

/// Bank names as they appear inside message text ("우리 계좌로 입금"). Matching is on a whole word, so everyday
/// words that contain a bank's short name are not read as banks.
public struct BankNameCatalog: Sendable {
    public let names: [String: InstitutionID]

    public init(names: [String: InstitutionID]) { self.names = names }

    public static let korean = BankNameCatalog(names: [
        "우리": .woori, "우리은행": .woori,
        "토스뱅크": .tossBank,
        "카카오뱅크": InstitutionID(rawValue: "kakaobank"),
        "신한": InstitutionID(rawValue: "shinhan"), "신한은행": InstitutionID(rawValue: "shinhan"),
        "국민": InstitutionID(rawValue: "kb"), "국민은행": InstitutionID(rawValue: "kb"),
        "하나": InstitutionID(rawValue: "hana"), "하나은행": InstitutionID(rawValue: "hana"),
        "농협": InstitutionID(rawValue: "nh"), "농협은행": InstitutionID(rawValue: "nh")
    ])

    public func institution(named word: String) -> InstitutionID? {
        names[word.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}
