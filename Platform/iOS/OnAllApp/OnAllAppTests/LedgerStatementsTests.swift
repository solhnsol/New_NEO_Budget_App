import NEOBudgetCalendar
import NEOBudgetCore
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
