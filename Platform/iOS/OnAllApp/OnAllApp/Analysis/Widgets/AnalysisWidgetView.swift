import SwiftUI

/// One widget drawn at its real size, like the matching iPhone widget (the gallery previews and, later, a home-screen widget use this same view).
/// Money spent is blue, money coming in is red, a waiting settlement is only ever labeled "정산 대기 중".
/// 오늘 쓸 수 있는 돈, 들어온 돈 and 일정별 have no data behind them yet and show fixed sample values.
struct AnalysisWidgetView: View {
    let spec: WidgetSpec
    let data: AnalysisWidgetData
    let size: CGSize

    /// Sample budget until the app keeps one.
    private static let budget: Int64 = 800_000
    private static let sampleBalance = "30,050원"
    private static let sampleIncome = "2,100,000원"
    private static let samplePeople: [(name: String, tint: Theme.CalendarTint, share: Double, won: String)] = [
        ("학교", .blue, 27, "11.1만"), ("약속", .orange, 52, "21.3만"), ("운동", .green, 9, "3.7만"), ("일정 없음", .blue, 12, "4.9만"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .combine)
    }

    private var budgetShare: Double { min(1, Double(data.spent) / Double(Self.budget)) }

    @ViewBuilder private var content: some View {
        switch (spec.topic, spec.style, spec.size) {
        case (.balance, _, .small):
            title("오늘 쓸 수 있는 돈"); Spacer(minLength: 0)
            value(Self.sampleBalance, size: 25, blue: true); meter(top: 10, bottom: 6)
            caption("예산 80만 중 \(short(data.spent))")
        case (.balance, _, _):
            title("오늘 쓸 수 있는 돈")
            value(Self.sampleBalance, size: 32, blue: true).padding(.top, 6); meter(top: 14, bottom: 8)
            HStack { Text("쓴 돈 \(short(data.spent))"); Spacer(); Text("예산 80만") }.font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
        case (.spent, _, _):
            title("이번 달 쓴 돈"); Spacer(minLength: 0)
            value(AnalysisText.won(data.spent), blue: true); caption("예산의 \(Int((budgetShare * 100).rounded()))%")
        case (.income, _, _):
            title("들어온 돈"); Spacer(minLength: 0)
            value(Self.sampleIncome, size: 18, color: Theme.income); caption("이번 달")
        case (.flow, _, _):
            title(data.monthLabel); Spacer(minLength: 0)
            HStack(spacing: 16) {
                flowColumn("쓴 돈", AnalysisText.won(data.spent), Theme.accent)
                Rectangle().fill(Theme.divider).frame(width: 1)
                flowColumn("들어온 돈", Self.sampleIncome, Theme.income)
            }
            .fixedSize(horizontal: false, vertical: true)
        case (.week, .number, _):
            title("이번 주 쓴 돈"); Spacer(minLength: 0)
            value(AnalysisText.won(data.weekTotal), blue: true); caption("하루 평균 \(short(data.weekAverage))")
        case (.week, .line, _):
            title("이번 주", trailing: "하루 평균 \(short(data.weekAverage))"); MiniLine(points: data.week, highlight: data.weekToday)
        case (.week, .barsList, _):
            title("이번 주", trailing: "하루 평균 \(short(data.weekAverage))"); MiniBars(points: data.week, highlight: data.weekToday)
            rows(data.weekTopDays, limit: 3, gap: 0).padding(.top, 10)
        case (.week, _, _):
            title("이번 주", trailing: "하루 평균 \(short(data.weekAverage))"); MiniBars(points: data.week, highlight: data.weekToday)
        case (.category, .top, _): categoryTop
        case (.category, _, _):
            title("분류별"); rows(data.categories, limit: spec.size == .large ? 5 : 3, bars: true, gap: spec.size == .large ? 10 : 0).padding(.top, spec.size == .large ? 6 : 4)
        case (.activity, _, _):
            title("쓴 돈이 큰 일정")
            eventCards(limit: spec.size == .large ? 4 : 2)
        case (.monthTrend, .line, _):
            title("월별 추이", trailing: "6개월"); MiniLine(points: data.months, highlight: data.months.count - 1)
        case (.monthTrend, _, .large):
            title("월별 추이", trailing: trend); MiniBars(points: data.months, highlight: data.months.count - 1)
            HStack { Text("\(data.monthLabel) 쓴 돈"); Spacer(); Text(AnalysisText.won(data.spent)).foregroundStyle(Theme.accent) }
                .font(Theme.Typo.rowTitle.weight(.medium)).foregroundStyle(Theme.textPrimary).padding(.top, 8)
        case (.monthTrend, _, _):
            title("월별 추이", trailing: "6개월"); MiniBars(points: data.months, highlight: data.months.count - 1)
        case (.calendar, _, _): calendarSplit
        case (.fixed, _, _):
            title("매달 나가는 돈"); Spacer(minLength: 0)
            value(AnalysisText.won(data.fixed)); caption(data.monthLabel)
        case (.pending, .list, _):
            title("정산 받을 돈", trailing: AnalysisText.won(data.pending)); pendingRows
        case (.pending, _, _):
            title("정산 받을 돈"); Spacer(minLength: 0)
            value(AnalysisText.won(data.pending)); caption(data.pendingLines.isEmpty ? "진행 중인 건 없어요" : "\(data.pendingLines.count)건 진행 중")
        }
    }

