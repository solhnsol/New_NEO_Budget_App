import Foundation
import NEOBudgetCalendar
import NEOBudgetCore

/// What an event's info sheet can choose from. Read from the life store, never invented by the view.
struct ActivityCatalog: Equatable {
    struct Option: Equatable, Identifiable {
        let id: String
        let name: String
    }
    struct Person: Equatable, Identifiable {
        let id: PersonID
        let name: String
        let isSelf: Bool
    }

    var types: [Option] = []
    var areas: [Option] = []
    var people: [Person] = []

    init(types: [Option] = [], areas: [Option] = [], people: [Person] = []) {
        self.types = types
        self.areas = areas
        self.people = people
    }

    init(_ state: LifeState) {
        types = state.activityTypes.values.filter { !$0.isArchived }
            .sorted { ($0.isPreset ? 0 : 1, $0.displayName) < ($1.isPreset ? 0 : 1, $1.displayName) }
            .map { Option(id: $0.id.rawValue, name: $0.displayName) }
        areas = state.areaCatalog.areasByID.values.sorted { $0.displayName < $1.displayName }.map { Option(id: $0.id.rawValue, name: $0.displayName) }
        people = state.persons.values.sorted { ($0.isSelf ? 0 : 1, $0.displayName) < ($1.isSelf ? 0 : 1, $1.displayName) }
            .map { Person(id: $0.id, name: $0.displayName, isSelf: $0.isSelf) }
    }
}

/// The edits of one event's activity as commands. An event and its activity are one thing to the user: choosing a type, a
/// place or a person for an event goes straight through the event-targeted commands, which create the internal Activity the
/// first time one is needed. There is no separate "create activity" or "link activity" step.
enum ActivityEditing {
    static func provenance(now: Int64) -> AssignmentProvenance { .user(at: now, evidenceVersion: nil) }

    static func setType(_ id: ActivityTypeID?, event: CalendarEventKey, now: Int64) -> CalendarCommand {
        .assignActivityType(AssignActivityTypeInput(target: .event(event), typeID: id, provenance: provenance(now: now)))
    }

    static func setArea(_ id: AreaID?, event: CalendarEventKey, now: Int64) -> CalendarCommand {
        .assignActivityArea(AssignActivityAreaInput(target: .event(event), areaID: id, provenance: provenance(now: now)))
    }

    static func setParticipant(_ person: PersonID, on: Bool, event: CalendarEventKey, now: Int64) -> CalendarCommand {
        let input = ParticipantInput(activity: .event(event), personID: person, provenance: provenance(now: now))
        return on ? .addParticipant(input) : .removeParticipant(input)
    }

    static func link(_ transaction: LedgerEntryID, event: CalendarEventKey, now: Int64) -> CalendarCommand {
        .linkTransaction(LinkTransactionInput(transactionID: transaction, target: .event(event), provenance: provenance(now: now)))
    }

    static func unlink(_ transaction: LedgerEntryID, now: Int64) -> CalendarCommand {
        // Kept out, so binding by time does not put it back (`docs/ledger-behavior.md`, Q1).
        .unlinkTransaction(UnlinkTransactionInput(transactionID: transaction, by: provenance(now: now), keepOut: true))
    }

    /// Transactions that no event has taken, nearest to the event's time first, as candidates to link. Spending inside an event's time is
    /// already bound to it (`TimeBinding`); this list is for the rest. Ones wholly linked elsewhere are not offered (move those from their details).
    static func linkCandidates(for block: EventBlock, in timeline: DayTimeline) -> [TransactionMarkerItem] {
        linkCandidates(for: block, among: timeline.markers)
    }

    /// The same over markers read from several days, so last night's payment can go into this morning's meeting.
    static func linkCandidates(for block: EventBlock, among markers: [TransactionMarkerItem]) -> [TransactionMarkerItem] {
        let middle = (block.startUnixMilliseconds + block.endUnixMilliseconds) / 2
        var seen = Set<LedgerEntryID>()
        return markers
            .filter { $0.allocations.allSatisfy { $0.activityID == nil } && seen.insert($0.transactionID).inserted }
            .sorted {
                let (left, right) = (abs($0.occurredAtUnixMilliseconds - middle), abs($1.occurredAtUnixMilliseconds - middle))
                return left != right ? left < right : $0.transactionID.rawValue < $1.transactionID.rawValue
            }
    }

    /// An event a transaction can be put in.
    struct EventChoice: Equatable, Identifiable {
        let key: CalendarEventKey
        let title: String
        let startUnixMilliseconds: Int64
        let endUnixMilliseconds: Int64
        /// The activity the event already has, so the one a transaction is in now can be marked.
        let activityID: ActivityID?
        var id: String { key.id }
    }

    /// The timed events of the days read, nearest to `time` first (one that contains it counts as nearest). An event across midnight is listed once.
    /// All-day events are not offered yet (shortcut: they carry days, not instants; add them when a trip needs it).
    static func eventChoices(near time: Int64, in timelines: [DayTimeline]) -> [EventChoice] {
        var seen = Set<CalendarEventKey>()
        let choices = timelines.flatMap(\.blocks)
            .filter { $0.revisionToken != nil && seen.insert($0.eventKey).inserted }
            .map { EventChoice(key: $0.eventKey, title: $0.title, startUnixMilliseconds: $0.startUnixMilliseconds, endUnixMilliseconds: $0.endUnixMilliseconds, activityID: $0.activity?.activityID) }
        func gap(_ choice: EventChoice) -> Int64 { max(0, choice.startUnixMilliseconds - time, time - choice.endUnixMilliseconds) }
        return choices.sorted { (gap($0), $0.startUnixMilliseconds, $0.id) < (gap($1), $1.startUnixMilliseconds, $1.id) }
    }

    /// The id for a place or person the user types in.
    static func newID(prefix: String) -> String { "\(prefix)-\(UUID().uuidString)" }

    /// A typed name is only used when it says something.
    static func cleanName(_ text: String) -> String? {
        let trimmed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return trimmed.isEmpty ? nil : trimmed
    }
}
