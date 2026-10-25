import Charts
import NEOBudgetCalendar
import SwiftUI

/// A white card with a title: one subject per card (`docs/design-system.md`).
struct AnalysisCard<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(title).font(Theme.Typo.title).foregroundStyle(Theme.textPrimary)
                Spacer()
                if let trailing { Text(trailing).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary) }
            }
            content
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// One ranked line: what it is, how much, and a bar for its share of the biggest line (the bar says "compared with the top", the number says how much).
struct RankRow: View {
    let symbol: String?
    let title: String
    let detail: String
    let amount: Int64
    let fraction: Double
    var pending: Int64 = 0
    var avatar: String?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if let avatar { PersonAvatar(name: avatar, size: 40) } else if let symbol { IconTile(systemName: symbol) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    Text(AnalysisText.won(amount)).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary)
                }
                GeometryReader { proxy in
                    Capsule().fill(Theme.fill)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.accent).frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
                        }
                }
                .frame(height: 6)
                HStack {
                    Text(detail).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
                    if pending > 0 { StatusBadge(text: "정산 대기 \(AnalysisText.won(pending))", tone: .caution) }
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A rounded stat with a small gray label above its value.
struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            Text(value).font(Theme.Typo.amount).foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
    }
}

/// Bars over a run of values (days of a month, or recent months), one hue; the chosen bar is solid and the rest are softened.
/// A dashed rule marks the average. Dragging over the chart reads out the bar under the finger.
struct BarsChart: View {
    struct Bar: Identifiable, Equatable {
        let id: Int
        let label: String
        let readout: String
        let value: Int64
    }

    let bars: [Bar]
    var highlighted: Int?
    var average: Int64?
    var axisLabels: [Int]
    @State private var picked: Int?

    var body: some View {
        let focus = picked ?? highlighted
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Group {
                if let shown = bars.first(where: { $0.id == picked }) {
                    Text(shown.readout + " · " + AnalysisText.won(shown.value))
                } else {
                    Text(" ")
                }
            }
            .font(Theme.Typo.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
            Chart {
                ForEach(bars) { bar in
                    BarMark(x: .value("날", bar.id), y: .value("원", max(0, bar.value)), width: .fixed(bars.count > 12 ? 6 : 28))
                        .foregroundStyle(Theme.accent.opacity(focus == nil || focus == bar.id ? 1 : 0.35))
                        .cornerRadius(3)
                }
                if let average, average > 0 {
                    RuleMark(y: .value("평균", average))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Theme.textTertiary)
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("평균 \(AnalysisText.won(average))").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                        }
                }
            }
            .chartXSelection(value: $picked)
            .chartXAxis {
                AxisMarks(values: axisLabels) { value in
                    AxisValueLabel {
                        if let id = value.as(Int.self), let bar = bars.first(where: { $0.id == id }) {
                            Text(bar.label).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Theme.divider)
                    AxisValueLabel {
                        if let won = value.as(Int64.self) ?? value.as(Double.self).map({ Int64($0) }) {
                            Text(Self.short(won)).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .chartXScale(domain: (bars.first?.id ?? 0) - 1 ... (bars.last?.id ?? 1) + 1)
            .frame(height: 150)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("막대 그래프")
            .accessibilityValue(bars.map { "\($0.label) \(AnalysisText.won($0.value))" }.joined(separator: ", "))
        }
    }

    /// 12,000 → "1.2만", 1,500,000 → "150만": the axis only needs the size of the number.
    static func short(_ won: Int64) -> String {
        if won == 0 { return "0" }
        if won >= 10_000 { let man = Double(won) / 10_000; return (man >= 100 ? String(Int(man)) : String(format: "%.1f", man).replacingOccurrences(of: ".0", with: "")) + "만" }
        return Formatting.grouped(won)
    }
}
