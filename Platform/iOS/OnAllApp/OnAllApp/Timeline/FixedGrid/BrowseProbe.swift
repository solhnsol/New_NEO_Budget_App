import Foundation
import QuartzCore
import os

/// Measurements of the fixed-grid Browse's main thread, for finding what holds a frame back. DEBUG builds record only when asked (`-browse-temporal-probe <path>`,
/// or a `-browse-temporal-script` run); a Release build compiles every call to a plain call of its body.
///
/// What is recorded, all on the main thread and on one clock (`CACurrentMediaTime`, the display link's):
/// - **spans** of the app's own work by `Kind`, with their nesting depth (also emitted as signposts, subsystem `dev.onall.app`, category `browse`, for Instruments);
/// - **run-loop turns**: from the main run loop waking to it going back to sleep. A turn holds everything the main thread did then, including what is not the
///   app's code: SwiftUI's graph update, UIKit layout, Core Animation's commit (its observer runs before ours goes to sleep);
/// - **display frames**: the display link's intervals. A frame is late when its interval is more than 1.5× the median.
///
/// A late frame is attributed to what overlapped it: the app's spans by kind, and the rest of the busiest turn in it (`unattributed`: framework work, or app
/// code that is not wrapped). That split is measured; what the unattributed part is made of is not (a time profile would say).
@MainActor
enum BrowseProbe {
    enum Kind: String, CaseIterable, Sendable {
        /// `FixedGridBrowseView.body` (the screen around the grid).
        case screenBody
        /// The grid content's SwiftUI tree built for one frame (`PinchZoomScrollView.Host`).
        case gridBuild
        /// The hosting controller's layout pass (`viewWillLayoutSubviews` … `viewDidLayoutSubviews`): SwiftUI laying out the grid in UIKit's layout.
        case hostLayout
        /// One step of the day move (position, week-strip pending day, prefetch request, anchor).
        case applyMove
        /// A partition planned in a frame (none was ready).
        case framePlan
        /// The layout engine (`AdaptiveLayoutEngine.layout`) for one window and zoom.
        case engine
        /// Planning ahead between frames (`warmAhead`, which runs the engine for the rested zoom).
        case warmAhead
        /// A partition planned off the main thread landing (bookkeeping and the redraw request).
        case warmLand
        /// A day read landing in the cache (merge and eviction), or a reload replacing it.
        case cacheMerge
        /// `Haptics.snap()` as the week strip's pending day changes.
        case haptics
        /// One pinch step in the scroll view (content size, offset, zoom).
        case pinchStep
        /// One step of an axis transition after a day arrived.
        case transitionTick
        /// Comparing the two plans of the day that passes from one window's decision to the next (`FixedGridColumns.blend`).
        case blend
        /// The screen around the grid (`DayTimelineScreen.body`: header, week strip, summary), the week strip's body and the summary bar's body. Measured to
        /// tell the grid's SwiftUI work from the screen's around it.
        case outerBody, weekStripBody, summaryBody
    }

    enum Mark: String, Sendable {
        case boundary, dragBegan, released, rested, pinchBegan, pinchEnded, dayLanded, axisTransition, held, selectedDayChanged
    }

    struct Token {
        #if DEBUG
        let kind: Kind
        let start: CFTimeInterval
        let state: OSSignpostIntervalState?
        #endif
    }

    @inline(__always)
    static func measure<T>(_ kind: Kind, _ body: () throws -> T) rethrows -> T {
        #if DEBUG
        guard BrowseProbeRecorder.shared.enabled else { return try body() }
        let token = begin(kind)
        defer { end(token) }
        return try body()
        #else
        return try body()
        #endif
    }

    static func begin(_ kind: Kind) -> Token? {
        #if DEBUG
        BrowseProbeRecorder.shared.begin(kind)
        #else
        nil
        #endif
    }

    static func end(_ token: Token?) {
        #if DEBUG
        if let token { BrowseProbeRecorder.shared.end(token) }
        #endif
    }

    static func mark(_ mark: Mark) {
        #if DEBUG
        BrowseProbeRecorder.shared.mark(mark)
        #endif
    }
}

/// Switches for the experiments that separate the causes of late frames (phase 2B-2). DEBUG launch arguments; always off in Release.
/// - `-probe-h1-strip-off`: the week strip's pending day is not updated while the days move (the haptic still fires at the same moment).
/// - `-probe-h1-layout-held` (measured on the 2B-1 code, commit 02d4d9f; gone with the per-column decisions of 2B-2): the decisions stayed those of the selected
///   day's window while the days moved.
/// - `-probe-h2-prewarm-haptics`: one selection feedback generator, prepared when the grid appears, is used for every snap (measured; the fixed grid now
///   always does this).
/// - `-probe-h3-stable-root`: the grid's hosting controller keeps one root view; a new frame's content reaches it through an observed box.
enum ProbeExperiment {
    static let stripOff = flag("-probe-h1-strip-off")
    static let stableRoot = flag("-probe-h3-stable-root")
    /// Before/after: the 2B-1 rules — decisions from the window nearest the position (`FixedGridColumns.legacyColumns`), and the zoom key of the frames
    /// and the rested zoom from the zoom as it is when the pinch ends (not where it comes to rest).
    static let legacyColumns = flag("-probe-legacy-columns")
    static let legacyZoomKey = flag("-probe-legacy-zoom-key")

