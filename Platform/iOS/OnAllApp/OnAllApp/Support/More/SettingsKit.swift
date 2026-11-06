import SwiftUI
import UIKit

// The pieces of the 더보기 tab's screens (design-v2/polish/settings-v5.html): a gray screen, white cards, 52-point rows, no system list.

/// A pushed settings screen: back button (44 touch), 20/28 bold title, an optional blue text action on the right.
struct SettingsPage<Content: View>: View {
    let title: String
    var action: (title: String, run: () -> Void)?
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button { dismiss() } label: {
                    LineIcon(name: "back").foregroundStyle(Theme.textPrimary).padding(10)
                }
                .accessibilityLabel("뒤로")
                Text(title).font(Theme.Typo.navTitle).tracking(-0.4).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if let action {
                    Button(action: action.run) {
                        Text(action.title).font(Theme.Typo.smallButton).foregroundStyle(Theme.accent).padding(10)
                    }
                }
            }
            .padding(.leading, 13).padding(.trailing, 14).padding(.top, 12).padding(.bottom, 6)
            ScrollView { VStack(spacing: 0) { content }.padding(.bottom, Theme.Space.xxl) }
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackEnabled()
    }
}

/// A group of rows under a small gray title (13/18 semibold); the rows sit on one white 16-radius card.
struct SSection<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.onAll(size: 13, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 28).padding(.top, 20)
            }
            SCard { content }.padding(.top, title == nil ? 12 : 8)
        }
    }
}

/// The white card. Each row draws its own hairline at the bottom; the card's last point is clipped so the last row shows none.
struct SCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.bottom, -1)
            .frame(maxWidth: .infinity)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .padding(.horizontal, Theme.cardMargin)
    }
}

extension View {
    /// The row's hairline, inset past the icon tile (64) or not (16).
    func rowDivider(inset: CGFloat) -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, inset) }
    }
}

enum STone {
    case accent, orange, green, purple, pink, teal, neutral

    var colors: (fg: Color, bg: Color) {
        switch self {
        case .accent: (Theme.accent, Theme.accentSoft)
        case .orange: (Theme.CalendarTint.orange.color, Theme.CalendarTint.orange.soft)
        case .green: (Theme.CalendarTint.green.color, Theme.CalendarTint.green.soft)
        case .purple: (Theme.CalendarTint.purple.color, Theme.CalendarTint.purple.soft)
        case .pink: (Theme.CalendarTint.pink.color, Theme.incomeSoft)
        case .teal: (Theme.CalendarTint.teal.color, Theme.CalendarTint.teal.soft)
        case .neutral: (Theme.textSecondary, Theme.fill)
        }
    }
}

/// A 36 tile with a 20 line icon on a soft color.
struct STile: View {
    let icon: String
    var tone: STone = .accent

    var body: some View {
        LineIcon(name: icon, size: 20).foregroundStyle(tone.colors.fg)
            .frame(width: 36, height: 36)
            .background(tone.colors.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One settings row: optional icon tile, 16 medium title with a 13 gray second line, then a gray value and chevron, or any trailing control.
struct SRow<Trailing: View>: View {
    var icon: String?
    var tone: STone = .accent
    /// A calendar's color, drawn as a dot tile in place of the icon.
    var dot: Color?
    let title: String
    var sub: String?
    var value: String?
    var chevron = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let dot { SDotTile(color: dot) } else if let icon { STile(icon: icon, tone: tone) }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary).lineSpacing(0)
                if let sub { Text(sub).font(Theme.Typo.label).foregroundStyle(Theme.textTertiary) }
            }
            Spacer(minLength: 8)
            if let value { Text(value).font(.onAll(size: 15)).foregroundStyle(Theme.textTertiary) }
            trailing
            if chevron { LineIcon(name: "chev", size: 18).foregroundStyle(Theme.disabled) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .rowDivider(inset: icon == nil && dot == nil ? 16 : 64)
    }
}

extension SRow where Trailing == EmptyView {
    init(icon: String? = nil, tone: STone = .accent, dot: Color? = nil, title: String, sub: String? = nil, value: String? = nil, chevron: Bool = false) {
        self.init(icon: icon, tone: tone, dot: dot, title: title, sub: sub, value: value, chevron: chevron) { EmptyView() }
    }
}

/// A row that is also a link or button.
struct SLink<Destination: View>: View {
    let row: SRow<EmptyView>
    @ViewBuilder let destination: Destination

