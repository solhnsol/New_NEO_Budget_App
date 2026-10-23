import SwiftUI
import UIKit

/// OnAll's design tokens: the one place colors, spacing, corner radii and type are decided, so every screen reads as the same app.
///
/// The rules follow what Korean users already know from Toss, 당근 and 배민 (`docs/design-system.md`):
/// - A light gray screen with white rounded cards; one card holds one subject.
/// - One accent (blue), used only for what can be tapped or what is chosen. Money coming in is blue, as Korean banks show it; red is only for
///   something going wrong, never for spending.
/// - The number that matters most is the biggest text on the screen; labels around it are small and gray.
/// - Copy is 해요체, short, and says what happens ("정산 요청을 보낼게요"), not what the system is.
enum Theme {
    // MARK: Color

    /// What can be tapped, what is chosen, and money coming in.
    static let accent = Color.dynamic(light: 0x3182F6, dark: 0x4C9AFF)
    /// Behind a chosen chip or an accent badge.
    static let accentSoft = Color.dynamic(light: 0xE8F3FF, dark: 0x1A2B44)
    /// Something went wrong, or an action that removes.
    static let danger = Color.dynamic(light: 0xF04452, dark: 0xFF6B76)
    /// Waiting on someone (money not received yet, a notification not placed).
    static let caution = Color.dynamic(light: 0xFF8A00, dark: 0xFFA43A)
    static let cautionSoft = Color.dynamic(light: 0xFFF3E5, dark: 0x3A2A14)

    /// The screen behind the cards.
    static let background = Color.dynamic(light: 0xF2F4F6, dark: 0x101012)
    /// A card.
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    /// An unchosen chip, a stepper button, an icon's tile.
    static let fill = Color.dynamic(light: 0xF2F4F6, dark: 0x2C2C2E)
    static let divider = Color.dynamic(light: 0xE5E8EB, dark: 0x333336)

    static let textPrimary = Color.dynamic(light: 0x191F28, dark: 0xF2F4F6)
    static let textSecondary = Color.dynamic(light: 0x4E5968, dark: 0xB0B8C1)
    static let textTertiary = Color.dynamic(light: 0x8B95A1, dark: 0x8B95A1)

    /// Money coming in (a refund, a deposit, a balance going up) is blue; money going out stays the plain text color.
    static func amountColor(isIncoming: Bool) -> Color { isIncoming ? accent : textPrimary }

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
        static let button: CGFloat = 14
        static let card: CGFloat = 18
    }

    /// The height of the one main button at the bottom of a sheet.
    static let primaryButtonHeight: CGFloat = 54

    // MARK: Type

    enum Typo {
        /// The one number a screen is about (what was paid, a balance).
        static let hero = Font.system(size: 28, weight: .bold).monospacedDigit()
        /// A card's title.
        static let title = Font.system(.title3, weight: .bold)
        static let rowTitle = Font.system(.body, weight: .medium)
        static let amount = Font.system(.body, weight: .semibold).monospacedDigit()
        static let label = Font.system(.subheadline)
        static let caption = Font.system(.footnote)
        static let badge = Font.system(.caption, weight: .semibold)
    }
}

extension Color {
    /// A color with its own value in light and in dark mode, from `0xRRGGBB`.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }
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
