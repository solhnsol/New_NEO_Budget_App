import Foundation
import NEOBudgetCore
import NEOBudgetInMemoryStorage

let seoul = TimeZone(identifier: "Asia/Seoul")!
let decoder = ShortcutNotificationDecoder(timeZone: seoul)
let intake = NotificationIntake(timeZoneIdentifier: "Asia/Seoul")
let clock = ContinuousClock()

func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
func rss() -> (cur: Double, peak: Double) {
    var cur = 0.0, peak = 0.0
    if let s = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) {
        for l in s.split(separator: "\n") {
            let p = l.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if l.hasPrefix("VmRSS:"), p.count > 1 { cur = Double(p[1])! / 1024 }
            if l.hasPrefix("VmHWM:"), p.count > 1 { peak = Double(p[1])! / 1024 }
        }
    }
    return (cur, peak)
}
func time<T>(_ f: () throws -> T) rethrows -> (T, Double) {
    var r: T!
    let d = try clock.measure { r = try f() }
    return (r, ms(d))
}

var cal = Calendar(identifier: .gregorian); cal.timeZone = seoul
var isoFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; return f }()
var bodyFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = seoul; f.dateFormat = "MM/dd HH:mm"; return f }()
let merchants = (0..<300).map { "가맹점\($0)" }

func payload(_ app: String, body: String, at date: Date) -> String {
    let f: [String: String] = ["app": app, "title": "", "subtitle": "", "body": body, "timestamp": isoFmt.string(from: date)]
    return String(data: try! JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]), encoding: .utf8)!
}

/// n notifications: card approvals, a third of them with the matching bank withdrawal two seconds later.
func generate(_ n: Int) -> [RawNotification] {
    var out: [RawNotification] = []
    let start = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09
    var i = 0
    var rng = SystemRandomNumberGenerator()
    while out.count < n {
        // ~6 purchases per day, minute-spaced so every one is distinct
        let t = start.addingTimeInterval(Double(i / 6) * 86_400 + Double(i % 6) * 3_600 * 3 + Double(i % 50) * 60 + Double(i / 6 % 7) * 600)
        let amount = (Int.random(in: 2...200, using: &rng)) * 500
        let m = merchants[Int.random(in: 0..<merchants.count, using: &rng)]
        let amt = NumberFormatter.localizedString(from: NSNumber(value: amount), number: .decimal)
        let card = payload("현대카드", body: "김가명 님, 현대 체크 승인 \r\n\(amt)원 일시불, \(bodyFmt.string(from: t)) \r\n\(m)", at: t)
        out.append(contentsOf: try! decoder.decode(card, receivedAtUnixMilliseconds: Int64(t.timeIntervalSince1970 * 1000) + 5_000))
        if i % 3 == 0, out.count < n {
            let b = payload("우리WON뱅킹", body: "[Web발신]\n우리 출금 \(amt)원 1002-123-456*** 잔액 1,234,000원 \(bodyFmt.string(from: t)):20", at: t.addingTimeInterval(2))
            out.append(contentsOf: try! decoder.decode(b, receivedAtUnixMilliseconds: Int64(t.timeIntervalSince1970 * 1000) + 7_000))
        }
        i += 1
    }
    return Array(out.prefix(n))
}

func makeSetup(from sample: [RawNotification]) throws -> IntakeSetup {
    var setup = IntakeSetup()
    var repo = try InMemoryCandidateProcessingRepository(configuration: setup.configuration)
    for n in sample.prefix(2) { _ = try intake.ingest(n, setup: &setup, repository: &repo) }
    let bank = setup.registry.openCandidates.first { $0.key.institution == .woori }!
    let card = setup.registry.openCandidates.first { $0.key.institution == .hyundaiCard }!
    let target = try setup.confirmAsNew(bank.id, displayName: "생활비", kind: .account(.bank, openingBalance: Money(minorUnits: 0, currency: "KRW")), makeID: { "account-1" })
    try setup.link(card.id, to: target.binding)
    return setup
}

let sizes = CommandLine.arguments.dropFirst().compactMap { Int($0) }
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(getpid())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
print("N, fileMB, encode_ms, write_ms, read+decode_ms, replay_cold_ms, peakRSS_MB(after replay), receive1_ms(copy+ingest), save_after_receive_ms, status_per_call_ms, inbox_all_est_ms, snapshot_ms, reportedBalances_ms, recorded_entries")
for n in sizes {
    let all = generate(n + 1)
    let notifications = Array(all.prefix(n)); let extra = all[n]
    let setup = try makeSetup(from: all)
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let url = dir.appendingPathComponent("notifications-\(n).json")
    let (data, tEnc) = try time { try enc.encode(notifications) }
    let (_, tWrite) = try time { try data.write(to: url, options: Data.WritingOptions.atomic) }
    let (_, tRead) = try time { () -> [RawNotification] in try JSONDecoder().decode([RawNotification].self, from: Data(contentsOf: url)) }
    let before = rss()
    let (ledger, tReplay) = try time { try IntakeLedger(notifications: notifications, setup: setup, intake: intake) }
    let after = rss()
    // AppLedger.receive: `case .live(var ledger, ...)` copies the struct while `backing` still holds the original.
    var copy = ledger
    let (_, tRecv) = try time { try copy.receive([extra]) }
    let (_, tSave) = try time { () -> Void in let d = try enc.encode(copy.notifications); try d.write(to: url, options: Data.WritingOptions.atomic) }
    let sample = Array(ledger.notifications.shuffled().prefix(min(200, n)))
    let (_, tStatus) = time { for s in sample { _ = ledger.status(of: s.id) } }
    let perCall = tStatus / Double(sample.count)
    let (snap, tSnap) = try time { try ledger.repository.processingSnapshot() }
    let (_, tBal) = time { _ = ledger.reportedBalances }
    print(String(format: "%d, %.2f, %.0f, %.0f, %.0f, %.0f, %.0f(+%.0f), %.0f, %.0f, %.3f, %.0f, %.1f, %.0f, %d",
                 n, Double(data.count)/1_048_576, tEnc, tWrite, tRead, tReplay, after.peak, after.cur - before.cur, tRecv, tSave, perCall, perCall * Double(n), tSnap, tBal, snap.ledger.entries.count))
    fflush(stdout)
}
