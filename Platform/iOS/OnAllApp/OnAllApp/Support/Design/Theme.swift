import SwiftUI
import UIKit
import CoreText

/// OnAll's design tokens: the one place colors, spacing, corner radii, type and motion are decided, so every screen reads as the same app.
///
/// Values come from the design-v2 mockups (`design-v2/ledger/palette.html`, `design-v2/polish/CHANGES.md`); `docs/design-system.md` has the rules:
/// - A light gray screen with white rounded cards; one card holds one subject.
/// - One blue accent. Money spent is blue, money coming in (real income) is red, the row text itself stays the default color.
/// - Warning red is only for something that cannot be undone.
/// - Dark values are derived (the mockups have no dark palette yet).
enum Theme {
    // MARK: Color

    /// Buttons, the cursor, chosen things, and money spent.
    static let accent = Color.dynamic(light: 0x3D6FE0, dark: 0x6B93E8)
    /// Text on an `accentSoft` background.
    static let accentStrong = Color.dynamic(light: 0x2B54B8, dark: 0xA9C1F5)
    /// Behind a chosen chip, today, a notification strip.
    static let accentSoft = Color.dynamic(light: 0xEAF0FD, dark: 0x1B2740)
    /// A chosen item's border.
    static let accentLine = Color.dynamic(light: 0xC9D8F8, dark: 0x34508F)

    /// Money coming in (real income only; a settlement repayment attaches to its expense and is not income).
    static let income = Color.dynamic(light: 0xC65B62, dark: 0xE88A90)
    static let incomeSoft = Color.dynamic(light: 0xFBEEEF, dark: 0x3A2325)

    /// Delete and other actions that cannot be undone.
    static let danger = Color.dynamic(light: 0xE5484D, dark: 0xFF6B70)
    static let dangerStrong = Color.dynamic(light: 0xC93A3F, dark: 0xFF8A8E)
    static let dangerSoft = Color.dynamic(light: 0xFDECEC, dark: 0x3A2224)

    /// Waiting on someone (money not received yet, a notification not placed). The palette has no amber, so it borrows the calendar orange.
    static let caution = Color.dynamic(light: 0xE8A25A, dark: 0xF0B46F)
    static let cautionSoft = Color.dynamic(light: 0xFCF4EA, dark: 0x3A2A14)

    /// The selection-mode bottom bar (white text on it); its delete label color.
    static let actionBar = Color.dynamic(light: 0x3E4C63, dark: 0x3E4C63)
    static let actionBarDelete = Color(red: 1, green: 0xC9 / 255, blue: 0xCB / 255)

    /// The screen behind the cards.
    static let background = Color.dynamic(light: 0xF4F5F7, dark: 0x101012)
    /// A card or sheet.
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    /// An unchosen chip, a segmented control's track on a card, pressed rows.
    static let fill = Color.dynamic(light: 0xF4F5F7, dark: 0x2C2C2E)
    static let divider = Color.dynamic(light: 0xEEF0F2, dark: 0x333336)
    /// A switch that is off, a disabled button, a sheet's grabber.
    static let disabled = Color.dynamic(light: 0xC6C6CB, dark: 0x48484C)
    /// The day timeline's vertical rail.
    static let rail = Color.dynamic(light: 0xE5E8EB, dark: 0x333336)

    static let textPrimary = Color.dynamic(light: 0x191F28, dark: 0xF2F4F6)
    static let textSecondary = Color.dynamic(light: 0x4E5968, dark: 0xB0B8C1)
    static let textTertiary = Color.dynamic(light: 0x8B95A1, dark: 0x8B95A1)

    /// Calendar colors (saturation-matched). `soft` is the 9% tint used behind an event card or a category tile.
    enum CalendarTint: CaseIterable {
        case blue, orange, green, purple, pink, teal

        var color: Color {
            switch self {
            case .blue: return Color(rgb: 0x6B93E8)
            case .orange: return Color(rgb: 0xE8A25A)
            case .green: return Color(rgb: 0x5DB38B)
            case .purple: return Color(rgb: 0x9B87E0)
            case .pink: return Color(rgb: 0xE07C8A)
            case .teal: return Color(rgb: 0x4FB0B8)
            }
        }

        var soft: Color { color.opacity(0.09) }
    }

    /// Row amount color: money spent is blue, money coming in is red. The row's text stays `textPrimary`.
    static func amountColor(isIncoming: Bool) -> Color { isIncoming ? income : accent }

