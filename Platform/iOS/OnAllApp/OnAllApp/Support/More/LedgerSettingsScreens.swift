import NEOBudgetCalendar
import SwiftUI
import UniformTypeIdentifiers

/// 가져오기·내보내기: the JSON import is real; the CSV row and the tester export are looks until those exist.
struct DataTransferScreen: View {
    let model: AppModel
    @Environment(\.switchAppMode) private var switchAppMode
    @State private var choosingFile = false
    @State private var imported: ImportSummary?
    @State private var importFailed = false
    @State private var hides: [String: Bool] = [:]

    var body: some View {
        SettingsPage(title: "가져오기·내보내기") {
            SSection(title: "가져오기") {
                SRow(icon: "up", tone: .green, title: "CSV 파일")
                Button { choosingFile = true } label: { SRow(icon: "file", tone: .green, title: "imported-history.json") }
                    .buttonStyle(.onAllRow).disabled(model.isDemo)
            }
            SSection(title: "테스터용 내보내기") {
                ForEach(["금액 가리기", "이름 가리기", "계좌번호 가리기", "메모 가리기"], id: \.self) { title in
                    SToggleRow(title: title, isOn: Binding(get: { hides[title] ?? (title != "메모 가리기") }, set: { hides[title] = $0 }))
                }
            }
            SButton(title: "내보내기")
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in Task { await importFile(result) } }
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

/// 정산 설정: the surplus choice is stored (`SurplusSetting`); the rest is looks.
struct SettlementSettingsScreen: View {
    @AppStorage(SurplusSetting.key) private var surplusRaw = SurplusTreatment.income.rawValue
    @AppStorage(DayStartSetting.key) private var dayStart = DayStartSetting.defaultMinutes
    @State private var shortfall = 0
    @State private var days = 14
    @State private var remember = true

    var body: some View {
        SettingsPage(title: "정산 설정") {
            SSection(title: "하루 시작 시각") {
                ForEach(DayStartSetting.hours, id: \.self) { hour in
                    SRadioRow(title: hour == 0 ? "자정" : "오전 \(hour)시", isOn: dayStart == hour * 60) { dayStart = hour * 60 }
                }
            }
            SSection(title: "정산보다 더 받은 돈") {
                SRadioRow(title: "별도 수입으로 기록", isOn: surplusRaw == SurplusTreatment.income.rawValue) { surplusRaw = SurplusTreatment.income.rawValue }
                SRadioRow(title: "그 지출에서 차감", isOn: surplusRaw == SurplusTreatment.reduceSpending.rawValue) { surplusRaw = SurplusTreatment.reduceSpending.rawValue }
            }
            SSection(title: "정산이 부족할 때") {
                ForEach(Array(["매번 물어봐요", "남은 금액 계속 받기", "여기서 마무리"].enumerated()), id: \.offset) { index, title in
                    SRadioRow(title: title, isOn: shortfall == index) { shortfall = index }
                }
            }
            SSection(title: "기한") {
                SControlRow(title: "지연으로 표시") { SStepper(value: $days, unit: "일") }
                SToggleRow(title: "상대 이름 기억하기", isOn: $remember)
            }
        }
    }
}

/// 예산. Looks only: the app has no budgets yet.
struct BudgetScreen: View {
    private let rows: [(name: String, amount: String, percent: Double, warm: Bool)] = [
        ("식비", "400,000원", 0.72, false), ("카페", "80,000원", 0.9, true), ("교통", "120,000원", 0.44, false),
        ("쇼핑", "150,000원", 0.31, false), ("문화", "100,000원", 0.12, false),
    ]

    var body: some View {
        SettingsPage(title: "예산", action: ("저장", {})) {
            VStack(alignment: .leading, spacing: 2) {
                Text("이번 달 예산").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                Text("1,200,000원").font(Theme.Typo.hero).tracking(-1).foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 4)
            SSection(title: "분류별") {
                ForEach(rows, id: \.name) { row in
                    VStack(spacing: 6) {
                        HStack {
                            Text(row.name).font(.onAll(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(row.amount).font(.onAll(size: 15)).foregroundStyle(Theme.textTertiary)
                        }
                        GeometryReader { proxy in
                            Capsule().fill(Theme.divider).overlay(alignment: .leading) {
                                Capsule().fill(row.warm ? Theme.CalendarTint.orange.color : Theme.accent).frame(width: proxy.size.width * row.percent)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12).rowDivider(inset: 16)
                }
            }
            SCard { SRow(title: "시작일", value: "매월 1일", chevron: true) }.padding(.top, 12)
        }
    }
}
