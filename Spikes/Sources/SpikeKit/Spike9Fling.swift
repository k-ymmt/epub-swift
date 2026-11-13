import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// 9. Continuous scroll under the finger (iOS Simulator): the wrapper keeps a sliding window of chapters while
/// someone flings it. The app only records; the swipes come from outside (a person, or a tool that injects touches)
/// during `SPIKE9_SECONDS`. Recorded per sample: the scroll view's offset and state, and how far the picture moved
/// since the previous sample, measured from the pixels. Scrolling that stays smooth while a chapter is added above
/// shows as a picture that keeps moving at the finger's speed while the offset jumps by the chapter's height.
///
/// Environment: `SPIKE9_MODE` (`manual` | `runway` | `anchor` | `none`), `SPIKE9_PRESET` (1: chapter heights are
/// known before the chapter is added), `SPIKE9_MARGIN` (px kept loaded above and below), `SPIKE9_START` (spine
/// index), `SPIKE9_SECONDS`, `SPIKE9_RUNWAY` (px of runway above the first chapter in `runway` mode).
@MainActor
public func runSpike9(_ ctx: SpikeContext) async -> SpikeResult {
    var r = SpikeResult(id: 9, title: "連続スクロール: 慣性スクロール中に上へ章を足す（iOS Simulator、外からスワイプを入れる）")
    #if canImport(UIKit)
    let env = ProcessInfo.processInfo.environment
    let mode = env["SPIKE9_MODE"] ?? "manual"
    let preset = (env["SPIKE9_PRESET"] ?? "1") == "1"
    let margin = Double(env["SPIKE9_MARGIN"] ?? "") ?? 2000
    let seconds = Double(env["SPIKE9_SECONDS"] ?? "") ?? 25
    do {
        let book = try BookFixture.fromEnvironment()
        let start = min(Int(env["SPIKE9_START"] ?? "") ?? 60, book.spine.count - 2)
        let rig = try await ScrollRig.make(book: book, mode: mode)
        defer { rig.host.close() }
        var heights: [String: Double] = [:]
        if preset {
            for i in max(0, start - 30)..<start { heights[String(i)] = try await rig.number("measureOnly(i)", ["i": i]) }
        }
        try await rig.add(start)
        try await rig.add(start + 1)
        let runway = mode == "runway" ? (Double(env["SPIKE9_RUNWAY"] ?? "") ?? 400_000) : 0
        if runway > 0 { _ = try await rig.call("setRunway(px)", ["px": runway]) }
        _ = try await rig.call("scrollTo(y)", ["y": runway + 300.0])
        _ = try await rig.call("autoWindow(o)", ["o": ["margin": margin, "heights": preset ? heights as Any : NSNull()] as [String: Any]])
        try await rig.host.settle(1500)
        let state0 = try await rig.dict("state()")
        r.note("mode=\(mode)、高さ既知=\(preset)、先読み \(Int(margin)) px、上の余白 \(Int(runway)) px、開始 spine \(start)、初期の窓 \(((state0["views"] as? [[String: Any]]) ?? []).compactMap { $0["index"] as? Int })")

        let scrollView = rig.host.webView.scrollView
        let size = spikeViewportSize()
        var samples: [FlingSample] = []
        let clock = ContinuousClock()
        let t0 = clock.now
        let wall0 = Date().timeIntervalSince1970 * 1000
        print("SPIKE9 READY \(Int(seconds))s")
        while clock.now - t0 < .seconds(seconds) {
            let offset = scrollView.contentOffset.y
            let flags = (scrollView.isTracking ? 1 : 0) | (scrollView.isDragging ? 2 : 0) | (scrollView.isDecelerating ? 4 : 0)
            let snap = try await rig.host.snapshot(scale: 1.0 / Double(rig.host.window.screen.scale), afterScreenUpdates: false)
            let elapsed = clock.now - t0
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            samples.append(FlingSample(ms: ms, offset: Double(offset), contentHeight: Double(scrollView.contentSize.height), flags: flags,
                                       signature: rowSignature(snap.bitmap)))
            try await Task.sleep(for: .milliseconds(2))
        }
        print("SPIKE9 RECORDING DONE, analysing \(samples.count) samples")
        let log = (try await rig.call("log()") as? [[String: Any]]) ?? []
        let state1 = try await rig.dict("state()")

        // How far the picture moved between consecutive samples, and whether that is what the offset says.
        // `shift` is the best match over every shift; lines of text repeat, so at speed it can lock onto a multiple
        // of the line height. `expected` is what the offset says, taking into account
        // - a late picture: the snapshot still shows the previous sample's offset (the offset and the snapshot are
        //   not read at the same instant), so the movement is owed to the next sample;
        // - a correction: the offset jumped by an amount the page logged (a chapter added above, its height settled),
        //   and the picture must move as if it had not.
        // `residualExpected` says how well the two pictures match at that shift.
        let corrections = log.filter { ($0["ev"] as? String) == "correct" }.compactMap { ($0["by"] as? NSNumber)?.doubleValue }
        var jumps: [Double] = [0] + corrections
        for i in corrections.indices.dropLast() { jumps.append(corrections[i] + corrections[i + 1]) }
        var rows: [[String: Any]] = []
        var owed = 0.0
        for i in samples.indices {
            var row: [String: Any] = ["ms": samples[i].ms, "offset": samples[i].offset, "contentHeight": samples[i].contentHeight,
                                      "flags": samples[i].flags, "blankRun": longestBlankRun(samples[i].signature)]
            if i > 0 {
                let (shift, residual) = bestShift(samples[i - 1].signature, samples[i].signature, range: 600)
                row["shift"] = shift
                row["residual"] = residual
                let delta = samples[i].offset - samples[i - 1].offset
                var best = (expected: 0, residual: 9.0, jump: 0.0)
                for jump in jumps {
                    let expected = Int((owed - (delta - jump)).rounded())
                    guard abs(expected) <= 600 else { continue }
                    let rr = residualAt(samples[i - 1].signature, samples[i].signature, shift: expected)
                    // An explanation without a jump wins unless the one with a jump is clearly better.
                    if rr < best.residual - (jump == 0 ? 0 : 0.05) { best = (expected, rr, jump) }
                }
                if best.residual >= 0.45, residual < 0.005, shift == 0, abs(delta) <= 600, abs(owed - delta) >= 1 {
                    // Nothing explains the pair, and the two pictures are identical while the offset moved: the
                    // picture is late.
                    row["late"] = true
                    row["expected"] = 0
                    row["residualExpected"] = residual
                    owed -= delta
                } else {
                    row["expected"] = best.expected
                    row["residualExpected"] = best.residual
                    if best.jump != 0 { row["jump"] = best.jump }
                    owed = 0
                }
            }
            rows.append(row)
        }
        let events = log.compactMap { e -> [String: Any]? in
            guard let t = (e["t"] as? NSNumber)?.doubleValue else { return nil }
            var out = e
            out["ms"] = t - wall0
            out.removeValue(forKey: "t")
            return out
        }
        let name = "spike9-\(mode)-\(preset ? "known" : "unknown").json"
        let json = try JSONSerialization.data(withJSONObject: ["mode": mode, "preset": preset, "margin": margin, "viewport": [size.width, size.height],
                                                               "samples": rows, "events": events], options: [.sortedKeys])
        try json.write(to: ctx.outputDirectory.appendingPathComponent(name))
        let moved = samples.contains { $0.flags != 0 }
        let shifts = events.filter { ($0["ev"] as? String) == "shift" }.count
        let prepends = events.filter { ($0["ev"] as? String) == "loaded" && ($0["where"] as? String) == "prepend" }.count
        let rate = Double(samples.count) / seconds
        r.note("標本 \(samples.count)（\(fmt(rate)) /秒）、指またはその慣性で動いた標本 \(samples.filter { $0.flags != 0 }.count)、上に足した章 \(prepends)、スクロール位置を書き換えた補正 \(corrections.count) 回、余白で吸収した補正 \(shifts) 回")
        r.note("終了時の窓 \(((state1["views"] as? [[String: Any]]) ?? []).compactMap { $0["index"] as? Int })、記録 \(name)（scripts/analyse-fling.py で読む）")
        r.verdict = moved ? .conditional : .notRun
        if !moved { r.note("スワイプが入らなかった（記録中にシミュレータへタッチを入れること）") }
    } catch {
        r.error = "\(error)"; r.verdict = .fail
    }
    #else
    r.note("iOS Simulator 専用（scripts/run-ios.sh 9）")
    #endif
    return r
}

