import Foundation

public enum SpikeSuite {
    @MainActor
    public static func run(ids: [Int], ctx: SpikeContext) async -> [SpikeResult] {
        var results: [SpikeResult] = []
        for id in ids {
            print("=== Spike \(id) ===")
            let r: SpikeResult
            switch id {
            case 1: r = await runSpike1(ctx)
            case 2: r = await runSpike2(ctx)
            case 3: r = await runSpike3(ctx)
            case 4: r = await runSpike4(ctx)
            case 5: r = await runSpike5(ctx)
            case 6: r = await runSpike6(ctx)
            case 7: r = await runSpike7(ctx)
            case 8: r = await runSpike8(ctx)
            case 9: r = await runSpike9(ctx)
            default: continue
            }
            print("  => \(r.verdict.rawValue)\(r.error.map { " (\($0))" } ?? "")")
            results.append(r)
        }
        return results
    }

    public static func report(_ results: [SpikeResult], platform: String) -> String {
        var s = "# Spike results (\(platform), \(Date().formatted(.iso8601)))\n\n"
        for r in results { s += r.rendered + "\n" }
        return s
    }
}
