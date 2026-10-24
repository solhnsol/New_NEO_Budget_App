import UIKit

/// Real text widths at the user's font and Dynamic Type size, for the layout engine. Measured once per change of content or text
/// size and handed to the engine as input; the engine never asks for a measurement while it works, and nothing measured on screen
/// is fed back into a layout.
enum TextMeasurer {
    /// The font event titles are drawn in, scaled like the SwiftUI `.caption.weight(.semibold)` they use.
    static func titleFont(contentSize: UIContentSizeCategory? = nil) -> UIFont {
        let base = UIFont.systemFont(ofSize: 12, weight: .semibold)
        let metrics = UIFontMetrics(forTextStyle: .caption1)
        guard let contentSize else { return metrics.scaledFont(for: base) }
        return metrics.scaledFont(for: base, compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSize))
    }

    /// How much larger text is than at the standard size: the `textScale` the engine takes.
    static func textScale(contentSize: UIContentSizeCategory? = nil) -> CGFloat {
        let metrics = UIFontMetrics(forTextStyle: .caption1)
        guard let contentSize else { return metrics.scaledValue(for: 1) }
        return metrics.scaledValue(for: 1, compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSize))
    }

    /// The width a title needs on one line, with the room its marks and padding take.
    static func titleWidth(_ title: String, contentSize: UIContentSizeCategory? = nil) -> CGFloat {
        let font = titleFont(contentSize: contentSize)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width) + 12 * textScale(contentSize: contentSize)
    }

    /// The line heights the event presentation's thresholds come from, at the user's text size.
    static func presentationMetrics(contentSize: UIContentSizeCategory? = nil) -> EventPresentation.Metrics {
        let scale = textScale(contentSize: contentSize)
        let metrics = UIFontMetrics(forTextStyle: .caption1)
        func lineHeight(_ base: UIFont) -> CGFloat {
            let font = contentSize.map { metrics.scaledFont(for: base, compatibleWith: UITraitCollection(preferredContentSizeCategory: $0)) } ?? metrics.scaledFont(for: base)
            return ceil(font.lineHeight)
        }
        return .measured(
            titleLine: lineHeight(.systemFont(ofSize: 12, weight: .semibold)),
            timeLine: lineHeight(.systemFont(ofSize: 9)), rowLine: lineHeight(.systemFont(ofSize: 10)), scale: scale
        )
    }
}
