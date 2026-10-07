import Foundation
import NEOBudgetCalendar
import NEOBudgetCore
import NEOBudgetInMemoryCalendar

/// `Tag` collides with Swift Testing's own `Tag`, so tests use this alias for the domain type.
typealias OnAllTag = NEOBudgetCalendar.Tag

let seoul = try! DisplayTimeZone(identifier: "Asia/Seoul")
let newYork = try! DisplayTimeZone(identifier: "America/New_York")

func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> LocalDate {
    try! LocalDate(year: year, month: month, day: dayOfMonth)
}

/// An instant for a wall-clock time in a zone (default Asia/Seoul).
func at(_ date: LocalDate, _ hour: Int, _ minute: Int = 0, in zone: DisplayTimeZone = seoul) -> Int64 {
    zone.instant(of: date, minuteOfDay: hour * 60 + minute)
}

func timed(_ start: Int64, _ end: Int64) -> TimedRange {
    try! TimedRange(startUnixMilliseconds: start, endUnixMilliseconds: end)
}

func allDayRange(_ first: LocalDate, _ last: LocalDate) -> DayRange {
    try! DayRange(firstDay: first, lastDay: last)
}

let today = day(2026, 10, 7)

func calendarID(_ name: String) -> CalendarID { CalendarID(rawValue: name) }
func eventID(_ name: String) -> CalendarEventID { CalendarEventID(rawValue: name) }
func key(_ calendar: String, _ event: String) -> CalendarEventKey {
    CalendarEventKey(calendarID: calendarID(calendar), eventID: eventID(event))
}

func event(
    _ id: String,
    calendar: String = "life",
    title: String = "일정",
    from start: Int64,
    to end: Int64,
    recurring: Bool = false,
    editable: Bool = true,
    notes: String? = nil,
    revision: String? = "r0"
) -> CalendarEvent {
    CalendarEvent(
        id: eventID(id),
        calendarID: calendarID(calendar),
        title: title,
        time: .timed(timed(start, end)),
        notes: notes,
        isRecurringInstance: recurring,
        isEditable: editable,
        revisionToken: revision
    )
}

func allDayEvent(_ id: String, calendar: String = "life", title: String = "종일", from first: LocalDate, to last: LocalDate) -> CalendarEvent {
    CalendarEvent(id: eventID(id), calendarID: calendarID(calendar), title: title, time: .allDay(allDayRange(first, last)), revisionToken: "r0")
}

func won(_ amount: Int64) -> Money { try! Money(minorUnits: amount, currency: "KRW") }

func marker(
    _ id: String,
    at instant: Int64,
    amount: Int64,
    flow: TransactionFlow = .spend,
    title: String? = nil
) -> TransactionMarker {
    TransactionMarker(id: LedgerEntryID(rawValue: id), occurredAtUnixMilliseconds: instant, amount: won(amount), flow: flow, title: title)
}

func txID(_ value: String) -> LedgerEntryID { LedgerEntryID(rawValue: value) }

let defaultCalendars = [
    CalendarDescriptor(id: calendarID("life"), title: "일상", colorHex: "#4C8BF5"),
    CalendarDescriptor(id: calendarID("school"), title: "학교", colorHex: "#2E7D32"),
    CalendarDescriptor(id: calendarID("readonly"), title: "공휴일", isWritable: false)
]

/// A thread-safe counter for deterministic activity IDs.
final class Sequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int64
    init(_ start: Int64) { current = start }
    func now() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    func advance(by milliseconds: Int64) {
        lock.lock()
        current += milliseconds
        lock.unlock()
    }
}

struct FakeStorageError: Error {}

/// A repository whose commits can be made to fail, to prove the "calendar written, local not" path.
struct FlakyLifeRepository: LifeRepository {
    var inner: InMemoryLifeRepository
    var failCommits = false

    func snapshot() throws -> LifeSnapshot { try inner.snapshot() }

    mutating func commit(_ changes: [LifeChange], expectedRevision: UInt64) throws -> LifeCommitResult {
        if failCommits { throw FakeStorageError() }
        return try inner.commit(changes, expectedRevision: expectedRevision)
    }
}

struct Harness {
    let provider: InMemoryCalendarProvider
    let service: CalendarCommandService
    let clock: FakeClock

    static func make(
        events: [CalendarEvent] = [],
        transactions: [TransactionMarker] = [],
        life: LifeState = .empty,
        supportedScopes: Set<RecurrenceScope> = [.thisOccurrence],
        editPolicy: TimelineEditPolicy = .standard,
        repository: (any LifeRepository)? = nil
    ) -> Harness {
        let provider = InMemoryCalendarProvider(calendars: defaultCalendars, events: events, supportedRecurrenceScopes: supportedScopes)
        let sequence = Sequence()
        let clock = FakeClock(1_790_000_000_000)
        let service = CalendarCommandService(
            provider: provider,
            repository: repository ?? InMemoryLifeRepository(initialState: life),
            transactions: InMemoryTransactionSource(transactions),
            configuration: CalendarServiceConfiguration(displayTimeZone: seoul, editPolicy: editPolicy),
            makeID: { kind in "\(kind.rawValue)-\(sequence.next())" },
            now: { clock.now() }
        )
        return Harness(provider: provider, service: service, clock: clock)
    }

    func life() async -> LifeState {
        try! await service.lifeSnapshot().state
    }
}

