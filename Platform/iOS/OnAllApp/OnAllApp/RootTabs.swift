import SwiftUI

/// The app's one screen: the calendar. The ledger's list and account statements open from the calendar's menu, so there is no tab bar.
struct RootTabs: View {
    let model: AppModel

    var body: some View {
        DayTimelineScreen(model: model)
            .tint(Theme.accent)
    }
}
