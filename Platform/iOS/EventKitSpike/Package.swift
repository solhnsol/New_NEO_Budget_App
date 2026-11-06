// swift-tools-version: 6.0
import PackageDescription
import AppleProductTypes

// Exploratory EventKit spike. Not part of the shipping package: it only records what EventKit actually does
// so the adapter design (docs/calendar-integration-design.md §C.4) rests on observed behavior.
let package = Package(
    name: "EventKitSpike",
    platforms: [.iOS(.v17)],
    products: [
        .iOSApplication(
            name: "EventKitSpike",
            targets: ["SpikeApp"],
            bundleIdentifier: "dev.onall.eventkitspike",
            displayVersion: "1.0",
            bundleVersion: "1",
            supportedDeviceFamilies: [.phone],
            supportedInterfaceOrientations: [.portrait],
            capabilities: [.calendars(purposeString: "EventKit behavior spike")]
        )
    ],
    targets: [
        .executableTarget(name: "SpikeApp")
    ]
)
