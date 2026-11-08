import Foundation
import WebKit

/// 3. Three-page-wide WKWebView clipped by its superview; takeSnapshot(with:) with rect for the pages outside the clip.
@MainActor
public func runSpike3(_ ctx: SpikeContext) async -> SpikeResult {
    var r = SpikeResult(id: 3, title: "3 ページ幅フレームと takeSnapshot(with:) の rect 指定")
    let pw = 300, ph = 400
    do {
        let host = WebHost(
            visibleSize: CGSize(width: pw, height: ph),
            webViewFrame: CGRect(x: -pw, y: 0, width: pw * 3, height: ph)
        )
        host.serve("/paged.xhtml", Fixtures.xhtmlMIME, Fixtures.pagedHorizontal(pageWidth: pw, pageHeight: ph))
        try await host.load("/paged.xhtml")
        let m = try await host.jsDict("""
            const d = document.documentElement;
            return { innerWidth: innerWidth, clientWidth: d.clientWidth, scrollWidth: d.scrollWidth,
                     htmlWidth: d.getBoundingClientRect().width, pages: Math.ceil(d.scrollWidth / \(pw)) };
            """)
        r.note("3 ページ幅ビューポートでの計測: \(m)")
        // Show pages 1,2,3 in the viewport (page 2 in the clip).
        try await host.js("document.scrollingElement.scrollLeft = \(pw); return document.scrollingElement.scrollLeft")
        try await host.settle(150)
        var ok = true
        var timings: [Double] = []
        for (slot, expectPage) in [(0, 1), (1, 2), (2, 3)] {
            let rect = CGRect(x: slot * pw, y: 0, width: pw, height: ph)
            let snap = try await host.snapshot(rect: rect)
            timings.append(Double(snap.elapsed.components.attoseconds) / 1e15 + Double(snap.elapsed.components.seconds) * 1000)
            let dom = snap.bitmap.dominantColor(in: CGRect(x: 10, y: 10, width: pw - 20, height: ph - 20))
            let exp = Fixtures.pageColors[expectPage].rgb
            let match = dom.near(Bitmap.RGB(r: exp.0, g: exp.1, b: exp.2))
            ok = ok && match && Int(Double(snap.bitmap.width) / snap.scale) == pw
            let where_ = slot == 1 ? "クリップ内（可視）" : "クリップ外（不可視）"
            r.note("rect=\(rect) \(where_): 画像 \(snap.bitmap.width)x\(snap.bitmap.height)px (\(snap.scale)x) 主色=\(dom) 期待=page\(expectPage)(\(Fixtures.pageColors[expectPage].hex)) 一致=\(match)")
            try writePNG(snap.image, to: ctx.outputDirectory.appendingPathComponent("spike3-slot\(slot)-page\(expectPage).png"))
        }
        // whole-frame snapshot for the record
        let whole = try await host.snapshot()
        try writePNG(whole.image, to: ctx.outputDirectory.appendingPathComponent("spike3-whole-frame.png"))
        r.note("フレーム全体のスナップショット: \(whole.bitmap.width)x\(whole.bitmap.height) → Spikes/output/spike3-whole-frame.png")
        // timing over repeated snapshots of the off-clip page
        var times: [Double] = []
        for _ in 0..<10 {
            let s = try await host.snapshot(rect: CGRect(x: 2 * pw, y: 0, width: pw, height: ph))
            times.append(Double(s.elapsed.components.seconds) * 1000 + Double(s.elapsed.components.attoseconds) / 1e15)
        }
        times.sort()
        r.note("クリップ外ページの takeSnapshot 所要時間 (ms, 10 回): min=\(fmt(times.first!)) median=\(fmt(times[times.count/2])) max=\(fmt(times.last!))（初回 3 回: \(timings.map { fmt($0) }))")
        // 2x scale cost
        let s2 = try await host.snapshot(rect: CGRect(x: 2 * pw, y: 0, width: pw, height: ph), scale: 2)
        r.note("2x スナップショット: \(s2.bitmap.width)x\(s2.bitmap.height) 所要=\(fmt(Double(s2.elapsed.components.seconds) * 1000 + Double(s2.elapsed.components.attoseconds) / 1e15)) ms")
        // Short document (2 pages) in the 3-page-wide viewport: scrollWidth cannot go below the viewport width.
        let short = Fixtures.pagedHorizontal(pageWidth: pw, pageHeight: ph).replacingOccurrences(of: "</body>", with: "<span id=\"__end\"></span></body>")
        var two = ""
        var kept = 0
        for line in short.components(separatedBy: "\n") {
            if line.contains("class=\"pg\"") { kept += 1; if kept > 2 { continue } }
            two += line + "\n"
        }
        host.serve("/two.xhtml", Fixtures.xhtmlMIME, two)
        try await host.load("/two.xhtml")
        let m2 = try await host.jsDict("""
            const s = document.scrollingElement; const end = document.getElementById("__end").getBoundingClientRect();
            return { scrollWidth: s.scrollWidth, clientWidth: s.clientWidth, pagesByScrollWidth: Math.ceil(s.scrollWidth / \(pw)),
                     endRight: end.right + s.scrollLeft, pagesBySentinel: Math.ceil((end.right + s.scrollLeft) / \(pw)) };
            """)
        r.note("2 ページ文書を 3 ページ幅ビューポートで: \(m2) → scrollWidth ベースの pageCount はビューポート幅で下限が付く")
        if (m2["pagesByScrollWidth"] as? Int) != 2 { r.verdict = .conditional } else { r.verdict = ok ? .pass : .fail }
        if !ok { r.verdict = .fail }
    } catch {
        r.error = "\(error)"; r.verdict = .fail
    }
    return r
}
