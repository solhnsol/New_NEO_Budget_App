// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NEOBudgetCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NEOBudgetCore", targets: ["NEOBudgetCore"]),
        .library(name: "NEOBudgetInMemoryStorage", targets: ["NEOBudgetInMemoryStorage"]),
        .library(name: "NEOBudgetCalendar", targets: ["NEOBudgetCalendar"]),
        .library(name: "NEOBudgetInMemoryCalendar", targets: ["NEOBudgetInMemoryCalendar"]),
        .library(name: "NEOBudgetCalendarContract", targets: ["NEOBudgetCalendarContract"]),
        .library(name: "NEOBudgetEventKit", targets: ["NEOBudgetEventKit"])
    ],
    targets: [
        .target(name: "NEOBudgetCore"),
        .target(name: "NEOBudgetInMemoryStorage", dependencies: ["NEOBudgetCore"]),
        // Platform-independent calendar / activity / semantic domain. No EventKit, SwiftUI, or OS types.
        .target(name: "NEOBudgetCalendar", dependencies: ["NEOBudgetCore"]),
        .target(name: "NEOBudgetInMemoryCalendar", dependencies: ["NEOBudgetCore", "NEOBudgetCalendar"]),
        // CalendarProvider backed by EventKit. The file compiles to nothing where EventKit does not exist.
        .target(name: "NEOBudgetEventKit", dependencies: ["NEOBudgetCalendar"]),
        // Executable CalendarProvider contract. No test-framework dependency, so an iOS app host can run it too.
        .target(name: "NEOBudgetCalendarContract", dependencies: ["NEOBudgetCalendar"]),
        .testTarget(
            name: "NEOBudgetCoreTests",
            dependencies: ["NEOBudgetCore", "NEOBudgetInMemoryStorage"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "NEOBudgetCalendarTests",
            dependencies: ["NEOBudgetCalendar", "NEOBudgetCalendarContract", "NEOBudgetCore", "NEOBudgetInMemoryCalendar", "NEOBudgetInMemoryStorage"]
        )
    ]
)
