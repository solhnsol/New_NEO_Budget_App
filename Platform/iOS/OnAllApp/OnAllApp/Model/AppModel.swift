import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetEventKit
import NEOBudgetInMemoryCalendar
import NEOBudgetInMemoryStorage
import Observation

/// One day of the strip around the two visible days. `timeline` is `nil` until it has been read.
struct StripDay: Identifiable {
    let day: LocalDate
    let timeline: DayTimeline?
    var id: LocalDate { day }
}

/// Everything the Day Timeline screen shows, derived from the calendar provider and the pure
/// `DayTimelineBuilder`. The view never touches a provider or a platform calendar object.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case needsAccess
        case denied
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var selectedDay: LocalDate
    /// The first of the two days on screen. `selectedDay` is its date.
    var timeline: DayTimeline? { cache[selectedDay] }
    /// The two consecutive days on screen, in order. They share one time axis.
    var visibleTimelines: [DayTimeline] { [cache[selectedDay], cache[selectedDay.adding(days: 1)]].compactMap { $0 } }
    /// One day either side of the two on screen, so a swipe has a neighbour ready to slide in and nothing waits on a read.
    /// Entries are `nil` until loaded.
    var strip: [StripDay] {
        (-1...2).map { offset in
            let day = selectedDay.adding(days: offset)
            return StripDay(day: day, timeline: cache[day])
        }
    }
    /// The days read, kept by `DayCachePolicy` (see `DayCache.swift`): required `D-1 ... D+2`, retained two more each side.
    private var cache = DayCache()
    /// How many days have been read from the calendar and the ledger since the app started. A move to a day already kept adds none.
    private(set) var dayReads = 0
    /// The days kept, for tests and diagnostics.
    var cachedDays: Set<LocalDate> { cache.days }
    /// A day as it is kept, if it is (read-only: the fixed grid draws any day around its moving position from here).
    func cachedTimeline(for day: LocalDate) -> DayTimeline? { cache[day] }
    /// Changes whenever the kept days change.
    var dataRevision: Int { cache.revision }

    /// Whether a day is kept, being read, failed to read, or not asked for. A kept day with nothing on it is `.loaded` (an empty day), never `.loading`.
    enum DayLoadState: Equatable { case loaded, loading, failed, notRead }

    func loadState(for day: LocalDate) -> DayLoadState {
        if cache[day] != nil { return .loaded }
        if let running = reading[day], running.generation == dataGeneration { return .loading }
        if fullReloadsInFlight > 0 { return .loading }
        if failedDays.contains(day) { return .failed }
        return .notRead
    }
    private var fullReloadsInFlight = 0
    private(set) var week: [WeekStripDay] = []
    /// The days of the week on screen and the weeks either side, by date, so the strip can page between weeks without waiting for a read.
    private(set) var weekCells: [LocalDate: WeekStripDay] = [:]
    private(set) var calendars: [CalendarDescriptor] = []
    /// What an event's info sheet can choose from (types, places, people).
    private(set) var catalog = ActivityCatalog()
    /// Created once the command service exists (after the first successful start). Gestures go through it.
    private(set) var editor: TimelineEditor?
    /// The save path for an edit session's time change (Phase 3A): re-checks the original, then writes through the same command service.
    /// Created with `editor`. Use `save(_:)` so the days are read again afterwards.
    private(set) var savePipeline: EventSavePipeline?

    let dayZone: DisplayTimeZone
    let isDemo: Bool

    private let provider: any CalendarProvider
    private let eventKit: EventKitCalendarProvider?
    private let ledger: AppLedger
    private var service: CalendarCommandService?
    private let prepare: (@Sendable () async -> Void)?
    /// The data generation: moves only when the calendar may have changed (`reload`). A day read in an earlier generation is stale and is never kept. A move does
    /// not touch it, so a read that a move outran is still kept (the day is still that day).
    private(set) var dataGeneration = 0
    /// The move requests (`prefetch`): moves with every one, and says which days the move needs now. Separate from `dataGeneration`.
    private(set) var navigationRevision = 0
    private var navigationNeeded: Set<LocalDate> = []
    /// The cache policy of the last read (the fixed grid's and Browse's have the same numbers).
    private var keptPolicy = DayCachePolicy.standard
    /// The day reads under way, one per day: a second asker joins the first instead of reading the day again.
    private struct Reading {
        let generation: Int
        let token: Int
        let task: Task<Bool, any Error>
    }
    private var reading: [LocalDate: Reading] = [:]
    private var readTokens = 0
    /// Days whose read failed in this data generation and that are not kept (they are read again when asked for).
    private(set) var failedDays: Set<LocalDate> = []
    /// Reads that landed after the calendar changed and were dropped. For tests and diagnostics.
    private(set) var staleReadsDropped = 0
    /// Wraps every day read (tests and the DEBUG launch arguments inject delays and failures here). `nil`: the service is read directly.
    var dayReadInterceptor: (@MainActor (LocalDate, @escaping @MainActor () async throws -> DayTimeline) async throws -> DayTimeline)?
    private var observer: Task<Void, Never>?

    private init(
        provider: any CalendarProvider,
        eventKit: EventKitCalendarProvider?,
        dayZone: DisplayTimeZone,
        ledger: AppLedger,
        isDemo: Bool,
        prepare: (@Sendable () async -> Void)?
    ) {
        self.provider = provider
        self.eventKit = eventKit
        self.dayZone = dayZone
        self.ledger = ledger
        self.isDemo = isDemo
        self.prepare = prepare
        selectedDay = dayZone.localDate(of: Self.nowMilliseconds())
    }

    /// The device calendar and the real ledger (the notifications the Shortcut delivered), unless `withSampleLedger`
    /// seeds the synthetic day (launch argument `-ledger-sample`) to check real calendar data against ledger-derived
    /// transactions.
    static func live(withSampleLedger: Bool = false) throws -> AppModel {
        let zone = try DisplayTimeZone(identifier: TimeZone.current.identifier)
        let provider = try EventKitCalendarProvider(dayZoneIdentifier: zone.identifier)
        let today = zone.localDate(of: nowMilliseconds())
        let ledger = withSampleLedger ? try SampleLedger.make(today: today, zone: zone) : try LiveLedger.shared()
        return AppModel(provider: provider, eventKit: provider, dayZone: zone, ledger: ledger, isDemo: false, prepare: nil)
    }

    /// Synthetic calendar and ledger for screenshots and UI regression checks (`-demo`). It never reads or writes the
    /// device calendar. Its transactions come through the same ledger projection as real ones.
    static func demo() throws -> AppModel {
        let zone = try DisplayTimeZone(identifier: TimeZone.current.identifier)
        let today = zone.localDate(of: nowMilliseconds())
        let demo = DemoData.make(today: today, zone: zone)
        let ledger = try SampleLedger.make(today: today, zone: zone)
        return AppModel(provider: demo.provider, eventKit: nil, dayZone: zone, ledger: ledger, isDemo: true, prepare: demo.seed)
    }

    // MARK: Lifecycle

    func start() async {
        if let prepare { await prepare() }
        observeLedger()
        if eventKit != nil {
            switch EventKitCalendarProvider.accessState() {
            case .notDetermined:
                phase = .needsAccess
                return
            case .fullAccess:
                break
            case .writeOnly, .denied, .restricted:
                phase = .denied
                return
            }
        }
        do {
            try await makeService()
        } catch {
            phase = .failed("일정과 거래를 불러오지 못했습니다.")
            return
        }
        await bindSpendingByTime()
        await reload()
        observeChanges()
    }

    private func makeService() async throws {
        guard service == nil else { return }
        let source = try await ledger.transactionSource()
        // The demo starts with meaning on its events (type, area, people); a real launch starts with none.
        var initialLife = LifeState.empty
        if isDemo {
            let bounds = dayZone.dayBounds(selectedDay)
            if let events = try? await provider.events(from: bounds.start, to: bounds.end, calendarIDs: nil) {
                initialLife = DemoLife.initialState(events: events)
            }
        }
        let service = CalendarCommandService(
            provider: provider,
            repository: InMemoryLifeRepository(initialState: initialLife),
            transactions: source,
            configuration: CalendarServiceConfiguration(displayTimeZone: dayZone),
            makeID: { kind in "\(kind.rawValue)-\(UUID().uuidString)" },
            now: { Int64(Date().timeIntervalSince1970 * 1_000) }
        )
        self.service = service
        if isDemo { await DemoLinks.apply(service: service, provider: provider, zone: dayZone, day: selectedDay) }
        let environment = TimelineEditor.Environment(
            perform: { await service.perform($0) },
            reload: { [weak self] in await self?.reload() },
            supportedScopes: provider.supportedRecurrenceScopes,
            zone: dayZone,
            policy: .standard,
            calendars: { [weak self] in self?.calendars ?? [] }
        )
        editor = TimelineEditor(environment: environment)
        savePipeline = EventSavePipeline(service: service, supportedScopes: provider.supportedRecurrenceScopes, zone: dayZone)
    }

    func requestAccess() async {
        guard let eventKit else { return }
        do {
            let granted = try await eventKit.requestFullAccess()
            if granted { await start() } else { phase = .denied }
        } catch {
            phase = .failed("캘린더 접근을 요청하지 못했습니다.")
        }
    }

    // MARK: Navigation

    func select(_ day: LocalDate) async {
        guard moveTo(day) else { return }
        await reload()
    }

    /// Moves the two visible days so the first is `day`, using days already read, with no waiting: a swipe that has just come to
    /// rest shows its result in the same frame. The caller reads whatever the new strip is missing (`reload`).
    @discardableResult
    func moveTo(_ day: LocalDate) -> Bool {
        guard day != selectedDay else { return false }
        BrowseProbe.mark(.selectedDayChanged)
        selectedDay = day
        if visibleTimelines.count == 2 { editor?.timelinesDidChange(visibleTimelines) }
        return true
    }

    /// Reads days that are about to slide past, for a jump to a day that is not next door. Nothing is kept: `adopt` keeps the ones needed.
    func readDays(_ days: [LocalDate]) async -> [StripDay] {
        guard let service else { return days.map { StripDay(day: $0, timeline: cache[$0]) } }
        var result: [StripDay] = []
        for day in days {
            let timeline: DayTimeline?
            if let known = cache[day] { timeline = known } else { dayReads += 1; timeline = try? await service.dayTimeline(for: day) }
            result.append(StripDay(day: day, timeline: timeline))
        }
        return result
    }

    /// Keeps days read ahead of a jump, so the move to the day lands on days that are already there.
    func adopt(_ days: [StripDay]) {
        for entry in days { if let timeline = entry.timeline { cache.insert(timeline) } }
    }

    func shift(days: Int) async { await select(selectedDay.adding(days: days)) }

    func goToday() async { await select(dayZone.localDate(of: Self.nowMilliseconds())) }

    /// Today's date in the display zone.
    var today: LocalDate { dayZone.localDate(of: Self.nowMilliseconds()) }

    var isToday: Bool { selectedDay == dayZone.localDate(of: Self.nowMilliseconds()) }

    // MARK: Loading

    /// Reads everything again: the days around the selected one, the weeks, the calendars, the life state. For "something changed" (the calendar's
    /// change notification, the app coming back, a saved edit). Days kept beyond the required ones may be stale after a change and are dropped.
    func reload() async {
        guard let service else { return }
        dataGeneration += 1
        let mine = dataGeneration
        fullReloadsInFlight += 1
        defer { fullReloadsInFlight -= 1 }
        do {
            let first = selectedDay
            var loaded: [LocalDate: DayTimeline] = [:]
            for day in DayCachePolicy.standard.required(around: first) { loaded[day] = try await readTimeline(day, service: service) }
            let loadedWeek = try await service.weekStrip(containing: selectedDay, firstWeekday: 0)
            var cells: [LocalDate: WeekStripDay] = [:]
            for offset in [-7, 0, 7] {
                let days = offset == 0 ? loadedWeek : try await service.weekStrip(containing: selectedDay.adding(days: offset), firstWeekday: 0)
                for cell in days { cells[cell.day] = cell }
            }
            let loadedCalendars = try await provider.calendars()
            guard mine == dataGeneration else { return }
            BrowseProbe.measure(.cacheMerge) { cache.replaceAll(with: loaded) }
            failedDays = []
            let shown = visibleTimelines
            if shown.count == 2 { editor?.timelinesDidChange(shown) }
            week = loadedWeek
            weekCells = cells
            calendars = loadedCalendars
            if let state = try? await service.lifeSnapshot().state { catalog = ActivityCatalog(state) }
            phase = .ready
        } catch CalendarProviderFailure.accessUnavailable {
            guard mine == dataGeneration else { return }
            phase = .denied
        } catch {
            guard mine == dataGeneration else { return }
            phase = .failed("일정과 거래를 불러오지 못했습니다.")
        }
    }

    /// After a move to another day: reads only the required days that are not kept yet (and, for a continuous move, `extra` more each side), the weeks
    /// around the selected day that are not kept, and evicts what the window left behind. Nothing already read is read again, and nothing near the selected
    /// day is dropped. Calendars and the life state are not read (a move does not change them). If a full `reload` is running it is the fresher read, so this
    /// becomes that.
    ///
    /// Each day is kept as soon as it is read (nearest first), so a day on screen does not wait for the others or for the weeks. A day that fails is marked
    /// failed and the others are still kept. A newer move does not throw this one's days away (they are still those days); only a `reload` (a new data
    /// generation) makes them stale.
    ///
    /// `failsScreen`: whether a day on screen that could not be read fails the whole screen (`phase = .failed`, Browse's behaviour). The fixed grid passes
    /// `false`: it marks that column as failed and reads it again, and the rest of the screen stays.
    func loadMissing(extra: Int = 0, policy: DayCachePolicy = .standard, failsScreen: Bool = true) async {
        guard let service else { return }
        guard fullReloadsInFlight == 0 else { await reload(); return }
        keptPolicy = policy
        let mine = dataGeneration
        let focus = selectedDay
        let missing = cache.missing(around: focus, policy: policy, extra: extra)
        var weeksToRead: [LocalDate] = []
        for offset in [-7, 0, 7] where weekCells[focus.adding(days: offset)] == nil { weeksToRead.append(focus.adding(days: offset)) }
        var failure: (any Error)?
        for day in missing {
            do { try await read(day) } catch { failure = failure ?? error }
        }
        var cells: [LocalDate: WeekStripDay] = [:]
        var loadedWeeks: [[WeekStripDay]] = []
        do {
            for day in weeksToRead {
                let days = try await service.weekStrip(containing: day, firstWeekday: 0)
                for cell in days { cells[cell.day] = cell }
                loadedWeeks.append(days)
            }
        } catch { failure = failure ?? error }
        guard mine == dataGeneration else { return }
        BrowseProbe.measure(.cacheMerge) { cache.evict(around: selectedDay, policy: policy, protecting: protectedDays) }
        forgetFailuresNoLongerWanted()
        for (day, cell) in cells { weekCells[day] = cell }
        // The week of the day selected now (a later move may have read it already, or this read may be for a day that is no longer selected).
        if let current = loadedWeeks.first(where: { $0.contains { $0.day == selectedDay } }) { week = current }
        let shown = visibleTimelines
        if shown.count == 2 { editor?.timelinesDidChange(shown) }
        switch failure {
        case nil: phase = .ready
        case CalendarProviderFailure.accessUnavailable?: phase = .denied
        default: phase = shown.count == 2 || !failsScreen ? .ready : .failed("일정과 거래를 불러오지 못했습니다.")
        }
    }

    /// While the window of days is between days (a swipe in progress, a flight to another day) and `selectedDay` has not moved yet: reads the days that the position
    /// and the day being headed for need (`DayPrefetchPolicy.neededDays`), nearest the position first, keeps the days on screen and the days the latest move
    /// needs, and evicts the rest of what the window around the selected day does not hold. `position` and `target` are epoch days. Nothing about the selected
    /// day changes. If a full `reload` is running it is left to finish (it is the fresher read) and nothing is read; a read that a `reload` overtakes is dropped.
    /// Each day is kept as it lands; a failed day does not drop the others; a day a later move no longer needs is not read.
    func prefetch(forPosition position: Double, target: Int? = nil, policy: DayPrefetchPolicy = .browse) async {
        guard service != nil, fullReloadsInFlight == 0 else { return }
        keptPolicy = policy.cachePolicy
        let needed = DayPrefetchPolicy.neededDays(position: position, target: target).map { LocalDate(daysSinceUnixEpoch: $0) }
        navigationRevision += 1
        navigationNeeded = Set(needed)
        forgetFailuresNoLongerWanted()
        let missing = needed.filter { cache[$0] == nil }.sorted { abs(Double($0.daysSinceUnixEpoch) - position) < abs(Double($1.daysSinceUnixEpoch) - position) }
        guard !missing.isEmpty else {
            BrowseProbe.measure(.cacheMerge) { cache.evict(around: selectedDay, policy: policy.cachePolicy, protecting: protectedDays) }
            return
        }
        for day in missing {
            guard fullReloadsInFlight == 0 else { return }
            guard cache[day] == nil, isWanted(day) else { continue }
            try? await read(day)
        }
    }

    // MARK: Reading one day

    /// A failure is remembered only for a day the window still wants (one it has left is simply not read).
    private func forgetFailuresNoLongerWanted() {
        if !failedDays.isEmpty { failedDays = failedDays.filter(isWanted) }
    }

    /// What eviction never drops: the two days on screen and the days the latest move needs.
    private var protectedDays: Set<LocalDate> { navigationNeeded.union([selectedDay, selectedDay.adding(days: 1)]) }

    /// Whether a day is still wanted where the window is now (around the selected day, or by the latest move).
    private func isWanted(_ day: LocalDate) -> Bool {
        keptPolicy.retained(around: selectedDay).contains(day) || protectedDays.contains(day)
    }

    /// Reads a day in this data generation, or joins the read of it already under way, and keeps it the moment it lands if the calendar did not change
    /// meanwhile and the window still wants it. Throws what the read threw (the day is then marked failed; nothing else is touched).
    private func read(_ day: LocalDate) async throws {
        guard let service else { return }
        let generation = dataGeneration
        if let running = reading[day], running.generation == generation {
            _ = try await running.task.value
            return
        }
        readTokens += 1
        let token = readTokens
        failedDays.remove(day)
        let task = Task<Bool, any Error> { @MainActor [weak self] in
            guard let self else { return false }
            defer { if self.reading[day]?.token == token { self.reading[day] = nil } }
            do {
                let timeline = try await self.readTimeline(day, service: service)
                return self.keep(timeline, for: day, readIn: generation)
            } catch {
                if generation == self.dataGeneration, self.cache[day] == nil { self.failedDays.insert(day) }
                throw error
            }
        }
        reading[day] = Reading(generation: generation, token: token, task: task)
        _ = try await task.value
    }

    /// A day just read: kept, unless it is stale (read before the calendar last changed: the newer read covers it) or the window has moved away from it.
    private func keep(_ timeline: DayTimeline, for day: LocalDate, readIn generation: Int) -> Bool {
        guard generation == dataGeneration else { staleReadsDropped += 1; return false }
        failedDays.remove(day)
        guard isWanted(day) else { return false }
        BrowseProbe.measure(.cacheMerge) { cache.merge([day: timeline], around: selectedDay, policy: keptPolicy, protecting: protectedDays) }
        BrowseProbe.mark(.dayLanded)
        return true
    }

    private func readTimeline(_ day: LocalDate, service: CalendarCommandService) async throws -> DayTimeline {
        dayReads += 1
        let direct: @MainActor () async throws -> DayTimeline = { try await service.dayTimeline(for: day) }
        if let dayReadInterceptor { return try await dayReadInterceptor(day, direct) }
        return try await direct()
    }

    /// Runs one edit of an event's meaning (type, place, people, linked transactions) and shows the result. The day is reloaded
    /// either way, so what is on screen is what is stored.
    @discardableResult
    func perform(_ command: CalendarCommand) async -> CalendarCommandOutcome? {
        guard let service else { return nil }
        let outcome = await service.perform(command)
        await reload()
        return outcome
    }

    /// Saves an edit session's time change and, if anything may have reached the calendar, reads the days again (as the timeline editor does after
    /// every write), so what is on screen is what is stored. A scope question or an unchanged proposal reads nothing. `nil` before the service exists.
    @discardableResult
    func save(_ request: EventSaveRequest) async -> EventSaveResult? {
        guard let savePipeline else { return nil }
        let result = await savePipeline.save(request)
        switch result {
        case .unchanged, .needsScope: break
        case .saved, .refused, .failed:                         // a refusal or failure may mean the calendar changed: show what it holds now
            await bindSpendingByTime()
            await reload()
        }
        return result
    }

    var nowMilliseconds: Int64 { Self.nowMilliseconds() }

    /// The ledger tab's list: every spend and refund, newest day first, with the activities each was split into.
    /// `nil` when the ledger could not be read. Before the command service exists (no calendar access yet) the
    /// transactions are still listed, without allocations.
    func ledgerSections() async -> [LedgerDaySection]? {
        guard let transactions = try? await ledger.transactions() else { return nil }
        let life = (try? await service?.lifeSnapshot().state) ?? .empty
        return LedgerList.sections(transactions, life: life, zone: dayZone)
    }

    /// The meaning kept around events (people, headcounts, components, obligations), for sheets that show it. `nil` before the service exists.
    func lifeState() async -> LifeState? {
        try? await service?.lifeSnapshot().state
    }

    /// Every account's and card's movements, unnetted (the ledger tab's statement view). `nil` when the ledger could not be read.
    func ledgerStatements() async -> [LedgerStatements.Statement]? {
        try? await ledger.statements()
    }

    // MARK: Received notifications

    /// Received notifications, newest first, with where each ended up. Empty in the demo.
    func inbox() async -> [InboxItem] { await ledger.inbox() }

    /// Accounts and cards the notifications mention that the user has not answered for yet.
    func accountQuestions() async -> [AccountQuestion] { await ledger.accountQuestions() }

    func registeredAccounts() async -> [AccountProfile] { await ledger.registeredAccounts() }

    /// Applies the user's answer about an account and replays the ledger with it. `false` if it could not be applied.
    @discardableResult
    func answer(_ question: AccountQuestion, with answer: AccountAnswer) async -> Bool {
        do {
            switch answer {
            case let .newAccount(name, kind): try await ledger.confirmAsNew(question.id, displayName: name, kind: kind)
            case let .existing(binding): try await ledger.link(question.id, to: binding)
            case .notMine: try await ledger.dismiss(question.id)
            }
        } catch {
            return false
        }
        await ledgerDidChange()
        return true
    }

    func ruleQuestion(for notificationID: String) async -> RuleQuestion? { await ledger.ruleQuestion(for: notificationID) }

    /// Messages like the question's belong to `binding`, or to a new account. `false` if it could not be applied (for
    /// one, when another account at the same institution could have sent the same message).
    @discardableResult
    func answer(_ question: RuleQuestion, binding: ResolvedLedgerBinding?, newAccount: (name: String, kind: NewTargetKind)?) async -> Bool {
        do {
            try await ledger.answer(question, binding: binding, newAccount: newAccount)
        } catch {
            return false
        }
        await ledgerDidChange()
        return true
    }

    /// The ledger changed (a notification arrived, an account was answered): the timeline and the ledger tab read it again.
    func ledgerDidChange() async {
        if service != nil {
            await bindSpendingByTime()
            await reload()
        } else {
            dataGeneration += 1
        }
    }

    /// Spending that happened during an event goes into it (`docs/ledger-behavior.md`, 1): each month that still has spending in no event is
    /// matched against its events, as automation, so the user's own decisions (including taking a transaction out) always stand. Run when the
    /// service starts, when the ledger changes and when the calendar changes; a transaction already decided is never looked at again.
    func bindSpendingByTime() async {
        guard let service, let transactions = try? await ledger.transactions() else { return }
        let life = (try? await service.lifeSnapshot().state) ?? .empty
        let months = Set(transactions
            .filter { $0.flow == .spend && (life.allocationSet(for: $0.id)?.isEmpty ?? true) }
            .compactMap { marker -> LocalDate? in
                let day = dayZone.localDate(of: marker.occurredAtUnixMilliseconds)
                return try? LocalDate(year: day.year, month: day.month, day: 1)
            })
        for month in months.sorted() {
            guard let next = try? LocalDate(year: month.month == 12 ? month.year + 1 : month.year, month: month.month % 12 + 1, day: 1) else { continue }
            _ = try? await service.bindByTime(from: dayZone.dayBounds(month).start, to: dayZone.dayBounds(next).start)
        }
    }

    private func observeLedger() {
        guard !isDemo else { return }
        LiveLedger.didReceive = { [weak self] in await self?.ledgerDidChange() }
    }

    private func observeChanges() {
        guard observer == nil else { return }
        let provider = provider
        observer = Task { [weak self] in
            for await _ in await provider.changes() {
                try? await Task.sleep(for: .milliseconds(300))
                await self?.bindSpendingByTime()
                await self?.reload()
            }
        }
    }

    private static func nowMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
}
