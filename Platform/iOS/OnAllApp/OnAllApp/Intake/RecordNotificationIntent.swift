import AppIntents
import Foundation
import NEOBudgetCore
import NEOBudgetInMemoryStorage

/// The Shortcut's way in: the notification automation passes the notification as JSON text
/// (`{app, title, subtitle, body, timestamp}`, or an array of them) and the app records it without opening.
struct RecordNotificationIntent: AppIntent {
    static var title: LocalizedStringResource { "알림 기록하기" }
    static var description: IntentDescription { IntentDescription("결제·입출금 알림을 OnAll 가계부에 기록해요. 단축어의 알림 JSON을 그대로 넘겨 주세요.") }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "알림 JSON")
    var payload: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$payload) 기록하기")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let ledger = try LiveLedger.shared()
        let received: [InboxItem]
        do {
            received = try await ledger.receive(payload)
        } catch is ShortcutNotificationDecoder.DecodingError {
            throw RecordNotificationError.unreadablePayload
        }
        if !received.isEmpty { await LiveLedger.didReceive?() }
        return .result(value: received.isEmpty ? "이미 기록된 알림" : received.map { IntakeText.status($0.status) }.joined(separator: ", "))
    }
}

enum RecordNotificationError: Error, CustomLocalizedStringResourceConvertible {
    case unreadablePayload

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unreadablePayload: "알림 JSON을 읽지 못했어요. 단축어가 app, title, body, timestamp를 사전으로 넘기는지 확인해 주세요."
        }
    }
}

struct OnAllShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordNotificationIntent(),
            phrases: ["\(.applicationName)에 알림 기록하기"],
            shortTitle: "알림 기록하기",
            systemImageName: "tray.and.arrow.down"
        )
    }
}
