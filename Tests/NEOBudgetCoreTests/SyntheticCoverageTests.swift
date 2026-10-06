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