struct FlingSample {
    var ms: Double
    var offset: Double
    var contentHeight: Double
    var flags: Int
    /// Ink per row of the snapshot, left half then right half (two values per row).
    var signature: [Int32]
}

/// Darkness summed along each row, separately for the left and the right half: lines of text of different lengths
/// give rows that differ, which makes the vertical shift between two snapshots recoverable.
func rowSignature(_ bitmap: Bitmap) -> [Int32] {
    var out = [Int32](repeating: 0, count: bitmap.height * 2)
    let half = bitmap.width / 2
    bitmap.bytes.withUnsafeBufferPointer { p in
        for y in 0..<bitmap.height {
            var left: Int32 = 0, right: Int32 = 0
            var i = y * bitmap.width * 4
            for x in 0..<bitmap.width {
                let dark = 255 - (Int32(p[i]) + Int32(p[i + 1]) + Int32(p[i + 2])) / 3
                if x < half { left += dark } else { right += dark }
                i += 4
            }
            out[y * 2] = left
            out[y * 2 + 1] = right
        }
    }
    return out
}

/// The shift (rows, positive = the picture moved down) that best maps `a` onto `b`, and the mean difference per row
/// at that shift relative to the mean ink per row (0 = identical, around 1 = unrelated pictures).
func bestShift(_ a: [Int32], _ b: [Int32], range: Int) -> (shift: Int, residual: Double) {
    let rows = min(a.count, b.count) / 2
    guard rows > 0 else { return (0, 1) }
    var mean = 0.0
    for v in a { mean += Double(v) }
    mean = max(1, mean / Double(a.count))
    var best = (shift: 0, residual: Double.infinity)
    a.withUnsafeBufferPointer { pa in
        b.withUnsafeBufferPointer { pb in
            for d in -range...range {
                let lo = max(0, -d), hi = min(rows, rows - d)
                // At least a third of the picture must overlap, or a shift past the edge would match nothing well.
                guard hi - lo >= rows / 3 else { continue }
                var sum: Int64 = 0
                for y in lo..<hi {
                    sum += Int64(abs(pa[y * 2] - pb[(y + d) * 2])) + Int64(abs(pa[y * 2 + 1] - pb[(y + d) * 2 + 1]))
                }
                let residual = Double(sum) / Double((hi - lo) * 2) / mean
                // Prefer the smaller shift on a tie (a picture that did not move).
                if residual < best.residual - 1e-9 || (abs(residual - best.residual) <= 1e-9 && abs(d) < abs(best.shift)) {
                    best = (d, residual)
                }
            }
        }
    }
    return best
}

/// The mean difference per row at one given shift, on the scale of `bestShift`'s residual.
func residualAt(_ a: [Int32], _ b: [Int32], shift d: Int) -> Double {
    let rows = min(a.count, b.count) / 2
    var mean = 0.0
    for v in a { mean += Double(v) }
    mean = max(1, mean / Double(max(1, a.count)))
    let lo = max(0, -d), hi = min(rows, rows - d)
    guard hi > lo else { return 9 }
    var sum: Int64 = 0
    for y in lo..<hi { sum += Int64(abs(a[y * 2] - b[(y + d) * 2])) + Int64(abs(a[y * 2 + 1] - b[(y + d) * 2 + 1])) }
    return Double(sum) / Double((hi - lo) * 2) / mean
}

/// Longest run of rows with (almost) no ink: a band of unpainted tiles shows as a long one.
func longestBlankRun(_ signature: [Int32]) -> Int {
    var longest = 0, run = 0
    for y in 0..<(signature.count / 2) {
        if signature[y * 2] + signature[y * 2 + 1] < 200 { run += 1; longest = max(longest, run) } else { run = 0 }
    }
    return longest
}