    private func short(_ won: Int64) -> String { BarsChart.short(won) }

    private var trend: String {
        guard data.months.count >= 2 else { return "" }
        let gap = data.months[data.months.count - 1].won - data.months[data.months.count - 2].won
        return "지난달보다 \(gap >= 0 ? "+" : "−")\(short(abs(gap)))"
    }

    // MARK: Pieces

    private func title(_ text: String, trailing: String? = nil) -> some View {
        HStack {
            Text(text)
            Spacer(minLength: 8)
            if let trailing { Text(trailing) }
        }
        .font(.onAll(size: 13, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1)
    }

    private func value(_ text: String, size: CGFloat = 24, blue: Bool = false, color: Color? = nil) -> some View {
        Text(text).font(.onAll(size: size, weight: .bold).monospacedDigit()).tracking(size >= 32 ? -1 : -0.6)
            .foregroundStyle(color ?? (blue ? Theme.accent : Theme.textPrimary)).lineLimit(1).minimumScaleFactor(0.5)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.onAll(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1).padding(.top, 4)
    }

    private func flowColumn(_ label: String, _ amount: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.onAll(size: 12)).foregroundStyle(Theme.textTertiary)
            value(amount, size: 22, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The meter under 오늘 쓸 수 있는 돈: spent so far, with a tick for where an even pace would be today.
    private func meter(top: CGFloat, bottom: CGFloat) -> some View {
        GeometryReader { proxy in
            Capsule().fill(Theme.fill)
                .overlay(alignment: .leading) { Capsule().fill(Theme.accent).frame(width: max(7, proxy.size.width * budgetShare)) }
                .overlay(alignment: .leading) { Capsule().fill(Theme.textPrimary).frame(width: 2, height: 13).offset(x: proxy.size.width * 0.54) }
                .frame(height: 7).frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 13).padding(.top, top - 3).padding(.bottom, bottom - 3)
    }

    private var categoryTop: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("가장 많이 쓴 곳")
            if let top = data.categories.first {
                tile(top.symbol ?? "tag", index: 0, side: 34).padding(.top, 10)
                Spacer(minLength: 0)
                Text("\(top.title) \(short(top.won))").font(.onAll(size: 20, weight: .bold)).foregroundStyle(Theme.accent).lineLimit(1).minimumScaleFactor(0.6)
                caption("전체의 \(data.categoryTotal > 0 ? Int((Double(top.won) / Double(data.categoryTotal) * 100).rounded()) : 0)%")
            } else {
                Spacer(minLength: 0)
                Text("아직 없어요").font(Theme.Typo.rowTitle).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// A category tile: the category's calendar-tint background (9%) with a gray line icon.
    private func tile(_ symbol: String, index: Int, side: CGFloat) -> some View {
        let tints: [Theme.CalendarTint] = [.orange, .blue, .green, .purple, .blue]
        return Group {
            if let line = Self.lineAsset[symbol] { LineIcon(name: line, size: side * 0.5) } else { Image(systemName: symbol).font(.system(size: side * 0.42, weight: .medium)) }
        }
        .foregroundStyle(Theme.textSecondary)
        .frame(width: side, height: side).background(tints[index % tints.count].soft, in: Circle())
    }

    private static let lineAsset = ["fork.knife": "bowl", "bag": "bag", "cup.and.saucer": "cup", "car": "train", "book": "book"]

    private func rows(_ items: [AnalysisWidgetData.Line], limit: Int, bars: Bool = false, gap: CGFloat) -> some View {
        let shown = Array(items.prefix(limit))
        let top = max(1, shown.map(\.won).max() ?? 1)
        return VStack(spacing: gap) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 10) {
                    tile(item.symbol ?? Self.dayIcon, index: index, side: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.onAll(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if bars {
                            Capsule().fill(Theme.fill).frame(height: 4)
                                .overlay(alignment: .leading) { GeometryReader { Capsule().fill(Theme.accent).frame(width: max(4, $0.size.width * Double(item.won) / Double(top))) } }
                        }
                    }
                    Spacer(minLength: 8)
                    Text(short(item.won)).font(.onAll(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.accent)
                }
                .padding(.vertical, 5)
            }
            if shown.isEmpty { Text("아직 없어요").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private static let dayIcon = "calendar"

    private func eventCards(limit: Int) -> some View {
        let tints: [Theme.CalendarTint] = [.orange, .orange, .blue, .blue]
        return VStack(spacing: spec.size == .large ? 10 : 6) {
            ForEach(Array(data.activities.prefix(limit).enumerated()), id: \.offset) { index, item in
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title).font(.onAll(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(item.detail).font(.onAll(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Text(AnalysisText.won(item.won)).font(.onAll(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(tints[index % tints.count].soft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
        .padding(.top, spec.size == .large ? 10 : 6)
    }

    private var pendingRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(data.pendingLines.prefix(2).enumerated()), id: \.offset) { _, item in
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title).font(.onAll(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(item.detail).font(.onAll(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Text(AnalysisText.won(item.won)).font(.onAll(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                }
                .padding(.vertical, 8)
            }
            if data.pendingLines.isEmpty { Text("진행 중인 건 없어요").font(Theme.Typo.label).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
        }
        .padding(.top, 8)
    }

    private var calendarSplit: some View {
        let large = spec.size == .large
        let items = Self.samplePeople
        return VStack(alignment: .leading, spacing: 0) {
            title("일정에 쓴 돈", trailing: "88%")
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Rectangle().fill(index == 3 ? Theme.disabled.opacity(0.6) : item.tint.color)
                            .frame(width: (proxy.size.width - 6) * item.share / 100)
                    }
                }
            }
            .frame(height: 14).clipShape(Capsule()).padding(.top, large ? 14 : 12).padding(.bottom, large ? 10 : 8)
            if large {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 8) {
                        Circle().fill(index == 3 ? Theme.disabled : item.tint.color).frame(width: 10, height: 10)
                        Text(item.name).font(.onAll(size: 14)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(item.won).font(.onAll(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.accent)
                    }
                    .padding(.vertical, 7)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 6) {
                            Circle().fill(index == 3 ? Theme.disabled : item.tint.color).frame(width: 8, height: 8)
                            Text(item.name).font(.onAll(size: 12)).foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 0)
                            Text(item.won).font(.onAll(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.accent)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

/// Seven or six bars with their labels; the highlighted one is solid, the rest soft.
private struct MiniBars: View {
    let points: [AnalysisWidgetData.Point]
    let highlight: Int

    var body: some View {
        let top = Double(max(1, points.map(\.won).max() ?? 1))
        HStack(alignment: .bottom, spacing: 7) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                VStack(spacing: 4) {
                    GeometryReader { proxy in
                        UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous)
                            .fill(index == highlight ? Theme.accent : Theme.accentLine)
                            .frame(width: min(26, proxy.size.width), height: max(6, proxy.size.height * Double(max(0, point.won)) / top))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                    Text(point.label).font(.onAll(size: 11, weight: index == highlight ? .semibold : .regular))
                        .foregroundStyle(index == highlight ? Theme.textPrimary : Theme.textTertiary)
                }
            }
        }
        .padding(.top, 8).frame(maxHeight: .infinity)
    }
}

private struct MiniLine: View {
    let points: [AnalysisWidgetData.Point]
    let highlight: Int

    var body: some View {
        let top = Double(max(1, points.map(\.won).max() ?? 1))
        VStack(spacing: 4) {
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
                    Text(point.label).font(.onAll(size: 11, weight: index == highlight ? .semibold : .regular))
                        .foregroundStyle(index == highlight ? Theme.textPrimary : Theme.textTertiary).frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 8).frame(maxHeight: .infinity)
    }
}
