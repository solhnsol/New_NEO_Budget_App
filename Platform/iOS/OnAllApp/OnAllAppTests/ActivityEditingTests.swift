import NEOBudgetCalendar
import NEOBudgetCore
import Testing
@testable import OnAllApp

private let zone = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private let day = (try? LocalDate(year: 2027, month: 3, day: 10)) ?? { fatalError("date") }()
private let key = CalendarEventKey(calendarID: CalendarID(rawValue: "c"), eventID: CalendarEventID(rawValue: "e"))

@Test func everyEditOfAnEventGoesThroughTheEventTargetedCommandSoNoActivityStepIsNeeded() {
    let now: Int64 = 5
    guard case let .assignActivityType(type) = ActivityEditing.setType(.study, event: key, now: now),
          case let .assignActivityArea(area) = ActivityEditing.setArea(AreaID(rawValue: "a"), event: key, now: now),
          case let .addParticipant(add) = ActivityEditing.setParticipant(PersonID(rawValue: "p"), on: true, event: key, now: now),
          case let .removeParticipant(remove) = ActivityEditing.setParticipant(PersonID(rawValue: "p"), on: false, event: key, now: now),
          case let .linkTransaction(link) = ActivityEditing.link(LedgerEntryID(rawValue: "t"), event: key, now: now)
    else { Issue.record("unexpected commands"); return }
    #expect(type.target == .event(key) && area.target == .event(key) && link.target == .event(key))
    #expect(add.activity == .event(key) && remove.activity == .event(key))
    #expect(type.typeID == .study && area.areaID == AreaID(rawValue: "a"))
    #expect(ActivityEditing.setType(nil, event: key, now: now) == .assignActivityType(AssignActivityTypeInput(target: .event(key), typeID: nil, provenance: ActivityEditing.provenance(now: now))))
}

@Test func theCatalogListsPresetsFirstAndHidesArchivedTypes() throws {
    let mine = ActivityTypeDefinition(id: ActivityTypeID(rawValue: "user.a"), displayName: "가")
    let old = ActivityTypeDefinition(id: ActivityTypeID(rawValue: "user.b"), displayName: "나", isArchived: true)
    let life = try LifeState.empty.applying([
        .upsertActivityType(mine), .upsertActivityType(old),
        .upsertArea(Area(id: AreaID(rawValue: "z"), displayName: "하")), .upsertArea(Area(id: AreaID(rawValue: "y"), displayName: "가")),
        .upsertPerson(Person(id: PersonID(rawValue: "o"), displayName: "가영")), .upsertPerson(Person(id: PersonID(rawValue: "me"), displayName: "나", isSelf: true)),
    ])
    let catalog = ActivityCatalog(life)
    #expect(catalog.types.contains { $0.id == "user.a" } && !catalog.types.contains { $0.id == "user.b" })
    #expect(catalog.types.first.map { $0.id.hasPrefix("preset.") } == true && catalog.types.last?.id == "user.a")
    #expect(catalog.areas.map(\.name) == ["가", "하"])
    #expect(catalog.people.map(\.name) == ["나", "가영"] && catalog.people.first?.isSelf == true)
}

@Test func linkCandidatesAreUnlinkedTransactionsNearestTheEventFirst() throws {
    let range = try TimedRange(startUnixMilliseconds: zone.instant(of: day, minuteOfDay: 720), endUnixMilliseconds: zone.instant(of: day, minuteOfDay: 780))
    let event = CalendarEvent(id: key.eventID, calendarID: key.calendarID, title: "점심", time: .timed(range), revisionToken: "r")
    func spend(_ id: String, _ minute: Int) throws -> TransactionMarker {
        TransactionMarker(id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: zone.instant(of: day, minuteOfDay: minute),
                          amount: try Money(minorUnits: 1_000, currency: "KRW"), flow: .spend, title: id)
    }
    let transactions = [try spend("far", 1_200), try spend("near", 740), try spend("taken", 750), try spend("before", 600)]
    let provenance = AssignmentProvenance.user(at: 1, evidenceVersion: nil)
    let other = Activity.materialized(from: CalendarEvent(id: CalendarEventID(rawValue: "x"), calendarID: key.calendarID, title: "다른", time: .timed(range), revisionToken: "r"), id: ActivityID(rawValue: "A"), at: 1)
    let life = try LifeState.empty.applying([
        .createActivity(other),
        .upsertAllocation(TransactionAllocation(
            id: AllocationID(rawValue: "al"), transactionID: LedgerEntryID(rawValue: "taken"), activityID: other.id,
            amount: try AmountEntry(currency: "KRW", knowledge: .exact(1_000), provenance: provenance), provenance: provenance, createdAtUnixMilliseconds: 1),
            transactionTotal: try Money(minorUnits: 1_000, currency: "KRW"), flow: .spend),
    ])
    let timeline = DayTimelineBuilder.build(DayTimelineInput(day: day, timeZone: zone, calendars: [], events: [event], life: life, transactions: transactions))
    let block = try #require(timeline.blocks.first)
    // The one linked elsewhere is not offered; the rest are nearest first, and none is already counted as this event's.
    #expect(ActivityEditing.linkCandidates(for: block, in: timeline).map(\.transactionID.rawValue) == ["near", "before", "far"])
    #expect(block.allocations.isEmpty)
}

@Test func typedNamesAreCleanedAndEmptyOnesIgnored() {
    #expect(ActivityEditing.cleanName("  성수   동 ") == "성수 동")
    #expect(ActivityEditing.cleanName("   ") == nil)
    #expect(ActivityEditing.newID(prefix: "area") != ActivityEditing.newID(prefix: "area"))
}
