import Foundation
import Testing
import NEOBudgetCore
import NEOBudgetInMemoryStorage

private struct SyntheticCoverage: Decodable {
    let schemaVersion: Int
    let policyVersion: String
    let notifications: [RawNotification]
}

@Test func syntheticProviderCoverageUsesTheNeutralCoreWithoutDeliveryClaims() throws {
    let url = try #require(Bundle.module.url(
        forResource: "synthetic-notification-coverage", withExtension: "json", subdirectory: "Fixtures"
    ))
    let coverage = try JSONDecoder().decode(SyntheticCoverage.self, from: Data(contentsOf: url))
    #expect(coverage.schemaVersion == 1)
    #expect(coverage.policyVersion == "coverage-synthesis-v1")
    #expect(Set(coverage.notifications.map(\.source.providerHint)) ==
            Set(["woori", "hyundai", "toss", "kakaopay", "wallet"].map(Optional.some)))
    var repository = InMemoryRawNotificationRepository()
    for input in coverage.notifications {
        #expect(input.sourceDeliveryID == nil)
        #expect(input.notificationAtUnixMilliseconds == nil)
        #expect(input.rawPayload == nil)
        #expect(!NotificationText.joined(input).isEmpty)
        #expect(try repository.insert(input) == .inserted)
        #expect(try repository.insert(input) == .alreadyStored)
        #expect(try repository.notification(withID: input.id) == input)
    }
    #expect(Set(coverage.notifications.map(\.id)).count == coverage.notifications.count)
}

@Test func syntheticCoverageIsDeterministicAtTheDraftBoundary() throws {
    let url = try #require(Bundle.module.url(
        forResource: "synthetic-notification-coverage", withExtension: "json", subdirectory: "Fixtures"
    ))
    let coverage = try JSONDecoder().decode(SyntheticCoverage.self, from: Data(contentsOf: url))
    let parser = KoreanFinancialNotificationParser()
    let context = try NotificationParsingContext(
        timeZoneIdentifier: "Asia/Seoul",
        referenceTimeUnixMilliseconds: 1_800_000_000_000,
        parserID: "korean-financial",
        parserVersion: "2"
    )
    var draftCount = 0
    for input in coverage.notifications {
        let first = try parser.parse(input, context: context)
        let second = try parser.parse(input, context: context)
        #expect(first == second)
        if case let .candidate(draft) = first {
            draftCount += 1
            #expect(draft.rawNotificationID == input.id)
            #expect(draft.occurredAt.source == .captureTime)
            #expect(draft.issues.contains(.timeAbsentFallback))
        }
    }
    #expect(draftCount > 0)
}

@Test func syntheticProviderShapesProduceSafeKindsDirectionsAndAmounts() throws {
    let url = try #require(Bundle.module.url(
        forResource: "synthetic-notification-coverage", withExtension: "json", subdirectory: "Fixtures"
    ))
    let coverage = try JSONDecoder().decode(SyntheticCoverage.self, from: Data(contentsOf: url))
    let parser = KoreanFinancialNotificationParser()
    let context = try NotificationParsingContext(
        timeZoneIdentifier: "Asia/Seoul",
        referenceTimeUnixMilliseconds: 1_800_000_000_000,
        parserID: "synthetic-coverage",
        parserVersion: "1"
    )
    let nonTransactions: Set<String> = [
        "synthetic-kp_receive_request-default",
        "synthetic-tb_interest-default",
        "synthetic-tmoney-balance",
        "synthetic-tmoney-ride"
    ]
    for input in coverage.notifications {
        let outcome = try parser.parse(input, context: context)
        if nonTransactions.contains(input.id) {
            guard case .notTransaction = outcome else {
                Issue.record("Expected safe non-transaction for \(input.id), got \(outcome)")
                continue
            }
            continue
        }
        guard case let .candidate(draft) = outcome else {
            Issue.record("Expected draft for synthetic provider shape \(input.id), got \(outcome)")
            continue
        }
        #expect(draft.amount.minorUnits == 12_000)
        if input.id.contains("cancel") {
            #expect(draft.kind == .cancellation)
            #expect(draft.direction == .inflow)
        } else if input.id.contains("approval") || input.id.contains("toss_pay") {
            #expect(draft.kind == .purchase)
            #expect(draft.direction == .outflow)
        } else if input.id.contains("kp_charge") {
            #expect(draft.kind == .walletTopUp)
            #expect(draft.direction == .inflow)
        } else if input.id.contains("kp_send") || input.id.contains("_out-") {
            #expect(draft.direction == .outflow)
        } else if input.id.contains("_in-") || input.id.contains("person_in") {
            #expect(draft.direction == .inflow)
        }
    }
}
