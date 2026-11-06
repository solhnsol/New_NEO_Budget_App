import SwiftUI
import UIKit

/// The times a precision bubble's wheel offers for one edge. Pure, so it is tested.
enum PrecisionWheelChoices {
    /// Every grid line of the day (15 minutes, aligned to `dayStart`) from `low` to `high`, both included, and each of `keep` that lies between them off the
    /// grid (the edge's original time, so an event that began at 10:07 can be put back there). In time order.
    static func make(low: Date, high: Date, dayStart: Date, keep: [Date] = [], stepMinutes: Int = 15) -> [Date] {
        guard low <= high else { return [] }
        let step = TimeInterval(stepMinutes * 60)
        let first = (low.timeIntervalSince(dayStart) / step).rounded(.up)
        let last = (high.timeIntervalSince(dayStart) / step).rounded(.down)
        var choices: [Date] = first <= last ? stride(from: first, through: last, by: 1).map { dayStart.addingTimeInterval($0 * step) } : []
        for instant in keep where instant >= low && instant <= high && !choices.contains(instant) { choices.append(instant) }
        return choices.sorted()
    }

    /// The row of `instant`: its own, else the nearest one (`nil` when there are none).
    static func index(of instant: Date, in choices: [Date]) -> Int? {
        if let exact = choices.firstIndex(of: instant) { return exact }
        return choices.indices.min { abs(choices[$0].timeIntervalSince(instant)) < abs(choices[$1].timeIntervalSince(instant)) }
    }
}

/// A vertical wheel of times, like the timer's: the row in the middle band is the chosen one. It is controlled: it shows `selected` and reports the row that
/// comes to the middle while a finger turns it (each row as it passes, not only where it stops), so the card follows the wheel. A tap on a row turns to it.
///
/// It is hidden from VoiceOver: the bubble's header is the one adjustable element for the same time.
struct PrecisionTimeWheel: UIViewRepresentable {
    let labels: [String]
    let selected: Int
    var isEnabled = true
    let onSelect: (Int) -> Void

    /// Rows shown: the chosen one and one either side.
    static let visibleRows = 3

    func makeUIView(context: Context) -> PrecisionWheelView { PrecisionWheelView() }

    func updateUIView(_ view: PrecisionWheelView, context: Context) {
        view.onSelect = onSelect
        view.update(labels: labels, selected: selected, enabled: isEnabled)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PrecisionWheelView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 160, height: uiView.rowHeight * CGFloat(Self.visibleRows))
    }
}

final class PrecisionWheelView: UIView, UIScrollViewDelegate {
    var onSelect: (Int) -> Void = { _ in }
    private(set) var rowHeight: CGFloat = 36

    private let scroll = UIScrollView()
    private let band = UIView()
    private var rows: [UILabel] = []
    private var texts: [String] = []
    /// What the owner says is chosen, and the row in the middle now (they differ only while a finger turns the wheel, until the owner answers).
    private var selected = 0
    private var centred = 0
    /// A tap's turn to a row is the person's, like a drag.
    private var turningToTappedRow = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        accessibilityElementsHidden = true
        band.isUserInteractionEnabled = false
        band.layer.cornerRadius = 8
        band.layer.cornerCurve = .continuous
        band.backgroundColor = UIColor.tintColor.withAlphaComponent(0.12)
        addSubview(band)
        scroll.delegate = self
        scroll.showsVerticalScrollIndicator = false
        scroll.decelerationRate = .fast
        scroll.scrollsToTop = false
        scroll.contentInsetAdjustmentBehavior = .never
        addSubview(scroll)
        scroll.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        measure()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: PrecisionWheelView, _) in
            view.measure()
            view.rows.forEach { $0.font = view.font }
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var font: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: traitCollection)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold],
            .featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType, UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]],
        ])
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private func measure() { rowHeight = ceil(font.lineHeight + 12) }

    private var userTurning: Bool { scroll.isTracking || scroll.isDragging || scroll.isDecelerating || turningToTappedRow }

    func update(labels: [String], selected: Int, enabled: Bool) {
        isUserInteractionEnabled = enabled
        if labels != texts {
            texts = labels
            rows.forEach { $0.removeFromSuperview() }
            rows = labels.map { text in
                let label = UILabel()
                label.text = text
                label.font = font
                label.textAlignment = .center
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.7
                scroll.addSubview(label)
                return label
            }
            setNeedsLayout()
            layoutIfNeeded()
        }
        self.selected = max(0, min(selected, labels.count - 1))
        // Turned by the person: the owner's answer is this row; nothing to move. Otherwise (a handle dragged, another edge) the wheel goes to it at once.
        if !userTurning, centred != self.selected || abs(scroll.contentOffset.y - offset(of: self.selected)) > 0.5 { go(to: self.selected, animated: false) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        let inset = max(0, (bounds.height - rowHeight) / 2)
        scroll.contentInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        scroll.contentSize = CGSize(width: bounds.width, height: rowHeight * CGFloat(rows.count))
        for (index, label) in rows.enumerated() {
            label.frame = CGRect(x: 8, y: CGFloat(index) * rowHeight, width: max(0, bounds.width - 16), height: rowHeight)
        }
        band.frame = CGRect(x: 0, y: inset, width: bounds.width, height: rowHeight)
        if !userTurning { go(to: selected, animated: false) }
        style()
    }

    private func offset(of row: Int) -> CGFloat { CGFloat(row) * rowHeight - scroll.contentInset.top }

    private func row(atOffset y: CGFloat) -> Int {
        guard !rows.isEmpty else { return 0 }
        return max(0, min(rows.count - 1, Int(((y + scroll.contentInset.top) / rowHeight).rounded())))
    }

    private func go(to row: Int, animated: Bool) {
        guard !rows.isEmpty else { return }
        centred = row
        scroll.setContentOffset(CGPoint(x: 0, y: offset(of: row)), animated: animated)
    }

    /// The rows away from the middle fade and shrink a little, as on a drum.
    private func style() {
        let middle = scroll.contentOffset.y + scroll.contentInset.top + rowHeight / 2
        for label in rows {
            let distance = min(1.5, abs(label.frame.midY - middle) / rowHeight)
            label.alpha = 1 - 0.55 * distance
            let scale = 1 - 0.12 * distance
            label.transform = CGAffineTransform(scaleX: scale, y: scale)
            label.textColor = distance < 0.5 ? .label : .secondaryLabel
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let y = gesture.location(in: scroll).y
        let target = max(0, min(rows.count - 1, Int(y / rowHeight)))
        guard target != centred else { return }
        turningToTappedRow = true
        scroll.setContentOffset(CGPoint(x: 0, y: offset(of: target)), animated: true)
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        style()
        guard userTurning else { return }
        let now = row(atOffset: scrollView.contentOffset.y)
        if now != centred {
            centred = now
            onSelect(now)
        }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        targetContentOffset.pointee.y = offset(of: row(atOffset: targetContentOffset.pointee.y))
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settled() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { turningToTappedRow = false; settled() }

    /// At rest: on the row the owner holds (a row it did not take goes back).
    private func settled() {
        if centred != selected || abs(scroll.contentOffset.y - offset(of: selected)) > 0.5 { go(to: selected, animated: true) }
    }
}
