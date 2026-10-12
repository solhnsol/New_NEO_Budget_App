import NEOBudgetCalendar
import Testing
@testable import OnAllApp

// The model on the synthetic calendar (`-demo`): no device calendar is read.

@MainActor
private func readyModel() async throws -> AppModel {
    let model = try AppModel.demo()
    await model.start()
    #expect(model.phase == .ready)
    return model
}

@MainActor
@Test func theFirstReadFillsTheRequiredDaysAndNothingElse() async throws {
    let model = try await readyModel()
    let day = model.selectedDay
    #expect(model.cachedDays == Set(DayCachePolicy.standard.required(around: day)))
    #expect(model.dayReads == 4)
    #expect(model.visibleTimelines.count == 2)
}

@MainActor
@Test func movingByADayReadsOneDayAndBackAgainReadsNone() async throws {
    let model = try await readyModel()
    let start = model.selectedDay
    let baseline = model.dayReads
    #expect(model.moveTo(start.adding(days: 1)))
    #expect(model.visibleTimelines.count == 2)                // the days already read are on screen in the same frame
    await model.loadMissing()
    #expect(model.dayReads == baseline + 1)                   // only D+3
    #expect(model.cachedDays.isSuperset(of: (-1...3).map { start.adding(days: $0) }))     // D-1 was not dropped
    #expect(model.moveTo(start))
    await model.loadMissing()
    #expect(model.dayReads == baseline + 1)                   // nothing read: everything was kept
    #expect(model.visibleTimelines.map(\.day) == [start, start.adding(days: 1)])
}

@MainActor
@Test func aRunOfMovesReadsAtMostOneNewDayPerMoveAndKeepsTheCacheBounded() async throws {
    let model = try await readyModel()
    let start = model.selectedDay
    var reads = model.dayReads
    for step in 1...8 {
        #expect(model.moveTo(start.adding(days: step)))
        await model.loadMissing()
        #expect(model.dayReads - reads <= 1)
        reads = model.dayReads
        #expect(model.visibleTimelines.count == 2)
        #expect(model.cachedDays.count <= DayCachePolicy.standard.capacity)
        #expect(model.cachedDays.isSubset(of: DayCachePolicy.standard.retained(around: model.selectedDay)))
    }
    for step in stride(from: 7, through: 0, by: -1) {
        #expect(model.moveTo(start.adding(days: step)))
        await model.loadMissing()
        #expect(model.dayReads - reads <= 1)
        reads = model.dayReads
        #expect(model.visibleTimelines.count == 2)
    }
    #expect(model.selectedDay == start)
}

@MainActor
@Test func readingAheadFillsTheMarginOnceAndTheNextMoveFindsItThere() async throws {
    let model = try await readyModel()
    let start = model.selectedDay
    let baseline = model.dayReads
    await model.loadMissing(extra: 2)
    #expect(model.dayReads == baseline + 4)                   // two more each side
    #expect(model.moveTo(start.adding(days: 1)))
    await model.loadMissing(extra: 2)
    #expect(model.dayReads == baseline + 5)                   // one more at the far end of the window, none of the others
    #expect(model.moveTo(start.adding(days: 2)))
    await model.loadMissing()
    #expect(model.dayReads == baseline + 5)                   // D+4... was read ahead
}

@MainActor
@Test func aCalendarChangeReadsTheRequiredDaysAgainAndDropsTheRest() async throws {
    let model = try await readyModel()
    let start = model.selectedDay
    await model.loadMissing(extra: 2)
    #expect(model.cachedDays.count == 8)
    let before = model.dayReads
    await model.reload()                                      // what the change notification, a saved edit and the app returning all do
    #expect(model.dayReads == before + 4)
    #expect(model.cachedDays == Set(DayCachePolicy.standard.required(around: start)))
}

@MainActor
@Test func aFarJumpKeepsTheDaysReadAheadUntilItLandsAndThenOnlyTheWindow() async throws {
    let model = try await readyModel()
    let start = model.selectedDay
    let target = start.adding(days: 20)
    let ahead = await model.readDays((19...22).map { start.adding(days: $0) })
    #expect(ahead.count == 4 && ahead.allSatisfy { $0.timeline != nil })
    model.adopt(ahead)
    #expect(model.moveTo(target))
    #expect(model.visibleTimelines.map(\.day) == [target, target.adding(days: 1)])      // on screen at once, from what was read ahead
    let before = model.dayReads
    await model.loadMissing()
    #expect(model.dayReads == before)                                                    // 19...22 is exactly target-1 ... target+2: nothing left to read
    #expect(model.cachedDays.isSubset(of: DayCachePolicy.standard.retained(around: target)))
    #expect(!model.cachedDays.contains(start))
}
