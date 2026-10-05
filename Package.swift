// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NEOBudgetCore",
    products: [
        .library(name: "NEOBudgetCore", targets: ["NEOBudgetCore"]),
        .library(name: "NEOBudgetInMemoryStorage", targets: ["NEOBudgetInMemoryStorage"])
    ],
    targets: [
        .target(name: "NEOBudgetCore"),
        .target(name: "NEOBudgetInMemoryStorage", dependencies: ["NEOBudgetCore"]),
        .testTarget(
            name: "NEOBudgetCoreTests",
            dependencies: ["NEOBudgetCore", "NEOBudgetInMemoryStorage"],
            resources: [.copy("Fixtures")]
        )
    ]
)
