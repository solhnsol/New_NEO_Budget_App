// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NEOBudgetCore",
    products: [
        .library(name: "NEOBudgetCore", targets: ["NEOBudgetCore"]),
        .library(name: "NEOBudgetInMemoryStorage", targets: ["NEOBudgetInMemoryStorage"]),
        .library(name: "NEOBudgetCalendar", targets: ["NEOBudgetCalendar"]),
        .library(name: "NEOBudgetInMemoryCalendar", targets: ["NEOBudgetInMemoryCalendar"])
    ],
    targets: [
        .target(name: "NEOBudgetCore"),
        .target(name: "NEOBudgetInMemoryStorage", dependencies: ["NEOBudgetCore"]),
        // Platform-independent calendar / activity / semantic domain. No EventKit, SwiftUI, or OS types.
        .target(name: "NEOBudgetCalendar", dependencies: ["NEOBudgetCore"]),
        .target(name: "NEOBudgetInMemoryCalendar", dependencies: ["NEOBudgetCore", "NEOBudgetCalendar"]),
        .testTarget(
            name: "NEOBudgetCoreTests",
            dependencies: ["NEOBudgetCore", "NEOBudgetInMemoryStorage"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "NEOBudgetCalendarTests",
            dependencies: ["NEOBudgetCalendar", "NEOBudgetCore", "NEOBudgetInMemoryCalendar", "NEOBudgetInMemoryStorage"]
        )
    ]
)
