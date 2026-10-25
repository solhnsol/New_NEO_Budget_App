import NEOBudgetCalendar
import SwiftUI

/// How a day in the month is written. Two drafts of the same panel, picked with a launch argument until one is chosen.
enum MonthCellStyle {
    /// The day's events as dots, and what was spent that day written under them.
    case amount
    /// The same dots; the day's spending as a compact figure on a tint that deepens with the amount.
    case heat

    static let current: MonthCellStyle = ProcessInfo.processInfo.arguments.contains("-month-heat") ? .heat : .amount
}

/// The month that unrolls from the week strip when the header is pulled down (or its title is tapped), in the list and the grid alike.
///
/// It is drawn over the screen like a curtain whose top edge is the strip: at progress 0 it is the strip's height with the selected week's row
/// at the top, so the strip and the row are the same place, and at 1 the whole month is shown. A day picked in it is the day the screen goes to;
/// the footer (and a sideways swipe) moves between months.
struct MonthDropdown: View {
    let cells: [LocalDate: WeekStripDay]
    let selected: LocalDate
    let today: LocalDate
    /// The first day of the month shown.
    @Binding var month: LocalDate
    /// 0 is the strip's own height, 1 the whole month.
    let progress: CGFloat
    let stripHeight: CGFloat
    let onSelect: (LocalDate) -> Void

    static let rowHeight: CGFloat = 60
    static let weekdayRow: CGFloat = 20
    static let footer: CGFloat = 46

    static func firstOfMonth(_ day: LocalDate) -> LocalDate { day.adding(days: 1 - day.day) }

    static func shifted(_ month: LocalDate, by delta: Int) -> LocalDate {
        let index = month.year * 12 + (month.month - 1) + delta
        return (try? LocalDate(year: index / 12, month: index % 12 + 1, day: 1)) ?? month
    }

    static func rows(for month: LocalDate) -> Int {
        (month.weekday + LocalDate.daysInMonth(year: month.year, month: month.month) + 6) / 7
    }

    static func fullHeight(for month: LocalDate) -> CGFloat {
        weekdayRow + CGFloat(rows(for: month)) * rowHeight + footer
    }

    private var gridStart: LocalDate { month.adding(days: -month.weekday) }

    /// The row the selected day is in, so it can sit where the strip is while the panel is closed.
    private var selectedRow: Int {
        let offset = selected.daysSinceUnixEpoch - gridStart.daysSinceUnixEpoch
        return (0..<Self.rows(for: month)).contains(offset / 7) && offset >= 0 ? offset / 7 : 0
    }

    private var maxSpend: Int64 {
        (0..<(Self.rows(for: month) * 7)).compactMap { spend(of: gridStart.adding(days: $0)) }.max() ?? 0
    }

    var body: some View {
        let full = Self.fullHeight(for: month)
        let height = stripHeight + (full - stripHeight) * progress
        return VStack(spacing: 0) {
            weekdayLabels
            VStack(spacing: 0) {
                ForEach(0..<Self.rows(for: month), id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in cell(gridStart.adding(days: row * 7 + column)) }
                    }
                    .frame(height: Self.rowHeight)
                }
            }
            .id(month)
            .transition(.opacity)
            footerBar
        }
        .frame(height: full, alignment: .top)
        .opacity(min(1, progress * 2.5))
        .offset(y: -CGFloat(selectedRow) * Self.rowHeight * (1 - progress))
        .frame(height: height, alignment: .top)
        .clipped()
        .background(Theme.surface.opacity(min(1, progress * 4)))
        .overlay(alignment: .bottom) { Divider().opacity(progress) }
        .padding(.horizontal, 8)
        .background(Theme.surface.opacity(min(1, progress * 4)))
        .animation(.easeOut(duration: 0.18), value: month)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    month = Self.shifted(month, by: value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    private var weekdayLabels: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { column in
                Text(Formatting.weekdayShort(gridStart.adding(days: column))).font(.system(.caption2)).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity)
            }
        }
        .frame(height: Self.weekdayRow)
    }

    private var footerBar: some View {
        HStack {
            Button { month = Self.shifted(month, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 40) }
            Spacer()
            Text("\(String(month.year))년 \(month.month)월").font(.system(.subheadline, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            Spacer()
            Button { month = Self.shifted(month, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 40) }
        }
        .foregroundStyle(Theme.textSecondary)
        .frame(height: Self.footer)
    }

    /// What was spent that day net of refunds (the strip's net is positive for spending), or nil when nothing was.
    private func spend(of day: LocalDate) -> Int64? {
        guard let money = cells[day]?.netSpend.first(where: { $0.currency == "KRW" }) ?? cells[day]?.netSpend.first, money.minorUnits > 0 else { return nil }
        return money.minorUnits
    }

    private func cell(_ day: LocalDate) -> some View {
        let inMonth = day.month == month.month
        let info = cells[day]
        let isSelected = day == selected
        let spent = spend(of: day)
        let heat = spent.map { maxSpend > 0 ? Double($0) / Double(maxSpend) : 0 } ?? 0
        return Button { onSelect(day) } label: {
            VStack(spacing: 2) {
                Text("\(day.day)")
                    .font(.callout.monospacedDigit().weight(isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? (day == today ? Color.white : Theme.surface) : (day == today ? Theme.accent : Theme.textPrimary))
                    .frame(width: 30, height: 30)
                    .background { if isSelected { Circle().fill(day == today ? Theme.accent : Theme.textPrimary) } }
                HStack(spacing: 3) {
                    ForEach(0..<min(info?.eventCount ?? 0, 3), id: \.self) { _ in Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                }
                .frame(height: 6)
                Text(spent.map(amountText) ?? " ")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if MonthCellStyle.current == .heat, spent != nil {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.danger.opacity(0.06 + 0.22 * heat)).padding(2)
                }
            }
            .opacity(inMonth ? 1 : 0.3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.month)월 \(day.day)일, 일정 \(info?.eventCount ?? 0)건" + (spent.map { ", 지출 \(Formatting.grouped($0))원" } ?? ""))
    }

    private func amountText(_ won: Int64) -> String {
        switch MonthCellStyle.current {
        case .amount: return Formatting.grouped(won)
        case .heat:
            guard won >= 10_000 else { return Formatting.grouped(won) }
            let tenThousands = Double(won) / 10_000
            return (tenThousands >= 100 ? String(format: "%.0f", tenThousands) : String(format: "%.1f", tenThousands)).replacingOccurrences(of: ".0", with: "") + "만"
        }
    }
}
