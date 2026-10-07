import NEOBudgetCalendar
import NEOBudgetCalendarContract
import NEOBudgetEventKit
import SwiftUI

enum HostLog {
    static let path = "/tmp/claude-501/eventkit-contract.log"
    static func reset() { try? "".write(toFile: path, atomically: true, encoding: .utf8) }
    static func line(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

@main
struct ContractHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("EventKit provider contract").task { await runContract() }
        }
    }

    private func runContract() async {
        HostLog.reset()
        do {
            let provider = try EventKitCalendarProvider()
            let granted = try await provider.requestFullAccess()
            HostLog.line("access granted: \(granted)")
            guard granted else { HostLog.line("RESULT: no access"); HostLog.line("exit"); return }
            let rig = try EventKitRig(provider: provider)
            let results = await CalendarProviderContract.run(rig: rig)
            for result in results {
                if let failure = result.failure { HostLog.line("FAIL  \(result.name)\n      \(failure)") }
                else if let reason = result.skipped { HostLog.line("SKIP  \(result.name) (\(reason))") }
                else { HostLog.line("PASS  \(result.name)") }
            }
            let failed = results.filter { !$0.passed }.count
            HostLog.line("RESULT: \(results.count) checks, \(failed) failed, \(results.filter { $0.skipped != nil }.count) skipped")
        } catch {
            HostLog.line("RESULT: error \(error)")
        }
        HostLog.line("exit")
    }
}
