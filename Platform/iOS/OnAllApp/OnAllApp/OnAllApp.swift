import SwiftUI

@main
struct OnAllApp: App {
    @State private var model: AppModel?

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    DayTimelineScreen(model: model)
                } else {
                    ProgressView()
                }
            }
            .task {
                guard model == nil else { return }
                let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
                do {
                    let created = isDemo ? try AppModel.demo() : try AppModel.live()
                    model = created
                    await created.start()
                } catch {
                    model = nil
                }
            }
        }
    }
}
