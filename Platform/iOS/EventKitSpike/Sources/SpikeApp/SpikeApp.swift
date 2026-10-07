import SwiftUI

@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("EventKit spike").task {
                do { try await EventKitSpike().run() } catch { SpikeLog.line("FAILED: \(error)") }
                SpikeLog.line("exit")
            }
        }
    }
}
