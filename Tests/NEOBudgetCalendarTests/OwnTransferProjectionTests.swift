import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryStorage

/// A spending on a person (`토스 <이름>`) that turns out to be a transfer between the user's own accounts leaves no trace in
/// what the app lists: neither the spending nor the cancellation that undid it (transfers are hidden from lists).
@Suite struct OwnTransferProjectionTests {
    private let intake = NotificationIntake(timeZoneIdentifier: "Asia/Seoul")
    private let decoder = ShortcutNotificationDecoder(timeZone: TimeZone(identifier: "Asia/Seoul")!)

    private func note(_ body: String, time: String) throws -> RawNotification {
        let fields = ["app": "우리WON뱅킹", "title": "", "subtitle": "", "body": body, "timestamp": "Oct 2, 2026 at \(time)"]
        let text = String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
        return try decoder.decode(text, receivedAtUnixMilliseconds: 1_790_936_040_000)[0]
    }

    private func snapshot(_ order: [Int]) throws -> CandidateProcessingSnapshot {
        var setup = IntakeSetup()
        var repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        for (number, id) in [("1002-663-019", "living"), ("1002-777-888", "saving")] {
            _ = try intake.ingest(try note("[입금] 설정용 1,000원 \(number)***계좌 잔액 5,000원 10/02 14:00:00", time: "2:00:00 PM"), setup: &setup, repository: &repository)
            let candidate = try #require(setup.registry.openCandidates.first { $0.key.institution == .woori })
            try setup.confirmAsNew(candidate.id, displayName: id, kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { id })
        }
        repository = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
        let all = [
            try note("[출금] 토스    김의근 10,000원 1002-663-019***계좌 잔액 3,861,435원 10/02 13:01:00", time: "1:01:00 PM"),
            try note("[입금] 김의근 10,000원 1002-777-888***계좌 잔액 15,000원 10/02 13:01:02", time: "1:01:02 PM"),
        ]
        for index in order { _ = try intake.ingest(all[index], setup: &setup, repository: &repository) }
        return try repository.processingSnapshot()
    }

    @Test func theSpendingAndItsCancellationNeverReachTheListOrTheRail() throws {
        // Withdrawal first: it is booked as spending on a person, then cancelled out by the deposit.
        let converted = try snapshot([0, 1])
        #expect(converted.ledger.entries.contains { $0.kind == .adjustment })
        #expect(LedgerTimelineProjection.transactions(in: converted).isEmpty)
        // Deposit first: the income is reversed; also nothing is listed.
        #expect(LedgerTimelineProjection.transactions(in: try snapshot([1, 0])).isEmpty)
    }

    @Test func aPersonSpendingWithNoDepositStaysListed() throws {
        let alone = try snapshot([0])
        #expect(LedgerTimelineProjection.transactions(in: alone).count == 1)
    }
}
