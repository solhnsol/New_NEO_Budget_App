import Foundation

/// 알림이 어느 계좌·카드에 대한 것인지 읽는 항목. 거래 값을 읽는 `ReadingEntry`와 따로 있어도 같은 사전에 들어 있다.
public struct ReadingEvidenceEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var origin: ReadingEntry.Origin = .official
    public var enabled: Bool = true
    public var rank: Int
    /// 알림을 보낸 앱(`SourceProviderID.rawValue`).
    public var provider: String
    public var conditions: [ReadingCondition]
    /// 맞으면 값을 더 읽고, 안 맞아도 항목은 유지된다(예: 잔액).
    public var optionalReads: [ReadingCondition] = []
    public var type: NotificationType
    public var instrument: EvidenceInstrument
    public var counterpart: EvidenceInstrument? = nil
    public var readsBalance: Bool = false
    public var readsTextAmount: Bool = false

    public init(
        id: String, name: String, rank: Int, provider: String, conditions: [ReadingCondition],
        optionalReads: [ReadingCondition] = [], type: NotificationType, instrument: EvidenceInstrument,
        counterpart: EvidenceInstrument? = nil, readsBalance: Bool = false, readsTextAmount: Bool = false,
        origin: ReadingEntry.Origin = .official
    ) {
        self.id = id; self.name = name; self.rank = rank; self.provider = provider; self.conditions = conditions
        self.optionalReads = optionalReads; self.type = type; self.instrument = instrument; self.counterpart = counterpart
        self.readsBalance = readsBalance; self.readsTextAmount = readsTextAmount; self.origin = origin
    }
}

public struct EvidenceInstrument: Codable, Equatable, Sendable {
    public enum Institution: Codable, Equatable, Sendable {
        case none
        case fixed(String)
        /// 알림에서 읽은 기관 이름을 은행 이름표에서 찾는다.
        case named
    }
    public enum Kind: Codable, Equatable, Sendable {
        case fixed(InstrumentKind)
        /// 읽은 카드 상품 이름으로 종류를 정한다(모르는 상품은 종류 미상).
        case cardProduct
    }
    public enum Identifier: Codable, Equatable, Sendable {
        case none
        case accountNumber
        case cardProduct
        case accountTail
    }
    /// 기관 이름을 못 찾았을 때.
    public enum Unresolved: String, Codable, Sendable {
        case allowNil, unknownHint, skipEntry
    }

    public var institution: Institution
    public var kind: Kind
    public var identifier: Identifier = .none
    public var unresolved: Unresolved = .allowNil

    public init(institution: Institution, kind: Kind, identifier: Identifier = .none, unresolved: Unresolved = .allowNil) {
        self.institution = institution; self.kind = kind; self.identifier = identifier; self.unresolved = unresolved
    }
}

/// 증거 항목을 해석한다. 앱 이름 → 앱 구분, 은행 이름표, 카드 상품 표는 데이터로 받는다.
public struct ReadingEvidenceReader: Sendable {
    public let providers: ProviderCatalog
    public let banks: BankNameCatalog
    public let cardProducts: [String: InstrumentKind]
    private let entries: [Compiled]

    private struct Compiled: Sendable {
        let entry: ReadingEvidenceEntry
        let optional: [(ReadingField, ReadingFrame)]
        let others: [ReadingCondition]
    }

    public init(
        entries: [ReadingEvidenceEntry], providers: ProviderCatalog = .standard, banks: BankNameCatalog = .korean,
        cardProducts: [String: InstrumentKind] = ["MM": .creditCard, "체크": .debitCard]
    ) {
        self.providers = providers
        self.banks = banks
        self.cardProducts = cardProducts
        self.entries = entries.filter(\.enabled).sorted { ($0.origin == .user ? 0 : 1, $0.rank, $0.id) < ($1.origin == .user ? 0 : 1, $1.rank, $1.id) }
            .map { entry in
                var optional: [(ReadingField, ReadingFrame)] = []
                for condition in entry.optionalReads {
                    if case let .frameContained(field, text) = condition, let frame = ReadingFrame(text, anchored: false) { optional.append((field, frame)) }
                }
                return Compiled(entry: entry, optional: optional, others: entry.conditions)
            }
    }

