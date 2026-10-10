import SwiftUI

@main
struct OnAllApp: App {
    @State private var model: AppModel?

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-render-gallery") {
                    RenderGallery()
                } else if let model {
                    DayTimelineScreen(model: model)
                } else {
                    ProgressView()
                }
                #else
                if let model {
                    DayTimelineScreen(model: model)
                } else {
                    ProgressView()
                }
                #endif
            }
            .task {
                guard model == nil else { return }
                let arguments = ProcessInfo.processInfo.arguments
                let isDemo = arguments.contains("-demo")
                do {
                    let created = isDemo ? try AppModel.demo() : try AppModel.live(withSampleLedger: arguments.contains("-ledger-sample"))
                    model = created
                    await created.start()
                    if isDemo, let index = arguments.firstIndex(of: "-demo-preview"), arguments.indices.contains(index + 1) {
                        DemoPreview.apply(arguments[index + 1], to: created)
                        await DemoPreview.runScript(arguments[index + 1], on: created)
                    }
                } catch {
                    model = nil
                }
            }
        }
    }
}
