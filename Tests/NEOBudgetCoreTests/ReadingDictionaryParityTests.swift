import Foundation
import Testing
import NEOBudgetCore

/// 읽기 사전(공식 항목)이 예전 코드 파서와 같은 결과를 내는지 모든 고정 알림으로 견주어 본다.
private struct AllFixtures: Decodable {
    struct Direction: Decodable { let input: RawNotification }
    struct Amount: Decodable { let input: RawNotification }
    let negative: [RawNotification]
    let directions: [Direction]
    let amounts: [Amount]
}
private struct Synthetic: Decodable { let notifications: [RawNotification] }

private func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

private func note(_ title: String?, _ subtitle: String?, _ body: String?, app: String = "x.app", time: Int64? = 1_780_000_000_000) -> RawNotification {
    RawNotification(
        id: UUID().uuidString, source: NotificationSource(applicationIdentifier: app), sourceDeliveryID: nil,
        capturedAtUnixMilliseconds: 1_780_000_001_000, notificationAtUnixMilliseconds: time, title: title, subtitle: subtitle, body: body
    )
}

private let handWritten: [RawNotification] = [
    note("카드", "₩1,550 for Metro", "Your new balance is ₩10,000."),
    note("카드", "₩0 for Metro", "Your new balance is ₩10,000."),
    note("카드", nil, "Your new balance is ₩10,000. No charge"),
    note("카드", "Fare", "Your new balance is ₩10,000."),
    note("현대카드", "스타벅스 강남점, 서울특별시", "₩4,500"),
    note("현대카드", "이마트, 에브리데이, 경기도", "₩12,000"),
    note("현대카드", "A, B", "₩0"),
    note("현대카드", "", "₩4,500"),
    note("Wallet", "스타벅스", "₩4,500"),
    note("우리WON뱅킹 입출금알림", nil, "[입금] 차유진        67,035원 1002-967-767***계좌 잔액 1,234,000원"),
    note("우리WON뱅킹 입출금알림", nil, "우리 입금 67,035원 1002-123-456*** 차유진 잔액 1,234,000원 10/02 19:10"),
    note("우리WON뱅킹 입출금알림", nil, "[출금] 토스 김철수 12,000원 잔액 1,000원"),
    note("우리WON뱅킹", nil, "[출금] 토스퀵계좌이체 3,300원"),
    note("토스뱅크", nil, "[출금] 토스뱅크 5,000원"),
    note("현대카드", "현대 MM 승인", "홍길동 님, 현대 MM 승인\n12,300원 일시불\n쿠팡\n승인번호 123456"),
    note("현대카드", nil, "현대 MM 승인취소\n12,300원\n쿠팡\n원승인번호 123456\n승인번호 7788"),
    note("토스", "결제 완료", "쿠팡에서 76,570원 결제"),
    note("토스", nil, "7.25 USD (10,760원) 결제"),
    note("토스", nil, "7.25 USD 결제"),
    note("토스", nil, "포인트 5,076원 사용 12,000원 결제"),
    note("카카오페이", nil, "충전이 완료되었어요 10,000원\n충전계좌: 우리은행 1234"),
    note("카카오페이", nil, "송금했어요 5,000원 홍길동 1234 ("),
    note("은행", nil, "카드대금 출금 350,000원"),
    note("은행", nil, "카드결제 출금 120,000원"),
    note("은행", nil, "광고 입금 이벤트"),
    note("은행", nil, "로그인 인증번호 123456"),
    note("은행", nil, "승인 거절 한도초과 30,000원"),
    note("은행", nil, "잔액 조회 1,000원"),
    note("은행", nil, "이체한도 변경 안내"),
    note("은행", nil, "취소 15,000원 중 5,000원 환불"),
    note("은행", nil, "입금 1,000원 환불 완료"),
    note("은행", nil, "출금 10원 100원"),
    note("은행", nil, "그냥 아무 알림"),
    note(nil, nil, nil),
    note("은행", "", "출금 1,000원 \n 2,000원", time: nil),
    note("은행", nil, "입금 1,000.5원"),
]

