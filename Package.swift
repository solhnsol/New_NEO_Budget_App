// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NEOBudgetCore",
    products: [
        .library(name: "NEOBudgetCore", targets: ["NEOBudgetCore"])
    ],
    targets: [
        .target(name: "NEOBudgetCore"),
        .testTarget(name: "NEOBudgetCoreTests", dependencies: ["NEOBudgetCore"])
    ]
)
