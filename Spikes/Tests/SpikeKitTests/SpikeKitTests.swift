import XCTest
@testable import SpikeKit

/// Runs the spikes that have platform-specific risk (3: off-screen snapshot, 7: scrolling with isScrollEnabled = false)
/// so they can be executed on the iOS Simulator via `xcodebuild test`. Also runs 1, 2, 4 for good measure.
final class SpikeKitTests: XCTestCase {
    @MainActor
    func testSpikesOnThisPlatform() async throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SPIKE_OUT"] ?? NSTemporaryDirectory()).appendingPathComponent("spike-output")
        let ctx = SpikeContext(outputDirectory: out)
        #if os(iOS)
        let platform = "iOS \(UIDevice.current.systemVersion) (\(UIDevice.current.model), Simulator)"
        #else
        let platform = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
        let results = await SpikeSuite.run(ids: [1, 2, 3, 4, 7], ctx: ctx)
        let report = SpikeSuite.report(results, platform: platform)
        try report.write(to: out.appendingPathComponent("results.md"), atomically: true, encoding: .utf8)
        print(report)
        print("SPIKE_OUTPUT_DIR=\(out.path)")
        for r in results { XCTAssertNotEqual(r.verdict, .notRun, "spike \(r.id)") }
    }
}
