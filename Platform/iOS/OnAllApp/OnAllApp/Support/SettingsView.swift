import NEOBudgetCalendar
import SwiftUI
import UniformTypeIdentifiers

/// Where the user picks the data the app shows. The choice is saved, so a launch from the home screen keeps it.
struct SettingsView: View {
    let model: AppModel
    @Environment(\.switchAppMode) private var switchAppMode
    @State private var confirming: AppMode?
    @State private var choosingFile = false
    @State private var imported: ImportSummary?
    @State private var importFailed = false
    @AppStorage(SurplusSetting.key) private var surplusRaw = SurplusTreatment.income.rawValue

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
            Section {
                NavigationLink {
                    CalendarSettingsView(model: model)
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        IconTile(systemName: "calendar", tint: Theme.accent)
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            Text("캘린더").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                            Text("캘린더 추가·삭제, 아이콘 정하기").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .onAllCardRow()
            Section {
                surplusRow(.income, title: "별도 수입으로 기록", detail: "더 받은 돈은 지출을 줄이지 않고 수입으로 따로 기록해요")
                surplusRow(.reduceSpending, title: "그 지출에서 차감", detail: "수입 분류를 만들지 않고, 더 받은 만큼 그 지출의 내 몫을 줄여요")
            } header: {
                Text("정산보다 더 받은 돈")
            } footer: {
                Text("친구가 받을 돈보다 많이 보냈을 때 남는 금액을 어떻게 셀지 정해요. 통장 내역은 그대로예요.")
            }
            .onAllCardRow()
            Section {
                Button { choosingFile = true } label: {
                    HStack(spacing: Theme.Space.m) {
                        IconTile(systemName: "tray.and.arrow.down", tint: Theme.accent)
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            Text("가계부 파일 가져오기").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                            Text("Actual Budget에서 내보낸 imported-history.json을 골라요").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .disabled(model.isDemo)
            } header: {
                Text("지난 가계부")
            } footer: {
                Text(model.isDemo
                     ? "'내 데이터'로 바꾼 뒤에 가져올 수 있어요."
                     : "가져온 뒤에는 파일 앱에서 원본 파일을 지워 주세요. 다시 가져오면 같은 거래가 두 번 세어지지 않아요.")
            }
            .onAllCardRow()
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
            Task { await importFile(result) }
        }
        .alert("가져왔어요", isPresented: Binding(get: { imported != nil }, set: { if !$0 { imported = nil } }), presenting: imported) { _ in
            // The calendar side starts from the imported settlements, so the model is opened again.
            Button("확인") { switchAppMode(.live) }
        } message: { summary in
            Text(summarize(summary))
        }
        .alert("가져오지 못했어요", isPresented: $importFailed) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("imported-history.json 파일이 맞는지 확인해 주세요.")
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

    private func summarize(_ summary: ImportSummary) -> String {
        var lines = ["거래 \(summary.rows)건, 계좌 \(summary.accounts)개를 가져왔고 정리할 거래는 \(summary.pending)건이에요."]
        if !summary.mismatchedAccounts.isEmpty {
            lines.append("잔액이 가계부 앱과 다른 계좌: " + summary.mismatchedAccounts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private func importFile(_ result: Result<URL, Error>) async {
        guard case let .success(url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let summary = await model.importHistory(data) else {
            importFailed = true
            return
        }
        imported = summary
    }

    private func surplusRow(_ treatment: SurplusTreatment, title: String, detail: String) -> some View {
        let selected = surplusRaw == treatment.rawValue
        return Button { surplusRaw = treatment.rawValue } label: {
            HStack(spacing: Theme.Space.m) {
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
