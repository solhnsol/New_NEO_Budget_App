import NEOBudgetCalendar
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let origin = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()

private func timeline(_ offset: Int) -> DayTimeline {
    DayTimelineBuilder.build(DayTimelineInput(day: origin.adding(days: offset), timeZone: zone, calendars: [], events: [], life: .empty, transactions: []))
}

private func loaded(_ range: ClosedRange<Int>) -> [LocalDate: DayTimeline] {
    Dictionary(uniqueKeysWithValues: range.map { (origin.adding(days: $0), timeline($0)) })
}

@Test func theRequiredAndRetainedWindowsAreNamedAndFollowTheDay() {
    let policy = DayCachePolicy.standard
    #expect(policy.required(around: origin) == (-1...2).map { origin.adding(days: $0) })
    #expect(policy.retained(around: origin) == Set((-3...4).map { origin.adding(days: $0) }))
    #expect(policy.capacity >= policy.retained(around: origin).count)
}

@Test func aMoveByOneDayKeepsTheDaysItAlreadyHasAndAsksForOnlyTheNewOne() {
    var cache = DayCache()
    cache.replaceAll(with: loaded(-1...2))
    #expect(cache.missing(around: origin).isEmpty)
    // The window moves one day on: only D+3 is missing; D-1 is not dropped (it is retained).
    let next = origin.adding(days: 1)
    #expect(cache.missing(around: next) == [origin.adding(days: 3)])
    cache.merge(loaded(3...3), around: next)
    #expect(cache.days == Set((-1...3).map { origin.adding(days: $0) }))
    // And back again: nothing to read.
    #expect(cache.missing(around: origin).isEmpty)
}

@Test func daysFarBehindTheWindowAreEvictedAndTheCacheNeverGrowsPastItsCapacity() {
    var cache = DayCache()
    var focus = origin
    cache.replaceAll(with: loaded(-1...2))
    var maximum = 0
    for step in 1...20 {
        focus = origin.adding(days: step)
        let missing = cache.missing(around: focus)
        #expect(missing.count <= 1)                          // one new day per day moved
        cache.merge(Dictionary(uniqueKeysWithValues: missing.map { ($0, timeline($0.daysSinceUnixEpoch - origin.daysSinceUnixEpoch)) }), around: focus)
        maximum = max(maximum, cache.count)
        #expect(cache.days.isSubset(of: DayCachePolicy.standard.retained(around: focus)))
        #expect(Set(DayCachePolicy.standard.required(around: focus)).isSubset(of: cache.days))
    }
    #expect(maximum <= DayCachePolicy.standard.capacity)
    #expect(cache[origin] == nil)                            // long gone
}

@Test func daysReadAheadOfAFarJumpAreKeptUntilTheMoveLandsAndThenEvicted() {
    var cache = DayCache()
    cache.replaceAll(with: loaded(-1...2))
    for offset in 28...33 { cache.insert(timeline(offset)) }
    #expect(cache.count == 10)                               // insert evicts nothing
    let landed = origin.adding(days: 30)
    #expect(cache.missing(around: landed).isEmpty)           // days 29 ... 32 were read ahead: nothing left to read on landing
    cache.merge([:], around: landed)
    #expect(cache.days.isSubset(of: DayCachePolicy.standard.retained(around: landed)))
    #expect(cache[origin] == nil && cache[landed] != nil)
}

@Test func aCalendarChangeKeepsExactlyWhatWasReadAgain() {
    var cache = DayCache()
    cache.replaceAll(with: loaded(-3...4))
    cache.replaceAll(with: loaded(-1...2))
    #expect(cache.days == Set((-1...2).map { origin.adding(days: $0) }))
}

@Test func readingAheadByOneAddsOneDayEachSideButNeverMoreThanTheMargin() {
    var cache = DayCache()
    cache.replaceAll(with: loaded(-1...2))
    #expect(Set(cache.missing(around: origin, extra: 1)) == [origin.adding(days: -2), origin.adding(days: 3)])
    #expect(cache.missing(around: origin, extra: 99).count == 4)           // capped at the margin (2 each side beyond the required ones)
    #expect(cache.missing(around: origin, extra: 99).allSatisfy { DayCachePolicy.standard.retained(around: origin).contains($0) })
}
