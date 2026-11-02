import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// One category, tag, appointment or person: what it came to this month, how it moved over the last months, and the transactions behind it.
struct AnalysisDetailView: View {
    let model: AppModel
    let snapshot: AnalysisSnapshot
    @Binding var month: AnalysisMonth
    let title: String
    let symbol: String
    var avatar: String?
    let includes: (AnalysisTransaction) -> Bool

    init(model: AppModel, snapshot: AnalysisSnapshot, month: Binding<AnalysisMonth>, title: String, symbol: String, avatar: String? = nil,
         includes: @escaping (AnalysisTransaction) -> Bool) {
        self.model = model
        self.snapshot = snapshot
        _month = month
        self.title = title
        self.symbol = symbol
        self.avatar = avatar
        self.includes = includes
    }

    private var period: AnalysisPeriod? { snapshot.period(year: month.year, month: month.month) }

    var body: some View {
        let rows = snapshot.rows.filter(includes)
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                if let period {
                    let summary = SpendingAnalysis.summary(rows, in: period)
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack(spacing: Theme.Space.m) {
                            if let avatar { PersonAvatar(name: avatar, size: 36) } else { IconTile(systemName: symbol, size: 36) }
                            Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textSecondary)
                        }
                        AmountHero(label: "\(month.title)에 쓴 돈", amount: AnalysisText.won(summary.totalMinorUnits))
                        if summary.pendingMinorUnits > 0 {
                            HStack(spacing: Theme.Space.s) {
                                StatusBadge(text: "정산 대기 중", tone: .caution)
                                Text("\(AnalysisText.won(summary.pendingMinorUnits))은 이미 뺀 금액이에요").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        HStack(spacing: Theme.Space.s) {
                            StatTile(label: "쓴 횟수", value: "\(summary.transactionCount)번")
                            StatTile(label: "한 번에 평균", value: AnalysisText.won(summary.averageMinorUnits))
                        }
                    }
                    .padding(Theme.Space.xl).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                    AnalysisCard(title: "최근 6개월") {
                        let bars = (-5...0).enumerated().map { index, offset in
                            let m = month.moved(by: offset)
                            return BarsChart.Bar(id: index, label: m.shortTitle, readout: m.title, value: total(rows, in: m))
                        }
                        BarsChart(bars: bars, highlighted: 5, average: nil, axisLabels: Array(0..<6))
                    }

                    let list = SpendingAnalysis.inPeriod(rows, period).sorted { ($0.date, $0.id) > ($1.date, $1.id) }
                    AnalysisCard(title: "\(month.shortTitle) 내역", trailing: "\(list.count)번") {
                        if list.isEmpty {
                            Text("이 달에는 쓴 돈이 없어요.").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                        }
                        VStack(spacing: Theme.Space.l) {
                            ForEach(list, id: \.id) { row in
                                if let entry = snapshot.entriesByID[LedgerEntryID(rawValue: row.id)] {
                                    NavigationLink { TransactionDetailView(entry: entry, model: model) } label: { line(row, entry) }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.l).padding(.bottom, Theme.Space.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func total(_ rows: [AnalysisTransaction], in month: AnalysisMonth) -> Int64 {
        guard let period = snapshot.period(year: month.year, month: month.month) else { return 0 }
        return SpendingAnalysis.inPeriod(rows, period).reduce(0) { $0 + $1.shareMinorUnits }
    }

    private func line(_ row: AnalysisTransaction, _ entry: LedgerListEntry) -> some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemName: AnalysisText.categorySymbol(row.category), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.transaction.title ?? "이름 없는 거래").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(Formatting.dayTitle(row.date)).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(AnalysisText.won(row.shareMinorUnits)).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
                if row.pendingMinorUnits > 0 { StatusBadge(text: "정산 대기 \(AnalysisText.won(row.pendingMinorUnits))", tone: .caution) }
            }
        }
        .contentShape(Rectangle())
    }
}
