import Foundation
import SwiftUI

/// Which data the app shows: the six-week demo, or the device calendar with the ledger the Shortcut fills.
enum AppMode: String, Sendable, CaseIterable {
    case demo, live

    /// The key under which the choice survives a relaunch.
    static let defaultsKey = "appMode"

    /// Launch arguments win for this launch only (`-live` for the device, `-demo` / `-demo-full` for screenshots and
    /// tests) and are never saved. Otherwise the saved choice applies, and with none saved the app opens the demo.
    static func resolve(arguments: [String], defaults: UserDefaults = .standard) -> AppMode {
        if arguments.contains("-live") { return .live }
        if arguments.contains("-demo") || arguments.contains("-demo-full") { return .demo }
        return defaults.string(forKey: defaultsKey).flatMap(AppMode.init(rawValue:)) ?? .demo
    }

    /// Remember the choice for the next launch. Only the mode changes; the received notifications stay as they are.
    static func save(_ mode: AppMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
    }

    /// The mode this launch runs in right now.
    static var current: AppMode { resolve(arguments: ProcessInfo.processInfo.arguments) }

    /// True when a launch argument decides the mode, so the in-app switch would not hold.
    static func isPinnedByLaunchArgument(_ arguments: [String]) -> Bool {
        arguments.contains("-live") || arguments.contains("-demo") || arguments.contains("-demo-full")
    }
}

private struct SwitchAppModeKey: EnvironmentKey {
    static let defaultValue: @MainActor (AppMode) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Switches the running app to another mode: saves it and rebuilds the model.
    var switchAppMode: @MainActor (AppMode) -> Void {
        get { self[SwitchAppModeKey.self] }
        set { self[SwitchAppModeKey.self] = newValue }
    }
}
