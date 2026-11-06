import NEOBudgetCalendar
import Testing
@testable import OnAllApp

// Which days a moving window needs, and that they are there before the day is selected.

@Test func aRestingWindowNeedsTheDayBeforeTheTwoShownAndTheDayAfter() {
    #expect(DayPrefetchPolicy.neededDays(position: 10) == 9...12)
    #expect(DayPrefetchPolicy.neededDays(position: 10.4) == 9...13)                        // between 10 and 11 both windows are in use
    #expect(DayPrefetchPolicy.neededDays(position: 10.0001) == 9...13)
    #expect(DayPrefetchPolicy.neededDays(position: 10, target: 11) == 9...13)
    #expect(DayPrefetchPolicy.neededDays(position: 10.5, target: 9) == 8...13)
    #expect(DayPrefetchPolicy.neededDays(position: 10, target: 13) == 9...15)
}

@Test func theCachePolicyKeepsEveryDayAWindowWithinTheHopCanNeed() {
    for hop in 1...4 {
        let policy = DayPrefetchPolicy(maximumHop: hop)
        let cache = policy.cachePolicy
        let selected = 100
        let day = LocalDate(daysSinceUnixEpoch: selected)
        let retained = cache.retained(around: day)
        for position in stride(from: Double(selected - hop), through: Double(selected + hop), by: 0.25) {
            for needed in DayPrefetchPolicy.neededDays(position: position) {
                #expect(retained.contains(LocalDate(daysSinceUnixEpoch: needed)), "hop \(hop) position \(position) day \(needed)")
            }
        }
        #expect(retained.count <= cache.capacity)
        #expect(policy.readAhead == hop + 1)
    }
    #expect(DayPrefetchPolicy.browse.maximumHop == 1)
}

@Test func aDragIsHeldToTheHopFromTheSelectedDay() {
    let policy = DayPrefetchPolicy.browse
    #expect(policy.clampedPosition(50.4, selected: 50) == 50.4)
    #expect(policy.clampedPosition(53, selected: 50) == 51)
    #expect(policy.clampedPosition(40, selected: 50) == 49)
    #expect(DayPrefetchPolicy(maximumHop: 3).clampedPosition(60, selected: 50) == 53)
}

@Test func aReleaseNeverCarriesTheMoveModelFurtherThanItsHop() {
    for hop in [1, 2, 3] {
        var model = DayMoveModel(day: 10, bounds: 0...30, maximumHop: hop)
        #expect(model.hopLimit == hop)
        model.beginDrag(); model.drag(to: 10.2)
        model.release(velocity: 60)
        #expect(model.target == 10 + hop)
        model.beginDrag(); model.drag(to: 10.0)
        model.release(velocity: -60)
        #expect(model.target == 10 - hop || model.target == model.bounds.lowerBound)
    }
    #expect(DayMoveModel(day: 5, bounds: 0...9, maximumHop: 0).hopLimit == 1)
    #expect(DayMoveModel(day: 5, bounds: 0...9).hopLimit == DayMoveModel.maximumHop)
}

// MARK: The model

@MainActor
private func readyModel() async throws -> AppModel {
    let model = try AppModel.demo()
    await model.start()
    #expect(model.phase == .ready)
    return model
}

@MainActor
@Test func atRestWithTheMarginFilledAPrefetchReadsNothing() async throws {
    let model = try await readyModel()
    let start = model.selectedDay
    await model.loadMissing(extra: DayPrefetchPolicy.browse.readAhead, policy: DayPrefetchPolicy.browse.cachePolicy)
    let reads = model.dayReads
    await model.prefetch(forPosition: Double(start.daysSinceUnixEpoch))
    await model.prefetch(forPosition: Double(start.daysSinceUnixEpoch) + 0.5)
    #expect(model.dayReads == reads)
    #expect(model.selectedDay == start)
}

@MainActor
@Test func aDraggedPositionHasItsDaysBeforeTheDayIsSelected() async throws {
    let model = try await readyModel()
    let start = model.selectedDay
    await model.loadMissing(extra: DayPrefetchPolicy.browse.readAhead, policy: DayPrefetchPolicy.browse.cachePolicy)
    let epoch = Double(start.daysSinceUnixEpoch)
    for position in stride(from: epoch, through: epoch + 1, by: 0.125) {
        await model.prefetch(forPosition: position, target: start.daysSinceUnixEpoch + 1)
        let needed = DayPrefetchPolicy.neededDays(position: position, target: start.daysSinceUnixEpoch + 1).map { LocalDate(daysSinceUnixEpoch: $0) }
        #expect(model.cachedDays.isSuperset(of: needed), "position \(position)")
        #expect(model.selectedDay == start)                                                // nothing was selected by reading
    }
}

@MainActor
@Test func aFastRunOfHopsReadsEachDayOnceKeepsTheCacheBoundedAndNeverEvictsWhatIsOnScreen() async throws {
    let model = try await readyModel()
    let start = model.selectedDay
    let policy = DayPrefetchPolicy.browse
    await model.loadMissing(extra: policy.readAhead, policy: policy.cachePolicy)
    var seen = Set<LocalDate>()
    let reads0 = model.dayReads
    // 30 days forward at 4 positions per hop, never waiting for a selection in between except when the hop is done.
    for hop in 1...30 {
        let from = Double(start.daysSinceUnixEpoch + hop - 1)
        for fraction in [0.25, 0.5, 0.75, 1.0] {
            let position = from + fraction
            await model.prefetch(forPosition: position, target: start.daysSinceUnixEpoch + hop)
            let needed = DayPrefetchPolicy.neededDays(position: position, target: start.daysSinceUnixEpoch + hop).map { LocalDate(daysSinceUnixEpoch: $0) }
            #expect(model.cachedDays.isSuperset(of: needed), "hop \(hop) fraction \(fraction)")
            #expect(model.cachedDays.count <= policy.cachePolicy.capacity)
        }
        #expect(model.moveTo(start.adding(days: hop)))
        #expect(model.visibleTimelines.count == 2)                                         // both shown days were there in the frame of the selection
        await model.loadMissing(extra: policy.readAhead, policy: policy.cachePolicy)
        seen.insert(model.selectedDay)
    }
    let perHop = Double(model.dayReads - reads0) / 30
    print(String(format: "MEASURE phase1a fast hops: %.2f day reads per hop over 30 hops, cache %d days (capacity %d)", perHop, model.cachedDays.count, policy.cachePolicy.capacity))
    #expect(perHop <= 1.5)                                                                 // one new far day per hop, and the few the first positions need
    #expect(seen.count == 30)
}

@MainActor
@Test func aPrefetchThatAFullReloadOvertakesIsDropped() async throws {
    let model = try await readyModel()
    let start = model.selectedDay
    async let ahead: Void = model.prefetch(forPosition: Double(start.daysSinceUnixEpoch + 40), target: start.daysSinceUnixEpoch + 41)
    await model.reload()
    await ahead
    #expect(model.cachedDays == Set(DayCachePolicy.standard.required(around: start)))
}
