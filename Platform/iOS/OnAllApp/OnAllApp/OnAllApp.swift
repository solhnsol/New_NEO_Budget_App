import SwiftUI

@main
struct OnAllApp: App {
    @State private var model: AppModel?
    /// The app's data could not be opened: say so instead of spinning forever.
    @State private var startFailure: String?
    /// Bumped to rebuild the model after the user switched modes.
    @State private var generation = 0

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
                } else if let startFailure {
                    LaunchFailureView(detail: startFailure)
                } else {
                    ProgressView()
                }
                #else
                if let model {
                    RootTabs(model: model)
                } else if let startFailure {
                    LaunchFailureView(detail: startFailure)
                } else {
                    ProgressView()
                }
                #endif
            }
            .environment(\.switchAppMode, { mode in
                AppMode.save(mode)
                model = nil
                startFailure = nil
                generation += 1
            })
            .task(id: generation) {
                guard model == nil else { return }
                let arguments = ProcessInfo.processInfo.arguments
                // A plain launch opens the full demo until the user switches to their own data in 설정; `-live` and `-demo` override for one launch.
                let isDemo = arguments.contains("-demo") || DemoFull.isOn
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
                    startFailure = String(describing: error)
                }
            }
        }
    }
}

/// Shown when the app's data cannot be opened at launch.
private struct LaunchFailureView: View {
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label("앱을 열지 못했어요", systemImage: "exclamationmark.triangle")
        } description: {
            Text("저장된 데이터를 읽지 못했어요. 앱을 완전히 닫았다가 다시 열어 주세요.\n\n" + detail)
        }
    }
}
