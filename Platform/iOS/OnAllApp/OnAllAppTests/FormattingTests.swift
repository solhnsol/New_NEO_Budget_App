import Foundation
import NEOBudgetCalendar
import Testing
@testable import OnAllApp

@Test func amountsAreGroupedAsKoreanFormatterWritesThem() {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.numberStyle = .decimal
    for value: Int64 in [0, 5, 999, 1_000, 12_345, 1_234_567, -1, -1_000, -9_876_543, Int64.max, Int64.min + 1] {
        #expect(Formatting.grouped(value) == formatter.string(from: NSNumber(value: value)), "\(value)")
    }
    #expect(Formatting.money(48_000, currency: "KRW") == "48,000원")
}

@Test func timesUseTheirOwnZoneWhenFormattersAreReused() {
    let instant: Int64 = 1_792_130_700_000 // 2026-10-16 15:05 KST
    #expect(Formatting.time(instant, zoneIdentifier: "Asia/Seoul") == "오후 3:05")
    #expect(Formatting.time(instant, zoneIdentifier: "UTC") == "오전 6:05")
    #expect(Formatting.time(instant, zoneIdentifier: "Asia/Seoul") == "오후 3:05")
    #expect(Formatting.shortDate(instant, zoneIdentifier: "Asia/Seoul") == "10/16")
}

@Test func categoryNamesAreKoreanForTheUser() {
    #expect(CategoryIcon.name(for: CanonicalCategoryID(rawValue: "food")) == "식비")
    #expect(CategoryIcon.name(for: CanonicalCategoryID(rawValue: "transport")) == "교통")
    // An id already in Korean is the user's own word; one that matches nothing keeps its id.
    #expect(CategoryIcon.name(for: CanonicalCategoryID(rawValue: "외식")) == "외식")
    #expect(CategoryIcon.name(for: CanonicalCategoryID(rawValue: "misc")) == "misc")
    #expect(CategoryIcon.name(for: nil) == nil)
}
