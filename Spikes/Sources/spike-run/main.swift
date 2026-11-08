#if os(macOS)
import AppKit
import Foundation
import SpikeKit

// Usage: swift run spike-run [--out <dir>] [1 2 3 ...]
var args = Array(CommandLine.arguments.dropFirst())
var outDir = URL(fileURLWithPath: "output", isDirectory: true)
if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
    outDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    args.removeSubrange(i...(i + 1))
}
let ids = args.compactMap { Int($0) }.isEmpty ? Array(1...7) : args.compactMap { Int($0) }

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
    let ctx = SpikeContext(outputDirectory: outDir)
    let results = await SpikeSuite.run(ids: ids, ctx: ctx)
    let report = SpikeSuite.report(results, platform: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    try? report.write(to: outDir.appendingPathComponent("results-macos.md"), atomically: true, encoding: .utf8)
    print("\n" + report)
    exit(0)
}
app.run()
#else
print("spike-run is macOS only; use `xcodebuild test` with SpikeKitTests on the iOS Simulator")
#endif
