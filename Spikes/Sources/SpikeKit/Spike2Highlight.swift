import Foundation
import WebKit

/// 2. CSS Custom Highlight API (CSS.highlights / ::highlight()).
@MainActor
public func runSpike2(_ ctx: SpikeContext) async -> SpikeResult {
    var r = SpikeResult(id: 2, title: "CSS Custom Highlight API")
    do {
        let host = WebHost(visibleSize: CGSize(width: 400, height: 200))
        host.serve("/hl.xhtml", Fixtures.xhtmlMIME, Fixtures.highlightXHTML)
        try await host.load("/hl.xhtml")
        let info = try await host.jsDict("""
            const support = { highlights: typeof CSS.highlights, Highlight: typeof Highlight,
                              supportsSelector: CSS.supports("selector(::highlight(x))") };
            const p = document.getElementById("t");
            const range = new Range();
            range.setStart(p.firstChild, 6); range.setEnd(p.firstChild, 17); // "highlighted"
            const h = new Highlight(range);
            CSS.highlights.set("spike", h);
            const st = document.createElement("style");
            st.textContent = "::highlight(spike) { background-color: #ffff00; color: #ff0000; }";
            document.head.appendChild(st);
            const b = range.getBoundingClientRect();
            return { ...support, size: CSS.highlights.size, rect: { x: b.x, y: b.y, w: b.width, h: b.height },
                     text: range.toString() };
            """)
        r.note("API: \(info)")
        try await host.settle(150)
        let snap = try await host.snapshot()
        try writePNG(snap.image, to: ctx.outputDirectory.appendingPathComponent("spike2-highlight.png"))
        let rect = info["rect"] as? [String: Any] ?? [:]
        let rr = CGRect(x: rect["x"] as? Double ?? 0, y: rect["y"] as? Double ?? 0,
                        width: rect["w"] as? Double ?? 0, height: rect["h"] as? Double ?? 0)
        // Tolerant thresholds: the iOS snapshot is a view-hierarchy capture and comes back slightly blurred.
        let isYellow: (Bitmap.RGB) -> Bool = { $0.r > 200 && $0.g > 170 && $0.b < 120 }
        let isRed: (Bitmap.RGB) -> Bool = { $0.r > 190 && $0.g < 130 && $0.b < 130 }
        let yIn = snap.bitmap.count(where: isYellow, in: rr)
        let rIn = snap.bitmap.count(where: isRed, in: rr)
        let yAll = snap.bitmap.count(where: isYellow)
        r.note("range rect=\(rr) 内の黄色ピクセル=\(yIn) 赤ピクセル=\(rIn)、画像全体の黄色=\(yAll)（範囲外=\(yAll - yIn)）")
        let area = Int(rr.width * rr.height * snap.scale * snap.scale)
        r.note("画像 \(snap.bitmap.width)x\(snap.bitmap.height)px (\(snap.scale)x)、rect のピクセル面積=\(area)")
        let ok = (info["highlights"] as? String) == "object" && yIn > area / 4 && rIn > 0 && yAll - yIn <= Int(rr.height * snap.scale) * 2
        r.verdict = ok ? .pass : .fail
        r.note("スクリーンショット: Spikes/output/spike2-highlight.png")
    } catch {
        r.error = "\(error)"; r.verdict = .fail
    }
    return r
}
