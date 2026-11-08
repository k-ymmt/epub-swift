import Foundation
import WebKit

/// 7. Setting scrollLeft / scrollTop from JS under column layout (and scrollView.isScrollEnabled = false on iOS).
@MainActor
public func runSpike7(_ ctx: SpikeContext) async -> SpikeResult {
    var r = SpikeResult(id: 7, title: "多段組 + overflow:hidden（iOS では isScrollEnabled=false）での JS scrollLeft/scrollTop 追従")
    let pw = 300, ph = 400
    do {
        let host = WebHost(visibleSize: CGSize(width: pw, height: ph))
        #if canImport(UIKit)
        r.note("iOS: scrollView.isScrollEnabled=\(host.webView.scrollView.isScrollEnabled) bounces=\(host.webView.scrollView.bounces)")
        #else
        r.note("macOS: WKWebView に scrollView はないため isScrollEnabled の検証は iOS シミュレータのテスト（SpikeKitTests）で行う")
        #endif
        host.serve("/paged.xhtml", Fixtures.xhtmlMIME, Fixtures.pagedHorizontal(pageWidth: pw, pageHeight: ph))
        try await host.load("/paged.xhtml")
        try await host.settle(150)
        let steps: [(label: String, js: String, expectPage: Int)] = [
            ("scrollingElement.scrollLeft = 300", "document.scrollingElement.scrollLeft = 300;", 1),
            ("window.scrollTo(600, 0)", "window.scrollTo(600, 0);", 2),
            ("scrollTo({left:900, behavior:'instant'})", "window.scrollTo({ left: 900, top: 0, behavior: 'instant' });", 3),
            ("documentElement.scrollLeft = 1200", "document.documentElement.scrollLeft = 1200;", 4),
            ("scrollLeft = 99999 (末尾にクランプ)", "document.scrollingElement.scrollLeft = 99999;", 5),
            ("scrollLeft = 0 (先頭へ戻す)", "document.scrollingElement.scrollLeft = 0;", 0),
        ]
        var ok = true
        for (i, step) in steps.enumerated() {
            let m = try await host.jsDict("""
                \(step.js)
                const s = document.scrollingElement;
                return { scrollLeft: s.scrollLeft, scrollX: window.scrollX, bodyScrollLeft: document.body.scrollLeft, maxScroll: s.scrollWidth - s.clientWidth };
                """)
            try await host.settle(120)
            let snap = try await host.snapshot()
            let dom = snap.bitmap.dominantColor(in: CGRect(x: 10, y: 10, width: pw - 20, height: ph - 20))
            let exp = Fixtures.pageColors[step.expectPage].rgb
            let match = dom.near(Bitmap.RGB(r: exp.0, g: exp.1, b: exp.2))
            let readback = (m["scrollLeft"] as? Int) == step.expectPage * pw
            ok = ok && match && readback
            r.note("\(step.label): \(m) 描画主色=\(dom) 期待 page\(step.expectPage)=\(Fixtures.pageColors[step.expectPage].hex) 一致=\(match)")
            if i == 1 { try writePNG(snap.image, to: ctx.outputDirectory.appendingPathComponent("spike7-after-scrollTo-600.png")) }
        }
        // Vertical doc: scrollTop under vertical-rl columns.
        host.serve("/vertical.xhtml", Fixtures.xhtmlMIME, Fixtures.verticalJapanese(pageWidth: pw, pageHeight: ph))
        try await host.load("/vertical.xhtml")
        try await host.settle(150)
        let before = try await host.snapshot()
        let v = try await host.jsDict("""
            document.scrollingElement.scrollTop = \(ph);
            return { scrollTop: document.scrollingElement.scrollTop, scrollY: window.scrollY };
            """)
        try await host.settle(120)
        let after = try await host.snapshot()
        var changed = 0
        for y in stride(from: 0, to: before.bitmap.height, by: 4) { for x in stride(from: 0, to: before.bitmap.width, by: 4) where before.bitmap.pixel(x, y) != after.bitmap.pixel(x, y) { changed += 1 } }
        let vOK = (v["scrollTop"] as? Int) == ph && changed > 50
        r.note("縦書き scrollTop=\(ph): \(v) 描画変化ピクセル(1/16 サンプル)=\(changed) 追従=\(vOK)")
        ok = ok && vOK
        #if canImport(UIKit)
        let native = host.webView.scrollView.contentOffset
        r.note("iOS: JS スクロール後の scrollView.contentOffset=\(native)")
        #endif
        r.verdict = ok ? .pass : .fail
    } catch {
        r.error = "\(error)"; r.verdict = .fail
    }
    return r
}
