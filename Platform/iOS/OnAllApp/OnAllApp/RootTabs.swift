import SwiftUI
import UIKit

/// The app's three bottom tabs: 캘린더 (the ledger list lives inside it as a toggle), 분석, 더보기.
struct RootTabs: View {
    let model: AppModel
    @State private var selection = Tab.calendar

    enum Tab: Hashable { case calendar, analysis, more }

    init(model: AppModel) {
        self.model = model
        // Design spec: 11px 500 labels, inactive #8B95A1, active #191F28 600 (the tint stays blue elsewhere).
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            item.normal.iconColor = UIColor(Theme.textTertiary)
            item.normal.titleTextAttributes = [.foregroundColor: UIColor(Theme.textTertiary), .font: UIFont.systemFont(ofSize: 11, weight: .medium)]
            item.selected.iconColor = UIColor(Theme.textPrimary)
            item.selected.titleTextAttributes = [.foregroundColor: UIColor(Theme.textPrimary), .font: UIFont.systemFont(ofSize: 11, weight: .semibold)]
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $selection) {
            DayTimelineScreen(model: model)
                .tabItem { Label("캘린더", systemImage: "calendar") }
                .tag(Tab.calendar)
            AnalysisScreen(model: model)
                .tabItem { Label("분석", systemImage: "chart.pie") }
                .tag(Tab.analysis)
            MoreScreen(model: model)
                .tabItem { Label("더보기", systemImage: "ellipsis") }
                .tag(Tab.more)
        }
        .tint(Theme.accent)
    }
}

/// 더보기: settings for now; the rest of the screen comes from its own area.
struct MoreScreen: View {
    let model: AppModel

    var body: some View {
        NavigationStack { SettingsView(model: model, embedded: true) }
    }
}
