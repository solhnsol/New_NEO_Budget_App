/// A balance a notification printed for an account, at the time of the act it reports, with the change that act made.
public struct BalanceObservation: Equatable, Sendable {
    public let accountID: AccountID
    public let atUnixMilliseconds: Int64
    public let minorUnits: Int64
    /// What the same notification says it moved (outflow negative); 0 for a notice that moves no money.
    public let deltaMinorUnits: Int64
    public let notificationID: String

    public init(accountID: AccountID, atUnixMilliseconds: Int64, minorUnits: Int64, deltaMinorUnits: Int64, notificationID: String) {
        self.accountID = accountID
        self.atUnixMilliseconds = atUnixMilliseconds
        self.minorUnits = minorUnits
        self.deltaMinorUnits = deltaMinorUnits
        self.notificationID = notificationID
    }
}

/// Two consecutive balances of one account that do not follow ("previous balance + this change is not this balance"): a
/// notification went missing, or arrives later.
public struct BalanceBreak: Equatable, Sendable, Identifiable {
    public let before: BalanceObservation
    public let after: BalanceObservation
    /// The balance that was seen minus the one the chain expected. Negative: money left the account unseen.
    public let differenceMinorUnits: Int64

    public var accountID: AccountID { after.accountID }
    /// Names this exact gap. When a late notification lands inside it the pair changes and so does the key.
    public var id: String { "gap:\(before.notificationID):\(after.notificationID)" }
}

/// Finds where notified balances do not follow each other. Pure and notification-only: nothing is stored, the answer is
/// recomputed from the replay, so a notification that arrives late makes its break disappear by itself.
public enum BalanceChain {
    public static func breaks(observations: [BalanceObservation]) -> [BalanceBreak] {
        var result: [BalanceBreak] = []
        for (_, all) in Dictionary(grouping: observations, by: \.accountID) {
            var previous: BalanceObservation?
            for run in timeRuns(all) {
                // Notifications of one second cannot be put in order by time: take the one that continues the chain, else the
                // smallest ID (shortcut: a run with two real breaks inside it reports them in ID order).
                var rest = run.sorted { $0.notificationID < $1.notificationID }
                while !rest.isEmpty {
                    let index = previous.flatMap { last in rest.firstIndex { last.minorUnits + $0.deltaMinorUnits == $0.minorUnits } } ?? 0
                    let current = rest.remove(at: index)
                    if let last = previous {
                        let difference = current.minorUnits - last.minorUnits - current.deltaMinorUnits
                        if difference != 0 { result.append(BalanceBreak(before: last, after: current, differenceMinorUnits: difference)) }
                    }
                    previous = current
                }
            }
        }
        return result.sorted { ($0.after.atUnixMilliseconds, $0.id) < ($1.after.atUnixMilliseconds, $1.id) }
    }

    /// Whether 1 to 3 of the acts in the gap that are not links of the chain (signed: outflow negative) add up to the
    /// difference. Then the money is already accounted for by something recorded or waiting for the user, and a suggestion
    /// would count it twice.
    public static func isExplained(_ gap: BalanceBreak, by others: [Int64]) -> Bool {
        func search(_ start: Int, _ left: Int, _ target: Int64) -> Bool {
            if target == 0 && left < 3 { return true }
            guard left > 0 else { return false }
            return (start..<others.count).contains { search($0 + 1, left - 1, target - others[$0]) }
        }
        return gap.differenceMinorUnits != 0 && search(0, 3, gap.differenceMinorUnits)
    }

    private static func timeRuns(_ observations: [BalanceObservation]) -> [[BalanceObservation]] {
        let sorted = observations.sorted { ($0.atUnixMilliseconds, $0.notificationID) < ($1.atUnixMilliseconds, $1.notificationID) }
        return sorted.reduce(into: [[BalanceObservation]]()) { runs, item in
            if runs.last?.first?.atUnixMilliseconds == item.atUnixMilliseconds { runs[runs.count - 1].append(item) } else { runs.append([item]) }
        }
    }
}

/// A break the user confirmed as real money that left or entered the account. It becomes a ledger entry only while the same
/// break is still there after replaying every notification, which is how a late notification is never counted twice.
public struct ConfirmedGap: Codable, Equatable, Sendable {
    public let key: String
    public let accountID: AccountID
    /// Signed like the break's difference: negative is an expense.
    public let signedMinorUnits: Int64
    public let atUnixMilliseconds: Int64
    /// What the user called it ("식비").
    public let label: String

    public init(key: String, accountID: AccountID, signedMinorUnits: Int64, atUnixMilliseconds: Int64, label: String) {
        self.key = key
        self.accountID = accountID
        self.signedMinorUnits = signedMinorUnits
        self.atUnixMilliseconds = atUnixMilliseconds
        self.label = label
    }
}
