import NEOBudgetCalendar
import NEOBudgetCalendarContract
import NEOBudgetInMemoryCalendar
import Testing

/// Drives `InMemoryCalendarProvider` through the shared provider contract. The EventKit provider runs the same
/// contract inside an iOS app host (`Platform/iOS/EventKitContractHost`).
private actor InMemoryRig: CalendarProviderTestRig {
    nonisolated let memory: InMemoryCalendarProvider
    nonisolated let dayZone: DisplayTimeZone
    nonisolated let supportsRecurrence = true
    private var next = 1

    init() throws {
        dayZone = try DisplayTimeZone(identifier: "Asia/Seoul")
        memory = InMemoryCalendarProvider(supportedRecurrenceScopes: [.thisOccurrence, .allInSeries], dayZone: dayZone)
    }

    nonisolated var provider: any CalendarProvider { memory }

    func makeWritableCalendar(title: String) async throws -> CalendarID {
        let id = CalendarID(rawValue: "mem-cal-\(next)")
        next += 1
        await memory.addCalendar(CalendarDescriptor(id: id, title: title))
        return id
    }

    func existingReadOnlyCalendar() async throws -> CalendarID? {
        let id = CalendarID(rawValue: "mem-readonly")
        await memory.addCalendar(CalendarDescriptor(id: id, title: "읽기 전용", isWritable: false))
        return id
    }

    func editExternally(_ key: CalendarEventKey, update: CalendarEventUpdate) async throws { await memory.editExternally(key, update: update) }
    func removeExternally(_ key: CalendarEventKey) async throws { await memory.removeExternally(key) }
    func removeCalendarExternally(_ id: CalendarID) async throws { await memory.removeCalendarExternally(id) }

    func failNextWrite() async -> Bool {
        await memory.failNextWrite(with: .saveFailed(retryable: true, reason: "injected"))
        return true
    }

    func setAccess(available: Bool) async -> Bool {
        await memory.setAccessAvailable(available)
        return true
    }

    func seedWeeklySeries(calendarID: CalendarID, title: String, firstStartUnixMilliseconds: Int64, durationMilliseconds: Int64, count: Int) async throws {
        await memory.seedSeries(calendarID: calendarID, title: title, firstStartUnixMilliseconds: firstStartUnixMilliseconds, durationMilliseconds: durationMilliseconds, count: count)
    }

    func cleanUp() async {}
}

@Test func inMemoryProviderSatisfiesTheProviderContract() async throws {
    let rig = try InMemoryRig()
    let results = await CalendarProviderContract.run(rig: rig)
    for result in results {
        if let failure = result.failure { Issue.record("\(result.name): \(failure)") }
    }
    #expect(results.count >= 15)
    #expect(results.filter { $0.skipped != nil }.isEmpty, "the in-memory rig exercises every check")
}

@Test func inMemoryProviderSatisfiesTheCommandFlowContract() async throws {
    let rig = try InMemoryRig()
    let results = await CommandFlowContract.run(rig: rig)
    for result in results {
        if let failure = result.failure { Issue.record("\(result.name): \(failure)") }
    }
    #expect(results.count == 9)
    #expect(results.filter { $0.skipped != nil }.count == 0, "the in-memory rig exercises every flow check")
}