    // MARK: Spacing, shape

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 8
        /// Segmented control (outer 10, inner 8).
        static let segment: CGFloat = 10
        static let smallButton: CGFloat = 12
        static let button: CGFloat = 14
        static let card: CGFloat = 16
        static let chip: CGFloat = 16
        static let sheet: CGFloat = 24
    }

    /// The main button at the bottom of a sheet (small button: 36).
    static let primaryButtonHeight: CGFloat = 52
    static let smallButtonHeight: CGFloat = 36
    static let chipHeight: CGFloat = 32
    static let segmentHeight: CGFloat = 32
    /// Minimum touch target (a header icon is a 24 glyph with 10 padding).
    static let hitTarget: CGFloat = 44
    /// A settings row.
    static let rowHeight: CGFloat = 52
    /// The screen's side margin for cards.
    static let cardMargin: CGFloat = 16

    // MARK: Type (size/line height from the mockups)

    enum Typo {
        /// A screen title (26/34 bold).
        static let h1 = Font.onAll(size: 26, weight: .bold)
        /// A pushed screen's title next to the back button (20/28 bold).
        static let navTitle = Font.onAll(size: 20, weight: .bold)
        /// A section's title, a date (18/24 semibold).
        static let section = Font.onAll(size: 18, weight: .semibold)
        /// A sheet's title (20/28 semibold).
        static let sheetTitle = Font.onAll(size: 20, weight: .semibold)
        /// The one number a screen is about (32/40 bold).
        static let hero = Font.onAll(size: 32, weight: .bold).monospacedDigit()
        /// A row's title (16/22 medium).
        static let rowTitle = Font.onAll(size: 16, weight: .medium)
        /// A row's second line (13/18).
        static let label = Font.onAll(size: 13)
        static let amount = Font.onAll(size: 16, weight: .medium).monospacedDigit()
        /// The smallest text there is (11).
        static let caption = Font.onAll(size: 11)
        static let badge = Font.onAll(size: 11, weight: .semibold)
        static let button = Font.onAll(size: 16, weight: .semibold)
        static let smallButton = Font.onAll(size: 15, weight: .semibold)
        static let chip = Font.onAll(size: 13, weight: .medium)
        /// A card's title.
        static let title = section
    }

    // MARK: Motion (see docs/design-system.md; every spring falls back to a 200 ms ease when Reduce Motion is on)

    enum Motion {
        /// A sheet opening (320 ms, damping 0.85).
        static let sheet = Animation.spring(duration: 0.32, bounce: 0.15)
        static let scrim = Animation.easeOut(duration: 0.2)
        /// A row or card pressed (120 ms) and a button's dim while pressed.
        static let press = Animation.easeOut(duration: 0.12)
        static let pressedButtonOpacity = 0.85
        /// A selection box appearing.
        static let select = Animation.easeOut(duration: 0.15)
        /// The rows making room for a selection box, and the box opening: a spring, so they slide along (the design: the box opens, it does not fade).
        static let selectSlide = Animation.spring(response: 0.36, dampingFraction: 0.88)
        /// The selection action bar rising.
        static let actionBar = Animation.spring(duration: 0.24, bounce: 0.15)
        /// The day body sliding to another day.
        static let daySlide = Animation.easeInOut(duration: 0.22)
        /// The month grid unfolding.
        static let monthUnfold = Animation.spring(duration: 0.28, bounce: 0.1)
        /// A dragged draft card settling.
        static let settle = Animation.easeOut(duration: 0.1)
        /// A widget picked up in edit mode and put down.
        static let widgetRearrange = Animation.spring(duration: 0.24, bounce: 0.15)
        static let badgeFade = Animation.easeOut(duration: 0.15)
        /// Reduce Motion: every spring or slide becomes this.
        static let reduced = Animation.easeInOut(duration: 0.2)

        /// `animation`, or the plain ease when the user turned Reduce Motion on.
        static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation { reduceMotion ? reduced : animation }

        /// Long-press that starts selection mode or picks something up.
        static let longPressSeconds = 0.35
        /// Dragging a new event snaps to this many minutes.
        static let dragSnapMinutes = 15
    }
}

extension Color {
    init(rgb hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// The app is light-only for now (the design has no dark palette): the light value always, whatever the system setting. `dark` is kept for when a dark palette is designed.
    static func dynamic(light: UInt32, dark: UInt32) -> Color { Color(rgb: light) }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// A list or form on the gray screen, its sections as white cards: the look every sheet and tab shares.
    func onAllGroupedScreen() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.background)
            .tint(Theme.accent)
    }

    /// A section of a list or form drawn as a card on the gray screen.
    func onAllCardRow() -> some View {
        listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.divider)
    }
}

extension Font {
    /// Pretendard (bundled in `Fonts/`, registered at launch by `PretendardFonts`) at a fixed size; the weight picks the nearest of the four cuts.
    static func onAll(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let cut: String
        switch weight {
        case .bold, .heavy, .black: cut = "Bold"
        case .semibold: cut = "SemiBold"
        case .medium: cut = "Medium"
        default: cut = "Regular"
        }
        return .custom("Pretendard-\(cut)", fixedSize: size)
    }
}

/// Registers the bundled Pretendard files with the system, once at launch, so `Font.onAll` finds them without an Info.plist font list.
enum PretendardFonts {
    static func register() {
        for cut in ["Regular", "Medium", "SemiBold", "Bold"] {
            guard let url = Bundle.main.url(forResource: "Pretendard-\(cut)", withExtension: "otf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
