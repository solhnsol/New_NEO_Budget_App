import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetInMemoryCalendar

@Test func fileLifeRepositoryKeepsStateAcrossLaunches() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "life-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var first = FileLifeRepository(url: url)
    let before = try first.snapshot()
    let person = Person(id: PersonID(rawValue: "p1"), displayName: "차유진")
    _ = try first.commit([.upsertPerson(person)], expectedRevision: before.revision)

    let second = FileLifeRepository(url: url)
    #expect(try second.snapshot().state.persons[PersonID(rawValue: "p1")]?.displayName == "차유진")
}

@Test func fileLifeRepositoryFallsBackToInitialStateWithoutFile() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "none-\(UUID().uuidString).json")
    let repo = FileLifeRepository(url: url)
    #expect(try repo.snapshot().state == LifeState.empty)
}
