import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import OnAllApp

// Phase 3A, the precision bubble on its own: where it goes next to a handle (preferred side, flips at the screen's edges, sideways clamping with the arrow
// following the handle, beside / clamped when nothing fits, pinned when the handle scrolls away, hysteresis), that it never covers the handle's touch circle,
// what it says (date and time in the event's zone, midnight as the next day, VoiceOver), that it is controlled (off controls emit nothing, nothing else is
// computed), and how its anchor follows a scroll and a pinch.

private typealias L = PrecisionBubbleLayout
private let seoul = TimeZone(identifier: "Asia/Seoul")!
/// 2026-10-13 14:15 in Seoul.
private let afternoon = Date(timeIntervalSince1970: 1_791_817_200 + 14 * 3600 + 15 * 60)
/// The visible grid of a 393 × 700 viewport with 8pt margins.
private let area = CGRect(x: 8, y: 8, width: 377, height: 684)
private let size = CGSize(width: 232, height: 128)

private func place(_ anchor: CGPoint, _ edge: PrecisionEdge, size: CGSize = size, bounds: CGRect = area, previous: L.Side? = nil) -> L.Placement {
    L.place(anchor: anchor, edge: edge, size: size, bounds: bounds, previous: previous)
}

/// The bubble (body and arrow) keeps out of the handle's touch circle.
private func clearsHandle(_ placement: L.Placement, _ anchor: CGPoint, radius: CGFloat = EditHit.handleRadius) -> Bool {
    let nearestX = min(max(anchor.x, placement.frame.minX), placement.frame.maxX)
    let nearestY = min(max(anchor.y, placement.frame.minY), placement.frame.maxY)
    let bodyClear = hypot(anchor.x - nearestX, anchor.y - nearestY) >= radius - 0.01
    let tipClear = placement.arrowTip.map { hypot($0.x - anchor.x, $0.y - anchor.y) >= radius - 0.01 } ?? true
    return bodyClear && tipClear
}

private func inside(_ frame: CGRect, _ bounds: CGRect = area) -> Bool { bounds.insetBy(dx: -0.01, dy: -0.01).contains(frame) }

// MARK: Placement

