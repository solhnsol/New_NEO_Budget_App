import CoreGraphics

/// The fixed grid as a `TimeAxisMapping`: the partition at the zoom it is drawn at, plus the constants of the column. Minutes are the grid's
/// own axis (wall-clock minutes of the day, 0...1440: see `DayWallClock`). Exact for fractional minutes, so a partition between two days
/// (`TemporalGridPartition.interpolated`) is as exact as one at rest.
struct TemporalAxisMapping: TimeAxisMapping, Equatable {
    var partition: TemporalGridPartition
    var gutterWidth: CGFloat = 60
    var trailingPadding: CGFloat = 6
    var columnSpacing: CGFloat = 2
    var minimumBlockHeight: CGFloat = 24

    init(partition: TemporalGridPartition) { self.partition = partition }

    var totalMinutes: Int { TemporalGridPartition.minutesPerDay }
    var contentHeight: CGFloat { partition.totalHeight }

    func y(minute: Int) -> CGFloat { partition.timeToY(Double(minute)) }
    func y(exactMinute minute: Double) -> CGFloat { partition.timeToY(minute) }
    func minute(atY y: CGFloat) -> Int { Int(partition.yToTime(y).rounded()) }
    func exactMinute(atY y: CGFloat) -> Double { partition.yToTime(y) }
}
