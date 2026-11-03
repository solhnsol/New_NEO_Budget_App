import NEOBudgetCalendar
import SwiftUI
import UniformTypeIdentifiers

/// Where the user picks the data the app shows. The choice is saved, so a launch from the home screen keeps it.
struct SettingsView: View {
    let model: AppModel
    /// In the 더보기 tab the screen draws its own big title; opened from the calendar menu it keeps the navigation bar (with 닫기).
    var embedded = false
    @Environment(\.switchAppMode) private var switchAppMode
    @State private var confirming: AppMode?
    @State private var choosingFile = false
    @State private var imported: ImportSummary?
    @State private var importFailed = false
    @AppStorage(SurplusSetting.key) private var surplusRaw = SurplusTreatment.income.rawValue
    @AppStorage(QuietHours.enabledKey) private var quietEnabled = false
    @AppStorage(QuietHours.startKey) private var quietStart = QuietHours.defaultStart
    @AppStorage(QuietHours.endKey) private var quietEnd = QuietHours.defaultEnd
    @State private var openKind: NotificationKind?
    @State private var accountCount: Int?

    var body: some View {
        List {
            if embedded {
                Text("더보기").font(Theme.Typo.h1).foregroundStyle(Theme.textPrimary)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            Section {
                Picker("보여줄 데이터", selection: modeBinding) {
                    Text("둘러보기").tag(AppMode.demo)
                    Text("내 데이터").tag(AppMode.live)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("정산보다 더 받은 돈").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Picker("정산보다 더 받은 돈", selection: $surplusRaw) {
                        Text("수입").tag(SurplusTreatment.income.rawValue)
                        Text("차감").tag(SurplusTreatment.reduceSpending.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
            .onAllCardRow()
            Section {
                NavigationLink { ShortcutsView(model: model) } label: {
                    MoreRowLabel(symbol: "bolt.fill", tint: Theme.CalendarTint.orange.color, title: "단축어", value: model.isDemo ? nil : "연결됨")
                }
                Button { choosingFile = true } label: {
                    HStack {
                        MoreRowLabel(symbol: "tray.and.arrow.down", tint: Theme.CalendarTint.green.color, title: "가져오기·내보내기")
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.disabled)
                    }
                }
                .buttonStyle(.onAllRow)
                .disabled(model.isDemo)
            } header: { MoreSectionTitle("데이터") }
            .onAllCardRow()
            Section {
                ForEach(NotificationKind.allCases) { kind in
                    NotificationToggleRow(kind: kind) { openKind = kind }
                }
                NavigationLink { QuietHoursView() } label: {
                    MoreRowLabel(symbol: "bell", title: "방해 금지", value: quietEnabled ? QuietHours.summary(start: quietStart, end: quietEnd) : "꺼짐")
                }
            } header: { MoreSectionTitle("알림") }
            .onAllCardRow()
            Section {
                NavigationLink { CalendarSettingsView(model: model) } label: {
                    MoreRowLabel(symbol: "calendar", tint: Theme.accent, title: "캘린더", value: "\(model.calendars.count)개")
                }
                NavigationLink { TransactionRulesView(model: model) } label: {
                    MoreRowLabel(symbol: "tag", tint: Theme.CalendarTint.purple.color, title: "분류 규칙", value: "\(model.transactionOverrides.rules.count)개")
                }
                NavigationLink { AccountsView(model: model).navigationTitle("계좌·카드").navigationBarTitleDisplayMode(.inline) } label: {
                    MoreRowLabel(symbol: "creditcard", tint: Theme.CalendarTint.teal.color, title: "계좌·카드", value: accountCount.map { "\($0)개" })
                }
            } header: { MoreSectionTitle("가계부") }
            .onAllCardRow()
        }
        .navigationDestination(item: $openKind) { NotificationKindView(kind: $0) }
        .task(id: model.dataGeneration) { accountCount = await model.registeredAccounts().count }
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
        .onAllGroupedScreen()
        .toolbar(embedded ? .hidden : .automatic, for: .navigationBar)
        .navigationTitle("더보기")
        .alert("내 데이터로 바꿀까요?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("바꾸기") { if let mode = confirming { switchAppMode(mode) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("캘린더 접근을 요청할 수 있어요. 예시 데이터는 따로 보관돼서 언제든 다시 볼 수 있어요.")
        }
    }

    private var modeBinding: Binding<AppMode> {
        Binding(
            get: { model.isDemo ? .demo : .live },
            set: { mode in
                guard mode != (model.isDemo ? .demo : .live) else { return }
                if mode == .live { confirming = mode } else { switchAppMode(mode) }
            }
        )
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
}

/// A notification type on the main screen: its icon and name open the detail screen, the switch turns it on or off.
private struct NotificationToggleRow: View {
    let kind: NotificationKind
    let open: () -> Void
    @AppStorage private var isOn: Bool

    init(kind: NotificationKind, open: @escaping () -> Void) {
        self.kind = kind
        self.open = open
        _isOn = AppStorage(wrappedValue: kind.defaultOn, kind.storageKey)
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button(action: open) { MoreRowLabel(symbol: kind.symbol, tint: kind.tint, title: kind.title).contentShape(Rectangle()) }
                .buttonStyle(.onAllRow)
            Toggle(kind.title, isOn: $isOn).labelsHidden()
            Button(action: open) { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.disabled) }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
        }
    }
}