@Test func officialReadingEntriesMatchTheOldCodeParserOnEveryFixture() throws {
    let red = try load("redteam-parser-fixtures", as: AllFixtures.self)
    let all = try load("raw-notifications", as: [RawNotification].self)
        + load("synthetic-notification-coverage", as: Synthetic.self).notifications
        + red.negative + red.directions.map(\.input) + red.amounts.map(\.input) + handWritten
    let context = try NotificationParsingContext(timeZoneIdentifier: "Asia/Seoul", referenceTimeUnixMilliseconds: 0, parserID: "p", parserVersion: "1")
    let legacy = LegacyKoreanParser()
    let entries = ReadingEntryParser()
    #expect(entries.invalidEntryIDs.isEmpty)
    for input in all {
        let old = try legacy.parse(input, context: context)
        let new = try entries.parse(input, context: context)
        #expect(old == new, "\(input.title ?? "") | \(input.subtitle ?? "") | \(input.body ?? "")\nold: \(old)\nnew: \(new)")
    }
    #expect(all.count > 40)
}

private func ctx() throws -> NotificationParsingContext {
    try NotificationParsingContext(timeZoneIdentifier: "Asia/Seoul", referenceTimeUnixMilliseconds: 0, parserID: "p", parserVersion: "1")
}

@Test func aUserIgnoreEntryForOneAppBeatsTheOfficialEntriesAndStaysInThatApp() throws {
    let ignore = ReadingEntry(
        id: "user.mukeunji", name: "묵은지 작업실 통장", origin: .user, applicationIdentifier: "viva.republica.toss",
        conditions: [.contains(.all, ["묵은지 작업실"])], action: .ignore(.unrecognized)
    )
    let parser = ReadingEntryParser(dictionary: ReadingDictionary(userEntries: [ignore]))
    let text = "묵은지 작업실 통장 출금 10,000원"
    #expect(try parser.parse(note("토스", nil, text, app: "viva.republica.toss"), context: ctx()) == .notTransaction(.unrecognized))
    guard case .candidate = try parser.parse(note("토스", nil, text, app: "other.app"), context: ctx()) else {
        Issue.record("the ignore entry must not reach other apps"); return
    }
}

@Test func aUserFrameEntryReadsItsSlotsAndAnOfficialEntryCanBeSwitchedOff() throws {
    let entry = ReadingEntry(
        id: "user.frame", name: "쿠폰 결제", origin: .user, applicationIdentifier: "my.app",
        conditions: [.frame(.body, "{가맹점}에서 {금액}원 결제")],
        action: .read(ReadingOutcome(ruleID: "user.frame", kind: .purchase, direction: .outflow))
    )
    let parser = ReadingEntryParser(dictionary: ReadingDictionary(userEntries: [entry]))
    guard case let .candidate(draft) = try parser.parse(note(nil, nil, "카페 모아에서 4,500원 결제", app: "my.app"), context: ctx()) else {
        Issue.record("frame entry must read"); return
    }
    #expect(draft.amount.minorUnits == 4_500)
    #expect(draft.counterparty.merchantRaw == "카페 모아")
    #expect(draft.ruleID == "user.frame")

    let off = ReadingEntryParser(dictionary: ReadingDictionary(disabledOfficialIDs: ["official.promotion"]))
    guard case .candidate = try off.parse(note(nil, nil, "광고 출금 1,000원"), context: ctx()) else {
        Issue.record("switching an official ignore entry off must read the notification"); return
    }
    #expect(NotificationIntake(timeZoneIdentifier: "Asia/Seoul").readingKey
        != NotificationIntake(timeZoneIdentifier: "Asia/Seoul", readingDictionary: ReadingDictionary(userEntries: [entry])).readingKey)
}

private func src(_ name: String, app: String = "x") -> NotificationSource {
    NotificationSource(applicationIdentifier: app, displayName: name, providerHint: nil)
}
private func appNote(_ app: String, _ title: String?, _ subtitle: String?, _ body: String?) -> RawNotification {
    RawNotification(
        id: UUID().uuidString, source: src(app), sourceDeliveryID: nil, capturedAtUnixMilliseconds: 1, notificationAtUnixMilliseconds: 1,
        title: title, subtitle: subtitle, body: body
    )
}

