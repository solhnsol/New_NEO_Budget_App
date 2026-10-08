import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetEventKit
import NEOBudgetInMemoryCalendar
import Observation

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
    private(set) var timeline: DayTimeline?
    private(set) var week: [WeekStripDay] = []
    private(set) var calendars: [CalendarDescriptor] = []
    /// Created once the command service exists (after the first successful start). Gestures go through it.
    private(set) var editor: TimelineEditor?

    let dayZone: DisplayTimeZone
    let isDemo: Bool

    private let provider: any CalendarProvider
    private let eventKit: EventKitCalendarProvider?
    private let ledger: AppLedger
    private var service: CalendarCommandService?
    private let prepare: (@Sendable () async -> Void)?
    private var generation = 0
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

    /// The device calendar and the app ledger. The ledger is empty until ingestion and durable storage exist, unless
    /// `withSampleLedger` seeds the synthetic day (launch argument `-ledger-sample`) to check real calendar data
    /// against ledger-derived transactions.
    static func live(withSampleLedger: Bool = false) throws -> AppModel {
        let zone = try DisplayTimeZone(identifier: TimeZone.current.identifier)
        let provider = try EventKitCalendarProvider(dayZoneIdentifier: zone.identifier)
        let today = zone.localDate(of: nowMilliseconds())
        let ledger = withSampleLedger ? try SampleLedger.make(today: today, zone: zone) : try AppLedger()
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
        guard day != selectedDay else { return }
        selectedDay = day
        await reload()
    }

    func shift(days: Int) async { await select(selectedDay.adding(days: days)) }

    func goToday() async { await select(dayZone.localDate(of: Self.nowMilliseconds())) }

    var isToday: Bool { selectedDay == dayZone.localDate(of: Self.nowMilliseconds()) }

    // MARK: Loading

    func reload() async {
        guard let service else { return }
        generation += 1
        let mine = generation
        do {
            let loadedTimeline = try await service.dayTimeline(for: selectedDay)
            let loadedWeek = try await service.weekStrip(containing: selectedDay, firstWeekday: 0)
            let loadedCalendars = try await provider.calendars()
            guard mine == generation else { return }
            timeline = loadedTimeline
            editor?.timelineDidChange(loadedTimeline)
            week = loadedWeek
            calendars = loadedCalendars
            phase = .ready
        } catch CalendarProviderFailure.accessUnavailable {
            guard mine == generation else { return }
            phase = .denied
        } catch {
            guard mine == generation else { return }
            phase = .failed("일정과 거래를 불러오지 못했습니다.")
        }
    }

    private func observeChanges() {
        guard observer == nil else { return }
        let provider = provider
        observer = Task { [weak self] in
            for await _ in await provider.changes() {
                try? await Task.sleep(for: .milliseconds(300))
                await self?.reload()
            }
        }
    }

    private static func nowMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
}
