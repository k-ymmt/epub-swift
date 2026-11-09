// swift-tools-version: 6.4
// EPUB-Swift: a WebView-based EPUB 3 viewer library for iOS 26+ / macOS 26+.
// Target layering is described in docs/design/00-overview.md §4.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
]

let package = Package(
    name: "EPUB-Swift",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        // Umbrella module re-exporting EPUBCore, EPUBRenderer and EPUBUI. Apps normally import only this.
        .library(name: "EPUB", targets: ["EPUB"]),
        .library(name: "EPUBCore", targets: ["EPUBCore"]),
        .library(name: "EPUBRenderer", targets: ["EPUBRenderer"]),
        .library(name: "EPUBUI", targets: ["EPUBUI"]),
    ],
    targets: [
        // Foundation / Compression / CryptoKit / libxml2 only. No UI, no WebKit.
        // libxml2 is imported from the SDK module (`import libxml2`); no system library target.
        .target(
            name: "EPUBCore",
            swiftSettings: swiftSettings
        ),
        // WebKit. No SwiftUI.
        .target(
            name: "EPUBRenderer",
            dependencies: ["EPUBCore"],
            resources: [.copy("Reader")],
            swiftSettings: swiftSettings
        ),
        // SwiftUI views, gestures, page transitions.
        .target(
            name: "EPUBUI",
            dependencies: ["EPUBCore", "EPUBRenderer"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "EPUB",
            dependencies: ["EPUBCore", "EPUBRenderer", "EPUBUI"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "EPUBCoreTests",
            dependencies: ["EPUBCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "EPUBRendererTests",
            dependencies: ["EPUBRenderer", "EPUBCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "EPUBUITests",
            dependencies: ["EPUBUI"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "EPUBTests",
            dependencies: ["EPUB"],
            swiftSettings: swiftSettings
        ),
    ]
)
