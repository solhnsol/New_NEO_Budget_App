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

    let dayZone: DisplayTimeZone
    let isDemo: Bool

    private let provider: any CalendarProvider
    private let eventKit: EventKitCalendarProvider?
    private let transactions: [TransactionMarker]
    private let prepare: (@Sendable () async -> Void)?
    private var generation = 0
    private var observer: Task<Void, Never>?

    private init(
        provider: any CalendarProvider,
        eventKit: EventKitCalendarProvider?,
        dayZone: DisplayTimeZone,
        transactions: [TransactionMarker],
        isDemo: Bool,
        prepare: (@Sendable () async -> Void)?
    ) {
        self.provider = provider
        self.eventKit = eventKit
        self.dayZone = dayZone
        self.transactions = transactions
        self.isDemo = isDemo
        self.prepare = prepare
        selectedDay = dayZone.localDate(of: Self.nowMilliseconds())
    }

    /// The device calendar. Transactions are not wired to the ledger yet, so none are shown.
    static func live() throws -> AppModel {
        let zone = try DisplayTimeZone(identifier: TimeZone.current.identifier)
        let provider = try EventKitCalendarProvider(dayZoneIdentifier: zone.identifier)
        return AppModel(provider: provider, eventKit: provider, dayZone: zone, transactions: [], isDemo: false, prepare: nil)
    }

    /// Synthetic data for screenshots and UI checks (`-demo`). It never reads or writes the device calendar.
    static func demo() throws -> AppModel {
        let zone = try DisplayTimeZone(identifier: TimeZone.current.identifier)
        let today = zone.localDate(of: nowMilliseconds())
        let demo = DemoData.make(today: today, zone: zone)
        return AppModel(provider: demo.provider, eventKit: nil, dayZone: zone, transactions: demo.transactions, isDemo: true, prepare: demo.seed)
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
        await reload()
        observeChanges()
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
        generation += 1
        let mine = generation
        let first = selectedDay.adding(days: -selectedDay.weekday)
        let from = dayZone.startOfDay(first)
        let to = dayZone.startOfDay(first.adding(days: 7))
        do {
            async let calendars = provider.calendars()
            async let events = provider.events(from: from, to: to, calendarIDs: nil)
            let (loadedCalendars, loadedEvents) = try await (calendars, events)
            guard mine == generation else { return }
            let input = DayTimelineInput(
                day: selectedDay, timeZone: dayZone, calendars: loadedCalendars, events: loadedEvents,
                life: .empty, transactions: transactions
            )
            timeline = DayTimelineBuilder.build(input)
            week = WeekStripBuilder.build(
                containing: selectedDay, firstWeekday: 0, timeZone: dayZone,
                events: loadedEvents, life: .empty, transactions: transactions
            )
            phase = .ready
        } catch CalendarProviderFailure.accessUnavailable {
            guard mine == generation else { return }
            phase = .denied
        } catch {
            guard mine == generation else { return }
            phase = .failed("일정을 불러오지 못했습니다.")
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
