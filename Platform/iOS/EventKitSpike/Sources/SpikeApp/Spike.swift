import EventKit
import Foundation

/// Appends observations to the file named by `SPIKE_LOG` (default: a temp file) so results survive the test runner.
enum SpikeLog {
    static let path = "/tmp/claude-501/eventkit-spike.log"
    static func reset() { try? "".write(toFile: path, atomically: true, encoding: .utf8) }
    static func line(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

private let seoul = TimeZone(identifier: "Asia/Seoul")!
private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = seoul; return c }
private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
}
private func fmt(_ date: Date?) -> String {
    guard let date else { return "nil" }
    let f = DateFormatter(); f.timeZone = seoul; f.dateFormat = "MM-dd HH:mm:ss"; return f.string(from: date)
}
private func dump(_ e: EKEvent, _ label: String = "") {
    SpikeLog.line("  \(label) title=\(e.title ?? "nil") start=\(fmt(e.startDate)) end=\(fmt(e.endDate)) occ=\(fmt(e.occurrenceDate)) " +
        "detached=\(e.isDetached) rec=\(e.hasRecurrenceRules) tz=\(e.timeZone?.identifier ?? "nil") allDay=\(e.isAllDay)")
    SpikeLog.line("    eventID=\(e.eventIdentifier ?? "nil") itemID=\(e.calendarItemIdentifier) ext=\(e.calendarItemExternalIdentifier ?? "nil") modified=\(fmt(e.lastModifiedDate))")
}

@MainActor
final class ChangeCounter {
    var count = 0
    private var token: NSObjectProtocol?
    init(_ store: EKEventStore) {
        token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { self.count += 1 }
        }
    }
}

@MainActor
struct EventKitSpike {
    let store = EKEventStore()

