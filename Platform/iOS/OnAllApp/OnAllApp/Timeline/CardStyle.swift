import SwiftUI
import UIKit

/// How an event card and a transaction chip look. `classic` is the card before the redesign; `apple` follows Apple Calendar (a bar down the left edge, a faint fill of the calendar's colour, the
/// title and time in a darker shade of it). A card too thin for its title writes it in small type on one line, as Apple's does.
enum CardStyle: String {
    case classic, apple

    /// A launch argument picks the style for comparisons (`-card-style apple`); the app itself uses `apple`.
    static let current: CardStyle = {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-card-style"), arguments.indices.contains(index + 1), let style = CardStyle(rawValue: arguments[index + 1]) { return style }
        return .apple
    }()

    var isApple: Bool { self != .classic }
    static let barWidth: CGFloat = 3
    /// Where text starts inside an Apple-style card: after the bar and a gap.
    static let textInset: CGFloat = 10
    static let cornerRadius: CGFloat = 6

    /// The calendar colour made dark enough to read on its own faint fill (lighter in dark mode).
    static func text(_ color: Color) -> Color {
        Color(UIColor { trait in
            let base = UIColor(color)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return trait.userInterfaceStyle == .dark
                ? UIColor(hue: h, saturation: max(0, s * 0.45), brightness: 1, alpha: 1)
                : UIColor(hue: h, saturation: min(1, s * 1.05), brightness: min(b, 1) * 0.55, alpha: 1)
        })
    }
}
