import NEOBudgetCalendar
import NEOBudgetCore
import SwiftUI

/// 분석: where my money went in a month, as my share only. Refunds and settlements already received are taken out; what friends still owe is
/// taken out in advance and shown as "정산 대기 중". Each group opens to the transactions behind it.
struct AnalysisScreen: View {
    let model: AppModel
    let onClose: () -> Void
    @State private var snapshot: AnalysisSnapshot?
    @State private var failed = false
    @State private var month: AnalysisMonth?

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot {
                    AnalysisHome(model: model, snapshot: snapshot, month: Binding(get: { month ?? AnalysisMonth(snapshot.today) }, set: { month = $0 }))
                } else if failed {
                    ContentUnavailableView("거래를 불러오지 못했어요", systemImage: "exclamationmark.circle", description: Text("잠시 뒤에 다시 열어 주세요."))
                } else {
                    ProgressView("분석하고 있어요").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.background)
            .tint(Theme.accent)
            .navigationTitle("분석")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("닫기", action: onClose) } }
        }
        .task(id: [model.dataGeneration, model.overrideRevision, model.recurringRevision]) {
            if let loaded = await AnalysisSnapshot.load(model) { snapshot = loaded } else if snapshot == nil { failed = true }
        }
    }
}

private struct AnalysisHome: View {
    let model: AppModel
    let snapshot: AnalysisSnapshot
    @Binding var month: AnalysisMonth

    private var isCurrent: Bool { month == AnalysisMonth(snapshot.today) }
    private var period: AnalysisPeriod? { snapshot.period(year: month.year, month: month.month) }
    private var through: LocalDate { isCurrent ? snapshot.today : (period?.last ?? snapshot.today) }

    var body: some View {
        ScrollView {
            if let period {
                VStack(spacing: Theme.Space.l) {
                    monthSwitcher
                    let summary = SpendingAnalysis.summary(snapshot.rows, in: period, through: through)
                    if summary.transactionCount == 0 {
                        ContentUnavailableView("이 달에는 쓴 돈이 없어요", systemImage: "wonsign.circle").padding(.top, Theme.Space.xxl)
                    } else {
                        heroCard(summary, period)
                        dailyCard(period, summary)
                        recurringCard(summary)
                        categoryCard(period)
                        tagCard(period)
                        activityCard(period)
                        gatheringCard(period)
                        personCard(period)
                    }
                }
                .padding(.horizontal, Theme.Space.l).padding(.bottom, Theme.Space.xxl)
            }
        }
        .scrollIndicators(.hidden)
        .animation(.snappy(duration: 0.28), value: month)
    }

    // MARK: Month

