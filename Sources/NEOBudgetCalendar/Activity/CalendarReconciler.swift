/// Compares what the calendar provider currently reports with the events Activities point at, and returns the
/// changes that bring Activities up to date. Pure: it only reads its inputs.
///
/// Scope is deliberate. Only Activities whose last-known time falls inside the fetched window, and whose
/// calendar was actually queried, can be judged missing; everything else is left alone. Identifier changes
/// (an event reappearing under a different ID) are NOT handled here: whether and when a provider changes
/// identifiers must be verified on a real device before any re-binding rule is written.
public enum CalendarReconciler {
    public static func reconcile(
        life: LifeState,
        fetched: [CalendarEvent],
        window: (from: Int64, to: Int64),
        queriedCalendarIDs: Set<CalendarID>?,
        timeZone: DisplayTimeZone,
        now: Int64
    ) -> [LifeChange] {
        let fetchedByKey = Dictionary(fetched.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [LifeChange] = []

        for activity in life.activities.values.sorted(by: { $0.id < $1.id }) {
            guard let association = activity.association else { continue }
            if let queriedCalendarIDs, !queriedCalendarIDs.contains(association.key.calendarID) { continue }

            if let event = fetchedByKey[association.key] {
                let refreshed = association.refreshed(from: event)
                if refreshed != association { changes.append(.updateAssociation(activity.id, refreshed)) }
            } else if !association.isMissing,
                      association.lastKnown.time.overlaps(from: window.from, to: window.to, in: timeZone) {
                changes.append(.updateAssociation(activity.id, association.markedMissing(at: now)))
            }
        }
        return changes
    }
}
