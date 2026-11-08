import Foundation
import WebKit

/// 4. writing-mode: vertical-rl + column-width: columns stack vertically; page count from scrollHeight.
@MainActor
public func runSpike4(_ ctx: SpikeContext) async -> SpikeResult {
    var r = SpikeResult(id: 4, title: "縦書き多段組（vertical-rl + column-width）と scrollHeight からのページ数")
    let pw = 300, ph = 400
    do {
        let host = WebHost(visibleSize: CGSize(width: pw, height: ph))
        host.serve("/vertical.xhtml", Fixtures.xhtmlMIME, Fixtures.verticalJapanese(pageWidth: pw, pageHeight: ph))
        try await host.load("/vertical.xhtml")
        try await host.settle(200)
        let m = try await host.jsDict("""
            const d = document.documentElement; const s = document.scrollingElement;
            const chars = document.body.textContent.replace(/\\s+/g, "").length;
            return { writingMode: getComputedStyle(d).writingMode, scrollHeight: s.scrollHeight, scrollWidth: s.scrollWidth,
                     clientHeight: s.clientHeight, clientWidth: s.clientWidth,
                     pageCount: Math.ceil(s.scrollHeight / \(ph)), remainder: s.scrollHeight % \(ph), chars: chars,
                     bodyRect: JSON.stringify(document.body.getBoundingClientRect()) };
            """)
        r.note("計測: \(m)")
        let pageCount = m["pageCount"] as? Int ?? 0
        let remainder = m["remainder"] as? Int ?? -1
        let scrollWidth = m["scrollWidth"] as? Int ?? 0
        // Visual check of the first pages and the last page.
        var inks: [Double] = []
        for i in [0, 1, 2, max(0, pageCount - 1)] {
            try await host.js("document.scrollingElement.scrollTop = \(i * ph); return document.scrollingElement.scrollTop")
            try await host.settle(120)
            let snap = try await host.snapshot()
            inks.append(snap.bitmap.inkRatio())
            try writePNG(snap.image, to: ctx.outputDirectory.appendingPathComponent("spike4-page\(i).png"))
        }
        r.note("ページ 0,1,2,last のインク率（非白ピクセル比）: \(inks.map { fmt($0, 3) })")
        // Find the first text position at each page top to verify lines are not split across pages:
        // the top-right point of each page should start a new line (caretRangeFromPoint offset at line start or column start).
        let cfiProbe = try await host.jsDict("""
            const out = [];
            for (let i = 0; i < Math.min(\(pageCount), 4); i++) {
              document.scrollingElement.scrollTop = i * \(ph);
              const rng = document.caretRangeFromPoint(\(pw) - 8, 8);
              out.push(rng ? (rng.startContainer.textContent.substr(rng.startOffset, 12)) : null);
            }
            document.scrollingElement.scrollTop = 0;
            return { heads: out };
            """)
        r.note("各ページ右上のテキスト先頭 12 文字: \(cfiProbe["heads"] ?? [])")
        // Three-page-tall frame variant (as the design plans for vertical writing).
        let host3 = WebHost(visibleSize: CGSize(width: pw, height: ph), webViewFrame: CGRect(x: 0, y: -ph, width: pw, height: ph * 3))
        host3.serve("/vertical.xhtml", Fixtures.xhtmlMIME, Fixtures.verticalJapanese(pageWidth: pw, pageHeight: ph))
        try await host3.load("/vertical.xhtml")
        try await host3.settle(200)
        let m3 = try await host3.jsDict("""
            const s = document.scrollingElement;
            return { scrollHeight: s.scrollHeight, clientHeight: s.clientHeight, pageCount: Math.ceil(s.scrollHeight / \(ph)),
                     htmlBox: JSON.stringify(document.documentElement.getBoundingClientRect()) };
            """)
        r.note("3 ページ高フレーム（\(pw)x\(ph*3)）での計測: \(m3)")
        let snap3 = try await host3.snapshot()
        try writePNG(snap3.image, to: ctx.outputDirectory.appendingPathComponent("spike4-three-page-frame.png"))
        let vertical = (m["writingMode"] as? String) == "vertical-rl"
        let stacked = remainder == 0 && pageCount >= 3 && scrollWidth == pw
        r.verdict = (vertical && stacked) ? .pass : .fail
        r.note("判定根拠: writingMode=\(m["writingMode"] ?? "?") scrollHeight が \(ph) の倍数=\(remainder == 0) 横方向のあふれなし=\(scrollWidth == pw) pageCount=\(pageCount)")
    } catch {
        r.error = "\(error)"; r.verdict = .fail
    }
    return r
}
