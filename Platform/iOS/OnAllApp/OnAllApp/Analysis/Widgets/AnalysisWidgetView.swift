import SwiftUI

/// One widget drawn at its real size (the same view the gallery previews and, later, a home-screen widget would use).
/// Money spent is blue; a waiting settlement is only ever labeled "정산 대기 중".
struct AnalysisWidgetView: View {
    let spec: WidgetSpec
    let data: AnalysisWidgetData
    let size: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            content
        }
        .padding(Theme.Space.l)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch (spec.topic, spec.style) {
        case (.week, .bars): header("이번 주", "하루 평균 \(short(data.weekAverage))"); MiniBars(points: data.week, highlight: data.weekToday)
        case (.week, .line): header("이번 주", "하루 평균 \(short(data.weekAverage))"); MiniLine(points: data.week, highlight: data.weekToday)
        case (.week, .barsList):
            header("이번 주", "하루 평균 \(short(data.weekAverage))")
            MiniBars(points: data.week, highlight: data.weekToday)
            lines(data.weekTopDays, limit: 3)
        case (.week, _): number("이번 주 쓴 돈", data.weekTotal, foot: "하루 평균 \(short(data.weekAverage))", blue: true)
        case (.monthTrend, .line): header("월별 추이", "6개월"); MiniLine(points: data.months, highlight: data.months.count - 1)
        case (.monthTrend, _):
            header("월별 추이", "6개월")
            MiniBars(points: data.months, highlight: data.months.count - 1)
            if spec.size == .large {
                HStack { Text("\(data.monthLabel) 쓴 돈").foregroundStyle(Theme.textSecondary); Spacer(); Text(AnalysisText.won(data.spent)).foregroundStyle(Theme.accent) }
                    .font(Theme.Typo.rowTitle)
            }
        case (.category, .top): categoryTop
        case (.category, _): header("분류별", nil); lines(data.categories, limit: spec.size == .large ? 5 : 3, bars: true)
        case (.activity, _): header("쓴 돈이 큰 일정", nil); lines(data.activities, limit: spec.size == .large ? 4 : 2)
        case (.spent, _): number("\(data.monthLabel) 쓴 돈", data.spent, foot: data.pending > 0 ? "정산 대기 중 \(AnalysisText.won(data.pending))" : nil, blue: true)
        case (.fixed, _): number("고정 지출", data.fixed, foot: data.monthLabel, blue: false)
        case (.pending, .list): header("정산 받을 돈", short(data.pending)); lines(data.pendingLines, limit: 2, showAmountInBlue: false)
        case (.pending, _): number("정산 받을 돈", data.pending, foot: data.pendingLines.isEmpty ? nil : "\(data.pendingLines.count)건 진행 중", blue: false)
        }
    }

    private func short(_ won: Int64) -> String { BarsChart.short(won) }

    private func header(_ title: String, _ trailing: String?) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Space.s)
            if let trailing { Text(trailing).foregroundStyle(Theme.textSecondary) }
        }
        .font(Theme.Typo.label).lineLimit(1)
    }

    private func number(_ title: String, _ won: Int64, foot: String?, blue: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            Text(AnalysisText.won(won)).font(Theme.Typo.hero).foregroundStyle(blue ? Theme.accent : Theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(foot ?? " ").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var categoryTop: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("가장 많이 쓴 곳").font(Theme.Typo.label).foregroundStyle(Theme.textSecondary)
            if let top = data.categories.first {
                IconTile(systemName: top.symbol ?? "tag")
                Spacer(minLength: 0)
                Text("\(top.title) \(short(top.won))").font(Theme.Typo.section).foregroundStyle(Theme.accent).lineLimit(1).minimumScaleFactor(0.6)
                Text("전체의 \(data.categoryTotal > 0 ? Int((Double(top.won) / Double(data.categoryTotal) * 100).rounded()) : 0)%")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            } else {
                Spacer(minLength: 0)
                Text("아직 없어요").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func lines(_ items: [AnalysisWidgetData.Line], limit: Int, bars: Bool = false, showAmountInBlue: Bool = true) -> some View {
        let shown = Array(items.prefix(limit))
        let top = max(1, shown.map(\.won).max() ?? 1)
        return VStack(spacing: Theme.Space.m) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                HStack(spacing: Theme.Space.m) {
                    if let symbol = item.symbol { IconTile(systemName: symbol) }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Spacer(minLength: Theme.Space.s)
                            Text(short(item.won)).font(Theme.Typo.amount).foregroundStyle(showAmountInBlue ? Theme.accent : Theme.textPrimary)
                        }
                        if bars {
                            Capsule().fill(Theme.fill).frame(height: 5)
                                .overlay(alignment: .leading) { GeometryReader { Capsule().fill(Theme.accent).frame(width: max(4, $0.size.width * Double(item.won) / Double(top))) } }
                        } else {
                            Text(item.detail).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                }
            }
            if shown.isEmpty { Text("아직 없어요").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

/// Seven or six bars with their labels; the highlighted one is solid, the rest soft.
private struct MiniBars: View {
    let points: [AnalysisWidgetData.Point]
    let highlight: Int

    var body: some View {
        let top = Double(max(1, points.map(\.won).max() ?? 1))
        VStack(spacing: Theme.Space.xs) {
            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: Theme.Space.s) {
                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(index == highlight ? Theme.accent : Theme.accent.opacity(0.22))
                            .frame(height: max(4, proxy.size.height * Double(max(0, point.won)) / top))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            HStack(spacing: Theme.Space.s) {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Text(point.label).font(.system(size: 10, weight: index == highlight ? .semibold : .regular))
                        .foregroundStyle(index == highlight ? Theme.textPrimary : Theme.textTertiary).frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minHeight: 60)
    }
}

private struct MiniLine: View {
    let points: [AnalysisWidgetData.Point]
    let highlight: Int

    var body: some View {
        let top = Double(max(1, points.map(\.won).max() ?? 1))
        VStack(spacing: Theme.Space.xs) {
            GeometryReader { proxy in
                let spots = points.enumerated().map { index, point in
                    CGPoint(x: points.count > 1 ? proxy.size.width * Double(index) / Double(points.count - 1) : 0,
                            y: proxy.size.height * (1 - Double(max(0, point.won)) / top))
                }
                Path { path in
                    for (index, spot) in spots.enumerated() { index == 0 ? path.move(to: spot) : path.addLine(to: spot) }
                }
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(Array(spots.enumerated()), id: \.offset) { index, spot in
                    Circle().fill(index == highlight ? Theme.accent : Theme.surface)
                        .overlay(Circle().stroke(Theme.accent, lineWidth: 1.5)).frame(width: 6, height: 6).position(spot)
                }
            }
            .padding(.vertical, 3)
            HStack {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Text(point.label).font(.system(size: 10, weight: index == highlight ? .semibold : .regular))
                        .foregroundStyle(index == highlight ? Theme.textPrimary : Theme.textTertiary).frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minHeight: 60)
    }
}