    var body: some View {
        NavigationLink { destination } label: { row }.buttonStyle(.onAllRow)
    }
}

/// 48×28 switch: off is the disabled gray, on is the accent.
struct SToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? Theme.accent : Theme.disabled)
                .frame(width: 48, height: 28)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 24, height: 24).shadow(color: .black.opacity(0.2), radius: 1.5, y: 1).padding(2)
                }
                .animation(Theme.Motion.press, value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "켜짐" : "꺼짐")
    }
}

/// A row with a switch on the right.
struct SToggleRow: View {
    var icon: String?
    var tone: STone = .accent
    let title: String
    var sub: String?
    @Binding var isOn: Bool

    var body: some View {
        SRow(icon: icon, tone: tone, title: title, sub: sub) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(SToggleStyle())
        }
    }
}

/// A row with a round radio mark on the right.
struct SRadioRow: View {
    let title: String
    let isOn: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            SRow(title: title) {
                Circle().strokeBorder(isOn ? Theme.accent : Theme.disabled, lineWidth: isOn ? 7 : 1.5).frame(width: 22, height: 22)
            }
        }
        .buttonStyle(.onAllRow)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A small gray label over a 16 medium value (a read-out field).
struct SField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.onAll(size: 12)).foregroundStyle(Theme.textTertiary)
            Text(value).font(Theme.Typo.rowTitle).foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .rowDivider(inset: 16)
    }
}

/// Segmented control: gray track, white chosen cell (32 high, 28 small).
struct SSegment: View {
    let options: [String]
    @Binding var selection: Int
    var small = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let on = selection == index
                Text(options[index])
                    .font(.onAll(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary)
                    .frame(maxWidth: .infinity).frame(height: small ? 28 : 32)
                    .background { if on { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface).shadow(color: .black.opacity(0.06), radius: 1, y: 1) } }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Theme.Motion.press) { selection = index } }
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous))
    }
}

/// A chip filter: white when off, soft blue when chosen.
struct SChip: View {
    let title: String
    let on: Bool
    var tap: () -> Void = {}

    var body: some View {
        Button(action: tap) {
            Text(title).font(.onAll(size: 13, weight: on ? .medium : .regular))
                .foregroundStyle(on ? Theme.accentStrong : Theme.textSecondary)
                .padding(.horizontal, 14).frame(height: Theme.chipHeight)
                .background(on ? Theme.accentSoft : Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SChipRow: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { ForEach(titles.indices, id: \.self) { i in SChip(title: titles[i], on: selection == i) { selection = i } } }
                .padding(.horizontal, 16)
        }
        .padding(.top, 12)
    }
}

/// `−  14일  +` in a gray pill with round white buttons.
struct SStepper: View {
    @Binding var value: Int
    var unit: String
    var range: ClosedRange<Int> = 1...99

    var body: some View {
        HStack(spacing: 10) {
            button("−") { value = max(range.lowerBound, value - 1) }
            Text("\(value)\(unit)").font(Theme.Typo.amount).frame(minWidth: 34)
            button("+") { value = min(range.upperBound, value + 1) }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func button(_ glyph: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(glyph).font(.onAll(size: 18)).foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32).background(Theme.surface, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// 52-high full-width button under the cards: solid blue, or soft blue (`light`).
struct SButton: View {
    let title: String
    var light = false
    var top: CGFloat = 16
    var run: () -> Void = {}

    var body: some View {
        Button(action: run) {
            Text(title).font(Theme.Typo.button).foregroundStyle(light ? Theme.accentStrong : .white)
                .frame(maxWidth: .infinity, minHeight: Theme.primaryButtonHeight)
                .background(light ? Theme.accentSoft : Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.cardMargin).padding(.top, top)
    }
}

/// A row holding a label and a trailing control (stepper, segment).
struct SControlRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View { SRow(title: title) { control } }
}

extension View {
    /// A hidden navigation bar also drops the edge-swipe back; this puts it back.
    func swipeBackEnabled() -> some View { background(SwipeBackEnabler()) }
}

private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Enabler() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    private final class Enabler: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigationController?.interactivePopGestureRecognizer?.delegate = nil
            navigationController?.interactivePopGestureRecognizer?.isEnabled = (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
