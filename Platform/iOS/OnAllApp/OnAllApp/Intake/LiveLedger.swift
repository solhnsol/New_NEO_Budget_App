import Foundation
import NEOBudgetCalendar
import NEOBudgetCore

/// The one real ledger in this process, shared by the app's screens and the Shortcut action, so a notification the
/// Shortcut delivers while the app is open shows up at once, and one delivered in the background is in the files the
/// next launch replays.
@MainActor
enum LiveLedger {
    /// Called after the Shortcut delivered at least one new notification (set by the live `AppModel`).
    static var didReceive: (@MainActor () async -> Void)?

    private static var instance: AppLedger?

    static func shared() throws -> AppLedger {
        if let instance { return instance }
        let zone = try DisplayTimeZone(identifier: TimeZone.current.identifier)
        let ledger = try AppLedger(store: .standard(), zone: zone)
        instance = ledger
        return ledger
    }
}

/// What the user said about an account a notification mentioned.
enum AccountAnswer: Sendable {
    case newAccount(name: String, kind: NewTargetKind)
    case existing(ResolvedLedgerBinding)
    case notMine
}
