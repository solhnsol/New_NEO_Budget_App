// swift-tools-version: 6.0
import PackageDescription

// Times the startup replay of N synthetic notifications (and the other per-count costs) against the real
// NEOBudgetCore / NEOBudgetInMemoryStorage. Run: swift run -c release ReplayBench 1000 3000 10000
let package = Package(
    name: "ReplayBench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "ReplayBench",
            dependencies: [
                .product(name: "NEOBudgetCore", package: "New_NEO_Budget_App"),
                .product(name: "NEOBudgetInMemoryStorage", package: "New_NEO_Budget_App")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
