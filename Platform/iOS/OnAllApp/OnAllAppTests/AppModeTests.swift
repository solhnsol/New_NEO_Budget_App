import Foundation
import Testing
@testable import OnAllApp

@Suite struct AppModeTests {
    private func freshDefaults() -> UserDefaults {
        let name = "AppModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func opensDemoWhenNothingIsSaved() {
        #expect(AppMode.resolve(arguments: [], defaults: freshDefaults()) == .demo)
    }

    @Test func savedChoiceSurvivesRelaunchAndIsReversible() {
        let defaults = freshDefaults()
        AppMode.save(.live, defaults: defaults)
        #expect(AppMode.resolve(arguments: [], defaults: defaults) == .live)
        AppMode.save(.demo, defaults: defaults)
        #expect(AppMode.resolve(arguments: [], defaults: defaults) == .demo)
    }

    @Test func launchArgumentsWinWithoutBeingSaved() {
        let defaults = freshDefaults()
        AppMode.save(.demo, defaults: defaults)
        #expect(AppMode.resolve(arguments: ["-live"], defaults: defaults) == .live)
        AppMode.save(.live, defaults: defaults)
        #expect(AppMode.resolve(arguments: ["-demo"], defaults: defaults) == .demo)
        #expect(AppMode.resolve(arguments: ["-demo-full"], defaults: defaults) == .demo)
        #expect(AppMode.resolve(arguments: [], defaults: defaults) == .live)
    }

    @Test func unknownSavedValueFallsBackToDemo() {
        let defaults = freshDefaults()
        defaults.set("bogus", forKey: AppMode.defaultsKey)
        #expect(AppMode.resolve(arguments: [], defaults: defaults) == .demo)
    }

    @Test func pinnedOnlyByModeArguments() {
        #expect(AppMode.isPinnedByLaunchArgument(["-live"]))
        #expect(AppMode.isPinnedByLaunchArgument(["-demo"]))
        #expect(!AppMode.isPinnedByLaunchArgument(["-ledger-sample"]))
    }
}
