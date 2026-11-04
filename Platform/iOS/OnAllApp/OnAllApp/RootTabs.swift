import SwiftUI
import UIKit

/// The app's three bottom tabs: 캘린더 (the ledger list lives inside it as a toggle), 분석, 더보기.
struct RootTabs: View {
    let model: AppModel
    @State private var selection = Tab.calendar

    enum Tab: Hashable { case calendar, analysis, more }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                DayTimelineScreen(model: model).tabLayer(selection == .calendar)
                AnalysisScreen(model: model).tabLayer(selection == .analysis)
                MoreScreen(model: model).tabLayer(selection == .more)
            }
            TabBar(selection: $selection)
        }
        .background(Theme.background)
        .tint(Theme.accent)
    }
}

private extension View {
    /// All three tabs stay alive (their scroll and state are kept); only the chosen one is seen and touched.
    func tabLayer(_ isOn: Bool) -> some View {
        opacity(isOn ? 1 : 0).allowsHitTesting(isOn).accessibilityHidden(!isOn)
    }
}

/// The flat bottom bar of the design: a hairline, three line icons with 11-point labels, the chosen one in the text color.
private struct TabBar: View {
    @Binding var selection: RootTabs.Tab

    private let items: [(tab: RootTabs.Tab, icon: String, title: String)] = [
        (.calendar, "cal", "캘린더"), (.analysis, "bars", "분석"), (.more, "dots", "더보기"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                let on = selection == item.tab
                Button { selection = item.tab } label: {
                    VStack(spacing: 3) {
                        LineIcon(name: item.icon)
                        Text(item.title).font(.onAll(size: 11, weight: on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10).padding(.bottom, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

/// 더보기: settings for now; the rest of the screen comes from its own area.
struct MoreScreen: View {
    let model: AppModel

    var body: some View {
        NavigationStack { SettingsView(model: model, embedded: true) }
    }
}
