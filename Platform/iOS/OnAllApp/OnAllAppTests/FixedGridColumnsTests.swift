import CoreGraphics
import NEOBudgetCalendar
import Testing
@testable import OnAllApp

// Phase 2B-2: which decision each day on screen is drawn from while the days move, and the crossfade of the one day two decisions describe — on the product's
// data (fixtures: dense, overlapping, transaction-dense, midnight, 32 events, 3.0× text). Plus the pinch's easing back inside 1 … 8×.

private let seoul = (try? DisplayTimeZone(identifier: "Asia/Seoul")) ?? { fatalError("tz") }()
private typealias Columns = FixedGridColumns

// MARK: The rule

@Test func atRestEachDayHasOneDecisionTheSameAsBefore() {
    let bounds = 9...12
    for a in 9...11 {
        let columns = Columns.columns(days: a...(a + 1), position: Double(a), bounds: bounds)
        #expect(columns == [
            Columns.Column(epoch: a, from: .init(window: a, role: .main), to: nil, weight: 0),
            Columns.Column(epoch: a + 1, from: .init(window: a, role: .secondary), to: nil, weight: 0),
        ])
        #expect(columns == Columns.legacyColumns(days: a...(a + 1), position: Double(a), bounds: bounds))     // what the screen showed at rest
    }
}