func userProvenance(_ time: Int64 = 1) -> AssignmentProvenance { .user(at: time) }
func autoProvenance(_ confidence: Double?, _ time: Int64 = 1) -> AssignmentProvenance {
    .automated(origin: "test-rule", confidence: confidence, at: time)
}

// MARK: Allocation helpers for tests

extension LifeState {
    /// The activity a transaction is wholly or mainly assigned to (its first activity allocation), if any.
    func activityID(of transaction: LedgerEntryID) -> ActivityID? {
        allocationSet(for: transaction)?.allocations.compactMap(\.activityID).first
    }
}

/// A change that assigns the whole transaction to an activity (what the old 1:1 link meant).
func wholeAllocation(
    _ transaction: String,
    to activity: String,
    total: Int64,
    id: String? = nil,
    provenance: AssignmentProvenance = userProvenance(),
    createdAt: Int64 = 1,
    flow: TransactionFlow = .spend
) -> LifeChange {
    allocation(transaction, to: activity, amount: .exact(total), of: total, id: id, provenance: provenance, createdAt: createdAt, flow: flow)
}

/// A change that assigns one portion (with any level of knowledge) of a transaction to an activity, or to
/// no activity when `activity` is nil.
func allocation(
    _ transaction: String,
    to activity: String?,
    amount: AmountKnowledge,
    of total: Int64,
    id: String? = nil,
    provenance: AssignmentProvenance = userProvenance(),
    createdAt: Int64 = 1,
    flow: TransactionFlow = .spend
) -> LifeChange {
    .upsertAllocation(
        TransactionAllocation(
            id: AllocationID(rawValue: id ?? "alloc-\(transaction)-\(activity ?? "none")"),
            transactionID: txID(transaction),
            activityID: activity.map { ActivityID(rawValue: $0) },
            amount: try! AmountEntry(currency: "KRW", knowledge: amount, provenance: provenance),
            provenance: provenance,
            createdAtUnixMilliseconds: createdAt
        ),
        transactionTotal: won(total),
        flow: flow
    )
}

// MARK: Amount, people, obligation, and settlement helpers

func entry(_ knowledge: AmountKnowledge, currency: String = "KRW", provenance: AssignmentProvenance = userProvenance()) -> AmountEntry {
    try! AmountEntry(currency: currency, knowledge: knowledge, provenance: provenance)
}

func amountRange(_ minimum: Int64, _ maximum: Int64) -> AmountKnowledge {
    .range(try! AmountRange(minMinorUnits: minimum, maxMinorUnits: maximum))
}

func inferred(_ value: Int64, summary: String = "test") -> AmountKnowledge {
    .inferred(value, InferenceEvidence(summary: summary))
}

func pid(_ value: String) -> PersonID { PersonID(rawValue: value) }
func oid(_ value: String) -> ObligationID { ObligationID(rawValue: value) }
let myself = pid("me")

func person(_ id: String, name: String? = nil, isSelf: Bool = false) -> Person {
    Person(id: pid(id), displayName: name ?? id, isSelf: isSelf)
}

func obligation(
    _ id: String,
    with counterparty: String = "friend",
    _ direction: ObligationDirection,
    _ knowledge: AmountKnowledge,
    activity: String? = nil,
    currency: String = "KRW",
    provenance: AssignmentProvenance = userProvenance(),
    createdAt: Int64 = 1
) -> Obligation {
    Obligation(
        id: oid(id),
        counterpartyID: pid(counterparty),
        activityID: activity.map { ActivityID(rawValue: $0) },
        direction: direction,
        amount: entry(knowledge, currency: currency, provenance: provenance),
        provenance: provenance,
        createdAtUnixMilliseconds: createdAt
    )
}

func transfer(_ transaction: String, _ direction: TransferDirection, _ amount: Int64, currency: String = "KRW") -> ActualTransfer {
    transfer(transaction, "friend", direction, amount, currency: currency)
}

func transfer(_ transaction: String, _ counterparty: String, _ direction: TransferDirection, _ amount: Int64, currency: String = "KRW") -> ActualTransfer {
    try! ActualTransfer(
        transactionID: txID(transaction), counterpartyID: pid(counterparty), direction: direction,
        amount: try! Money(minorUnits: amount, currency: currency), occurredAtUnixMilliseconds: 1_000
    )
}

/// A state with me (self) and the given other people, then the given changes.
func lifeWithPeople(_ others: [String] = ["friend"], extra: [LifeChange] = []) -> LifeState {
    let people: [LifeChange] = [.upsertPerson(person("me", name: "나", isSelf: true))] + others.map { .upsertPerson(person($0)) }
    return try! LifeState.empty.applying(people + extra)
}

func settleable(_ life: LifeState, _ id: String) -> ObligationStatus? { life.obligations[oid(id)]?.status }

func settle(_ life: LifeState, _ proposal: SettlementProposal, id: String = "s1", provenance: AssignmentProvenance = userProvenance()) throws -> LifeState {
    let settlement = try proposal.makeSettlement(id: SettlementID(rawValue: id), life: life, provenance: provenance, createdAtUnixMilliseconds: 50)
    return try life.applying([.recordSettlement(settlement)])
}

extension SettlementMatchResult {
    var proposal: SettlementProposal? {
        switch self {
        case let .exactMatch(p), let .netMatch(p), let .inferredUniqueSolution(p): return p
        default: return nil
        }
    }
}
