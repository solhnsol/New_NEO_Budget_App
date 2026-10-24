import Foundation
import NEOBudgetCalendar
import Testing
@testable import OnAllApp

@Test func aPickedIconWinsOverTheGuessFromTheName() {
    #expect(CalendarIcon.symbol(picked: nil, title: "일상") == "house")
    #expect(CalendarIcon.symbol(picked: "dumbbell", title: "일상") == "dumbbell")
    #expect(CalendarIcon.symbol(picked: nil, title: "기타") == "calendar")
}

@Test func pickedIconsSurviveSavingAndLoading() {
    let key = "calendarIconsTest"
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var store = CalendarIconStore()
    store.set("airplane", for: CalendarID(rawValue: "a"))
    store.save(key: key)
    #expect(CalendarIconStore.load(key: key).symbol(for: CalendarID(rawValue: "a")) == "airplane")
    store.set(nil, for: CalendarID(rawValue: "a"))
    #expect(store.symbol(for: CalendarID(rawValue: "a")) == nil)
}