@Test func betweenTwoDaysTheComingDayHasItsOwnDecisionAndTheSharedDayPassesWithinTheBand() {
    let bounds = 9...12
    for step in 1..<100 {
        let f = Double(step) / 100
        let columns = Columns.columns(days: 10...12, position: 10 + f, bounds: bounds)
        #expect(columns[0].from == .init(window: 10, role: .main) && columns[0].to == nil)
        #expect(columns[2].from == .init(window: 11, role: .secondary) && columns[2].to == nil)     // never without the engine
        let shared = columns[1]
        let w = Columns.weight(fraction: (10 + f) - 10)
        if w == 0 { #expect(shared.from == .init(window: 10, role: .secondary) && shared.to == nil) }
        else if w == 1 { #expect(shared.from == .init(window: 11, role: .main) && shared.to == nil) }
        else { #expect(shared.from == .init(window: 10, role: .secondary) && shared.to == .init(window: 11, role: .main)) }
        #expect(shared.dominant == (f < 0.5 ? Columns.Source(window: 10, role: .secondary) : Columns.Source(window: 11, role: .main)))
    }
    // The old rule changed every column at once at the halfway line, and drew the coming day without the engine.
    let before = Columns.legacyColumns(days: 10...12, position: 10.49, bounds: bounds), after = Columns.legacyColumns(days: 10...12, position: 10.51, bounds: bounds)
    #expect(zip(before, after).allSatisfy { $0.from != $1.from })
    #expect(before[2].from.role == nil)
}

@Test func theWeightIsSmoothAndMonotone() {
    var previous = Columns.weight(fraction: 0)
    var steepest = 0.0
    for step in 1...1000 {
        let w = Columns.weight(fraction: Double(step) / 1000)
        #expect(w >= previous)
        steepest = max(steepest, (w - previous) * 1000)
        previous = w
    }
    #expect(Columns.weight(fraction: 0.3) == 0 && Columns.weight(fraction: 0.7) == 1 && abs(Columns.weight(fraction: 0.5) - 0.5) < 1e-12)
    #expect(steepest < 3.76)                                                          // 1.5 / 0.4: a 1% move changes an opacity by under 4%
}

// MARK: On the product's data

private struct Rig {
    let timelines: [Int: DayTimeline]
    let first: Int
    let environment: FixedGridEnvironment
    let textScale: CGFloat

    init(_ prefix: String) throws {
        let scenario = try #require(TemporalGridFixtures.all.first { $0.name.hasPrefix(prefix) })
        let days = try scenario.days.map { try fixtureTimeline($0) }
        first = days[0].day.daysSinceUnixEpoch
        timelines = Dictionary(uniqueKeysWithValues: days.map { ($0.day.daysSinceUnixEpoch, $0) })
        textScale = scenario.textScale
        environment = FixedGridEnvironment(viewportHeight: 640, contentWidth: 165, textScale: scenario.textScale)
    }

    var inputs: FixedGridBrowseModel.Inputs {
        FixedGridBrowseModel.Inputs(zone: seoul, environment: environment, timelineFor: { [timelines] in timelines[$0.daysSinceUnixEpoch] }, revision: 0)
    }
}

/// Every event and transaction of a day, and how opaque it is drawn in total at one position: a card, a line or a row inside a card, an overflow card.
private struct Seen {
    var events: [String: Double] = [:]
    var transactions: [String: Double] = [:]
    /// How much of the day is drawn from each decision (1 in total).
    var shares: [Columns.Source: Double] = [:]
    var crossfaded = 0
}

@MainActor
private func seen(_ rig: Rig, model: FixedGridBrowseModel, preparations: DayPlanPreparations, position: Double, bounds: ClosedRange<Int>, zoomKey: Int = 4) -> [Int: Seen] {
    let geometry = DayAxisGeometry(dayWidth: 171, visibleColumns: 2)
    let shown = model.shared(position: position, bounds: bounds, inputs: rig.inputs)
    let columns = Columns.columns(days: geometry.renderedDays(at: position), position: position, bounds: bounds)
    var decisions: [Int: FixedGridBrowseModel.Decision] = [:]
    for window in Columns.windows(of: columns) { decisions[window] = model.decision(window: window, zoomKey: zoomKey, inputs: rig.inputs) }
    func plan(_ timeline: DayTimeline, _ source: Columns.Source) -> DayRenderPlan {
        model.renderPlan(timeline, source: source, decision: decisions[source.window]!, partition: shown, zone: seoul, layoutWidth: 60 + 171, textScale: rig.textScale,
                         metrics: nil, preparations: preparations)
    }
    var result: [Int: Seen] = [:]
    for column in columns {
        guard let timeline = rig.timelines[column.epoch] else { continue }
        var seen = Seen()
        func add(_ plan: DayRenderPlan, opacity: (Columns.Item) -> Double) {
            for event in plan.events {
                let o = opacity(event.blendItem)
                seen.events[event.block.id.rawValue, default: 0] += o
                for row in event.insideRows { seen.transactions[row.transactionID.rawValue, default: 0] += o }
            }
            for line in plan.lines { seen.transactions[line.id, default: 0] += opacity(.line(line.id)) }
            for overflow in plan.overflows {
                let o = opacity(.overflow(overflow.id))
                for member in overflow.members { seen.transactions[member.transactionID, default: 0] += o }
            }
        }
        let leaving = plan(timeline, column.from)
        if let to = column.to {
            let arriving = plan(timeline, to)
            let blend = Columns.blend(leaving, arriving)
            seen.crossfaded = blend.leaving.count + blend.arriving.count
            add(leaving) { blend.leaving.contains($0) ? 1 - column.weight : 0 }
            add(arriving) { blend.arriving.contains($0) ? column.weight : 1 }
            seen.shares = [column.from: 1 - column.weight, to: column.weight]
        } else {
            add(leaving) { _ in 1 }
            seen.shares = [column.from: 1]
        }
        result[column.epoch] = seen
    }
    return result
}

@MainActor
@Test func whileTheDaysMoveEveryEventAndTransactionIsDrawnOnceInTotalAndNothingChangesInOneFrame() throws {
    var crossfadedSomewhere = 0
    for prefix in ["3 ", "6 ", "7 ", "8 ", "14 ", "16 ", "17 ", "18 ", "19 "] {
        let rig = try Rig(prefix)
        let model = FixedGridBrowseModel()
        let preparations = DayPlanPreparations(limit: 16)
        let selected = rig.first + 2
        let bounds = (selected - 1)...(selected + 2)
        // Forward a day in 1% steps, back again (a reversal), and a day back from the selected one.
        let base = Double(selected)
        let forward: [Double] = (0...100).map { base + Double($0) / 100 }
        let back: [Double] = forward.reversed()
        let before: [Double] = (0...100).map { base - Double($0) / 100 }
        let path = forward + back + before
        var previous: [Int: Seen] = [:]
        var largestStep = 0.0
        for position in path {
            let now = seen(rig, model: model, preparations: preparations, position: position, bounds: bounds)
            for (epoch, day) in now {
                let timeline = try #require(rig.timelines[epoch])
                for block in timeline.blocks { #expect(abs((day.events[block.id.rawValue] ?? 0) - 1) < 1e-9, "\(prefix) \(position) event \(block.title) drawn \(day.events[block.id.rawValue] ?? 0)") }
                for (id, total) in day.transactions { #expect(abs(total - 1) < 1e-9, "\(prefix) \(position) transaction \(id) drawn \(total)") }
                if position == position.rounded() { #expect(day.crossfaded == 0) }
                crossfadedSomewhere += day.crossfaded
                if let before = previous[epoch] {
                    // How far the day's drawing moved from one decision to another in this 1% of a day (the old rule: 2 at the halfway line).
                    let change = Set(day.shares.keys).union(before.shares.keys).reduce(0) { $0 + abs((day.shares[$1] ?? 0) - (before.shares[$1] ?? 0)) }
                    largestStep = max(largestStep, change)
                }
            }
            // Every transaction of a day is drawn somewhere (as a line, a row or in an overflow card).
            for (epoch, day) in now { #expect(Set(day.transactions.keys).isSuperset(of: transactionIDs(rig.timelines[epoch]!)), "\(prefix) \(position) a transaction is missing") }
            previous = now
        }
        #expect(largestStep < 0.08, "\(prefix) largest per-step change \(largestStep)")
        // The engine ran once per window, never per frame, and nothing was planned per frame beyond the windows.
        #expect(model.continuousLayoutRuns <= 4 && model.framePlans <= 4, "\(prefix) engine \(model.continuousLayoutRuns), plans \(model.framePlans)")
    }
    // Measured: on these fixtures the two windows draw the shared day the same way (once it is on the shared axis), so nothing is crossfaded here; the
    // crossfade itself is checked below on a pair that differs.
    print("MEASURE 2b2 crossfaded items over the sweeps: \(crossfadedSomewhere)")
}

@MainActor
@Test func whereTwoDecisionsDifferTheDayIsCrossfadedWithNothingLostOrDoubled() throws {
    var differing = 0
    for prefix in ["14 ", "16 ", "17 ", "18 ", "19 "] {
        let rig = try Rig(prefix)
        let model = FixedGridBrowseModel()
        let preparations = DayPlanPreparations(limit: 16)
        let selected = rig.first + 2
        let shown = model.shared(position: Double(selected) + 0.5, bounds: (selected - 1)...(selected + 2), inputs: rig.inputs)
        let timeline = try #require(rig.timelines[selected + 1])
        // The same day without the engine's decision and with it: lines become rows or overflow cards, cards change level — two drawings that differ.
        let bare = model.renderPlan(timeline, source: .init(window: selected, role: nil), decision: .init(layout: nil, titleWidths: [:]), partition: shown, zone: seoul,
                                    layoutWidth: 231, textScale: rig.textScale, metrics: nil, preparations: preparations)
        let decided = model.renderPlan(timeline, source: .init(window: selected + 1, role: .main), decision: model.decision(window: selected + 1, zoomKey: 4, inputs: rig.inputs),
                                       partition: shown, zone: seoul, layoutWidth: 231, textScale: rig.textScale, metrics: nil, preparations: preparations)
        let blend = Columns.blend(bare, decided)
        differing += blend.leaving.count + blend.arriving.count
        for w in stride(from: 0.0, through: 1.0, by: 0.1) {
            var events: [String: Double] = [:], transactions: [String: Double] = [:]
            func add(_ plan: DayRenderPlan, _ opacity: (Columns.Item) -> Double) {
                for event in plan.events {
                    let o = opacity(event.blendItem); events[event.block.id.rawValue, default: 0] += o
                    for row in event.insideRows { transactions[row.transactionID.rawValue, default: 0] += o }
                }
                for line in plan.lines { transactions[line.id, default: 0] += opacity(.line(line.id)) }
                for overflow in plan.overflows { for member in overflow.members { transactions[member.transactionID, default: 0] += opacity(.overflow(overflow.id)) } }
            }
            add(bare) { blend.leaving.contains($0) ? 1 - w : 0 }
            add(decided) { blend.arriving.contains($0) ? w : 1 }
            #expect(timeline.blocks.allSatisfy { abs((events[$0.id.rawValue] ?? 0) - 1) < 1e-9 }, "\(prefix) w \(w): an event drawn other than once")
            #expect(transactions.values.allSatisfy { abs($0 - 1) < 1e-9 }, "\(prefix) w \(w): a transaction drawn other than once")
            #expect(Set(transactions.keys).isSuperset(of: transactionIDs(timeline)), "\(prefix) w \(w): a transaction missing")
        }
    }
    #expect(differing > 0)
}

private func transactionIDs(_ timeline: DayTimeline) -> Set<String> {
    Set(timeline.markers.map(\.transactionID.rawValue)).union(timeline.blocks.flatMap(\.allocations).filter(\.occursOnSelectedDay).map(\.transactionID.rawValue))
}

@MainActor
@Test func theComingDayIsDrawnWithTheDecisionItWillHaveAtRest() throws {
    for prefix in ["3 ", "16 ", "18 "] {
        let rig = try Rig(prefix)
        let model = FixedGridBrowseModel()
        let preparations = DayPlanPreparations(limit: 16)
        let selected = rig.first + 2
        let bounds = (selected - 1)...(selected + 2)
        let rest = seen(rig, model: model, preparations: preparations, position: Double(selected + 1), bounds: bounds)[selected + 2]!
        for f in stride(from: 0.05, through: 0.95, by: 0.15) {
            let moving = seen(rig, model: model, preparations: preparations, position: Double(selected) + f, bounds: bounds)[selected + 2]!
            #expect(moving.crossfaded == 0 && moving.shares == rest.shares && Set(moving.events.keys) == Set(rest.events.keys), "\(prefix) \(f)")   // one decision, the rest one
        }
    }
}

@MainActor
@Test func atRestATouchHasOnePlanToGoTo() throws {
    let rig = try Rig("16 ")
    let model = FixedGridBrowseModel()
    let selected = rig.first + 2
    let bounds = (selected - 1)...(selected + 2)
    for position in [Double(selected), Double(selected + 1)] {
        let columns = Columns.columns(days: DayAxisGeometry(dayWidth: 171, visibleColumns: 2).renderedDays(at: position), position: position, bounds: bounds)
        #expect(columns.allSatisfy { $0.to == nil })
        _ = model
    }
}

// MARK: Pinch easing back inside 1 … 8×

@MainActor
@Test func aPinchThatEasesBackIsPlannedForWhereItComesToRest() throws {
    let model = FixedGridBrowseModel()
    #expect(model.plannedZoomKey(current: 8.6, settling: 8) == 32)
    #expect(model.plannedZoomKey(current: 9.4, settling: nil) == 32)                 // held to 8×: no decision for a zoom nobody rests at
    #expect(model.plannedZoomKey(current: 0.7, settling: 1) == 4 && model.plannedZoomKey(current: 0.6, settling: nil) == 4)
    #expect(model.plannedZoomKey(current: 3.1, settling: nil) == 12)

    let rig = try Rig("17 ")
    let w = rig.first + 2
    _ = model.decision(window: w, zoomKey: 4, inputs: rig.inputs)
    let runs = model.continuousLayoutRuns
    // The frames of the easing back (8.6× … 8×) ask for the settled key while easing: none runs the engine.
    for zoom in stride(from: 8.6, through: 8.0, by: -0.05) {
        let key = model.plannedZoomKey(current: CGFloat(zoom), settling: 8)
        _ = model.decisionForDrawing(window: w, zoomKey: key, isInteracting: true, inputs: rig.inputs)
    }
    #expect(model.continuousLayoutRuns == runs && model.drawingEngineRuns == 0)
    // At rest the settled key's decision is made once (between frames in the screen; here directly), and then found.
    _ = model.decision(window: w, zoomKey: 32, inputs: rig.inputs)
    _ = model.decisionForDrawing(window: w, zoomKey: 32, isInteracting: false, inputs: rig.inputs)
    #expect(model.continuousLayoutRuns == runs + 1)
}