@Test func evidenceEntriesMatchTheOldExtractorOnEveryShape() throws {
    let red = try load("redteam-parser-fixtures", as: AllFixtures.self)
    var all = try load("raw-notifications", as: [RawNotification].self)
        + load("synthetic-notification-coverage", as: Synthetic.self).notifications
        + red.negative + red.directions.map(\.input) + red.amounts.map(\.input)
    all += [
        appNote("우리WON뱅킹", "입출금알림", nil, "우리 입금 67,035원 1002-123-456*** 차유진 잔액 1,234,000원"),
        appNote("우리WON뱅킹", nil, nil, "[출금] 1002-9*-7 5,000원"),
        appNote("우리WON뱅킹", nil, nil, "잔액 1,000원"),
        appNote("우리WON뱅킹", nil, nil, "광고"),
        appNote("현대카드", nil, nil, "현대 MM 승인\n12,300원"),
        appNote("현대카드", nil, nil, "현대 체크 승인취소 12,300원"),
        appNote("현대카드", nil, nil, "현대 M3 취소"),
        appNote("Toss", "결제", nil, "현대카드 MM 12,000원"),
        appNote("Toss", "토스", nil, "토스페이머니・ 12,000원 결제"),
        appNote("Toss", nil, nil, "우리・ 1234 12,000원 결제"),
        appNote("Toss", nil, nil, "알수없은・ 1234 결제"),
        appNote("Toss", nil, nil, "결제 완료 5,000원"),
        appNote("Toss", nil, "결제", "5,000원"),
        appNote("Toss", nil, nil, "내 토스뱅크 통장 → 우리 계좌로 입금"),
        appNote("Toss", nil, nil, "토스뱅크 통장 이자 100원 입금"),
        appNote("Toss", nil, nil, "우리 계좌로 입금 홍길동"),
        appNote("Kakaopay", nil, nil, "충전이 완료되었어요 10,000원 충전계좌: 우리은행 1234"),
        appNote("Kakaopay", nil, nil, "충전 10,000원 충전계좌:모름은행 1234"),
        appNote("Kakaopay", nil, nil, "송금했어요 5,000원 우리은행 1234 (홍길동)"),
        appNote("Kakaopay", nil, nil, "홍길동님이 보냈어요"),
        appNote("Wallet", "교통카드", "₩1,550 for Metro", "Your new balance is ₩10,000."),
        appNote("Wallet", "교통카드", nil, "Your new balance is ₩10,000. No Charge"),
        appNote("Wallet", "교통카드", nil, "Your new balance is ₩10,000."),
        appNote("Wallet", "현대카드", "스타벅스, 서울특별시", "₩4,500"),
        appNote("Wallet", "삼성카드", "스타벅스", "₩4,500"),
        appNote("Wallet", "메모", nil, "₩4,500"),
        appNote("Other", "현대카드", nil, "현대 MM 승인"),
    ]
    let old = LegacyAccountEvidenceExtractor()
    let new = AccountEvidenceExtractor()
    for input in all {
        #expect(old.evidence(from: input) == new.evidence(from: input),
                "\(input.title ?? "") | \(input.subtitle ?? "") | \(input.body ?? "")\nold: \(old.evidence(from: input))\nnew: \(new.evidence(from: input))")
    }
}

@Test func theParserSaysWhichEntryReadEachNotification() {
    let parser = ReadingEntryParser()
    #expect(parser.entryID(for: note("은행", nil, "입금 1,000원")) == "official.deposit")
    #expect(parser.entryID(for: note("은행", nil, "광고 입금")) == "official.promotion")
    #expect(parser.entryID(for: note("은행", nil, "그냥 아무 알림")) == nil)
}

