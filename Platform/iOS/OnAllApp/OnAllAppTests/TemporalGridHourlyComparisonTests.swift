import CoreGraphics
import Testing
@testable import OnAllApp

// 5 minute candidates (the existing policy), hour-only boundaries, and an experiment with half-hour cells allowed. Lines starting "HG|" are the
// tables in docs/ui-reviews/hourly-grid/README.md.

private typealias F = TemporalGridFixtures
private func f1(_ v: Double) -> String { String(format: "%.1f", v) }
private func f1(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
private func f2(_ v: Double) -> String { String(format: "%.2f", v) }

private struct Policy: Sendable {
    let name: String
    let make: @Sendable (Int) -> TemporalGridParameters
}
private let policies = [
    Policy(name: "5분 후보(기존)") { TemporalGridParameters.with(slotCount: $0) },
    Policy(name: "정각 전용") { TemporalGridParameters.hourly(slotCount: $0) },
    Policy(name: "정각 전용+부분 claim 유지") { var p = TemporalGridParameters.hourly(slotCount: $0); p.keepsPartlyServableClaims = true; return p },
    Policy(name: "정각+30분 칸(실험)") { TemporalGridParameters.halfHour(slotCount: $0) },
]

@Test func printHourlyAgainstFiveMinuteCandidates() {
    print("HG|N|정책|최대Y이동 합|평균Y이동 합|제목표시 합/일정 합|E0선 합|E1 합|거래글자 합/독립거래 합|경계이동 평균(분)|분할 계산(ms/창, 차가운 캐시)|30분 미만 칸")
    for n in [10, 12, 16] {
        for policy in policies {
            var max: CGFloat = 0, mean: CGFloat = 0, titles = 0.0, events = 0.0, lines = 0.0, slivers = 0.0, tx = 0.0, txAll = 0.0, boundary = 0.0, seconds = 0.0
            var short = 0
            for scenario in F.all {
                let report = TemporalGridComparison.report(scenario, method: .temporal(slotCount: n), grid: policy.make(n))
                max += report.maxYShift; mean += report.meanYShift; titles += report.mainTitlesShown; events += report.mainEvents
                lines += report.mainLinesOnly; slivers += report.mainSlivers; tx += report.mainTransactionTextShown; txAll += report.mainIndependentTransactions
                boundary += report.meanBoundaryShift; seconds += report.secondsPerWindow
                for window in report.windows { let b = window.boundaries ?? []; short += zip(b, b.dropFirst()).filter { $1 - $0 < 30 }.count }
            }
            print("HG|\(n)|\(policy.name)|\(f1(max))|\(f1(mean))|\(f1(titles))/\(f1(events))|\(f1(lines))|\(f1(slivers))|\(f1(tx))/\(f1(txAll))|\(f2(boundary / Double(F.all.count)))|\(f2(seconds / Double(F.all.count) * 1000))|\(short)")
        }
    }
}

@Test func printWhereHourOnlyIsWorseThanFiveMinuteCandidates() {
    print("HG|악화|시나리오|N|지표|정각 전용|5분 후보")
    var worse = 0
    for scenario in F.all {
        for n in [10, 12, 16] {
            let fine = TemporalGridComparison.report(scenario, method: .temporal(slotCount: n), grid: TemporalGridParameters.with(slotCount: n))
            let hour = TemporalGridComparison.report(scenario, method: .temporal(slotCount: n), grid: TemporalGridParameters.hourly(slotCount: n))
            func check(_ name: String, _ h: Double, _ f: Double, lowerIsBetter: Bool, tolerance: Double = 0.2) {
                if lowerIsBetter ? h > f + tolerance : h < f - tolerance { worse += 1; print("HG|악화|\(scenario.name)|\(n)|\(name)|\(f1(h))|\(f1(f))") }
            }
            check("제목 표시", hour.mainTitlesShown, fine.mainTitlesShown, lowerIsBetter: false)
            check("거래 글자", hour.mainTransactionTextShown, fine.mainTransactionTextShown, lowerIsBetter: false)
            check("E0 선", hour.mainLinesOnly, fine.mainLinesOnly, lowerIsBetter: true)
            check("평균 Y 이동", Double(hour.meanYShift), Double(fine.meanYShift), lowerIsBetter: true, tolerance: 2)
        }
    }
    print("HG|악화 수|\(worse)")
}
