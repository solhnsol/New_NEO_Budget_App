import SwiftUI

/// The app's two tabs: the calendar (day timeline grid) and the ledger (a plain transaction list).
struct RootTabs: View {
    let model: AppModel

    var body: some View {
        TabView {
            DayTimelineScreen(model: model)
                .tabItem { Label("캘린더", systemImage: "calendar") }
            LedgerScreen(model: model)
                .tabItem { Label("가계부", systemImage: "wonsign.circle") }
        }
        .tint(Theme.accent)
    }
}
