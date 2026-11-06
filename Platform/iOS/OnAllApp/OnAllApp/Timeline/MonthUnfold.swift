import NEOBudgetCalendar
import SwiftUI
import UIKit

/// The sizes and calendar arithmetic of the month that unfolds out of the header.
enum MonthUnfold {
    /// A week of the month: the number row, the event bars (two lanes), the dots for the events with no bar, and what was spent. The week strip has
    /// the same rows, without the bars until the month opens.
    static let numberRow: CGFloat = 36
    static let barsRow: CGFloat = MonthWeekBars.height
    static let dotsRow: CGFloat = EventDots.height
    static let spendRow: CGFloat = 14
    /// Between the dots and the amount in a month cell (the design's rows are 96: 36 + 34 + 9 + 3 + 14).
    static let monthGap: CGFloat = 3
    static let rowHeight: CGFloat = numberRow + barsRow + dotsRow + monthGap + spendRow
    /// The weekday names over the weeks and the title bar (month and arrows) over those.
    static let labelRow: CGFloat = 20
    static let titleRow: CGFloat = 0
    /// What the strip has under its dots and the month does not.
    static let stripBottomPadding: CGFloat = 1

    static func firstOfMonth(_ day: LocalDate) -> LocalDate { day.adding(days: 1 - day.day) }

    static func shifted(_ month: LocalDate, by delta: Int) -> LocalDate {
        let index = month.year * 12 + (month.month - 1) + delta
        return (try? LocalDate(year: index / 12, month: index % 12 + 1, day: 1)) ?? month
    }

    static func rows(for month: LocalDate) -> Int {
        (month.weekday + LocalDate.daysInMonth(year: month.year, month: month.month) + 6) / 7
    }

    static func gridStart(of month: LocalDate) -> LocalDate { month.adding(days: -month.weekday) }

    /// The row of `month` the week of `day` is, or nil when that week is not in it.
    static func anchorRow(of day: LocalDate, in month: LocalDate) -> Int? {
        let offset = day.daysSinceUnixEpoch - gridStart(of: month).daysSinceUnixEpoch
        guard offset >= 0, offset / 7 < rows(for: month) else { return nil }
        return offset / 7
    }

    /// How far the header's bottom edge travels between closed and open: the finger moves the same distance, so the edge follows it.
    static func travel(rows: Int) -> CGFloat {
        let closed = labelRow + numberRow + dotsRow + spendRow + stripBottomPadding
        return titleRow + labelRow + CGFloat(rows) * rowHeight - closed
    }

    /// The height of the strip at `unfold` (its weekday names folded away, a line for what was spent opened).
    static func stripHeight(unfold: CGFloat) -> CGFloat {
        labelRow * (1 - unfold) + numberRow + (barsRow + monthGap) * unfold + dotsRow + spendRow + stripBottomPadding * (1 - unfold)
    }

    /// 24,000 → 2.4만, 70,000 → 7만; under 10,000 it is written out (1,550). Nil when nothing was spent that day.
    static func spendText(of cell: WeekStripDay?) -> String? {
        guard let money = cell?.netSpend.first(where: { $0.currency == "KRW" }) ?? cell?.netSpend.first, money.minorUnits > 0 else { return nil }
        return amountText(money.minorUnits)
    }

    /// 24,000 → 2.4만; under 10,000 written out.
    static func amountText(_ won: Int64) -> String {
        guard won >= 10_000 else { return Formatting.grouped(won) }
        let tenThousands = Double(won) / 10_000
        return (tenThousands >= 100 ? String(format: "%.0f", tenThousands) : String(format: "%.1f", tenThousands)).replacingOccurrences(of: ".0", with: "") + "만"
    }

    /// 0 until `from`, 1 from `to`, a straight line between.
    static func ramp(_ value: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat { max(0, min(1, (value - from) / (to - from))) }
}

/// How far the month is open (0 the week, 1 the whole month). Held apart from the screen so that a finger moving it re-draws only the calendar.
@MainActor @Observable
final class MonthUnfoldState {
    var progress: CGFloat = 0
    var isOpen: Bool { progress > 0.001 }

    /// A finger that has dragged the calendar is not tapping: a day under it when it lets go is not a pick. The day taps fire on release, before or
    /// after the drag's own end, so the lock holds while dragging and a moment past the end.
    @ObservationIgnored private var tapsLockedUntil = Date.distantPast
    var allowsTap: Bool { Date() >= tapsLockedUntil }
    func lockTaps() { tapsLockedUntil = .distantFuture }
    func unlockTapsSoon() { tapsLockedUntil = Date().addingTimeInterval(0.25) }

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var target: CGFloat = 0
    @ObservationIgnored private var velocity: CGFloat = 0

    /// The design's `expand` (response 0.42, damping 0.88) as a spring stepped here, so a finger can take hold of it mid-flight and hand its speed on.
    private static let stiffness: CGFloat = 223.8, damping: CGFloat = 26.3

    func toggle() { isOpen && progress > 0.5 ? close() : open() }
    func open() { settle(to: 1) }
    func close() { settle(to: 0) }

    /// Springs to `target` (0 or 1) from the current progress, starting at `velocity` (progress per second).
    func settle(to target: CGFloat, velocity: CGFloat = 0) {
        self.target = target
        self.velocity = max(-12, min(12, velocity))
        guard link == nil else { return }
        let proxy = LinkProxy { [weak self] in self?.step() }
        let link = CADisplayLink(target: proxy, selector: #selector(LinkProxy.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// A finger took hold: whatever was moving stops where it is.
    func stop() {
        link?.invalidate()
        link = nil
    }

    private func step() {
        guard let link else { return }
        let dt = min(1.0 / 30, link.targetTimestamp - link.timestamp)
        let sub = 4
        for _ in 0..<sub {
            let h = dt / CGFloat(sub)
            velocity += (-Self.stiffness * (progress - target) - Self.damping * velocity) * h
            progress += velocity * h
        }
        if abs(progress - target) < 0.0005, abs(velocity) < 0.01 {
            progress = target
            stop()
        }
    }
}

private final class LinkProxy: NSObject {
    let tick: () -> Void
    init(_ tick: @escaping () -> Void) { self.tick = tick }
    @objc func fire() { tick() }
}
