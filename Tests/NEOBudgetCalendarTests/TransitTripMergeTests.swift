import Testing
import NEOBudgetCalendar
import NEOBudgetCore

private func leg(_ id: String, minute: Int, _ amount: Int64, flow: TransactionFlow = .spend) -> TransactionMarker {
    TransactionMarker(
        id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: Int64(minute) * 60_000,
        amount: try! Money(minorUnits: amount, currency: "KRW"), flow: flow, title: id.hasPrefix("t") ? "티머니" : "식당"
    )
}

private func trips(_ markers: [TransactionMarker], account: String? = "card") -> [[String]] {
    TransitTripMerge.trips(in: markers, accountOf: { _ in account }, isTransit: { $0.title == "티머니" }).map { $0.legs.map(\.rawValue) }
}

@Test func aSurchargeAfterTheBoardingJoinsIt() {
    #expect(trips([leg("t1", minute: 490, 1_550), leg("t2", minute: 520, 100)]) == [["t1", "t2"]])
}

@Test func aSecondFullFareIsANewBoardingEvenWithinTheWindow() {
    #expect(trips([leg("t1", minute: 490, 1_550), leg("t2", minute: 520, 1_550)]).isEmpty)
}

@Test func aTransferChargeChainsOntoTheTrip() {
    #expect(trips([leg("t1", minute: 480, 1_550), leg("t2", minute: 520, 450), leg("t3", minute: 560, 300)]) == [["t1", "t2", "t3"]])
}

@Test func otherSpendingBetweenSplitsTheTrip() {
    #expect(trips([leg("t1", minute: 490, 1_550), leg("x", minute: 500, 4_000), leg("t2", minute: 520, 100)]).isEmpty)
}

@Test func tooFarApartOrTooLongDoesNotJoin() {
    #expect(trips([leg("t1", minute: 400, 1_550), leg("t2", minute: 400 + 91, 100)]).isEmpty)
    #expect(trips([leg("t1", minute: 0, 3_000), leg("t2", minute: 80, 200), leg("t3", minute: 160, 200), leg("t4", minute: 181, 200)]) == [["t1", "t2", "t3"]])
}

@Test func differentOrUnknownAccountsNeverMerge() {
    let markers = [leg("t1", minute: 490, 1_550), leg("t2", minute: 520, 100)]
    #expect(TransitTripMerge.trips(in: markers, accountOf: { $0.rawValue == "t1" ? "a" : "b" }, isTransit: { $0.title == "티머니" }).isEmpty)
    #expect(trips(markers, account: nil).isEmpty)
}

@Test func refundsDoNotBreakATrip() {
    #expect(trips([leg("t1", minute: 490, 1_550), leg("x", minute: 500, 4_000, flow: .refund), leg("t2", minute: 520, 100)]) == [["t1", "t2"]])
}
