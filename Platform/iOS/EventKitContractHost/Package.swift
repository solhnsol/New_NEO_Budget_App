// swift-tools-version: 6.0
import PackageDescription

// App host that runs the shared CalendarProvider contract against the EventKit provider inside the iOS
// simulator. A bare `xctest` runner cannot be granted calendar access, so the checks run in an app bundle
// that `run-contract.sh` assembles and grants access to.
let package = Package(
    name: "EventKitContractHost",
    platforms: [.iOS(.v17)],
    products: [.executable(name: "ContractHost", targets: ["ContractHost"])],
    dependencies: [.package(path: "../../..")],
    targets: [
        .executableTarget(
            name: "ContractHost",
            dependencies: [
                .product(name: "NEOBudgetEventKit", package: "New_NEO_Budget_App"),
                .product(name: "NEOBudgetCalendarContract", package: "New_NEO_Budget_App"),
                .product(name: "NEOBudgetCalendar", package: "New_NEO_Budget_App"),
            ]
        )
    ]
)