    public func evidence(from notification: RawNotification) -> AccountEvidence {
        let provider = providers.provider(for: notification.source)
        let view = NotificationView(notification)
        guard let provider else { return AccountEvidence(provider: nil, type: .unrecognized, instrument: .unknown) }
        for compiled in entries where compiled.entry.provider == provider.rawValue {
            guard var values = Self.match(compiled.others, view) else { continue }
            for (field, frame) in compiled.optional {
                if let found = frame.match(in: view.field(field)) { values.merge(found) { $1 } }
            }
            if let result = build(compiled.entry, values, provider: provider) { return result }
        }
        return AccountEvidence(provider: provider, type: .unrecognized, instrument: .unknown)
    }

    private static func match(_ conditions: [ReadingCondition], _ view: NotificationView) -> [ReadingSlot: String]? {
        var values: [ReadingSlot: String] = [:]
        for condition in conditions {
            switch condition {
            case let .contains(field, terms):
                guard terms.contains(where: view.field(field).contains) else { return nil }
            case let .notEmpty(field):
                guard !view.field(field).isEmpty else { return nil }
            case let .frame(field, text):
                guard let frame = ReadingFrame(text, anchored: true), let found = frame.match(in: view.field(field)) else { return nil }
                values.merge(found) { $1 }
            case let .frameContained(field, text):
                guard let frame = ReadingFrame(text, anchored: false), let found = frame.match(in: view.field(field)) else { return nil }
                values.merge(found) { $1 }
            }
        }
        return values
    }

    private func build(_ entry: ReadingEvidenceEntry, _ values: [ReadingSlot: String], provider: SourceProviderID) -> AccountEvidence? {
        guard let instrument = hint(entry.instrument, values) else { return nil }
        var counterpart: FinancialInstrumentHint?
        if let spec = entry.counterpart {
            guard let hint = hint(spec, values, counterpart: true) else { return nil }
            counterpart = hint
        }
        func won(_ slot: ReadingSlot) -> Int64? { values[slot].flatMap { Int64($0.replacingOccurrences(of: ",", with: "")) } }
        let balance = entry.readsBalance ? won(.balance) : nil
        return AccountEvidence(
            provider: provider, type: entry.type, instrument: instrument, counterpart: counterpart,
            balanceMinorUnits: balance, textAmountMinorUnits: entry.readsTextAmount ? won(.amount) : nil
        )
    }

    private func hint(_ spec: EvidenceInstrument, _ values: [ReadingSlot: String], counterpart: Bool = false) -> FinancialInstrumentHint? {
        var institution: InstitutionID?
        switch spec.institution {
        case .none: institution = nil
        case let .fixed(raw): institution = InstitutionID(rawValue: raw)
        case .named:
            institution = values[.institution].flatMap(banks.institution(named:))
            if institution == nil {
                switch spec.unresolved {
                case .skipEntry: return nil
                case .unknownHint: return .unknown
                case .allowNil: break
                }
            }
        }
        var kind: InstrumentKind
        switch spec.kind {
        case let .fixed(value): kind = value
        case .cardProduct: kind = values[.cardName].flatMap { cardProducts[$0.uppercased()] } ?? .unknown
        }
        var identifier: AccountIdentifier?
        var weak = false
        switch spec.identifier {
        case .none: break
        case .accountNumber:
            if let raw = values[.accountNumber], let number = MaskedNumber(raw) {
                let candidate = AccountIdentifier.accountNumber(number)
                if candidate.isStrong { identifier = candidate } else { weak = true }
            }
        case .cardProduct: identifier = values[.cardName].map { .cardProduct($0.uppercased()) }
        case .accountTail: identifier = values[.accountNumber].map { .accountTail($0) }
        }
        return FinancialInstrumentHint(institution: institution, kind: kind, identifier: identifier, hasWeakIdentifier: weak)
    }
}
