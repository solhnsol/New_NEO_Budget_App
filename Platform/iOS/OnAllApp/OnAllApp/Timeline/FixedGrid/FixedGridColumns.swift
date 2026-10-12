import CoreGraphics
import Foundation

/// Which of the engine's decisions each day on screen is drawn from while the days move, and how the one day that two decisions describe passes from one to
/// the other. Pure, so it is tested.
///
/// Between two whole days `a` and `a+1` (fraction `f`) two windows are on screen: window `a` decided days `a` (main) and `a+1` (secondary); window `a+1` decided
/// `a+1` (main) and `a+2` (secondary). So:
/// - day `a` is drawn from window `a` as main — what it is at rest on `a`;
/// - day `a+2` (coming in, or going out) from window `a+1` as secondary — what it is at rest on `a+1` (it is never drawn without the engine's decision);
/// - day `a+1` is in both: drawn from window `a` while `f` is below `band`, from window `a+1` above it, and in between both are drawn, what they agree on once
///   and what differs crossfaded by position (`weight`). No representation changes in one frame, a drag back undoes it exactly, and at rest each day has one
///   decision.
enum FixedGridColumns {
    /// One of the engine's decisions for a day: the window that made it and the day's role in it.
    struct Source: Hashable {
        let window: Int
        /// `nil` only in the old rule kept for measuring (`legacyColumns`): a day outside the window's two, drawn without the engine.
        let role: DayRole?
    }

    struct Column: Equatable {
        let epoch: Int
        let from: Source
        /// The decision the day is passing to, with `weight` its share (0 … 1). `nil` when the day has one decision.
        let to: Source?
        let weight: Double

        /// The decision a touch goes to (taps count at rest, where there is only one).
        var dominant: Source { to != nil && weight >= 0.5 ? to! : from }
    }

    /// The fractions over which the shared day passes from one decision to the other.
    static let band: ClosedRange<Double> = 0.3...0.7

    /// The destination's share at fraction `f`: 0 below the band, 1 above it, smooth (no step, no kink) in between.
    static func weight(fraction f: Double) -> Double {
        let t = min(max((f - band.lowerBound) / (band.upperBound - band.lowerBound), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The decisions for `days` at `position`, the windows held to `bounds` (the windows planned around the selected day).
    static func columns(days: ClosedRange<Int>, position: Double, bounds: ClosedRange<Int>) -> [Column] {
        let clamped = min(max(position, Double(bounds.lowerBound)), Double(bounds.upperBound))
        let a = min(Int(clamped.rounded(.down)), bounds.upperBound - 1)
        let w = weight(fraction: clamped - Double(a))
        return days.map { day in
            switch day - a {
            case ...0: return Column(epoch: day, from: Source(window: day, role: .main), to: nil, weight: 0)
            case 1:
                guard w > 0 else { return Column(epoch: day, from: Source(window: a, role: .secondary), to: nil, weight: 0) }
                guard w < 1 else { return Column(epoch: day, from: Source(window: a + 1, role: .main), to: nil, weight: 0) }
                return Column(epoch: day, from: Source(window: a, role: .secondary), to: Source(window: a + 1, role: .main), weight: w)
            default: return Column(epoch: day, from: Source(window: day - 1, role: .secondary), to: nil, weight: 0)
            }
        }
    }

    /// The rule before 2B-2, kept for before/after measurements (`-probe-legacy-columns`): every day from the window nearest the position, the day beyond
    /// its two without the engine — so at the halfway line every column changes decision in one frame.
    static func legacyColumns(days: ClosedRange<Int>, position: Double, bounds: ClosedRange<Int>) -> [Column] {
        let window = min(max(Int(position.rounded()), bounds.lowerBound), bounds.upperBound)
        return days.map { day in
            let role: DayRole? = day == window ? .main : day == window + 1 ? .secondary : nil
            return Column(epoch: day, from: Source(window: window, role: role), to: nil, weight: 0)
        }
    }

    /// The windows whose decisions the columns use.
    static func windows(of columns: [Column]) -> Set<Int> { Set(columns.flatMap { [$0.from.window] + ($0.to.map { [$0.window] } ?? []) }) }

    // MARK: What two decisions agree on

    /// One thing drawn for a day: an event card (with its title, header and rows), a transaction line, or an overflow card.
    enum Item: Hashable {
        case event(String)
        case line(String)
        case overflow(String)
    }

    /// How opaque each thing of a day is drawn from each of its two plans: what both draw the same way is drawn once (from the destination, fully), what
    /// differs is drawn from both, faded by the weight. A thing missing from one plan fades in or out.
    struct Blend: Equatable {
        /// Drawn from the plan the day is leaving, at `1 - weight`.
        let leaving: Set<Item>
        /// Drawn from the plan the day is passing to, at `weight` (the rest of that plan is drawn fully: it is the same in both).
        let arriving: Set<Item>
    }

    static func blend(_ from: DayRenderPlan, _ to: DayRenderPlan) -> Blend {
        let a = signatures(of: from), b = signatures(of: to)
        let differing = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }
        return Blend(leaving: differing.filter { a[$0] != nil }, arriving: differing.filter { b[$0] != nil })
    }

    /// What is seen of each thing: where it is and what it says, not which decision made it (the same card from the main or the secondary role is the same).
    static func signatures(of plan: DayRenderPlan) -> [Item: [AnyHashable]] {
        var result: [Item: [AnyHashable]] = [:]
        for event in plan.events {
            result[.event(event.block.id.rawValue)] = [
                event.drawnFrame.hashableValue, event.title.dx, event.title.dy, event.title.overflows, event.presentation.signature, event.header?.hashableValue,
                event.showsTitleInCard, event.shownRows, event.hiddenRows, event.insideRows.map(\.transactionID.rawValue), event.titleMaxWidth,
                event.insideAnchors, event.startTimeFits,
            ]
        }
        for line in plan.lines {
            result[.line(line.id)] = [line.frame.hashableValue, line.reveal, line.anchorY, line.display?.title, line.display?.amount.minorUnits, line.link?.eventID, line.linkedEventTitle]
        }
        for overflow in plan.overflows {
            result[.overflow(overflow.id)] = [
                overflow.frame.hashableValue, overflow.reveal, overflow.anchorY, overflow.members.map(\.transactionID), overflow.showsAmountTotal,
                overflow.countsByKind.map(\.count), overflow.amountTotals.map(\.minorUnits),
            ]
        }
        return result
    }
}

extension DayRenderPlan.EventItem {
    /// The item key `FixedGridColumns.blend` uses for it.
    var blendItem: FixedGridColumns.Item { .event(block.id.rawValue) }
}

private extension CGRect {
    var hashableValue: [CGFloat] { [minX, minY, width, height] }
}

private extension EventPresentation {
    var signature: String { String(describing: self) }
}
