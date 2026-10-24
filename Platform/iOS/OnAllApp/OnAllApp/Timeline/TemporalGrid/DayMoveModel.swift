import Foundation

/// The explicit state of moving along the days, as a value: where the window is (`position`, in days), how fast it is going, where it is going,
/// and which of three things is happening. No view, no clock and no gesture is in here: a drag, a button or a test feeds it the same events and gets the
/// same positions. (The real swipe gesture is not part of this stage; `drag` and `release` are what it will call.)
///
///   - `resting`: on a whole day.
///   - `dragging`: a finger (or anything) sets the position directly; the velocity is not integrated.
///   - `settling`: a critically damped spring pulls the position to `target`, from wherever it is and at whatever speed it has. Because the spring is
///     solved exactly, advancing by 1/60 s sixty times gives the same position as advancing by 1 s once: frame rate does not matter.
///
/// Any event can come in any phase. A new drag during a settle takes over from the current position (a reversal has no jump and no wait); a new
/// target during a settle keeps the current position and speed (rapid taps add up); nothing ever leaves `bounds`.
struct DayMoveModel: Equatable {
    enum Phase: Equatable { case resting, dragging, settling }

    private(set) var position: Double
    /// Days per second.
    private(set) var velocity = 0.0
    private(set) var target: Int
    private(set) var phase = Phase.resting
    let bounds: ClosedRange<Int>
    /// The most days one release may carry the window over (`DayPrefetchPolicy` says how many days must be read ahead for a given hop).
    let hopLimit: Int

    /// The spring's natural frequency (rad/s): a move of one day settles in about 0.4 s.
    static let frequency = 14.0
    /// How far ahead a release looks: a flick of `v` days per second lands `v · lookahead` days further on.
    static let lookahead = 0.15
    /// The default for the most days one release may carry the window over (the DEBUG grid). Browse starts at 1: see `DayPrefetchPolicy.browse`.
    static let maximumHop = 3

    init(day: Int, bounds: ClosedRange<Int>, maximumHop: Int = DayMoveModel.maximumHop) {
        let clamped = min(max(day, bounds.lowerBound), bounds.upperBound)
        self.bounds = bounds
        hopLimit = max(1, maximumHop)
        position = Double(clamped)
        target = clamped
    }

    var isMoving: Bool { phase != .resting }
    /// The day and the fraction of the way to the next.
    var day: Int { min(Int(position.rounded(.down)), bounds.upperBound) }
    var progress: Double { day >= bounds.upperBound ? 0 : position - Double(day) }

    private func clamp(_ value: Double) -> Double { min(max(value, Double(bounds.lowerBound)), Double(bounds.upperBound)) }

    mutating func beginDrag() {
        phase = .dragging
        velocity = 0
        target = Int(position.rounded())
    }

    mutating func drag(to newPosition: Double) {
        if phase != .dragging { beginDrag() }
        position = clamp(newPosition)
    }

    /// The finger lets go at `velocity` days per second (positive: towards later days).
    mutating func release(velocity releaseVelocity: Double) {
        let projected = clamp(position + releaseVelocity * Self.lookahead)
        let hop = hopLimit
        let nearest = Int(position.rounded())
        let landing = min(max(Int(projected.rounded()), nearest - hop), nearest + hop)
        settle(to: landing, velocity: releaseVelocity)
    }

    /// Go to `day`, from wherever the window is now and at whatever speed it has.
    mutating func retarget(to day: Int) { settle(to: day, velocity: phase == .settling ? velocity : 0) }

    /// `delta` days on from the day being headed for (or from the day rested on): rapid taps add up.
    mutating func retarget(by delta: Int) {
        let base = phase == .settling ? target : Int(position.rounded())
        retarget(to: base + delta)
    }

    private mutating func settle(to day: Int, velocity newVelocity: Double) {
        target = min(max(day, bounds.lowerBound), bounds.upperBound)
        velocity = newVelocity
        phase = .settling
        if abs(position - Double(target)) < 1e-4, abs(velocity) < 1e-3 { position = Double(target); velocity = 0; phase = .resting }
    }

    /// Move the spring on by `seconds`. Only a settle moves by itself.
    mutating func advance(by seconds: Double) {
        guard phase == .settling, seconds > 0 else { return }
        let omega = Self.frequency
        let x0 = position - Double(target), v0 = velocity
        let decay = exp(-omega * seconds)
        let c = v0 + omega * x0
        let x = (x0 + c * seconds) * decay
        let v = (c - omega * (x0 + c * seconds)) * decay
        position = Double(target) + x
        velocity = v
        if position < Double(bounds.lowerBound) || position > Double(bounds.upperBound) { position = clamp(position); velocity = 0 }
        if abs(position - Double(target)) < 1e-4, abs(velocity) < 1e-3 {
            position = Double(target); velocity = 0; phase = .resting
        }
    }
}
