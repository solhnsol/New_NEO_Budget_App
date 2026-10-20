import SwiftUI

/// Where the user picks the data the app shows. The choice is saved, so a launch from the home screen keeps it.
struct SettingsView: View {
    let model: AppModel
    @Environment(\.switchAppMode) private var switchAppMode
    @State private var confirming: AppMode?

    private var pinned: Bool { AppMode.isPinnedByLaunchArgument(ProcessInfo.processInfo.arguments) }

    var body: some View {
        List {
            Section {
                modeRow(.demo, title: "둘러보기", detail: "예시 일정과 지출로 앱을 살펴봐요", symbol: "sparkles")
                modeRow(.live, title: "내 데이터", detail: "내 캘린더 일정과 단축어로 받은 알림을 보여줘요", symbol: "person.crop.circle")
            } header: {
                Text("보여줄 데이터")
            } footer: {
                Text(pinned
                     ? "지금은 실행할 때 정한 모드로 열려 있어서, 여기서 바꿔도 다음 실행에는 적용되지 않아요."
                     : "언제든 바꿀 수 있어요. 바꿔도 지금까지 받은 알림은 지워지지 않아요.")
            }
            .onAllCardRow()
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
        .alert("내 데이터로 바꿀까요?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("바꾸기") { if let mode = confirming { switchAppMode(mode) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("캘린더 접근을 요청할 수 있어요. 예시 데이터는 따로 보관돼서 언제든 다시 볼 수 있어요.")
        }
    }

    private func modeRow(_ mode: AppMode, title: String, detail: String, symbol: String) -> some View {
        let selected = (model.isDemo ? AppMode.demo : .live) == mode
        return Button {
            guard !selected else { return }
            if mode == .live { confirming = mode } else { switchAppMode(mode) }
        } label: {
            HStack(spacing: Theme.Space.m) {
                IconTile(systemName: symbol, tint: selected ? Theme.accent : Theme.textSecondary)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold) }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