    private static func flag(_ name: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(name)
        #else
        false
        #endif
    }
}

#if DEBUG
/// The recorder behind `BrowseProbe`. DEBUG only.
@MainActor
final class BrowseProbeRecorder {
    static let shared = BrowseProbeRecorder()

    struct Span { let kind: BrowseProbe.Kind; let start: CFTimeInterval; let duration: CFTimeInterval; let depth: Int }
    struct Interval { let start: CFTimeInterval; let end: CFTimeInterval; var duration: CFTimeInterval { end - start } }

    private(set) var enabled = false
    private(set) var spans: [Span] = []
    private(set) var marks: [(mark: BrowseProbe.Mark, time: CFTimeInterval)] = []
    private(set) var turns: [Interval] = []
    private(set) var frames: [Interval] = []
    private(set) var startedAt: CFTimeInterval = 0
    private var depth = 0
    private var turnStart: CFTimeInterval?
    private var observers: [CFRunLoopObserver] = []
    private var ticker: Ticker?
    private let signposter = OSSignposter(subsystem: "dev.onall.app", category: "browse")
    private static let limit = 60_000

    /// Starts (or restarts) recording from now.
    func start() {
        reset()
        guard !enabled else { return }
        enabled = true
        let main = CFRunLoopGetMain()
        let woke = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { BrowseProbeRecorder.shared.turnBegan() }
        }
        let sleeps = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { BrowseProbeRecorder.shared.turnEnded() }
        }
        for observer in [woke, sleeps].compactMap({ $0 }) { CFRunLoopAddObserver(main, observer, .commonModes); observers.append(observer) }
        let ticker = Ticker { [weak self] previous, now in self?.frame(previous, now) }
        ticker.start()
        self.ticker = ticker
    }

    /// Forgets what was recorded (recording goes on).
    func reset() {
        spans.removeAll(keepingCapacity: true); marks.removeAll(keepingCapacity: true)
        turns.removeAll(keepingCapacity: true); frames.removeAll(keepingCapacity: true)
        startedAt = CACurrentMediaTime()
        turnStart = nil
        ticker?.restart()
    }

    func stop() {
        enabled = false
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers = []
        ticker?.stop(); ticker = nil
    }

    func begin(_ kind: BrowseProbe.Kind) -> BrowseProbe.Token? {
        guard enabled else { return nil }
        depth += 1
        let state = signposter.beginInterval("work", id: signposter.makeSignpostID(), "\(kind.rawValue, privacy: .public)")
        return BrowseProbe.Token(kind: kind, start: CACurrentMediaTime(), state: state)
    }

    func end(_ token: BrowseProbe.Token) {
        let now = CACurrentMediaTime()
        depth = max(0, depth - 1)
        if let state = token.state { signposter.endInterval("work", state) }
        guard enabled, spans.count < Self.limit else { return }
        spans.append(Span(kind: token.kind, start: token.start, duration: now - token.start, depth: depth))
    }

    func mark(_ mark: BrowseProbe.Mark) {
        guard enabled, marks.count < Self.limit else { return }
        signposter.emitEvent("mark", "\(mark.rawValue, privacy: .public)")
        marks.append((mark, CACurrentMediaTime()))
    }

    private func turnBegan() { turnStart = CACurrentMediaTime() }

    private func turnEnded() {
        guard let begun = turnStart else { return }
        turnStart = nil
        if turns.count < Self.limit { turns.append(Interval(start: begun, end: CACurrentMediaTime())) }
    }

    private func frame(_ previous: CFTimeInterval, _ now: CFTimeInterval) {
        if frames.count < Self.limit { frames.append(Interval(start: previous, end: now)) }
    }

    // MARK: Report

    private static func ms(_ seconds: CFTimeInterval) -> Double { seconds * 1000 }

    private static func stats(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n=0" }
        let sorted = values.sorted()
        let p = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        return String(format: "n=%d mean %.3f p50 %.3f p99 %.3f max %.3f ms", values.count, values.reduce(0, +) / Double(values.count), p(0.5), p(0.99), sorted.last ?? 0)
    }

    /// What was recorded since `start`/`reset`, with every late frame and what overlapped it.
    func report(title: String) -> String {
        let intervals = frames.map { Self.ms($0.duration) }
        let nominal = intervals.sorted().dropFirst(intervals.count / 2).first ?? 16.7
        let late = frames.filter { Self.ms($0.duration) > nominal * 1.5 }
        var lines: [String] = []
        lines.append("PROBE \(title)")
        lines.append(String(format: "recorded %.2f s; display frames %@; nominal %.2f ms; late (>1.5x) %d", CACurrentMediaTime() - startedAt, Self.stats(intervals), nominal, late.count))
        lines.append("main run-loop turns busy: \(Self.stats(turns.map { Self.ms($0.duration) }))")
        for kind in BrowseProbe.Kind.allCases {
            let values = spans.filter { $0.kind == kind }.map { Self.ms($0.duration) }
            if !values.isEmpty { lines.append("  \(kind.rawValue): \(Self.stats(values))") }
        }
        let markCounts = Dictionary(grouping: marks, by: \.mark).map { "\($0.key.rawValue) \($0.value.count)" }.sorted().joined(separator: ", ")
        lines.append("marks: \(markCounts.isEmpty ? "—" : markCounts)")
        // The main-thread turn each mark fell in, and the next one (what the change set off is often drawn in the turn after): the cost of that moment, whatever
        // the display did.
        for (mark, entries) in Dictionary(grouping: marks, by: \.mark).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let costs: [Double] = entries.compactMap { entry in
                guard let index = turns.firstIndex(where: { $0.start <= entry.time && entry.time <= $0.end }) else { return nil }
                let next = turns.indices.contains(index + 1) && turns[index + 1].start - turns[index].end < 0.017 ? turns[index + 1].duration : 0
                return Self.ms(turns[index].duration + next)
            }
            if !costs.isEmpty { lines.append("  turn at \(mark.rawValue): \(Self.stats(costs))") }
        }
        var attributedTotal = 0.0, unattributedTotal = 0.0
        var byKind: [BrowseProbe.Kind: Double] = [:]
        var withMark: [String: Int] = [:]
        for frame in late {
            let window = Interval(start: frame.start, end: frame.end)
            let inside = spans.filter { $0.start < window.end && $0.start + $0.duration > window.start }
            let busiest = turns.filter { $0.start < window.end && $0.end > window.start }.max { $0.duration < $1.duration }
            let topLevel = inside.filter { $0.depth == 0 }
            let inTurn = busiest.map { turn in topLevel.filter { $0.start >= turn.start && $0.start < turn.end } } ?? []
            let attributed = inTurn.reduce(0) { $0 + $1.duration }
            let unattributed = max(0, (busiest?.duration ?? 0) - attributed)
            attributedTotal += Self.ms(attributed); unattributedTotal += Self.ms(unattributed)
            var kinds: [BrowseProbe.Kind: Double] = [:]
            for span in inside { kinds[span.kind, default: 0] += Self.ms(span.duration) }
            for (kind, value) in kinds { byKind[kind, default: 0] += value }
            let nearby = marks.filter { $0.time > window.start - 0.034 && $0.time < window.end + 0.017 }.map(\.mark.rawValue)
            for name in Set(nearby) { withMark[name, default: 0] += 1 }
            let parts = kinds.sorted { $0.value > $1.value }.map { String(format: "%@ %.1f", $0.key.rawValue, $0.value) }.joined(separator: ", ")
            lines.append(String(format: "  late +%.3fs %.1f ms: busiest turn %.1f ms (app %.1f, unattributed %.1f) [%@] marks [%@]",
                                frame.end - startedAt, Self.ms(frame.duration), Self.ms(busiest?.duration ?? 0), Self.ms(attributed), Self.ms(unattributed),
                                parts.isEmpty ? "—" : parts, nearby.joined(separator: " ")))
        }
        if !late.isEmpty {
            let kinds = byKind.sorted { $0.value > $1.value }.map { String(format: "%@ %.1f", $0.key.rawValue, $0.value) }.joined(separator: ", ")
            lines.append(String(format: "late frames, summed: app spans %.1f ms, unattributed %.1f ms; by kind (inclusive) [%@]", attributedTotal, unattributedTotal, kinds))
            lines.append("late frames near a mark: " + withMark.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// The display link, kept apart so the recorder is not an `NSObject`.
    @MainActor private final class Ticker: NSObject {
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private let tick: @MainActor (CFTimeInterval, CFTimeInterval) -> Void
        init(tick: @escaping @MainActor (CFTimeInterval, CFTimeInterval) -> Void) { self.tick = tick }
        func start() { let link = CADisplayLink(target: self, selector: #selector(step(_:))); link.add(to: .main, forMode: .common); self.link = link }
        func restart() { last = 0 }
        func stop() { link?.invalidate(); link = nil }
        @objc private func step(_ link: CADisplayLink) {
            if last > 0 { tick(last, link.timestamp) }
            last = link.timestamp
        }
    }
}
#endif
