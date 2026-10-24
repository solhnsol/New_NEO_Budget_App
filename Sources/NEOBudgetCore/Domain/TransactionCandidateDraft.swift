public enum DraftEventKind: String, Codable, Sendable {
    case purchase, cancellation, refund, withdrawal, deposit
    case transferOut, transferIn, cardBillPayment, cashWithdrawal, walletTopUp
    case purchaseSettlementNotice, feeCharge
}

public enum TransactionDirection: String, Codable, Sendable {
    case outflow, inflow, neutral
}

public enum TimestampPrecision: String, Codable, Sendable {
    case second, minute, day
}

public enum TimestampSource: String, Codable, Sendable {
    case text, notificationTime, captureTime
}

public struct ObservedTimestamp: Codable, Equatable, Sendable {
    public let unixMilliseconds: Int64
    public let precision: TimestampPrecision
    public let source: TimestampSource

    public init(unixMilliseconds: Int64, precision: TimestampPrecision, source: TimestampSource) {
        self.unixMilliseconds = unixMilliseconds
        self.precision = precision
        self.source = source
    }
}

public enum InstrumentHintKind: String, Codable, Sendable {
    case unknown, bankAccount, debitCard, creditCard, prepaidWallet, transitCard
}

public struct InstrumentHint: Codable, Equatable, Sendable {
    public let kind: InstrumentHintKind
    public let maskedHint: String?
    public let displayNameRaw: String?

    public init(kind: InstrumentHintKind, maskedHint: String? = nil, displayNameRaw: String? = nil) {
        self.kind = kind
        self.maskedHint = maskedHint
        self.displayNameRaw = displayNameRaw
    }
}

public struct DraftCounterparty: Codable, Equatable, Sendable {
    public let merchantRaw: String?
    public let payeeRaw: String?
    public let memoRaw: String?

    public init(merchantRaw: String? = nil, payeeRaw: String? = nil, memoRaw: String? = nil) {
        self.merchantRaw = merchantRaw
        self.payeeRaw = payeeRaw
        self.memoRaw = memoRaw
    }
}

public enum ParserIssueSeverity: String, Codable, Sendable {
    case soft, hard
}

public enum ParserIssue: String, Codable, Hashable, Sendable {
    case merchantMissing, timeAbsentFallback, instrumentHintMissing
    case amountAmbiguous, amountZero, timeMalformed, timeBoundaryRisk
    case directionUnknown, kindAmbiguous, parserUncertain

    public var severity: ParserIssueSeverity {
        switch self {
        case .merchantMissing, .timeAbsentFallback, .instrumentHintMissing:
            return .soft
        default:
            return .hard
        }
    }
}

public enum DraftConfidence: String, Codable, Sendable {
    case high, medium, low
}

public enum DraftEvidenceKind: String, Codable, Sendable {
    case deliveryID, providerTransactionID, approvalNumber, originalApprovalReference
    case fingerprintExact, fingerprintLoose
}

public enum DraftEvidenceStrength: String, Codable, Sendable {
    case strong, scoped, relation, weak
}

public struct DraftEvidence: Codable, Equatable, Sendable {
    public let kind: DraftEvidenceKind
    public let strength: DraftEvidenceStrength
    public let value: String
    public let scope: String?

    public init(kind: DraftEvidenceKind, strength: DraftEvidenceStrength, value: String, scope: String? = nil) {
        self.kind = kind
        self.strength = strength
        self.value = value
        self.scope = scope
    }
}

public enum DraftValidationError: Error, Equatable, Sendable {
    case invalidRawNotificationID
    case invalidEventIndex
    case emptyParserIdentity
    case nonPositiveAmount
    case duplicateIssue(ParserIssue)
}

/// Parser-owned observed facts. Account, credit-instrument, and ledger identifiers are absent.
public struct TransactionCandidateDraft: Codable, Equatable, Sendable {
    public let rawNotificationID: String
    public let eventIndex: Int
    public let parserID: String
    public let parserVersion: String
    public let ruleID: String
    public let kind: DraftEventKind
    public let direction: TransactionDirection
    public let amount: Money
    public let balanceAfter: Money?
    public let occurredAt: ObservedTimestamp
    public let instrument: InstrumentHint
    public let counterparty: DraftCounterparty
    public let evidence: [DraftEvidence]
    public let issues: [ParserIssue]
    public let confidence: DraftConfidence

    public var hasHardIssues: Bool {
        issues.contains(where: { $0.severity == .hard })
    }

    public init(
        rawNotificationID: String,
        eventIndex: Int = 0,
        parserID: String,
        parserVersion: String,
        ruleID: String,
        kind: DraftEventKind,
        direction: TransactionDirection,
        amount: Money,
        balanceAfter: Money? = nil,
        occurredAt: ObservedTimestamp,
        instrument: InstrumentHint = InstrumentHint(kind: .unknown),
        counterparty: DraftCounterparty = DraftCounterparty(),
        evidence: [DraftEvidence] = [],
        issues: [ParserIssue] = [],
        confidence: DraftConfidence
    ) throws {
        guard !rawNotificationID.isEmpty else { throw DraftValidationError.invalidRawNotificationID }
        guard eventIndex >= 0 else { throw DraftValidationError.invalidEventIndex }
        guard !parserID.isEmpty, !parserVersion.isEmpty, !ruleID.isEmpty else {
            throw DraftValidationError.emptyParserIdentity
        }
        guard amount.minorUnits > 0 else { throw DraftValidationError.nonPositiveAmount }
        var uniqueIssues = Set<ParserIssue>()
        for issue in issues where !uniqueIssues.insert(issue).inserted {
            throw DraftValidationError.duplicateIssue(issue)
        }
        self.rawNotificationID = rawNotificationID
        self.eventIndex = eventIndex
        self.parserID = parserID
        self.parserVersion = parserVersion
        self.ruleID = ruleID
        self.kind = kind
        self.direction = direction
        self.amount = amount
        self.balanceAfter = balanceAfter
        self.occurredAt = occurredAt
        self.instrument = instrument
        self.counterparty = counterparty
        self.evidence = evidence
        self.issues = issues
        self.confidence = confidence
    }
}
