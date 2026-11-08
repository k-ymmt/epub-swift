// swift-tools-version: 6.2
// Spike package for verifying the assumptions listed in docs/design/04-roadmap.md §2.
// This package is intentionally separate from the root Package.swift and contains no production code.
import PackageDescription

let package = Package(
    name: "EPUBSpikes",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    targets: [
        .target(
            name: "SpikeKit",
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .executableTarget(
            name: "spike-run",
            dependencies: ["SpikeKit"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .executableTarget(
            name: "spike-ios-app",
            dependencies: ["SpikeKit"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .testTarget(
            name: "SpikeKitTests",
            dependencies: ["SpikeKit"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
    ]
)
