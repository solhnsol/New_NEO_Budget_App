import CoreGraphics
import Foundation

/// Reads one finger's samples and says what the movement is: sideways (a swipe along the days), up and down (a scroll) or not decided yet,
/// and how far and how fast it has gone sideways. Pure: the samples carry their own time. The distance is from where the finger came down, so the
/// content is under the finger from the first moment it is recognised, not 10 points later.
struct HorizontalDragClassifier: Equatable {
    struct Sample: Equatable { let time: Double; let x: CGFloat; let y: CGFloat }
    enum Decision: Equatable { case undecided, horizontal, vertical }

    /// Sideways distance at which a mostly sideways movement is a swipe (UIKit's own pan needs about 10).
    static let beginDistance: CGFloat = 4
    /// Vertical distance at which a mostly vertical movement is a scroll.
    static let verticalDistance: CGFloat = 6
    /// How much more one direction must have gone than the other.
    static let dominance: CGFloat = 1.4
    /// Samples older than this (seconds) before the last one do not count towards the speed, and a finger that stopped this long ago has no speed.
    static let velocityWindow = 0.08

    private(set) var origin: Sample?
    private(set) var samples: [Sample] = []
    private(set) var decision = Decision.undecided

    var translation: CGFloat { (samples.last?.x ?? 0) - (origin?.x ?? 0) }

    mutating func begin(_ sample: Sample) { origin = sample; samples = [sample]; decision = .undecided }

    @discardableResult
    mutating func move(_ sample: Sample) -> Decision {
        guard let origin else { return .undecided }
        samples.append(sample)
        if samples.count > 16 { samples.removeFirst(samples.count - 16) }
        if decision == .undecided {
            let dx = abs(sample.x - origin.x), dy = abs(sample.y - origin.y)
            if dx >= Self.beginDistance, dx > dy * Self.dominance { decision = .horizontal }
            else if dy >= Self.verticalDistance, dy > dx / Self.dominance { decision = .vertical }
        }
        return decision
    }

    /// Points per second sideways at `time` (the moment the finger lifts, or now): over the last `velocityWindow`, zero for a finger that has stopped.
    func velocity(at time: Double) -> CGFloat {
        guard let last = samples.last, time - last.time <= Self.velocityWindow else { return 0 }
        let recent = samples.filter { last.time - $0.time <= Self.velocityWindow }
        guard let first = recent.first, last.time - first.time > 0.004 else { return 0 }
        return (last.x - first.x) / CGFloat(last.time - first.time)
    }
}
