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
                } else if ProcessInfo.processInfo.arguments.contains(PrecisionBubbleFixture.launchArgument) {
                    PrecisionBubbleFixture()
                } else if ProcessInfo.processInfo.arguments.contains("-render-grid") || ProcessInfo.processInfo.arguments.contains("-render-continuous") {
                    RenderGridScreen()
                } else if let model {
                    RootTabs(model: model)
                } else {
                    ProgressView()
                }
                #else
                if let model {
                    RootTabs(model: model)
                } else {
                    ProgressView()
                }
                #endif
            }
            .task {
                guard model == nil else { return }
                let arguments = ProcessInfo.processInfo.arguments
                let isDemo = arguments.contains("-demo") || DemoFull.isOn   // until real data is connected, a plain launch opens the full demo (`-live` for the device)
                do {
                    let created = isDemo ? try AppModel.demo() : try AppModel.live(withSampleLedger: arguments.contains("-ledger-sample"))
                    model = created
                    await created.start()
                    #if DEBUG
                    if isDemo { created.dayReadInterceptor = DayReadFaults.interceptor(arguments: arguments) }
                    #endif
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
