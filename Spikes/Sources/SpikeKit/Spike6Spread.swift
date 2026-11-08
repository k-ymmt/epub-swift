import Foundation
import WebKit

/// 6. Two iframes loading the same vertical document, scrolled to adjacent pages; memory recorded.
@MainActor
public func runSpike6(_ ctx: SpikeContext) async -> SpikeResult {
    var r = SpikeResult(id: 6, title: "縦書き見開き: 同一文書を 2 つの iframe に読み込み隣接ページを並べる（メモリ記録）")
    let pw = 300, ph = 400
    do {
        let existing = Set(webContentPIDs())
        let host = WebHost(visibleSize: CGSize(width: pw * 2, height: ph))
        host.rememberExistingWebContentProcesses()
        r.note("既存 WebContent プロセス数=\(existing.count)、_webProcessIdentifier 応答=\(host.webView.responds(to: Selector(("_webProcessIdentifier"))))")
        let vertical = Fixtures.verticalJapanese(pageWidth: pw, pageHeight: ph, repeatCount: 6)
        host.serve("/vertical.xhtml", Fixtures.xhtmlMIME, vertical)
        host.serve("/blank.xhtml", Fixtures.xhtmlMIME, "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>b</title></head><body></body></html>")
        host.serve("/spread.html", Fixtures.htmlMIME, Fixtures.spreadWrapper(pageWidth: pw, pageHeight: ph, src: "epub://spike/vertical.xhtml"))

        func mem(_ label: String) -> Double? {
            guard let pid = host.webContentPID else { r.note("\(label): WebContent pid 取得不可"); return nil }
            let rss = residentMemoryMB(pid: pid)
            r.note("\(label): WebContent pid=\(pid) RSS=\(rss.map { fmt($0) } ?? "?") MB")
            return rss
        }

        try await host.load("/blank.xhtml")
        try await host.settle(300)
        let m0 = mem("空文書")

        try await host.load("/vertical.xhtml")
        try await host.settle(300)
        let single = try await host.jsDict("""
            const s = document.scrollingElement; const heads = [];
            const box = document.documentElement.getBoundingClientRect(); // html is 300px wide inside this 600px viewport
            for (let i = 0; i < 4; i++) { s.scrollTop = i * \(ph); const c = document.caretRangeFromPoint(box.right - 8, 8); heads.push(c ? c.startContainer.textContent.substr(c.startOffset, 10) : null); }
            s.scrollTop = 0;
            return { pageCount: Math.ceil(s.scrollHeight / \(ph)), heads, htmlBox: JSON.stringify(box) };
            """)
        r.note("単独読み込み: \(single)")
        let m1 = mem("単独文書（1 レイアウト）")

        try await host.load("/spread.html")
        // wait for both iframes
        let clock = ContinuousClock(); let deadline = clock.now + .seconds(10)
        var ready = false
        while clock.now < deadline {
            let st = try await host.js("""
                const l = document.getElementById('left'), rt = document.getElementById('right');
                return !!(l.contentDocument && rt.contentDocument && l.contentDocument.readyState === 'complete' && rt.contentDocument.readyState === 'complete'
                          && l.contentDocument.body && l.contentDocument.body.textContent.length > 100);
                """) as? Bool ?? false
            if st { ready = true; break }
            try await host.settle(50)
        }
        guard ready else { throw SpikeError.timeout("iframes") }
        try await host.settle(300)
        let spread = try await host.jsDict("""
            const l = document.getElementById('left').contentDocument, rt = document.getElementById('right').contentDocument;
            const i = 1;
            rt.scrollingElement.scrollTop = i * \(ph);
            l.scrollingElement.scrollTop = (i + 1) * \(ph);
            const head = (d) => { const c = d.caretRangeFromPoint(\(pw) - 8, 8); return c ? c.startContainer.textContent.substr(c.startOffset, 10) : null; };
            return { sameOrigin: true, rightScrollTop: rt.scrollingElement.scrollTop, leftScrollTop: l.scrollingElement.scrollTop,
                     rightPageCount: Math.ceil(rt.scrollingElement.scrollHeight / \(ph)), leftPageCount: Math.ceil(l.scrollingElement.scrollHeight / \(ph)),
                     writingMode: getComputedStyle(rt.documentElement).writingMode, rightHead: head(rt), leftHead: head(l) };
            """)
        r.note("見開き（右=page1, 左=page2）: \(spread)")
        try await host.settle(150)
        let snap = try await host.snapshot()
        try writePNG(snap.image, to: ctx.outputDirectory.appendingPathComponent("spike6-spread.png"))
        let inkL = snap.bitmap.inkRatio(in: CGRect(x: 0, y: 0, width: pw, height: ph))
        let inkR = snap.bitmap.inkRatio(in: CGRect(x: pw, y: 0, width: pw, height: ph))
        r.note("スナップショット \(snap.bitmap.width)x\(snap.bitmap.height) インク率 左=\(fmt(inkL, 3)) 右=\(fmt(inkR, 3)) → Spikes/output/spike6-spread.png")
        let m2 = mem("ラッパー + iframe x2（2 レイアウト）")
        if let m0, let m1, let m2 {
            r.note("メモリ増分: 単独 \(fmt(m1 - m0)) MB、iframe x2 \(fmt(m2 - m0)) MB（比 \(fmt((m2 - m0) / max(0.1, m1 - m0), 2)) 倍）")
        }
        let heads = single["heads"] as? [Any] ?? []
        let headsMatch = heads.count >= 3 && (heads[1] as? String) == (spread["rightHead"] as? String) && (heads[2] as? String) == (spread["leftHead"] as? String)
        let scrolled = (spread["rightScrollTop"] as? Int) == ph && (spread["leftScrollTop"] as? Int) == ph * 2
        let sameLayout = (spread["rightPageCount"] as? Int) == (single["pageCount"] as? Int)
        r.note("判定根拠: scrollTop 反映=\(scrolled) 単独読み込みと同じページ数=\(sameLayout) ページ先頭テキスト一致=\(headsMatch) 両面に描画あり=\(inkL > 0.01 && inkR > 0.01)")
        r.verdict = (scrolled && sameLayout && headsMatch && inkL > 0.01 && inkR > 0.01) ? .pass : .fail
    } catch {
        r.error = "\(error)"; r.verdict = .fail
    }
    return r
}
