import CoreGraphics
import NEOBudgetCalendar
import Testing
@testable import OnAllApp

@Test func smallWidgetsPairUpAndAMediumStartsANewRow() {
    let packed = WidgetPacker.frames([.small, .small, .medium, .small], width: 338)
    let unit = WidgetPacker.unit(width: 338)
    #expect(packed.frames[0].minY == 0 && packed.frames[1].minY == 0 && packed.frames[1].minX > packed.frames[0].minX)
    #expect(packed.frames[2].minY == unit + WidgetPacker.gap && packed.frames[2].width == 338)
    #expect(packed.frames[3].minY == 2 * (unit + WidgetPacker.gap))
}

@Test func aLargeWidgetTakesTwoRowsAndKeepsReadingOrder() {
    let packed = WidgetPacker.frames([.small, .large, .small], width: 338)
    #expect(packed.frames[1].minY > packed.frames[0].minY)               // the large one cannot sit beside the small one
    #expect(packed.frames[2].minY > packed.frames[1].minY)               // and the next widget stays after it
}

@Test func droppingPicksTheSlotBeforeTheFirstWidgetBelowOrToTheRight() {
    let frames = WidgetPacker.frames([.small, .small, .medium], width: 338).frames
    #expect(WidgetPacker.insertionIndex(frames, at: CGPoint(x: 5, y: 5)) == 0)
    #expect(WidgetPacker.insertionIndex(frames, at: CGPoint(x: 330, y: 5)) == 2)
    #expect(WidgetPacker.insertionIndex(frames, at: CGPoint(x: 100, y: 10_000)) == 3)
}

@Test func weekAndPendingNumbersUseMyShareAndKeepWaitingSeparate() throws {
    let today = try LocalDate(year: 2027, month: 3, day: 10)                // Wednesday
    let rows = [
        AnalysisTransaction(id: "a", date: today, shareMinorUnits: 9_500, pendingMinorUnits: 28_500, activity: AnalysisActivity(id: ActivityID(rawValue: "d"), title: "테스트 회식", headcount: 4, participants: [])),
        AnalysisTransaction(id: "b", date: today.adding(days: -2), shareMinorUnits: 4_000),
    ]
    let data = AnalysisWidgetData.make(rows: rows, month: AnalysisMonth(today), today: today)
    #expect(data.weekToday == 2 && data.week.count == 7)
    #expect(data.week[2].won == 9_500 && data.week[0].won == 4_000)
    #expect(data.weekTotal == 13_500 && data.weekAverage == 4_500)
    #expect(data.pending == 28_500 && data.pendingLines.first?.title == "테스트 회식")
    #expect(data.months.count == 6 && data.months.last?.won == 13_500)
}

@Test func catalogVariantsOfOneStyleListTheirSizes() {
    let weekBars = WidgetSpec.all.first { $0.topic == .week && $0.style == .bars }
    #expect(weekBars?.sizes().map(\.size) == [.medium])
    #expect(WidgetSpec.all.first { $0.topic == .category && $0.style == .list }?.sizes().map(\.size) == [.medium, .large])
    #expect(Set(WidgetSpec.all.map(\.id)).count == WidgetSpec.all.count)
}
