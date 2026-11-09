// swift-tools-version: 6.4
// Minimal SwiftUI reader used to try EPUB-Swift by hand on macOS and the iOS Simulator (docs/design/04-roadmap.md M1).
// macOS: `swift run` in this directory. iOS Simulator: `scripts/run-ios.sh`.
import PackageDescription

let package = Package(
    name: "ReaderDemo",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "ReaderDemo",
            dependencies: [.product(name: "EPUB", package: "epub-swift")],
            resources: [.copy("Books")],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
    ]
)
