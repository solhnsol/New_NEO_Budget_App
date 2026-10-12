import CoreGraphics
import NEOBudgetCalendar

/// What the fixed grid is drawn in: the room, the text size. The same four numbers always give the same window.
struct FixedGridEnvironment: Equatable {
    var viewportHeight: CGFloat
    var contentWidth: CGFloat
    var textScale: CGFloat
    /// Identifies the Dynamic Type setting the title widths were measured at.
    var contentSize: String = ""
}

/// The decisions for the two days on screen (and the ones around them), made once for as long as the days and the environment stay the same: the partition of
/// the day into equal-height cells, and the engine's layout on that partition.
struct FixedGridWindow {
    let partition: TemporalGridPartition
    /// `nil` while a day on screen is waiting to be read, and when one of them has a daylight-saving transition (see `WallClockProjection`): such days are drawn
    /// from their own data and the axis, without the engine's decisions.
    let layout: AdaptiveLayout?
    let titleWidths: [String: CGFloat]
}

/// Plans the fixed grid for Browse's four days (D-1 ... D+2) and keeps the result until a day or the environment changes. A scroll, a swipe or a redraw finds it
/// there; the planner (the dynamic programme) and the layout engine run only when something they read has changed, never per frame. Not thread-safe: it lives with
/// the view that draws.
@MainActor
final class FixedGridBrowseModel {
    static let parameters = TemporalGridParameters.hourly(slotCount: 12)

    let store = TemporalGridStore()
    /// How many windows were decided, and how many times the layout engine ran. For tests and diagnostics.
    private(set) var windowRuns = 0
    private(set) var layoutRuns = 0
    private(set) var windowHits = 0
    var measureTitle: (String) -> CGFloat = { TextMeasurer.titleWidth($0) }

    private struct Key: Equatable {
        let days: [LocalDate]
        let timelines: [DayTimeline?]
        let environment: FixedGridEnvironment
    }
    private var key: Key?
    private var cached: FixedGridWindow?
    private var projections: [LocalDate: WallClockProjection] = [:]

    func projection(for day: LocalDate, zone: DisplayTimeZone) -> WallClockProjection {
        if let found = projections[day] { return found }
        if projections.count > 16 { projections.removeAll() }
        let made = WallClockProjection(day: day, zone: zone)
        projections[day] = made
        return made
    }

    /// The axis a day is drawn on: the partition's, seen in the day's own (elapsed) minutes.
    func axis(for day: LocalDate, partition: TemporalGridPartition, zone: DisplayTimeZone) -> ElapsedMinuteAxisMapping {
        ElapsedMinuteAxisMapping(inner: TemporalAxisMapping(partition: partition), projection: projection(for: day, zone: zone))
    }

    /// `strip` is the model's strip: D-1, D, D+1, D+2 (more only during a far jump, which is not part of the window).
    func window(strip: [StripDay], zone: DisplayTimeZone, environment: FixedGridEnvironment) -> FixedGridWindow? {
        let four = Array(strip.prefix(4))
        guard four.count == 4, environment.viewportHeight > 1 else { return nil }
        let newKey = Key(days: four.map(\.day), timelines: four.map(\.timeline), environment: environment)
        if newKey == key, let cached { windowHits += 1; return cached }
        windowRuns += 1

        let days = four.map { entry -> AllocationDay in
            guard let timeline = entry.timeline else { return AllocationDay(day: entry.day, totalMinutes: 1440, events: [], transactions: []) }
            return projection(for: entry.day, zone: zone).projected(AllocationDay(timeline))
        }
        var parameters = Self.parameters
        parameters.viewportHeight = environment.viewportHeight
        parameters.textScale = environment.textScale
        let partition = store.plan(window: TemporalWindow(days: days, mainIndex: 1), parameters: parameters).partition

        var layout: AdaptiveLayout?
        var widths: [String: CGFloat] = [:]
        if let main = four[1].timeline, let secondary = four[2].timeline, main.totalMinutes == 1440, secondary.totalMinutes == 1440 {
            var input = AllocationInput(
                main: AllocationDay(main), secondary: AllocationDay(secondary),
                viewportHeight: environment.viewportHeight, contentWidth: environment.contentWidth, textScale: environment.textScale
            )
            for timeline in [main, secondary] { for block in timeline.blocks { input.titleWidths[block.title] = measureTitle(block.title) } }
            input.fixedAxis = partition.timelineAxis().axis
            widths = input.titleWidths
            layout = AdaptiveLayoutEngine.layout(input)
            layoutRuns += 1
        } else {
            for entry in four { for block in entry.timeline?.blocks ?? [] { widths[block.title] = measureTitle(block.title) } }
        }
        let made = FixedGridWindow(partition: partition, layout: layout, titleWidths: widths)
        key = newKey
        cached = made
        return made
    }
}
