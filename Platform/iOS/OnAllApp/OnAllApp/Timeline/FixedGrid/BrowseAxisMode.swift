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

    /// What the fixed grid does and does not do yet, said to the person using it.
    static let editingNotice = "고정 격자 보기 · 빈 곳을 길게 눌러 끌면 새 일정 · 일정을 눌러 시간을, 제목을 한 번 더 눌러 이름을 바꿉니다 · 길게 누르면 정보"
}
