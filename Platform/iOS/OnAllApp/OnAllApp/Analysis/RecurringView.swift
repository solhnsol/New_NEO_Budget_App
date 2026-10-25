import NEOBudgetCalendar
import SwiftUI

/// 정기 지출: the app suggests expenses that repeat on a fixed cycle (rent, phone, subscriptions); the user says yes or no, and that answer is kept.
/// Only a fixed cycle counts, so a café visited often is not suggested.
struct RecurringView: View {
    let model: AppModel
    let snapshot: AnalysisSnapshot

    private var decisions: RecurringDecisions { model.recurringDecisions }

    var body: some View {
        let suggestions = snapshot.suggestions(decisions)
        List {
            Section {
                AmountHero(label: "한 달 고정비", amount: AnalysisText.won(decisions.perMonthMinorUnits),
                           note: decisions.confirmed.isEmpty ? "맞다고 확인한 정기 지출을 한 달 기준으로 더해요" : "\(decisions.confirmed.count)개를 한 달 기준으로 더했어요")
            }
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.key) { series in suggestion(series) }
                } header: { Text("정기 지출이 맞나요?") } footer: { Text("같은 이름으로 같은 주기에 비슷한 금액이 나간 거래예요.") }
                .onAllCardRow()
            }
            if !decisions.confirmed.isEmpty {
                Section("정기 지출") {
                    ForEach(decisions.confirmed, id: \.key) { series in confirmed(series) }
                }
                .onAllCardRow()
            }
            if suggestions.isEmpty && decisions.confirmed.isEmpty {
                Section {
                    Text("아직 찾은 정기 지출이 없어요. 같은 곳에 같은 주기로 두세 번 나가면 여기에 알려 드려요.").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                }
                .onAllCardRow()
            }
            if !decisions.dismissedKeys.isEmpty {
                Section {
                    ForEach(decisions.dismissedKeys.sorted(), id: \.self) { key in
                        HStack {
                            Text(key).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button("다시 보기") { model.decideRecurring { $0.dismissedKeys.remove(key) } }.buttonStyle(.onAllSecondary)
                        }
                    }
                } header: { Text("아니라고 한 것") }
                .onAllCardRow()
            }
        }
        .onAllGroupedScreen()
        .animation(.snappy(duration: 0.25), value: model.recurringRevision)
        .navigationTitle("정기 지출")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func suggestion(_ series: RecurringSeries) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            summary(series)
            HStack(spacing: Theme.Space.s) {
                Button("아니에요") { model.decideRecurring { $0.dismiss(series) } }.buttonStyle(.onAllSecondary)
                Button("맞아요") { model.decideRecurring { $0.confirm(series) } }
                    .buttonStyle(.onAllSecondary).foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private func confirmed(_ series: RecurringSeries) -> some View {
        HStack(alignment: .center) {
            summary(series)
            Button("해제") { model.decideRecurring { $0.dismiss(series) } }.buttonStyle(.onAllSecondary)
        }
    }

    private func summary(_ series: RecurringSeries) -> some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemName: "arrow.triangle.2.circlepath")
            VStack(alignment: .leading, spacing: 3) {
                Text(series.displayName).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text("\(Self.cycleTitle(series.cycle)) · \(series.isVariableAmount ? "약 " : "")\(AnalysisText.won(series.expectedMinorUnits))")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                Text("다음엔 \(series.nextDue.month)월 \(series.nextDue.day)일쯤이에요").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    static func cycleTitle(_ cycle: RecurringCycle) -> String {
        switch cycle {
        case .weekly: "매주"
        case .biweekly: "2주마다"
        case .monthly: "매달"
        case .yearly: "매년"
        }
    }
}
