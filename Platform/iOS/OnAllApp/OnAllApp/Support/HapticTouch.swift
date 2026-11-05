import SwiftUI
import UIKit

/// The iPhone's own Haptic Touch. There is no call that says "a Haptic Touch happened"; the system offers it only as a context menu (the press time, the
/// tick and the lift of what is under the finger are all the system's, and follow the user's Haptic Touch setting). So a Haptic Touch in the app opens a
/// menu, and the menu's first item is the action.
extension View {
    /// A row's Haptic Touch menu: `선택` starts selection mode with it. No menu (and no lift) while selecting, or for what cannot be selected.
    func hapticTouchSelect(enabled: Bool, perform: @escaping () -> Void) -> some View {
        contextMenu {
            if enabled { Button { perform() } label: { Label("선택", systemImage: "checkmark.circle") } }
        }
    }

    /// Empty space that answers a Haptic Touch with a one-item menu; `perform` gets where the finger was (in this view's space). The spot is lifted as a
    /// small bar there, like the event it would make.
    /// `excluding` are the parts that have touches of their own (rows, cards): the spot lets those through.
    func hapticTouchSpot(title: String, systemImage: String, excluding: [CGRect], perform: @escaping (CGPoint) -> Void) -> some View {
        overlay(HapticTouchSpot(title: title, systemImage: systemImage, excluding: excluding, perform: perform))
    }
}

private struct HapticTouchSpot: UIViewRepresentable {
    let title: String
    let systemImage: String
    let excluding: [CGRect]
    let perform: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SpotView {
        let view = SpotView()
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return view
    }

    /// Answers touches only outside `excluding`, so what is drawn there keeps its own taps and holds.
    final class SpotView: UIView {
        var excluding: [CGRect] = []
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            super.point(inside: point, with: event) && !excluding.contains { $0.contains(point) }
        }
    }

    func updateUIView(_ view: SpotView, context: Context) {
        view.excluding = excluding
        context.coordinator.title = title
        context.coordinator.systemImage = systemImage
        context.coordinator.perform = perform
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var title = ""
        var systemImage = ""
        var perform: (CGPoint) -> Void = { _ in }
        private var spot = CGPoint.zero

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            spot = location
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                let action = UIAction(title: self.title, image: UIImage(systemName: self.systemImage)) { _ in self.perform(self.spot) }
                return UIMenu(children: [action])
            }
        }

        /// Lifts a small bar at the finger, not the whole empty area.
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            guard let view = interaction.view else { return nil }
            let parameters = UIPreviewParameters()
            let bar = CGRect(x: max(8, spot.x - 80), y: spot.y - 14, width: 160, height: 28)
            parameters.visiblePath = UIBezierPath(roundedRect: bar, cornerRadius: 8)
            parameters.backgroundColor = UIColor(Theme.accentSoft)
            return UITargetedPreview(view: view, parameters: parameters)
        }
    }
}
