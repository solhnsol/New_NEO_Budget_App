import Foundation
import Testing
import NEOBudgetCore
import NEOBudgetInMemoryStorage

/// A saved ledger plus the notifications after it must be the ledger a full replay gives; anything that does not fit is refused.
@Suite struct IntakeLedgerSnapshotTests {
    private let decoder = ShortcutNotificationDecoder(timeZone: TimeZone(identifier: "Asia/Seoul")!)
    private let intake = NotificationIntake(timeZoneIdentifier: "Asia/Seoul")

    private func note(_ app: String, _ body: String, minute: Int, title: String = "") throws -> RawNotification {
        let fields = ["app": app, "title": title, "body": body, "timestamp": "Oct 2, 2026 at 7:\(String(format: "%02d", minute)):30 PM"]
        let text = String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
        return try decoder.decode(text, receivedAtUnixMilliseconds: 1_790_000_000_000 + Int64(minute) * 60_000)[0]
    }

    /// Ads, a card approval and its bank withdrawal (one act), another purchase, a deposit, an unreadable amount.
    private func stream() throws -> [RawNotification] {
        [
            try note("Toss", "이번 주 혜택을 확인해 보세요", minute: 1),
            try note("현대카드", "김가명 님, 현대 체크 승인 \r\n51,000원 일시불, 10/02 19:13 \r\n가맹점A", minute: 13),
            try note("우리WON뱅킹", "[Web발신]\n우리 출금 51,000원 1002-123-456*** 잔액 1,234,000원 10/02 19:13:20", minute: 14),
            try note("현대카드", "김가명 님, 현대 체크 승인 \r\n8,500원 일시불, 10/02 19:20 \r\n가맹점B", minute: 20),
            try note("우리WON뱅킹", "[Web발신]\n우리 입금 67,035원 1002-123-456*** 차유진 잔액 1,301,035원 10/02 19:30", minute: 30),
            try note("우리WON뱅킹", "[Web발신]\n우리 출금 원 1002-123-456*** 10/02 19:40", minute: 40),
        ]
    }

    /// The first `count` notifications replayed, the account they ask about confirmed, as a launch would have left it.
    private func settled(_ notifications: [RawNotification]) throws -> IntakeLedger {
        var ledger = try IntakeLedger(notifications: [], setup: IntakeSetup(), intake: intake)
        try ledger.receive(notifications)
        for candidate in ledger.setup.registry.openCandidates {
            try ledger.confirmAsNew(candidate.id, displayName: "계좌 \(candidate.id.rawValue)", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "acct-\(candidate.id.rawValue)" })
        }
        return ledger
    }

    private func roundTrip(_ snapshot: IntakeLedgerSnapshot) throws -> IntakeLedgerSnapshot {
        try JSONDecoder().decode(IntakeLedgerSnapshot.self, from: JSONEncoder().encode(snapshot))
    }

    @Test func aSavedLedgerContinuedWithTheNewNotificationsIsTheFullReplay() throws {
        let all = try stream()
        for split in 0...all.count {
            let saved = try settled(Array(all[..<split]))
            let snapshot = try roundTrip(try #require(saved.snapshot()))
            let restored = try IntakeLedger(restoring: snapshot, notifications: all, setup: saved.setup, intake: intake)
            var full = try IntakeLedger(notifications: [], setup: saved.setup, intake: intake)
            try full.receive(all)

            #expect(try restored.repository.processingSnapshot() == full.repository.processingSnapshot())
            #expect(restored.notifications == full.notifications)
            #expect(restored.setup == full.setup)
            #expect(all.map { restored.status(of: $0.id) } == all.map { full.status(of: $0.id) })
            #expect(restored.isComplete)
            if split == all.count { #expect(try !restored.repository.processingSnapshot().ledger.entries.isEmpty) }
        }
    }

    @Test func aSnapshotMadeUnderOtherInputsIsRefused() throws {
        let all = try stream()
        let saved = try settled(Array(all[..<4]))
        let snapshot = try roundTrip(try #require(saved.snapshot()))

        // Another time zone (the rules key), a different setup, a notification missing from the start, a different order.
        #expect(throws: IntakeLedgerSnapshotError.notApplicable) {
            try IntakeLedger(restoring: snapshot, notifications: all, setup: saved.setup, intake: NotificationIntake(timeZoneIdentifier: "UTC"))
        }
        #expect(throws: IntakeLedgerSnapshotError.notApplicable) {
            try IntakeLedger(restoring: snapshot, notifications: all, setup: IntakeSetup(), intake: intake)
        }
        #expect(throws: IntakeLedgerSnapshotError.notApplicable) {
            try IntakeLedger(restoring: snapshot, notifications: Array(all.dropFirst()), setup: saved.setup, intake: intake)
        }
        #expect(throws: IntakeLedgerSnapshotError.notApplicable) {
            try IntakeLedger(restoring: snapshot, notifications: [all[1], all[0]] + all.dropFirst(2), setup: saved.setup, intake: intake)
        }
    }

    @Test func aPartialReplayHasNoSnapshotAndTornJSONDoesNotDecode() throws {
        let all = try stream()
        let partial = try IntakeLedger(notifications: all, setup: IntakeSetup(), intake: intake, replayingSince: try #require(all[3].notificationAtUnixMilliseconds))
        #expect(!partial.isComplete)
        #expect(partial.snapshot() == nil)
        let data = try JSONEncoder().encode(try #require(try settled(all).snapshot()))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(IntakeLedgerSnapshot.self, from: data.prefix(data.count / 2)) }
    }
}
