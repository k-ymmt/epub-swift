import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// One web view showing the wrapper document, with the book behind `epub://spike/book/`.
@MainActor
struct ScrollRig {
    let host: WebHost
    let book: BookFixture
    let urls: [String]

    static func make(book: BookFixture, extra: [String: String] = [:], mode: String = "anchor") async throws -> ScrollRig {
        let host = WebHost(
            visibleSize: spikeViewportSize(),
            userScripts: [UserScriptSpec(ContinuousScrollJS.controller, at: .atDocumentEnd, mainFrameOnly: true)],
            scrollable: true
        )
        book.install(on: host, extra: extra)
        host.serve("/wrapper.html", Fixtures.htmlMIME, ContinuousScrollJS.wrapper)
        try await host.load("/wrapper.html")
        let urls = book.urls + extra.keys.sorted().map { "epub://spike" + BookFixture.prefix + $0 }
        let rig = ScrollRig(host: host, book: book, urls: urls)
        _ = try await rig.call("configure(urls, mode)", ["urls": urls, "mode": mode])
        return rig
    }

    @discardableResult
    func call(_ expression: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await host.js("return await window.__cs.\(expression);", args: args)
    }

    func dict(_ expression: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        (try await call(expression, args) as? [String: Any]) ?? [:]
    }

    func number(_ expression: String, _ args: [String: Any] = [:]) async throws -> Double {
        (try await call(expression, args) as? NSNumber)?.doubleValue ?? .nan
    }

    @discardableResult
    func add(_ index: Int, _ place: String = "append", preset: Double = 0) async throws -> [String: Any] {
        try await dict("add(i, place, preset)", ["i": index, "place": place, "preset": preset])
    }

    /// Footprints of the WebContent and the GPU process in MB.
    func memory() -> (web: Double?, gpu: Double?) {
        (host.webContentPID.flatMap(footprintMB(pid:)), host.gpuPID.flatMap(footprintMB(pid:)))
    }
}

@MainActor
func spikeViewportSize() -> CGSize {
    #if canImport(UIKit)
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
        return scene.coordinateSpace.bounds.size
    }
    return CGSize(width: 390, height: 844)
    #else
    return CGSize(width: 390, height: 760)
    #endif
}

extension Bitmap {
    /// Fraction of the sampled pixels (every `step`-th in both directions) that differ by more than `tolerance`.
    func diffRatio(_ other: Bitmap, step: Int = 3, tolerance: Int = 24) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        var total = 0, different = 0
        bytes.withUnsafeBufferPointer { a in
            other.bytes.withUnsafeBufferPointer { b in
                var y = 0
                while y < height {
                    var x = 0
                    while x < width {
                        let i = (y * width + x) * 4
                        total += 1
                        if abs(Int(a[i]) - Int(b[i])) > tolerance || abs(Int(a[i + 1]) - Int(b[i + 1])) > tolerance
                            || abs(Int(a[i + 2]) - Int(b[i + 2])) > tolerance { different += 1 }
                        x += step
                    }
                    y += step
                }
            }
        }
        return Double(different) / Double(max(1, total))
    }
}

private func trace(_ s: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["SPIKE8_TRACE"] != nil { print("    trace: " + s()) }
}

private func mb(_ v: Double?) -> String { v.map { fmt($0) } ?? "?" }

