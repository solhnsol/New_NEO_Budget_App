import Foundation

/// Which time axis Browse is drawn on. `classic` is the product as it was and stays the default; `fixedGrid` is the fixed Temporal Grid (N equal-height cells, hour
/// boundaries) read-only: the internal path being compared against `classic` before it can replace it (`docs/development/browse-temporal-grid-integration.md`, phase 1).
///
/// An internal switch: only a DEBUG build reads the launch argument `-browse-temporal`; a release build is always `classic`.
enum BrowseAxisMode: Equatable {
    case classic
    case fixedGrid

    static let launchArgument = "-browse-temporal"

    static func resolve(arguments: [String]) -> BrowseAxisMode {
        #if DEBUG
        return arguments.contains(launchArgument) ? .fixedGrid : .classic
        #else
        return .classic
        #endif
    }

    static let current = resolve(arguments: ProcessInfo.processInfo.arguments)

    /// What the fixed grid does and does not do yet, said to the person using it.
    static let editingNotice = "고정 격자 보기 · 일정을 눌러 시간을, 제목을 한 번 더 눌러 이름을 바꿉니다 · 길게 누르면 정보"
}