    private func makeCalendar(_ name: String) throws -> EKCalendar {
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = name
        guard let source = store.sources.first(where: { $0.sourceType == .local }) ?? store.defaultCalendarForNewEvents?.source else {
            throw SpikeError.noSource
        }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func weekly(_ calendar: EKCalendar, _ title: String, count: Int = 5) throws -> EKEvent {
        let e = EKEvent(eventStore: store)
        e.calendar = calendar; e.title = title
        e.startDate = date(2026, 11, 2, 10); e.endDate = date(2026, 11, 2, 11)
        e.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: count)))
        try store.save(e, span: .futureEvents, commit: true)
        return e
    }

    private func occurrences(_ calendar: EKCalendar, title: String? = nil) -> [EKEvent] {
        let p = store.predicateForEvents(withStart: date(2026, 10, 1), end: date(2027, 1, 31), calendars: [calendar])
        return store.events(matching: p).filter { title == nil || $0.title == title }.sorted { $0.startDate < $1.startDate }
    }

    func run() async throws {
        SpikeLog.reset()
        SpikeLog.line("== access ==")
        SpikeLog.line("status before = \(EKEventStore.authorizationStatus(for: .event).rawValue)")
        let granted = try await store.requestFullAccessToEvents()
        SpikeLog.line("requestFullAccess granted=\(granted) status=\(EKEventStore.authorizationStatus(for: .event).rawValue)")
        guard granted else { throw SpikeError.denied }
        SpikeLog.line("sources: " + store.sources.map { "\($0.title)(\($0.sourceType.rawValue))" }.joined(separator: ", "))

        let counter = ChangeCounter(store)
        let main = try makeCalendar("spike-main")
        defer { for c in store.calendars(for: .event) where c.title.hasPrefix("spike-") { try? store.removeCalendar(c, commit: true) } }

        // #7 floating / #10 lastModified / #12 echo
        SpikeLog.line("== #7 floating, #10 lastModified, #12 echo ==")
        let before = counter.count
        let floating = EKEvent(eventStore: store)
        floating.calendar = main; floating.title = "floating"
        floating.startDate = date(2026, 11, 10, 9); floating.endDate = date(2026, 11, 10, 10)
        floating.timeZone = nil
        try store.save(floating, span: .thisEvent, commit: true)
        try await Task.sleep(for: .seconds(1))
        SpikeLog.line("EKEventStoreChanged after own save: \(counter.count - before)")
        dump(floating, "floating-after-save")
        let reloaded = store.event(withIdentifier: floating.eventIdentifier!)!
        dump(reloaded, "floating-reloaded")
        let m1 = reloaded.lastModifiedDate
        try await Task.sleep(for: .seconds(1.2))
        reloaded.title = "floating-renamed"
        try store.save(reloaded, span: .thisEvent, commit: true)
        SpikeLog.line("lastModified changed on update: \(m1 != reloaded.lastModifiedDate) (\(fmt(m1)) -> \(fmt(reloaded.lastModifiedDate)))")

        // #10b lastModifiedDate resolution: rapid consecutive saves
        SpikeLog.line("== #10b lastModified resolution ==")
        let rapid = EKEvent(eventStore: store)
        rapid.calendar = main; rapid.title = "rapid"
        rapid.startDate = date(2026, 11, 12, 9); rapid.endDate = date(2026, 11, 12, 10)
        try store.save(rapid, span: .thisEvent, commit: true)
        for i in 1...4 {
            rapid.title = "rapid-\(i)"
            try store.save(rapid, span: .thisEvent, commit: true)
            SpikeLog.line("  save \(i): lastModified=\(rapid.lastModifiedDate.map { String($0.timeIntervalSince1970) } ?? "nil")")
        }

        // #6 all-day end convention
        SpikeLog.line("== #6 all-day ==")
        let allDay = EKEvent(eventStore: store)
        allDay.calendar = main; allDay.title = "allday-3days"; allDay.isAllDay = true
        allDay.startDate = date(2026, 11, 11); allDay.endDate = date(2026, 11, 13) // inclusive last day = 13th
        try store.save(allDay, span: .thisEvent, commit: true)
        dump(store.event(withIdentifier: allDay.eventIdentifier!)!, "allday(start 11, end 13)")
        let allDay2 = EKEvent(eventStore: store)
        allDay2.calendar = main; allDay2.title = "allday-endMidnightNext"; allDay2.isAllDay = true
        allDay2.startDate = date(2026, 11, 11); allDay2.endDate = date(2026, 11, 14)
        try store.save(allDay2, span: .thisEvent, commit: true)
        dump(store.event(withIdentifier: allDay2.eventIdentifier!)!, "allday(start 11, end 14 00:00)")

        // #2/#3 recurrence identifiers + detached occurrence
        SpikeLog.line("== #2/#3 recurrence ids, thisEvent move ==")
        let seriesX = try makeCalendar("spike-x")
        _ = try weekly(seriesX, "X")
        var occ = occurrences(seriesX, title: "X")
        SpikeLog.line("occurrences: \(occ.count)")
        for (i, e) in occ.enumerated() { dump(e, "X[\(i)]") }
        SpikeLog.line("distinct eventIdentifiers: \(Set(occ.map(\.eventIdentifier)).count)  distinct itemIdentifiers: \(Set(occ.map(\.calendarItemIdentifier)).count)")
        let target = occ[1]
        target.startDate = date(2026, 11, 10, 15); target.endDate = date(2026, 11, 10, 16)
        try store.save(target, span: .thisEvent, commit: true)
        occ = occurrences(seriesX, title: "X")
        SpikeLog.line("-- after moving X[1] with .thisEvent (11-09 10:00 -> 11-10 15:00) --")
        for (i, e) in occ.enumerated() { dump(e, "X[\(i)]") }
        SpikeLog.line("distinct eventIdentifiers: \(Set(occ.map(\.eventIdentifier)).count)")

        // #4 futureEvents from middle
        SpikeLog.line("== #4 .futureEvents from the middle ==")
        let calY = try makeCalendar("spike-y")
        _ = try weekly(calY, "Y")
        var y = occurrences(calY, title: "Y")
        let originalIDs = y.map(\.eventIdentifier)
        for (i, e) in y.enumerated() { dump(e, "Y-before[\(i)]") }
        let mid = y[2]
        mid.title = "Y-edited"
        mid.startDate = date(2026, 11, 16, 12); mid.endDate = date(2026, 11, 16, 13)
        try store.save(mid, span: .futureEvents, commit: true)
        y = occurrences(calY)
        for (i, e) in y.enumerated() { dump(e, "Y-after[\(i)]") }
        SpikeLog.line("old IDs still present after: \(originalIDs.map { id in y.contains { $0.eventIdentifier == id } })")
        SpikeLog.line("old master id resolves: \(store.event(withIdentifier: originalIDs[0]!) != nil)")

        // #5 "all in series"
        SpikeLog.line("== #5 all-in-series via .futureEvents on the first occurrence ==")
        let calZ = try makeCalendar("spike-z")
        _ = try weekly(calZ, "Z")
        var z = occurrences(calZ, title: "Z")
        let zIDs = z.map(\.eventIdentifier)
        z[0].title = "Z-renamed"
        try store.save(z[0], span: .futureEvents, commit: true)
        z = occurrences(calZ)
        for (i, e) in z.enumerated() { dump(e, "Z-after[\(i)]") }
        SpikeLog.line("ids unchanged: \(z.map(\.eventIdentifier) == zIDs)")
        SpikeLog.line("-- renaming from a *later* occurrence with .futureEvents does not touch earlier ones (see Y). Fetching master by id and saving .futureEvents:")
        let calW = try makeCalendar("spike-w")
        _ = try weekly(calW, "W")
        var w = occurrences(calW, title: "W")
        if let master = store.event(withIdentifier: w[3].eventIdentifier!) {
            SpikeLog.line("event(withIdentifier:) of occurrence[3] returns start=\(fmt(master.startDate)) occ=\(fmt(master.occurrenceDate)) (master=first? \(master.startDate == w[0].startDate))")
            master.title = "W-renamed-via-lookup"
            try store.save(master, span: .futureEvents, commit: true)
        }
        w = occurrences(calW)
        for (i, e) in w.enumerated() { dump(e, "W-after[\(i)]") }

        // #8 calendar deletion
        SpikeLog.line("== #8 calendar deletion ==")
        let gone = try makeCalendar("spike-gone")
        let g = EKEvent(eventStore: store)
        g.calendar = gone; g.title = "g"; g.startDate = date(2026, 11, 20, 9); g.endDate = date(2026, 11, 20, 10)
        try store.save(g, span: .thisEvent, commit: true)
        let gid = g.eventIdentifier!
        let beforeDel = counter.count
        try store.removeCalendar(gone, commit: true)
        try await Task.sleep(for: .seconds(1))
        SpikeLog.line("changed notifications on calendar removal: \(counter.count - beforeDel)")
        SpikeLog.line("event(withIdentifier:) after calendar removal: \(store.event(withIdentifier: gid) == nil ? "nil" : "still found")")
        SpikeLog.line("calendar(withIdentifier:) after removal: \(store.calendar(withIdentifier: gone.calendarIdentifier) == nil ? "nil" : "still found")")

        // #11 writability flags
        SpikeLog.line("== #11 writability of existing calendars ==")
        for c in store.calendars(for: .event) {
            SpikeLog.line("  \(c.title) allowsContentModifications=\(c.allowsContentModifications) immutable=\(c.isImmutable) subscribed=\(c.isSubscribed) type=\(c.type.rawValue) source=\(c.source.title)")
        }
        SpikeLog.line("== done ==")
    }
}

enum SpikeError: Error { case denied, noSource }