private func summary(_ values: [Double]) -> String {
    guard !values.isEmpty else { return "-" }
    let s = values.sorted()
    func q(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
    return "中央 \(fmt(q(0.5))) / 95% \(fmt(q(0.95))) / 最大 \(fmt(s.last!))"
}

@MainActor
private final class Box {
    var done = false
    var result: [String: Any] = [:]
    var error: (any Error)?
}

/// 8. Continuous vertical scroll: one web view, one iframe per chapter. Memory, the cost of adding a chapter, and
/// whether the text on screen stays put when the document changes above it.
@MainActor
public func runSpike8(_ ctx: SpikeContext) async -> SpikeResult {
    var r = SpikeResult(id: 8, title: "連続スクロール: 1 つの WebView に章ごとの iframe を縦に並べる（メモリ・追加コスト・位置の安定）")
    let phases = Set((ProcessInfo.processInfo.environment["SPIKE8_PHASES"] ?? "window all giant stability").split(separator: " ").map(String.init))
    do {
        let book = try BookFixture.fromEnvironment()
        let size = spikeViewportSize()
        r.note("本: \(book.root.lastPathComponent)、線形 spine \(book.spine.count) 項目、ビューポート \(Int(size.width))x\(Int(size.height))")
        // A window that is not on screen (locked screen, display asleep) gets no animation frames and no paints: the
        // scrolling and stability phases would wait forever, so they are skipped and the note says why.
        let probe = try await ScrollRig.make(book: book, mode: "none")
        let visibility = try await probe.host.js("""
            const raf = await Promise.race([new Promise(r => requestAnimationFrame(() => r(true))), new Promise(r => setTimeout(() => r(false), 1500))]);
            return { state: document.visibilityState, raf: raf };
            """) as? [String: Any] ?? [:]
        probe.host.close()
        let painting = (visibility["raf"] as? Bool) ?? false
        r.note("ページの可視状態: \(visibility["state"] ?? "?")、requestAnimationFrame が来る=\(painting)")
        if !painting {
            r.note("画面に出ていないので、スクロールと位置の安定のフェーズは実行しない（メモリと読み込み時間だけ）")
        }
        if phases.contains("window") { try await phaseWindow(&r, book) }
        if phases.contains("all") { try await phaseLoadAll(&r, book, ctx, scrolls: painting) }
        if phases.contains("giant") { try await phaseGiant(&r, book, ctx, scrolls: painting) }
        if phases.contains("stability"), painting { try await phaseStability(&r, book) }
        r.verdict = .conditional
    } catch {
        r.error = "\(error)"; r.verdict = .fail
    }
    return r
}

// MARK: - memory by number of chapters kept

@MainActor
private func phaseWindow(_ r: inout SpikeResult, _ book: BookFixture) async throws {
    let rig = try await ScrollRig.make(book: book, mode: "none")
    defer { rig.host.close() }
    r.note("overflow-anchor 対応=\(try await rig.call("supportsAnchor()") as? Bool ?? false)、WebContent pid=\(rig.host.webContentPID.map(String.init) ?? "?")、GPU pid=\(rig.host.gpuPID.map(String.init) ?? "?")")
    try await rig.host.settle(500)
    let base = rig.memory()
    r.note("[窓] 空のラッパー: WebContent \(mb(base.web)) MB、GPU \(mb(base.gpu)) MB")
    let start = min(40, max(0, book.spine.count - 64))
    var loaded = 0
    var totalHeight = 0.0
    for n in [1, 3, 7, 15, 31, 63] where start + n <= book.spine.count {
        while loaded < n {
            let res = try await rig.add(start + loaded)
            totalHeight += (res["height"] as? NSNumber)?.doubleValue ?? 0
            loaded += 1
        }
        try await rig.host.settle(700)
        let m = rig.memory()
        let dw = (m.web ?? 0) - (base.web ?? 0), dg = (m.gpu ?? 0) - (base.gpu ?? 0)
        r.note("[窓] \(n) 章（合計の高さ \(Int(totalHeight)) px）: WebContent \(mb(m.web)) MB（+\(fmt(dw))）、GPU \(mb(m.gpu)) MB（+\(fmt(dg))）、1 章あたり WebContent +\(fmt(dw / Double(n), 2)) MB")
    }
}

// MARK: - the whole book at once

@MainActor
private func phaseLoadAll(_ r: inout SpikeResult, _ book: BookFixture, _ ctx: SpikeContext, scrolls: Bool) async throws {
    let rig = try await ScrollRig.make(book: book, mode: "none")
    defer { rig.host.close() }
    try await rig.host.settle(500)
    let base = rig.memory()
    var loadMs: [Double] = [], measureMs: [Double] = [], heights: [Double] = []
    let clock = ContinuousClock()
    let t0 = clock.now
    for i in book.spine.indices {
        let res = try await rig.add(i)
        loadMs.append((res["loadMs"] as? NSNumber)?.doubleValue ?? 0)
        measureMs.append((res["measureMs"] as? NSNumber)?.doubleValue ?? 0)
        heights.append((res["height"] as? NSNumber)?.doubleValue ?? 0)
    }
    let elapsed = clock.now - t0
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let total = heights.reduce(0, +)
    r.note("[全章] \(book.spine.count) 章を順に追加: \(fmt(seconds, 2)) 秒、文書の高さ \(Int(total)) px（ビューポート \(fmt(total / spikeViewportSize().height, 0)) 枚分）")
    r.note("[全章] 1 章の読み込み（src 設定 → load）ms: \(summary(loadMs))")
    r.note("[全章] 1 章の高さの計測（強制レイアウト）ms: \(summary(measureMs))")
    r.note("[全章] 章の高さ px: \(summary(heights))、最小 \(Int(heights.min() ?? 0))")
    try await rig.host.settle(1000)
    // `load` comes before the book's web font: the heights above are with the fallback font.
    let settled = ((try await rig.dict("state()"))["views"] as? [[String: Any]] ?? []).compactMap { ($0["height"] as? NSNumber)?.doubleValue }
    let settledTotal = settled.reduce(0, +)
    r.note("[全章] フォント適用後の文書の高さ \(Int(settledTotal)) px（load 時点の \(fmt(settledTotal / max(1, total) * 100, 1))%）、高さが変わった章 \(zip(heights, settled).filter { $0 != $1 }.count)/\(heights.count)")
    let loaded = rig.memory()
    r.note("[全章] 読み込み後: WebContent \(mb(loaded.web)) MB（+\(fmt((loaded.web ?? 0) - (base.web ?? 0)))）、GPU \(mb(loaded.gpu)) MB（+\(fmt((loaded.gpu ?? 0) - (base.gpu ?? 0)))）")
    for fraction in [0.25, 0.5, 0.75, 0.999] where scrolls {
        let y = (settledTotal - spikeViewportSize().height) * fraction
        _ = try await rig.call("scrollTo(y)", ["y": y])
        try await rig.host.settle(500)
        let snap = try await rig.host.snapshot()
        let m = rig.memory()
        r.note("[全章] \(Int(fraction * 100))% へスクロール（y=\(Int(y))）: インク率 \(fmt(snap.bitmap.inkRatio(), 3))、WebContent \(mb(m.web)) MB、GPU \(mb(m.gpu)) MB")
        if fraction == 0.5 {
            try writePNG(snap.image, to: ctx.outputDirectory.appendingPathComponent("spike8-all-50.png"))
        }
    }
}

// MARK: - one very long chapter

@MainActor
private func phaseGiant(_ r: inout SpikeResult, _ book: BookFixture, _ ctx: SpikeContext, scrolls: Bool) async throws {
    // The longest chapter of the fixture, twenty times over.
    let longest = try book.spine.indices.max { (try book.text($0).utf8.count) < (try book.text($1).utf8.count) } ?? 0
    let giant = try book.repeated(longest, count: 20)
    let name = (book.spine[longest] as NSString).deletingLastPathComponent + "/__giant.xhtml"
    let rig = try await ScrollRig.make(book: book, extra: [name: giant], mode: "none")
    defer { rig.host.close() }
    try await rig.host.settle(500)
    let base = rig.memory()
    let res = try await rig.add(book.spine.count)
    let height = (res["height"] as? NSNumber)?.doubleValue ?? 0
    try await rig.host.settle(800)
    let m = rig.memory()
    r.note("[巨大章] \(giant.utf8.count / 1024) KB（\(book.spine[longest]) × 20）: 読み込み \(fmt((res["loadMs"] as? NSNumber)?.doubleValue ?? 0)) ms、計測 \(fmt((res["measureMs"] as? NSNumber)?.doubleValue ?? 0)) ms、高さ \(Int(height)) px")
    r.note("[巨大章] WebContent \(mb(m.web)) MB（+\(fmt((m.web ?? 0) - (base.web ?? 0)))）、GPU \(mb(m.gpu)) MB（+\(fmt((m.gpu ?? 0) - (base.gpu ?? 0)))）")
    guard scrolls else { return }
    _ = try await rig.call("scrollTo(y)", ["y": height * 0.6])
    try await rig.host.settle(500)
    let snap = try await rig.host.snapshot()
    let after = rig.memory()
    r.note("[巨大章] 60% へスクロール: インク率 \(fmt(snap.bitmap.inkRatio(), 3))、WebContent \(mb(after.web)) MB、GPU \(mb(after.gpu)) MB")
    try writePNG(snap.image, to: ctx.outputDirectory.appendingPathComponent("spike8-giant-60.png"))
}

// MARK: - does the text stay where it is?

private struct TrialOutcome {
    /// Where the marked element ended up, relative to where it was (px).
    var settled: Double
    /// Largest displacement seen in a `requestAnimationFrame` sample while the change was happening (px).
    var transient: Double
    /// Snapshots taken during the change that differed from the one taken before it.
    var changedFrames: Int
    var frames: Int
    /// Difference between the snapshot before and the one after everything settled.
    var finalDiff: Double
    /// iOS: UIScrollView's offset minus the document's own `scrollY` at the end.
    var nativeLag: Double?
}

/// Marks an element near the top of the viewport, runs `operation` (an expression on `window.__cs` returning a
/// promise), and reports whether the element — and the pixels — moved.
@MainActor
private func trial(_ rig: ScrollRig, operation: String, args: [String: Any] = [:]) async throws -> TrialOutcome {
    try await rig.host.settle(250)
    let y0 = try await rig.number("mark()")
    trace("marked y0=\(y0)")
    let before = try await rig.host.snapshot(scale: 1)
    // A band across the middle of the viewport: small enough to be captured faster than the display refreshes, so a
    // single frame with the text in the wrong place is not missed. On iOS the snapshot is what the render server
    // shows (WebKit renders the layer through CARenderServer), not what the web process thinks it drew.
    let size = spikeViewportSize()
    let band = CGRect(x: 0, y: (size.height * 0.4).rounded(), width: size.width, height: 48)
    let bandBefore = try await rig.host.snapshot(rect: band, scale: 1)
    trace("reference snapshot \(before.bitmap.width)x\(before.bitmap.height), band \(bandBefore.bitmap.width)x\(bandBefore.bitmap.height)")
    let box = Box()
    Task { @MainActor in
        do {
            box.result = (try await rig.host.js("""
                const sampling = window.__cs.sampleFrames(700);
                await window.__cs.\(operation);
                return await sampling;
                """, args: args) as? [String: Any]) ?? [:]
        } catch { box.error = error }
        box.done = true
        trace("operation done \(box.result) \(String(describing: box.error))")
    }
    var frames = 0, changed = 0
    while !box.done {
        let s = try await rig.host.snapshot(rect: band, scale: 1, afterScreenUpdates: false)
        frames += 1
        if s.bitmap.diffRatio(bandBefore.bitmap, step: 2) > 0.004 { changed += 1 }
        // On iOS a snapshot without screen updates completes synchronously, so without this the loop never lets
        // the main run loop deliver the web view's callbacks and the operation never finishes.
        try await Task.sleep(for: .milliseconds(2))
    }
    trace("snapshot loop done frames=\(frames)")
    if let error = box.error { throw error }
    try await rig.host.settle(350)
    let end = try await rig.dict("probe()")
    let after = try await rig.host.snapshot(scale: 1)
    let y1 = (end["y"] as? NSNumber)?.doubleValue ?? .nan
    let lo = (box.result["min"] as? NSNumber)?.doubleValue ?? y0, hi = (box.result["max"] as? NSNumber)?.doubleValue ?? y0
    var lag: Double?
    #if canImport(UIKit)
    lag = Double(rig.host.webView.scrollView.contentOffset.y) - ((end["scrollY"] as? NSNumber)?.doubleValue ?? 0)
    #endif
    return TrialOutcome(settled: y1 - y0, transient: max(abs(lo - y0), abs(hi - y0)), changedFrames: changed, frames: frames,
                        finalDiff: after.bitmap.diffRatio(before.bitmap), nativeLag: lag)
}

private func line(_ label: String, _ outcomes: [TrialOutcome]) -> String {
    let settled = outcomes.map { abs($0.settled) }.max() ?? 0
    let transient = outcomes.map(\.transient).max() ?? 0
    let changed = outcomes.map(\.changedFrames).reduce(0, +), frames = outcomes.map(\.frames).reduce(0, +)
    let diff = outcomes.map(\.finalDiff).max() ?? 0
    var s = "\(label): 最終のズレ 最大 \(fmt(settled)) px、途中のズレ 最大 \(fmt(transient)) px、途中で変化した帯のスナップショット \(changed)/\(frames)、前後の画像差 最大 \(fmt(diff * 100, 2))%"
    if let lag = outcomes.compactMap(\.nativeLag).map({ abs($0) }).max() { s += "、UIScrollView と文書の差 最大 \(fmt(lag)) px" }
    return s
}

@MainActor
private func phaseStability(_ r: inout SpikeResult, _ book: BookFixture) async throws {
    let rig = try await ScrollRig.make(book: book, mode: "none")
    defer { rig.host.close() }
    // Heights as a background measuring pass would know them.
    var heights: [Int: Double] = [:]
    let range = 10..<min(100, book.spine.count)
    for i in range { heights[i] = try await rig.number("measureOnly(i)", ["i": i]) }
    let viewport = Double(spikeViewportSize().height)
    let candidates = range.dropFirst().filter { (heights[$0] ?? 0) > 1200 + viewport * 2 && (heights[$0 - 1] ?? 0) > 900 }
    let ks = stride(from: 0, to: candidates.count, by: max(1, candidates.count / 5)).prefix(5).map { candidates[$0] }
    r.note("[安定] 試す章 k=\(ks)（k の高さ \(ks.map { Int(heights[$0] ?? 0) })、上に足す k−1 の高さ \(ks.map { Int(heights[$0 - 1] ?? 0) })）")

    func prepare(_ mode: String, _ indices: [Int], scrollInto k: Int, by offset: Double) async throws {
        _ = try await rig.call("reset()")
        _ = try await rig.call("setMode(m)", ["m": mode])
        var y = offset
        if mode == "runway" {
            _ = try await rig.call("setRunway(px)", ["px": 100_000.0])
            y += 100_000
        }
        for i in indices {
            try await rig.add(i)
            if i < k { y += heights[i] ?? 0 }
        }
        _ = try await rig.call("scrollTo(y)", ["y": y])
        try await rig.host.settle(300)
    }

    // A chapter added above the viewport.
    for (label, mode, known) in [("anchor・高さ未知", "anchor", false), ("anchor・高さ既知", "anchor", true),
                                 ("manual・高さ未知", "manual", false), ("manual・高さ既知", "manual", true),
                                 ("runway・高さ未知", "runway", false), ("runway・高さ既知", "runway", true),
                                 ("補正なし（対照）", "none", false)] {
        var outcomes: [TrialOutcome] = []
        for k in ks {
            try await prepare(mode, [k, k + 1], scrollInto: k, by: 700)
            outcomes.append(try await trial(rig, operation: "add(i, 'prepend', preset)", args: ["i": k - 1, "preset": known ? (heights[k - 1] ?? 0) : 0]))
        }
        r.note("[安定] 上に章を足す — " + line(label, outcomes))
    }

    // The same change made with an ordinary block instead of an iframe: does scroll anchoring work here at all?
    for (label, mode) in [("anchor", "anchor"), ("manual", "manual"), ("runway", "runway")] {
        var outcomes: [TrialOutcome] = []
        for k in ks.prefix(3) {
            try await prepare(mode, [k, k + 1], scrollInto: k, by: 700)
            outcomes.append(try await trial(rig, operation: "insertSpacer(500)"))
        }
        r.note("[安定] ラッパー自身の先頭に 500 px の div を足す（iframe ではない）— " + line(label, outcomes))
    }

    // A block appearing late in the chapter above (wholly above the viewport), and in the chapter being read
    // (above the viewport, inside the same iframe as the visible text).
    for (label, mode) in [("anchor", "anchor"), ("manual", "manual"), ("runway", "runway"), ("補正なし（対照）", "none")] {
        var above: [TrialOutcome] = [], inside: [TrialOutcome] = [], removed: [TrialOutcome] = [], removedAtEnd: [TrialOutcome] = []
        for k in ks.prefix(3) {
            try await prepare(mode, [k - 1, k, k + 1], scrollInto: k, by: 700)
            above.append(try await trial(rig, operation: "insertBlock(i, 300)", args: ["i": k - 1]))
            try await prepare(mode, [k - 1, k, k + 1], scrollInto: k, by: 700)
            inside.append(try await trial(rig, operation: "insertBlock(i, 300)", args: ["i": k]))
            let removal = "frames(1).then(function () { window.__cs.remove(i); return window.__cs.frames(4); })"
            try await prepare(mode, [k - 1, k, k + 1, k + 2, k + 3], scrollInto: k, by: 700)
            removed.append(try await trial(rig, operation: removal, args: ["i": k - 1]))
            // The same with nothing loaded below the chapter being read, scrolled to its last screen: the document
            // becomes shorter than the scroll position and the scroll view clamps it.
            try await prepare(mode, [k - 1, k], scrollInto: k, by: max(0, (heights[k] ?? 0) * 0.9 - viewport))
            removedAtEnd.append(try await trial(rig, operation: removal, args: ["i": k - 1]))
        }
        r.note("[安定] 上の章が後から 300 px 伸びる — " + line(label, above))
        r.note("[安定] 読んでいる章の画面より上が 300 px 伸びる — " + line(label, inside))
        r.note("[安定] 上の章を外す — " + line(label, removed))
        r.note("[安定] 上の章を外す（下に何も読み込んでいない末尾付近）— " + line(label, removedAtEnd))
    }
}
