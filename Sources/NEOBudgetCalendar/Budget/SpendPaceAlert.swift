import Foundation

// "At this pace you'll go over" — the one alert on by default (docs: records/20261102-분석-예산-탭-설계.md §12.3, §13).
// The multiplier is the only setting; the 4-day and 15% guards are fixed and hidden.

public struct SpendPaceAlertState: Equatable, Codable, Sendable {
    public var sentCount = 0
    public var lastLevel: Double?
    public var lastSentOn: LocalDate?
    public init() {}
}

public struct SpendPaceAlert: Equatable, Sendable {
    public let projectedMinorUnits: Int64
    public let overMinorUnits: Int64
    public let ratio: Double
}

public enum SpendPaceAlerts {
    static let minimumElapsedDays = 4
    static let minimumUsedShare = 0.15
    static let maximumPerPeriod = 3
    /// Later alerts need the pace to get this much worse than the last one (1.3 → 1.6 → 2.0 for the default).
    static let escalationSteps = [0.3, 0.4]
    static let quietStartMinute = 21 * 60, quietEndMinute = 8 * 60

    /// `budget`/`spent`: the variable part of the period. `elapsedDays`: full days gone. Returns the alert to send, if any, and the state to keep
    /// (unchanged when nothing is sent; during quiet hours nothing is sent or recorded so a later check can still send it).
    public static func evaluate(
        budgetMinorUnits: Int64, spentMinorUnits: Int64, elapsedDays: Int, periodDays: Int, multiplier: Double = 1.3, state: SpendPaceAlertState,
        today: LocalDate, minuteOfDay: Int
    ) -> (alert: SpendPaceAlert?, state: SpendPaceAlertState) {
        guard budgetMinorUnits > 0, periodDays > 0, elapsedDays >= minimumElapsedDays, state.sentCount < maximumPerPeriod, state.lastSentOn != today,
              minuteOfDay >= quietEndMinute, minuteOfDay < quietStartMinute,
              Double(spentMinorUnits) >= Double(budgetMinorUnits) * minimumUsedShare else { return (nil, state) }
        let ratio = Double(spentMinorUnits) / (Double(budgetMinorUnits) * Double(elapsedDays) / Double(periodDays))
        let step = state.sentCount == 0 ? 0 : escalationSteps[min(state.sentCount - 1, escalationSteps.count - 1)]
        guard ratio >= multiplier, ratio >= (state.lastLevel ?? 0) + step else { return (nil, state) }
        let projected = Int64((Double(spentMinorUnits) * Double(periodDays) / Double(elapsedDays)).rounded())
        var next = state
        next.sentCount += 1
        next.lastLevel = ratio
        next.lastSentOn = today
        return (SpendPaceAlert(projectedMinorUnits: projected, overMinorUnits: max(projected - budgetMinorUnits, 0), ratio: ratio), next)
    }
}
