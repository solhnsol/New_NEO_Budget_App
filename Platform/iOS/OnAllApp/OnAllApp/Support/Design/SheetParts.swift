import NEOBudgetCalendar
import SwiftUI

// The pieces the detail sheets share (event, transaction, settlement; design-v2 FULL-2/3/4, DETAIL-1/2/4, polish/CHANGES.md). Plain stacks on the
// white sheet, not a List: 20 side margin, rows 52 tall with a hairline between, text in the default color and only an amount in color.

/// A sheet's scrolling body with its one main button pinned under it.
struct SheetScaffold<Content: View, Button: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var button: () -> Button

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xxl)
                .padding(.bottom, Theme.Space.l)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            button().padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.s).background(Theme.surface)
        }
        .background(Theme.surface)
        .tint(Theme.accent)
    }
}

/// `이 일정의 지출`, `상세`: a small gray label over a group of rows.
struct SheetSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Space.xl).padding(.bottom, Theme.Space.xs)
    }
}

/// `결제 시각   11월 3일 11:40`: a gray label and its value, 52 tall, a hairline under it. `value` nil shows the placeholder in the lightest gray.
struct SheetRow: View {
    let label: String
    var value: String?
    /// Shown in the lightest gray while `value` is nil.
    var placeholder: String? = "추가하기"
    var valueColor: Color = Theme.textPrimary
    var valueWeight: Font.Weight = .regular
    var showsChevron = false
    var showsDivider = true
    var action: (() -> Void)?

    var body: some View {
        let row = HStack(spacing: Theme.Space.s) {
            Text(label).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: Theme.Space.m)
            if let shown = value ?? placeholder {
                Text(shown).font(.onAll(size: 16, weight: valueWeight).monospacedDigit())
                    .foregroundStyle(value == nil ? Theme.disabled : valueColor).multilineTextAlignment(.trailing).lineLimit(2)
            }
            if showsChevron { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary) }
        }
        .frame(minHeight: Theme.rowHeight)
        .overlay(alignment: .bottom) { if showsDivider { Theme.divider.frame(height: 1) } }
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { row }.buttonStyle(.onAllRow)
        } else {
            row
        }
    }
}

/// A line icon on a pale tint, at the start of a row: the category's (`CategoryIcon.tile`).
struct CategoryTile: View {
    let category: CanonicalCategoryID?
    var size: CGFloat = 38

    var body: some View {
        let tile = CategoryIcon.tile(for: category)
        LineIcon(name: tile.icon, size: size * 0.5).foregroundStyle(Theme.textSecondary)
            .frame(width: size, height: size)
            .background(tile.tint, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}

/// `일정 이름` over a second gray line, with a calendar-colored bar at its side (the event card's rail).
struct SheetTitleBlock: View {
    let title: String
    let lines: [String]
    var barColor: Color?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            if let barColor { RoundedRectangle(cornerRadius: 2).fill(barColor).frame(width: 4) }
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title).font(Theme.Typo.sheetTitle).foregroundStyle(Theme.textPrimary)
                ForEach(lines, id: \.self) { Text($0).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Formatting {
    /// `14:30`, 24-hour like the timeline and the mockups (`Formatting.time` writes `오후 2:30`).
    static func clock24(_ unixMilliseconds: Int64, zoneIdentifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneIdentifier) ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(unixMilliseconds) / 1_000))
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `12:15 – 13:30`.
    static func range24(_ start: Int64, _ end: Int64, zoneIdentifier: String) -> String {
        clock24(start, zoneIdentifier: zoneIdentifier) + " – " + clock24(end, zoneIdentifier: zoneIdentifier)
    }

    /// Money spent as the sheets write it: `−9,500` (a true minus sign, no unit).
    static func spent(_ minorUnits: Int64) -> String { "−" + grouped(minorUnits) }
}
