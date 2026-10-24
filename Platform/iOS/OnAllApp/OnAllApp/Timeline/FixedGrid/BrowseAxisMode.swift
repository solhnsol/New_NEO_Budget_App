import Foundation

/// Which time axis Browse is drawn on. `fixedGrid` (the fixed Temporal Grid: N equal-height cells, hour boundaries, editing and creating
/// in place) is the default in every build; `classic` is the earlier Browse, kept only to compare against
/// (`docs/development/browse-temporal-grid-integration.md`).
///
/// Only a DEBUG build reads the launch argument `-browse-classic`. `-browse-temporal` is still accepted and changes nothing.
enum BrowseAxisMode: Equatable {
    case classic
    case fixedGrid

    static let classicLaunchArgument = "-browse-classic"

    static func resolve(arguments: [String]) -> BrowseAxisMode {
        #if DEBUG
        return arguments.contains(classicLaunchArgument) ? .classic : .fixedGrid
        #else
        return .fixedGrid
        #endif
    }

    static let current = resolve(arguments: ProcessInfo.processInfo.arguments)
}
