import Foundation
import NEOBudgetCalendar

/// Keeps the life state (links, settlements, people, ...) in a JSON file so it survives a restart. Commit rules are the in-memory
/// repository's; the file is rewritten after each successful commit. The revision restarts at 0 on every launch.
public struct FileLifeRepository: LifeRepository {
    private var inner: InMemoryLifeRepository
    private let url: URL

    /// A readable file wins over `initialState`, which is only the very first launch's start (for example an imported ledger's settlements).
    public init(url: URL, initialState: LifeState = .empty) {
        self.url = url
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(LifeState.self, from: $0) }
        inner = InMemoryLifeRepository(initialState: saved ?? initialState)
    }

    public func snapshot() throws -> LifeSnapshot { try inner.snapshot() }

    public mutating func commit(_ changes: [LifeChange], expectedRevision: UInt64) throws -> LifeCommitResult {
        let result = try inner.commit(changes, expectedRevision: expectedRevision)
        // shortcut: a failed write is ignored (the change stays in memory for this run); surface it when there is a place to show it.
        if let state = try? inner.snapshot().state, let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
        return result
    }
}
