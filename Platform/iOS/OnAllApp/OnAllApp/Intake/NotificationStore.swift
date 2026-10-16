import Foundation
import NEOBudgetCore

/// The real ledger's durable inputs, in Application Support: every notification the Shortcut sent, in arrival order,
/// and the user's account setup. The ledger is derived from them by replay (`IntakeLedger`), so these two files are all
/// that has to survive a relaunch. Real financial text lives only here, on the device.
struct NotificationStore: Sendable {
    let directory: URL

    static func standard() throws -> NotificationStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("Intake", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return NotificationStore(directory: directory)
    }

    func notifications() throws -> [RawNotification] { try read([RawNotification].self, from: "notifications.json") ?? [] }

    func setup() throws -> IntakeSetup { try read(IntakeSetup.self, from: "setup.json") ?? IntakeSetup() }

    func save(notifications: [RawNotification]) throws { try write(notifications, to: "notifications.json") }

    func save(setup: IntakeSetup) throws { try write(setup, to: "setup.json") }

    private func read<Value: Decodable>(_ type: Value.Type, from name: String) throws -> Value? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    /// Whole-file atomic replace. Readable after the first unlock, so a notification that arrives while the phone is
    /// locked can still be written.
    private func write<Value: Encodable>(_ value: Value, to name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(
            to: directory.appendingPathComponent(name),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
