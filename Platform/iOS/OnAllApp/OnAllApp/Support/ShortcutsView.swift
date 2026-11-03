import NEOBudgetCore
import SwiftUI

/// 단축어: whether the Shortcut is delivering, and the received-notification history.
struct ShortcutsView: View {
    let model: AppModel
    @State private var items: [InboxItem]?

    var body: some View {
        List {
            Section {
                HStack(spacing: Theme.Space.m) {
                    IconTile(systemName: "bolt.fill", tint: Theme.CalendarTint.orange.color, size: 36)
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text("알림 받기").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                        Text(lastReceived).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if items?.isEmpty == false { StatusBadge(text: "연결됨", tone: .accent) }
                }
            }
            .onAllCardRow()
            Section {
                NavigationLink { IntakeInboxView(model: model) } label: {
                    MoreRowLabel(symbol: "list.bullet", tint: Theme.CalendarTint.orange.color, title: "받은 알림 내역", value: items.map { "\($0.count)건" })
                }
            }
            .onAllCardRow()
        }
        .onAllGroupedScreen()
        .navigationTitle("단축어")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataGeneration) { items = await model.inbox() }
    }

    private var lastReceived: String {
        guard let item = items?.first else { return "아직 받은 알림이 없어요" }
        let time = item.notification.notificationAtUnixMilliseconds ?? item.notification.capturedAtUnixMilliseconds
        return "마지막 수신 " + Formatting.shortDate(time, zoneIdentifier: model.dayZone.identifier) + " " + Formatting.time(time, zoneIdentifier: model.dayZone.identifier)
    }
}
