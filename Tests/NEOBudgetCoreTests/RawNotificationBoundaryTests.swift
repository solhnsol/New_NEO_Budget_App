import Foundation
import Testing
import NEOBudgetCore
import NEOBudgetInMemoryStorage

private func fixtures() throws -> [RawNotification] {
    let url = try #require(Bundle.module.url(
        forResource: "raw-notifications", withExtension: "json", subdirectory: "Fixtures"
    ))
    return try JSONDecoder().decode([RawNotification].self, from: Data(contentsOf: url))
}

@Test func differentAdapterInputsUseTheSameCoreTextPath() throws {
    let inputs = try fixtures()
    #expect(inputs.count == 2)
    #expect(inputs[0].source.applicationIdentifier != inputs[1].source.applicationIdentifier)
    for input in inputs {
        #expect(NotificationText.joined(input) == "승인\n5,000원\n테스트상호\n잔액 100,000원")
    }
}

@Test func neutralInputRoundTripsWithoutLosingSourceOrOriginalPayload() throws {
    for input in try fixtures() {
        let encoded = try JSONEncoder().encode(input)
        let restored = try JSONDecoder().decode(RawNotification.self, from: encoded)
        #expect(restored == input)
        #expect(restored.body?.contains("\r\n") == true)
    }
}

@Test func missingDeliveryIdentityAndNotificationTimeRemainUnknown() throws {
    let input = try fixtures()[1]
    #expect(input.sourceDeliveryID == nil)
    #expect(input.notificationAtUnixMilliseconds == nil)
    #expect(input.rawPayload == nil)
}

/// Exercises the port through its protocol rather than implementation-only APIs.
private func assertRepositoryContract<R: RawNotificationRepository>(_ repository: inout R) throws {
    let inputs = try fixtures()
    #expect(try repository.notification(withID: "absent") == nil)
    #expect(try repository.insert(inputs[0]) == .inserted)
    #expect(try repository.insert(inputs[0]) == .alreadyStored)
    #expect(try repository.notification(withID: inputs[0].id) == inputs[0])
    #expect(try repository.insert(inputs[1]) == .inserted)
    #expect(try repository.notification(withID: inputs[1].id) == inputs[1])
}

@Test func inMemoryAdapterSatisfiesTheCoreStorageContract() throws {
    var repository = InMemoryRawNotificationRepository()
    try assertRepositoryContract(&repository)
}

@Test func conflictingRecordCannotOverwriteStoredEvidence() throws {
    let original = try fixtures()[0]
    let conflict = RawNotification(
        id: original.id, source: original.source,
        capturedAtUnixMilliseconds: original.capturedAtUnixMilliseconds,
        body: "different original evidence"
    )
    var repository = InMemoryRawNotificationRepository()
    #expect(try repository.insert(original) == .inserted)
    #expect(throws: RawNotificationStorageError.conflictingRecord(id: original.id)) {
        try repository.insert(conflict)
    }
    #expect(repository.notification(withID: original.id) == original)
}

@Test func similarTextWithDistinctRecordIDsIsNotSilentlyDeduplicatedByStorage() throws {
    let inputs = try fixtures()
    var repository = InMemoryRawNotificationRepository()
    for input in inputs {
        #expect(try repository.insert(input) == .inserted)
    }
    #expect(repository.notification(withID: inputs[0].id) == inputs[0])
    #expect(repository.notification(withID: inputs[1].id) == inputs[1])
}
