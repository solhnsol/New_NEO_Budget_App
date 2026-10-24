#if DEBUG
import Foundation
import NEOBudgetCalendar

/// Slow and failing day reads for checking the fixed-grid Browse by hand and for its measurements (DEBUG, `-demo` only, after the first read):
/// `-day-read-delay <ms>` makes every day read take that long, plus up to `-day-read-jitter <ms>` more (so reads can land out of order);
/// `-day-read-fail-every <n>` makes every n-th read fail.
enum DayReadFaults {
    struct ReadFailure: Error {}

    static func interceptor(arguments: [String]) -> (@MainActor (LocalDate, @escaping @MainActor () async throws -> DayTimeline) async throws -> DayTimeline)? {
        func value(_ name: String) -> Int? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return Int(arguments[index + 1])
        }
        let delay = value("-day-read-delay") ?? 0, jitter = value("-day-read-jitter") ?? 0, failEvery = value("-day-read-fail-every") ?? 0
        guard delay > 0 || jitter > 0 || failEvery > 0 else { return nil }
        var count = 0
        return { _, read in
            count += 1
            let wait = delay + (jitter > 0 ? Int.random(in: 0...jitter) : 0)
            if wait > 0 { try await Task.sleep(for: .milliseconds(wait)) }
            if failEvery > 0, count % failEvery == 0 { throw ReadFailure() }
            return try await read()
        }
    }
}
#endif
