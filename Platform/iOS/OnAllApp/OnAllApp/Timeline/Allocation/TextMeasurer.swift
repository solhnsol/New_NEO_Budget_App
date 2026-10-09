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
}
