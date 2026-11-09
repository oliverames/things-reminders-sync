// swift-tools-version: 6.2
import PackageDescription

// No third-party dependencies: Foundation, CryptoKit, Security, ServiceManagement, and SwiftUI only.
let package = Package(
    name: "ThingsRemindersSync",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ThingsRemindersSync", targets: ["ThingsRemindersSync"]),
        .library(name: "SyncCore", targets: ["SyncCore"]),
    ],
    targets: [
        .target(name: "SyncCore"),
        .executableTarget(name: "ThingsRemindersSync", dependencies: ["SyncCore"]),
        // Maintenance CLI (not bundled into the app): runs teardown and completed-copy removal headlessly.
        .executableTarget(name: "trs-admin", dependencies: ["SyncCore"]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"]),
    ]
)