@Test func theStartBubbleSitsAboveItsHandleAndTheEndBubbleBelow() {
    let anchor = CGPoint(x: 200, y: 350)
    let start = place(anchor, .start), end = place(anchor, .end)
    #expect(start.side == .above && end.side == .below)
    #expect(start.frame.maxY == anchor.y - EditHit.handleRadius - L.arrowLength)
    #expect(end.frame.minY == anchor.y + EditHit.handleRadius + L.arrowLength)
    // Centred on the handle, the arrow's tip on the touch circle straight above / below it.
    #expect(start.frame.midX == anchor.x && start.arrowTip == CGPoint(x: anchor.x, y: anchor.y - EditHit.handleRadius))
    #expect(end.arrowTip == CGPoint(x: anchor.x, y: anchor.y + EditHit.handleRadius))
    for placement in [start, end] { #expect(inside(placement.frame) && clearsHandle(placement, anchor) && placement.anchorVisible) }
}

@Test func nearTheTopOrBottomItFlipsToTheOtherSide() {
    let nearTop = CGPoint(x: 200, y: 40), nearBottom = CGPoint(x: 200, y: 680)
    #expect(place(nearTop, .start).side == .below)
    #expect(place(nearTop, .end).side == .below)
    #expect(place(nearBottom, .end).side == .above)
    #expect(place(nearBottom, .start).side == .above)
    // Exactly at the line where the preferred side just fits it stays; a point further, it flips.
    let line = area.minY + size.height + L.arrowLength + EditHit.handleRadius
    #expect(place(CGPoint(x: 200, y: line), .start).side == .above)
    #expect(place(CGPoint(x: 200, y: line - 1), .start).side == .below)
    for anchor in [nearTop, nearBottom] {
        for edge in [PrecisionEdge.start, .end] {
            let placement = place(anchor, edge)
            #expect(inside(placement.frame) && clearsHandle(placement, anchor))
        }
    }
}

@Test func atTheLeftAndRightEdgesItStaysOnScreenAndTheArrowFollowsTheHandle() {
    for x in stride(from: area.minX, through: area.maxX, by: 7) {
        for edge in [PrecisionEdge.start, .end] {
            let anchor = CGPoint(x: x, y: 350)
            let placement = place(anchor, edge)
            #expect(inside(placement.frame))
            #expect(clearsHandle(placement, anchor))
            let tip = try! #require(placement.arrowTip)
            let low = placement.frame.minX + L.cornerRadius + L.arrowHalfWidth, high = placement.frame.maxX - L.cornerRadius - L.arrowHalfWidth
            // The arrow points at the handle wherever the rounded corners allow, and stays off them otherwise.
            #expect(tip.x >= low - 0.01 && tip.x <= high + 0.01)
            if x >= low && x <= high { #expect(abs(tip.x - x) < 0.01) }
        }
    }
    #expect(place(CGPoint(x: 20, y: 350), .start).frame.minX == area.minX)
    #expect(place(CGPoint(x: 380, y: 350), .start).frame.maxX == area.maxX)
}

@Test func whenNeitherAboveNorBelowFitsItGoesBesideThenClamps() {
    // A tall (accessibility-size) bubble in a short landscape area: beside the handle, on the roomier side.
    let short = CGRect(x: 8, y: 8, width: 836, height: 340), tall = CGSize(width: 300, height: 260)
    let left = CGPoint(x: 200, y: 170), right = CGPoint(x: 650, y: 170)
    let besideLeft = place(left, .start, size: tall, bounds: short), besideRight = place(right, .end, size: tall, bounds: short)
    #expect(besideLeft.side == .trailing && besideRight.side == .leading)
    for (placement, anchor) in [(besideLeft, left), (besideRight, right)] {
        #expect(inside(placement.frame, short) && clearsHandle(placement, anchor))
        #expect(abs((placement.arrowTip?.y ?? 0) - anchor.y) < 0.01)
    }
    // Nothing fits anywhere beside it: inside the area, no arrow.
    let tiny = CGRect(x: 8, y: 8, width: 320, height: 300)
    let clamped = place(CGPoint(x: 160, y: 150), .start, size: tall, bounds: tiny)
    #expect(clamped.side == .clamped && clamped.arrowTip == nil && inside(clamped.frame, tiny))
}

@Test func aHandleScrolledAwayPinsTheBubbleToThatEdge() {
    let above = place(CGPoint(x: 200, y: -60), .start), below = place(CGPoint(x: 200, y: 900), .end)
    #expect(above.side == .pinnedTop && above.frame.minY == area.minY && above.arrowTip == nil && !above.anchorVisible)
    #expect(below.side == .pinnedBottom && below.frame.maxY == area.maxY && below.arrowTip == nil && !below.anchorVisible)
    // Back inside, it is next to the handle again.
    #expect(place(CGPoint(x: 200, y: area.minY + 1), .start, previous: .pinnedTop).side == .below)
}

@Test func aSlowScrollAcrossTheFlipLineDoesNotFlicker() {
    let line = area.minY + size.height + L.arrowLength + EditHit.handleRadius
    // Scrolling down, the handle crosses the line: below, and it stays below until above has `hysteresis` to spare.
    var side: L.Side? = nil
    var sides: [L.Side] = []
    for y in stride(from: line - 10, through: line + L.hysteresis + 10, by: 1) {
        let placement = place(CGPoint(x: 200, y: y), .start, previous: side)
        side = placement.side
        sides.append(placement.side)
    }
    for y in stride(from: line + L.hysteresis + 10, through: line - 10, by: -1) {
        let placement = place(CGPoint(x: 200, y: y), .start, previous: side)
        side = placement.side
        sides.append(placement.side)
    }
    let flips = zip(sides, sides.dropFirst()).filter { $0 != $1 }.count
    #expect(flips == 2)                                                                    // once back up past the band, once down past the line
    // Jitter of a few points around the line never flips.
    side = .below
    for y in [line + 1, line - 1, line + 3, line, line + 2] {
        side = place(CGPoint(x: 200, y: y), .start, previous: side).side
        #expect(side == .below)
    }
    // A big jump lands on the preferred side whatever came before.
    #expect(place(CGPoint(x: 200, y: 400), .start, previous: .below).side == .above)
}

@Test func theBubbleNeverCoversItsHandleAnywhereOnScreen() {
    for y in stride(from: area.minY, through: area.maxY, by: 11) {
        for x in stride(from: area.minX, through: area.maxX, by: 13) {
            for edge in [PrecisionEdge.start, .end] {
                for bubble in [size, CGSize(width: 340, height: 250)] {
                    let anchor = CGPoint(x: x, y: y)
                    let placement = place(anchor, edge, size: bubble)
                    #expect(inside(placement.frame))
                    if placement.side != .clamped { #expect(clearsHandle(placement, anchor)) }
                }
            }
        }
    }
}

// MARK: Content

@MainActor @Test func itShowsTheEdgeTheDateAndTheTimeInTheEventsZone() {
    let start = PrecisionBubbleText(PrecisionBubbleInput(edge: .start, instant: afternoon, timeZone: seoul))
    #expect(start.edge == "시작" && start.date == "10월 13일 (화)" && start.time == "오후 2:15")
    #expect(start.accessibilityLabel == "시작 시각" && start.accessibilityValue == "10월 13일 화요일 오후 2:15")
    // The same instant elsewhere reads that zone's wall clock and day.
    let newYork = PrecisionBubbleText(PrecisionBubbleInput(edge: .end, instant: afternoon, timeZone: TimeZone(identifier: "America/New_York")!))
    #expect(newYork.edge == "종료" && newYork.date == "10월 13일 (화)" && newYork.time == "오전 1:15")
    // An end at midnight is the next day's 12:00 AM, so the date says which midnight.
    let midnight = PrecisionBubbleText(PrecisionBubbleInput(edge: .end, instant: afternoon.addingTimeInterval(9 * 3600 + 45 * 60), timeZone: seoul))
    #expect(midnight.date == "10월 14일 (수)" && midnight.time == "오전 12:00")
}

@MainActor @Test func theVoiceOverHintSaysOnlyWhatCanBeDone() {
    func hint(_ down: Bool, _ up: Bool) -> String {
        PrecisionBubbleText(PrecisionBubbleInput(edge: .start, instant: afternoon, timeZone: seoul, canDecrement: down, canIncrement: up)).accessibilityHint
    }
    #expect(hint(true, true).contains("위로") && hint(true, true).contains("아래로"))
    #expect(!hint(false, true).contains("아래로 쓸면") && hint(false, true).contains("늦게"))
    #expect(!hint(true, false).contains("위로 쓸면") && hint(true, false).contains("일찍"))
    #expect(hint(false, false) == "지금은 바꿀 수 없어요")
}

// MARK: Controlled

@Test func itOnlyReportsWhatWasPressedAndNothingWhileAStepIsOff() {
    let open = PrecisionBubbleInput(edge: .end, instant: afternoon, timeZone: seoul)
    #expect(open.action(for: .decrement) == .decrement15)
    #expect(open.action(for: .increment) == .increment15)
    #expect(open.action(for: .dismiss) == .dismiss)
    let atLimit = PrecisionBubbleInput(edge: .end, instant: afternoon, timeZone: seoul, canDecrement: false, canIncrement: true)
    #expect(atLimit.action(for: .decrement) == nil && atLimit.action(for: .increment) == .increment15)
    let frozen = PrecisionBubbleInput(edge: .start, instant: afternoon, timeZone: seoul, canDecrement: false, canIncrement: false)
    #expect(!frozen.isInteractive)
    #expect(frozen.action(for: .decrement) == nil && frozen.action(for: .increment) == nil)
    #expect(frozen.action(for: .dismiss) == .dismiss)                                     // closing is always possible
    // VoiceOver's swipe up is later, swipe down earlier, through the same gate.
    #expect(PrecisionBubbleControl(.increment) == .increment && PrecisionBubbleControl(.decrement) == .decrement)
    #expect(atLimit.action(for: PrecisionBubbleControl(.decrement)!) == nil)
}

@Test func aHandleNamesItsEdgeAndTheBodyHasNone() {
    #expect(PrecisionEdge(.resizeStart) == .start)
    #expect(PrecisionEdge(.resizeEnd) == .end)
    #expect(PrecisionEdge(.body) == nil)
}

@Test func dynamicTypeWidensTheBubble() {
    let sizes: [DynamicTypeSize] = [.xSmall, .large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility2, .accessibility3]
    let widths = sizes.map(PrecisionBubbleMetrics.preferredWidth)
    #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(PrecisionBubbleMetrics.width(.accessibility3, available: 300) == 300)        // never wider than the area
    #expect(PrecisionBubbleMetrics.minimumTarget >= 44)
}

// MARK: Following a scroll and a pinch

@Test func theAnchorFollowsTheScrollAndThePinch() {
    // A handle at y 300 of the content at 1×: scrolled 120 down it is 180 from the viewport's top.
    let unit = CGPoint(x: 240, y: 300)
    #expect(PrecisionAnchorTracker.viewportPoint(content: unit, offset: 120) == CGPoint(x: 240, y: 180))
    // At 3× the content is three times as tall: the handle is at 900 of it, x unchanged.
    let zoomed = PrecisionAnchorTracker.contentPoint(atUnitZoom: unit, zoom: 3)
    #expect(zoomed == CGPoint(x: 240, y: 900))
    // A pinch that keeps the time under the fingers where it is (`PinchZoomMath.offsetAfterZoom`) keeps a handle at the focal point where it is too.
    // From 2× scrolled 400 down, a handle at 400 (1×) is at 400 in the viewport; pinching on it, it stays there.
    let viewport: CGFloat = 700, handle = CGPoint(x: 240, y: 400)
    let focal = PrecisionAnchorTracker.viewportPoint(content: PrecisionAnchorTracker.contentPoint(atUnitZoom: handle, zoom: 2), offset: 400).y
    #expect(focal == 400)
    for zoom in [1.5, 3, 4, 8] as [CGFloat] {
        let offset = PinchZoomMath.offsetAfterZoom(from: 2, to: zoom, offset: 400, focal: focal, viewport: viewport)
        let point = PrecisionAnchorTracker.viewportPoint(content: PrecisionAnchorTracker.contentPoint(atUnitZoom: handle, zoom: zoom), offset: offset)
        #expect(abs(point.y - focal) < 0.5)
    }
}

@MainActor @Test func theTrackerPublishesOnlyWhenTheHandleMoves() {
    let tracker = PrecisionAnchorTracker()
    var offset: CGFloat = 0
    tracker.track { PrecisionAnchorTracker.viewportPoint(content: CGPoint(x: 100, y: 400), offset: offset) }
    #expect(tracker.anchor == CGPoint(x: 100, y: 400) && tracker.publishCount == 1)
    tracker.refresh()
    #expect(tracker.publishCount == 1)                                                    // nothing moved
    offset = 0.05
    tracker.refresh()
    #expect(tracker.publishCount == 1)                                                    // under a tenth of a point
    offset = 37
    tracker.refresh()
    #expect(tracker.anchor == CGPoint(x: 100, y: 363) && tracker.publishCount == 2)
    tracker.stop()
    #expect(tracker.anchor == nil)
    #expect(PrecisionAnchorTracker.moved(from: nil, to: .zero) && !PrecisionAnchorTracker.moved(from: nil, to: nil))
}

// MARK: The wheel

@Test func theWheelOffersEveryQuarterHourBetweenTheLimitsAndTheOriginalOffTheGrid() {
    let dayStart = afternoon.addingTimeInterval(-(14 * 3600 + 15 * 60))                  // 00:00 of the same day
    func at(_ h: Int, _ m: Int) -> Date { dayStart.addingTimeInterval(TimeInterval(h * 3600 + m * 60)) }
    let choices = PrecisionWheelChoices.make(low: at(9, 0), high: at(10, 0), dayStart: dayStart, keep: [at(9, 7)])
    #expect(choices == [at(9, 0), at(9, 7), at(9, 15), at(9, 30), at(9, 45), at(10, 0)])
    // Limits off the grid start and end on the lines inside them; an original outside the limits is not offered.
    #expect(PrecisionWheelChoices.make(low: at(9, 5), high: at(9, 50), dayStart: dayStart, keep: [at(11, 7)]) == [at(9, 15), at(9, 30), at(9, 45)])
    #expect(PrecisionWheelChoices.make(low: at(10, 0), high: at(9, 0), dayStart: dayStart).isEmpty)
    // The row of a time is its own, else the nearest.
    #expect(PrecisionWheelChoices.index(of: at(9, 30), in: choices) == 3)
    #expect(PrecisionWheelChoices.index(of: at(9, 31), in: choices) == 3)
    #expect(PrecisionWheelChoices.index(of: at(9, 0), in: []) == nil)
}

@MainActor @Test func theWheelsRowsReadAsTheClockAndAnEndAtMidnightIsMidnight() {
    #expect(PrecisionBubbleText.wheelLabel(afternoon, edge: .start, timeZone: seoul) == "오후 2:15")
    let midnight = afternoon.addingTimeInterval(9 * 3600 + 45 * 60)
    #expect(PrecisionBubbleText.wheelLabel(midnight, edge: .end, timeZone: seoul) == "자정")
    #expect(PrecisionBubbleText.wheelLabel(midnight, edge: .start, timeZone: seoul) == "오전 12:00")
    // Without choices the wheel shows the time alone.
    #expect(PrecisionBubbleInput(edge: .start, instant: afternoon, timeZone: seoul).wheelChoices == [afternoon])
}
