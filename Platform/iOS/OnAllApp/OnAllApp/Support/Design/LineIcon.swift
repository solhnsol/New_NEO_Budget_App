import SwiftUI

/// The design's line icons (24-point grid, 1.5 stroke, round caps), drawn from the `line-*` vector assets so they take the surrounding text color.
struct LineIcon: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        Image("line-\(name)").renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}
