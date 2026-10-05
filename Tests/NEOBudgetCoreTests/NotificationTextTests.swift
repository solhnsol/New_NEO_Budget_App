import Testing
@testable import NEOBudgetCore

@Test func composedAndDecomposedKoreanProduceTheSameNormalizedText() {
    #expect(NotificationText.normalize("\u{1112}\u{1161}\u{11AB}") == "한")
}

@Test func notificationFieldsPreserveOrderAndSkipMissingFields() {
    #expect(NotificationText.joined(title: " 승인 ", subtitle: nil, body: "\r\n 5,000원\r\n") == "승인\n5,000원")
}

@Test func unicodePaddingAndLineEndingsAreNormalized() {
    #expect(NotificationText.normalize("\u{3000}가게\u{00A0}이름\r\n금액\r시각 ") == "가게 이름\n금액\n시각")
}

@Test func emptyNotificationFieldsRemainEmpty() {
    #expect(NotificationText.joined(title: nil, subtitle: "\u{3000}", body: "\r\n") == "")
}

@Test func differingAmountsAndPurchaseTimesRemainDifferent() {
    #expect(NotificationText.normalize("가게 5,000원 12:00") != NotificationText.normalize("가게 5,000원 12:01"))
    #expect(NotificationText.normalize("가게 5,000원 12:00") != NotificationText.normalize("가게 6,000원 12:00"))
}

@Test func normalizationDoesNotMutateTheSourceValue() {
    let raw = "\u{3000}가게\r\n5,000원\u{00A0}"
    _ = NotificationText.normalize(raw)
    #expect(raw == "\u{3000}가게\r\n5,000원\u{00A0}")
}
