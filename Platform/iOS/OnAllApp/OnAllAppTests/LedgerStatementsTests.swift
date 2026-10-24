import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryStorage
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()

/// The synthetic sample day (`SampleLedger`): no real data.
private func sampleStatements() async throws -> [LedgerStatements.Statement] {
    try await SampleLedger.make(today: day, zone: zone).statements()
}

@Test func accountStatementRunsItsBalance() async throws {
    let statements = try await sampleStatements()
    let bank = try #require(statements.first { $0.name == "생활비" })
    // 1,000,000 opening + 2,000,000 salary − 23,700 spending − 100,000 transfer − 15,000 card bill + 5,000 refund.
    #expect(bank.current == 2_866_300)
    #expect(bank.lines.first?.balanceAfter == bank.current)          // newest first
    #expect(bank.lines.contains { $0.kind == .income && $0.delta.minorUnits == 2_000_000 })
    #expect(bank.lines.contains { $0.kind == .transfer && $0.delta.minorUnits == -100_000 })
}

@Test func cardUsageIsWhatWasChargedNotWhatWasPaidOrSettled() async throws {
    let statements = try await sampleStatements()
    let usage = LedgerStatements.cardUsage(statements, month: try BudgetMonth(year: 2027, month: 3), zone: zone)
    let card = try #require(usage.first { $0.name == "카드" })
    #expect(card.usedMinorUnits == 11_000)                            // 4,800 + 6,200; the 15,000 bill payment is not usage
    #expect(card.count == 2)
    #expect(LedgerStatements.cardUsage(statements, month: try BudgetMonth(year: 2027, month: 4), zone: zone).allSatisfy { $0.usedMinorUnits == 0 })
}

/// A real ledger replayed from synthetic notifications, with no opening balance: the way the app starts without an imported history.
private func liveStatements(anchored: Bool) throws -> (statements: [LedgerStatements.Statement], bankID: AccountID) {
    let decoder = ShortcutNotificationDecoder(timeZone: TimeZone(identifier: "Asia/Seoul")!)
    func note(_ app: String, _ body: String, time: String) throws -> RawNotification {
        let fields = ["app": app, "body": body, "timestamp": time]
        let text = String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
        return try decoder.decode(text, receivedAtUnixMilliseconds: 1_790_936_040_000)[0]
    }
    var ledger = try IntakeLedger(notifications: [], setup: IntakeSetup(), intake: NotificationIntake(timeZoneIdentifier: "Asia/Seoul"))
    try ledger.receive([
        note("우리WON뱅킹", "[Web발신]\n우리 출금 51,000원 1002-123-456*** 잔액 1,234,000원 10/02 19:13:20", time: "Oct 2, 2026 at 7:13:30 PM"),
        note("우리WON뱅킹", "[Web발신]\n우리 입금 100,000원 1002-123-456*** 잔액 1,334,000원 10/03 09:00:00", time: "Oct 3, 2026 at 9:00:00 AM"),
        note("우리WON뱅킹", "[Web발신]\n우리 출금 4,000원 1002-123-456*** 잔액 1,330,000원 10/04 09:00:00", time: "Oct 4, 2026 at 9:00:00 AM"),
    ])
    let bank = try #require(ledger.setup.registry.openCandidates.first { $0.key.institution == .woori })
    try ledger.confirmAsNew(bank.id, displayName: "우리 생활비", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "bank" })
    let statements = LedgerStatements.statements(
        try ledger.repository.processingSnapshot(), configuration: ledger.setup.configuration,
        reportedBalances: anchored ? ledger.reportedBalances : [:]
    )
    return (statements, AccountID(rawValue: "bank"))
}

@Test func anAccountWithoutOpeningBalanceShowsTheBalanceItsNotificationsReported() throws {
    let (statements, bankID) = try liveStatements(anchored: true)
    let bank = try #require(statements.first { $0.source == .account(bankID) })
    // Only the deposit is in the ledger: the two withdrawals nothing explains wait for review. The bank's own last balance wins.
    #expect(bank.current == 1_330_000)
    #expect(bank.anchorAdjustment == 1_230_000)
    #expect(bank.lines.first?.balanceAfter == bank.current)
}

@Test func withoutAReportedBalanceTheLedgerStartsFromZeroAsBefore() throws {
    let (statements, bankID) = try liveStatements(anchored: false)
    let bank = try #require(statements.first { $0.source == .account(bankID) })
    #expect(bank.current == 100_000)
    #expect(bank.anchorAdjustment == 0)
}