@Test func aUserTeachesTheAppToReadAnUnreadNotificationFromPickedPieces() throws {
    let text = "[출금] 묵은지 작업실 150,000원 잔액 2,310,000원 11/05 18:22"
    let builder = ReadingEntryBuilder(text: text)
    #expect(builder.tokens.map(\.text) == ["[", "출금", "]", "묵은지", "작업실", "150,000", "원", "잔액", "2,310,000", "원", "11/05", "18:22"])
    // 앱이 미리 칠해 주는 것: 종류 글자, 금액, 날짜·시각.
    var picks = builder.suggestions()
    #expect(Set(picks.values) == [.direction, .amount, .time])
    for token in builder.tokens where ["묵은지", "작업실"].contains(token.text) { picks[token.id] = .accountName }
    picks[builder.tokens.first { $0.text == "2,310,000" }!.id] = .balance

    #expect(throws: ReadingEntryBuilder.BuildError.needsName) {
        try builder.readEntry(name: " ", applicationIdentifier: "toss", kind: nil, assignments: picks)
    }
    #expect(throws: ReadingEntryBuilder.BuildError.needsAmount) {
        try builder.readEntry(name: "x", applicationIdentifier: "toss", kind: .withdrawal, assignments: [:])
    }
    #expect(ReadingEntryBuilder.pieces(of: builder.frame(assignments: picks)) == [
        .text("["), .slot("방향"), .text("] "), .slot("통장 이름"), .text(" "), .slot("금액"), .text("원 잔액 "), .slot("잔액"), .text("원 "), .slot("시각"),
    ])
    let entry = try builder.readEntry(name: "토스 출금 알림", applicationIdentifier: "toss", kind: nil, assignments: picks)
    let parser = ReadingEntryParser(dictionary: ReadingDictionary(userEntries: [entry]))
    func parse(_ body: String, app: String = "toss") throws -> NotificationParseOutcome {
        try parser.parse(note(nil, nil, body, app: app), context: ctx())
    }
    // 같은 틀이면 같은 알림이다: 숫자·날짜·이름은 달라도 읽고, 방향 글자가 입금이면 입금으로 읽는다.
    guard case let .candidate(draft) = try parse("[출금] 다른통장 7,000원 잔액 1,000원 01/02 03:04") else {
        Issue.record("same shape must be read"); return
    }
    #expect(draft.amount.minorUnits == 7_000)
    #expect(draft.balanceAfter?.minorUnits == 1_000)
    #expect(draft.ruleID == entry.id)
    #expect(draft.kind == .withdrawal && draft.direction == .outflow)
    #expect(draft.instrument.displayNameRaw == "다른통장")
    guard case let .candidate(deposit) = try parse("[입금] 홍길동 7,000원 잔액 1,000원 01/02 03:04") else {
        Issue.record("deposit word must be read"); return
    }
    #expect(deposit.ruleID == entry.id)
    #expect(deposit.kind == .deposit && deposit.direction == .inflow)
    // 다른 앱, 또는 틀이 다른 글자는 공식 항목이 읽는다.
    guard case let .candidate(otherApp) = try parse("[출금] 묵은지 작업실 7,000원 잔액 1,000원 01/02 03:04", app: "other") else {
        Issue.record("official entries still read these"); return
    }
    #expect(otherApp.ruleID == "withdrawal")
}

@Test func withoutADirectionWordTheUserPicksTheKind() throws {
    let builder = ReadingEntryBuilder(text: "묵은지 150,000원")
    let picks = builder.suggestions()
    #expect(throws: ReadingEntryBuilder.BuildError.needsKind) {
        try builder.readEntry(name: "x", applicationIdentifier: nil, kind: nil, assignments: picks)
    }
    let entry = try builder.readEntry(name: "x", applicationIdentifier: nil, kind: .purchase, assignments: picks)
    guard case let .read(outcome) = entry.action else { Issue.record("read"); return }
    #expect(outcome.kind == .purchase && outcome.directionWords == nil)
}

@Test func theUserCanSplitGluedTextIntoPieces() {
    let text = "묵은지작업실계좌"
    let builder = ReadingEntryBuilder(text: text, cuts: [3, 6])
    #expect(builder.tokens.map(\.text) == ["묵은지", "작업실", "계좌"])
    #expect(ReadingEntryBuilder(text: text).tokens.map(\.text) == [text])
}

@Test func anIgnoreEntryKeepsOnlyThePickedPiecesAndAnythingElseMatches() throws {
    let builder = ReadingEntryBuilder(text: "[광고] 현대카드 M포인트 3,200 점이 소멸돼요 11/30")
    let fixed = Set(builder.tokens.prefix(3).map(\.id))
    let entry = try builder.ignoreEntry(name: "현대카드 광고", applicationIdentifier: "hyundai", fixedTokenIDs: fixed)
    guard case let .frame(_, frame) = entry.conditions[0] else { Issue.record("frame"); return }
    #expect(frame == "[광고]{*}")
    #expect(ReadingEntryBuilder.pieces(of: frame) == [.text("[광고]"), .slot("아무 텍스트")])
    let parser = ReadingEntryParser(dictionary: ReadingDictionary(userEntries: [entry]))
    #expect(try parser.parse(note(nil, nil, "[광고] 아무 내용 입금 5,000원", app: "hyundai"), context: ctx()) == .notTransaction(.unrecognized))
    // 다른 앱에서는 내 무시 항목이 아니라 공식 항목(광고)이 걸러 낸다.
    #expect(try parser.parse(note(nil, nil, "[광고] 아무 내용 입금 5,000원", app: "other"), context: ctx()) == .notTransaction(.promotion))
}

