public struct NotificationParsingContext: Codable, Equatable, Sendable {
    public let timeZoneIdentifier: String
    public let referenceTimeUnixMilliseconds: Int64
    public let parserID: String
    public let parserVersion: String

    public init(timeZoneIdentifier: String, referenceTimeUnixMilliseconds: Int64, parserID: String, parserVersion: String) throws {
        guard !timeZoneIdentifier.isEmpty, !parserID.isEmpty, !parserVersion.isEmpty else {
            throw NotificationParserContractError.emptyContextValue
        }
        self.timeZoneIdentifier = timeZoneIdentifier
        self.referenceTimeUnixMilliseconds = referenceTimeUnixMilliseconds
        self.parserID = parserID
        self.parserVersion = parserVersion
    }
}

public enum NotificationParserContractError: Error, Equatable, Sendable {
    case emptyContextValue
    case invalidRawNotificationID
    case amountOverflow
}

public enum NotTransactionReason: String, Codable, Sendable {
    case promotion, authentication, declined, pending, balanceInquiry, unrecognized
}

public enum NotificationParseFailure: Error, Equatable, Sendable {
    case amountMissing
    case amountUnparseable
    case multipleTransactions
}

public enum NotificationParseOutcome: Equatable, Sendable {
    case candidate(TransactionCandidateDraft)
    case notTransaction(NotTransactionReason)
    case failed(NotificationParseFailure)
}

/// Converts immutable raw input into observed facts only. It cannot bind accounts or write a ledger.
public protocol TransactionCandidateParser {
    func parse(_ notification: RawNotification, context: NotificationParsingContext) throws -> NotificationParseOutcome
}
