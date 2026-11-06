import Foundation

/// How often two people appear in the same Activities, weighted so a few small, recent gatherings count for
/// more than one big, old one. This is only a *co-occurrence* signal. It never says friend, partner, or family:
/// relationship labels exist only when the user states them (`Person.relationshipLabel`).

public struct AffinityConfiguration: Equatable, Sendable {
    /// After this many days an Activity counts half as much as one that happened now.
    public let recencyHalfLifeDays: Double

    public init(recencyHalfLifeDays: Double = 180) {
        self.recencyHalfLifeDays = max(1, recencyHalfLifeDays)
    }
}

/// An unordered pair of people, stored in a fixed order so it can be a dictionary key.
public struct PersonPair: Hashable, Comparable, Sendable {
    public let first: PersonID
    public let second: PersonID

    public init(_ a: PersonID, _ b: PersonID) {
        first = min(a, b)
        second = max(a, b)
    }

    public static func < (lhs: PersonPair, rhs: PersonPair) -> Bool { (lhs.first, lhs.second) < (rhs.first, rhs.second) }

    public func contains(_ person: PersonID) -> Bool { first == person || second == person }
    public func other(than person: PersonID) -> PersonID { first == person ? second : first }
}

public struct PairAffinity: Equatable, Sendable {
    public let pair: PersonPair
    /// How many Activities both took part in. Raw count, no weighting.
    public let coOccurrenceCount: Int
    /// Sum over shared Activities of `smallGroupWeight × recencyWeight`. Larger means closer co-occurrence.
    public let weightedScore: Double
    public let lastTogetherUnixMilliseconds: Int64
    public let commonActivityTypes: [ActivityTypeID: Int]
}

public struct ParticipantRecommendation: Equatable, Sendable {
    public let personID: PersonID
    public let score: Double
    /// With how many of the already chosen people this person has appeared before.
    public let supportingPairs: Int
}

public enum ParticipantAffinityCalculator {
    private static let millisecondsPerDay = 86_400_000.0

    /// Pair affinities from every Activity with at least two participants besides the user.
    ///
    /// A shared Activity adds `1 / (n - 1)` where `n` is how many people other than the user took part, so a
    /// dinner for three outweighs a lecture of thirty: eight dinners are worth about four points, eight
    /// lectures about a quarter of one. Recency halves the weight every `recencyHalfLifeDays`.
    public static func affinities(
        in life: LifeState,
        now: Int64,
        configuration: AffinityConfiguration = AffinityConfiguration()
    ) -> [PersonPair: PairAffinity] {
        let selfIDs = Set(life.persons.values.filter(\.isSelf).map(\.id))
        var counts: [PersonPair: Int] = [:]
        var scores: [PersonPair: Double] = [:]
        var last: [PersonPair: Int64] = [:]
        var types: [PersonPair: [ActivityTypeID: Int]] = [:]

        for activity in life.activities.values {
            let people = Set(activity.participants.map(\.personID)).subtracting(selfIDs).sorted()
            guard people.count >= 2 else { continue }
            let start = startInstant(of: activity.time)
            let ageDays = max(0, Double(now - start)) / millisecondsPerDay
            let weight = (1.0 / Double(people.count - 1)) * pow(0.5, ageDays / configuration.recencyHalfLifeDays)
            for i in 0..<people.count {
                for j in (i + 1)..<people.count {
                    let pair = PersonPair(people[i], people[j])
                    counts[pair, default: 0] += 1
                    scores[pair, default: 0] += weight
                    last[pair] = max(last[pair] ?? Int64.min, start)
                    if let type = activity.activityType?.value { types[pair, default: [:]][type, default: 0] += 1 }
                }
            }
        }
        var result: [PersonPair: PairAffinity] = [:]
        for (pair, count) in counts {
            result[pair] = PairAffinity(
                pair: pair, coOccurrenceCount: count, weightedScore: scores[pair] ?? 0,
                lastTogetherUnixMilliseconds: last[pair] ?? 0, commonActivityTypes: types[pair] ?? [:]
            )
        }
        return result
    }

    /// People most likely to be added next, given those already on the Activity. Ranked by summed pair score;
    /// the user and anyone already chosen are excluded. Returns nothing when no one has appeared with them.
    public static func recommend(
        given chosen: [PersonID],
        in life: LifeState,
        now: Int64,
        limit: Int = 5,
        configuration: AffinityConfiguration = AffinityConfiguration()
    ) -> [ParticipantRecommendation] {
        let chosenSet = Set(chosen)
        guard !chosenSet.isEmpty, limit > 0 else { return [] }
        let affinities = affinities(in: life, now: now, configuration: configuration)
        var scores: [PersonID: Double] = [:]
        var supporting: [PersonID: Int] = [:]
        for (pair, affinity) in affinities {
            for person in chosenSet where pair.contains(person) {
                let candidate = pair.other(than: person)
                guard !chosenSet.contains(candidate), life.persons[candidate]?.isSelf == false else { continue }
                scores[candidate, default: 0] += affinity.weightedScore
                supporting[candidate, default: 0] += 1
            }
        }
        return scores
            .filter { $0.value > 0 }
            .map { ParticipantRecommendation(personID: $0.key, score: $0.value, supportingPairs: supporting[$0.key] ?? 0) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.personID < $1.personID }
            .prefix(limit)
            .map { $0 }
    }

    private static func startInstant(of time: EventTimeRange) -> Int64 {
        switch time {
        case let .timed(range): return range.startUnixMilliseconds
        case let .allDay(range): return Int64(range.firstDay.daysSinceUnixEpoch) * 86_400_000
        }
    }
}