    private var monthSwitcher: some View {
        HStack {
            Button { month = month.moved(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("이전 달")
            Spacer()
            Text(month.title).font(Theme.Typo.title).foregroundStyle(Theme.textPrimary).contentTransition(.numericText())
            Spacer()
            Button { month = month.moved(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(isCurrent).accessibilityLabel("다음 달")
        }
        .font(.body.weight(.semibold))
    }

    // MARK: Cards

    private func heroCard(_ summary: SpendingSummary, _ period: AnalysisPeriod) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            AmountHero(label: isCurrent ? "이번 달 내가 쓴 돈" : "\(month.shortTitle)에 내가 쓴 돈", amount: AnalysisText.won(summary.totalMinorUnits))
                .contentTransition(.numericText())
            if summary.pendingMinorUnits > 0 {
                HStack(spacing: Theme.Space.s) {
                    StatusBadge(text: "정산 대기 중", tone: .caution)
                    Text("\(AnalysisText.won(summary.pendingMinorUnits))은 이미 뺀 금액이에요").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            HStack(spacing: Theme.Space.s) {
                StatTile(label: "하루 평균", value: AnalysisText.won(summary.dailyAverageMinorUnits))
                StatTile(label: "쓴 횟수", value: "\(summary.transactionCount)번")
            }
            if let versus = try? SpendingAnalysis.versusEarlier(snapshot.rows, period: period, through: through) {
                Text(AnalysisText.comparison(current: versus.current, earlier: versus.earlier))
                    .font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func dailyCard(_ period: AnalysisPeriod, _ summary: SpendingSummary) -> some View {
        var perDay: [Int: Int64] = [:]
        for row in SpendingAnalysis.inPeriod(snapshot.rows, period) { perDay[row.date.day, default: 0] += row.shareMinorUnits }
        let lastDay = min(through, period.last).day
        let bars = (1...max(1, lastDay)).map { day in
            BarsChart.Bar(id: day, label: "\(day)일", readout: "\(month.shortTitle) \(day)일", value: perDay[day] ?? 0)
        }
        return AnalysisCard(title: "날마다 쓴 돈") {
            BarsChart(
                bars: bars, highlighted: isCurrent ? snapshot.today.day : nil, average: summary.dailyAverageMinorUnits,
                axisLabels: Array(stride(from: 1, through: max(1, lastDay), by: 7))
            )
        }
    }

    private func recurringCard(_ summary: SpendingSummary) -> some View {
        let waiting = snapshot.suggestions(model.recurringDecisions).count
        return NavigationLink {
            RecurringView(model: model, snapshot: snapshot)
        } label: {
            AnalysisCard(title: "고정비와 변동비", trailing: waiting > 0 ? "확인할 게 \(waiting)개" : "정기 지출 보기") {
                let total = max(1, summary.totalMinorUnits)
                let fixedFraction = Double(max(0, summary.recurringMinorUnits)) / Double(total)
                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        Capsule().fill(Theme.accent).frame(width: max(0, proxy.size.width * fixedFraction - 1.5))
                        Capsule().fill(Theme.accent.opacity(0.3))
                    }
                }
                .frame(height: 10)
                HStack {
                    legend("고정비", summary.recurringMinorUnits, solid: true)
                    Spacer()
                    legend("그 밖의 지출", summary.oneOffMinorUnits, solid: false)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func legend(_ title: String, _ amount: Int64, solid: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Circle().fill(Theme.accent.opacity(solid ? 1 : 0.3)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                Text(AnalysisText.won(amount)).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private func categoryCard(_ period: AnalysisPeriod) -> some View {
        let groups = SpendingAnalysis.byCategory(snapshot.rows, in: period).filter { $0.totalMinorUnits > 0 }
        return rankedCard("어디에 썼나요", groups.prefix(6), id: \.key) { group, top in
            NavigationLink {
                AnalysisDetailView(model: model, snapshot: snapshot, month: $month, title: AnalysisText.category(group.key),
                                   symbol: AnalysisText.categorySymbol(group.key)) { $0.category == group.key }
            } label: {
                RankRow(symbol: AnalysisText.categorySymbol(group.key), title: AnalysisText.category(group.key), detail: "\(group.count)번",
                        amount: group.totalMinorUnits, fraction: Double(group.totalMinorUnits) / Double(top), pending: group.pendingMinorUnits)
            }
        }
    }

    private func tagCard(_ period: AnalysisPeriod) -> some View {
        let groups = SpendingAnalysis.byTag(snapshot.rows, in: period).filter { $0.key != nil && $0.totalMinorUnits > 0 }
        return VStack(spacing: Theme.Space.s) {
            if groups.isEmpty {
                AnalysisCard(title: "태그별로 보면") {
                    Text("거래나 일정에 #태그를 붙이면 여기서 모아 볼 수 있어요.").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
                }
            } else {
                rankedCard("태그별로 보면", groups.prefix(6), id: \.key) { group, top in
                    NavigationLink {
                        AnalysisDetailView(model: model, snapshot: snapshot, month: $month, title: "#" + (group.key ?? ""), symbol: "number") { $0.tags.contains(group.key ?? "") }
                    } label: {
                        RankRow(symbol: "number", title: "#" + (group.key ?? ""), detail: "\(group.count)번", amount: group.totalMinorUnits,
                                fraction: Double(group.totalMinorUnits) / Double(top), pending: group.pendingMinorUnits)
                    }
                }
                Text("태그가 둘인 거래는 두 곳에 모두 들어가요.").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Theme.Space.s)
            }
            NavigationLink { TagManagementView(model: model, snapshot: snapshot) } label: {
                HStack { Label("태그 관리", systemImage: "tag"); Spacer(); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary) }
                    .font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).padding(Theme.Space.l)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func activityCard(_ period: AnalysisPeriod) -> some View {
        let groups = SpendingAnalysis.byActivity(snapshot.rows, in: period).filter { $0.totalMinorUnits > 0 }
        return rankedCard("어떤 약속에 썼나요", groups.prefix(6), id: \.title) { group, top in
            NavigationLink {
                let key = RecurringDetector.normalize(group.title)
                AnalysisDetailView(model: model, snapshot: snapshot, month: $month, title: group.title, symbol: "calendar") {
                    $0.activity.map { RecurringDetector.normalize($0.title) == key } ?? false
                }
            } label: {
                RankRow(symbol: group.isGathering ? "person.2" : "calendar", title: group.title,
                        detail: group.occurrences > 1 ? "\(group.occurrences)번 · 한 번에 \(AnalysisText.won(group.perOccurrenceMinorUnits))" : "한 번",
                        amount: group.totalMinorUnits, fraction: Double(group.totalMinorUnits) / Double(top))
            }
        }
    }

    @ViewBuilder
    private func gatheringCard(_ period: AnalysisPeriod) -> some View {
        let summary = SpendingAnalysis.gatherings(snapshot.rows, in: period)
        if summary.count > 0 {
            NavigationLink {
                AnalysisDetailView(model: model, snapshot: snapshot, month: $month, title: "모임", symbol: "person.2") { $0.activity?.isGathering == true }
            } label: {
                AnalysisCard(title: "모임에 쓴 돈", trailing: "\(summary.count)번") {
                    Text(AnalysisText.won(summary.totalMinorUnits)).font(Theme.Typo.hero).foregroundStyle(Theme.textPrimary)
                    HStack(spacing: Theme.Space.s) {
                        StatTile(label: "한 번에", value: AnalysisText.won(summary.perGatheringMinorUnits))
                        StatTile(label: "한 사람당", value: AnalysisText.won(summary.perPersonMinorUnits))
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func personCard(_ period: AnalysisPeriod) -> some View {
        let groups = SpendingAnalysis.byPerson(snapshot.rows, in: period, excluding: snapshot.me).filter { $0.totalMinorUnits > 0 }
        if !groups.isEmpty {
            rankedCard("누구와 썼나요", groups.prefix(6), id: \.personID, footer: "함께한 약속에 쓴 돈 전부예요. 여럿이 함께한 약속은 사람마다 겹쳐서 세요.") { group, top in
                let name = snapshot.people[group.personID] ?? "알 수 없음"
                NavigationLink {
                    AnalysisDetailView(model: model, snapshot: snapshot, month: $month, title: name, symbol: "person", avatar: name) {
                        $0.activity?.participants.contains(group.personID) == true
                    }
                } label: {
                    RankRow(symbol: nil, title: name, detail: "\(group.activityCount)번 함께", amount: group.totalMinorUnits,
                            fraction: Double(group.totalMinorUnits) / Double(top), avatar: name)
                }
            }
        }
    }

    /// A card of ranked rows, each scaled against the biggest.
    private func rankedCard<Group, ID: Hashable, Row: View>(
        _ title: String, _ groups: ArraySlice<Group>, id: KeyPath<Group, ID>, footer: String? = nil, @ViewBuilder row: @escaping (Group, Int64) -> Row
    ) -> some View {
        let top = max(1, groups.map { ($0 as? any AnalysisAmount)?.amountForBar ?? 0 }.max() ?? 1)
        return AnalysisCard(title: title) {
            VStack(spacing: Theme.Space.l) { ForEach(groups, id: id) { row($0, top) } }
            if let footer { Text(footer).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary) }
        }
    }
}

/// Lets the ranked card scale its bars without knowing what kind of group it holds.
protocol AnalysisAmount { var amountForBar: Int64 { get } }

extension AnalysisGroup: AnalysisAmount { var amountForBar: Int64 { totalMinorUnits } }
extension ActivityGroup: AnalysisAmount { var amountForBar: Int64 { totalMinorUnits } }
extension PersonGroup: AnalysisAmount { var amountForBar: Int64 { totalMinorUnits } }
