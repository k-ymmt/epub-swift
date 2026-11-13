import Foundation

/// The wrapper document and its controller for the continuous-scroll spikes (8 and 9): one web view, the main frame
/// scrolls, one same-origin `<iframe>` per chapter, each as tall as its content.
public enum ContinuousScrollJS {
    public static let wrapper = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
        <style>
        html, body { margin: 0; padding: 0; background: #fff; }
        html { scrollbar-width: none; }
        ::-webkit-scrollbar { display: none; }
        #stage { display: block; }
        #runway { display: block; height: 0; }
        iframe { display: block; width: 100%; border: 0; margin: 0; padding: 0; }
        html.no-anchor, html.no-anchor body, html.no-anchor #runway, html.no-anchor #stage, html.no-anchor iframe { overflow-anchor: none; }
        </style></head><body><div id="runway"></div><div id="stage"></div></body></html>
        """

    /// `window.__cs` in the reader world of the wrapper's main frame.
    ///
    /// Modes: `anchor` leaves the position to WebKit's scroll anchoring; `manual` turns anchoring off and corrects the
    /// scroll position itself, by the distance an element near the top of the viewport moved (the same rule for a
    /// chapter added above, a late resize and a removed chapter); `runway` also turns anchoring off and keeps an
    /// empty block (the runway) above the first chapter, as tall as what is not loaded above: it takes the same
    /// distance out of the runway's height instead, so the text stays put without the scroll position changing at
    /// all (it scrolls only when the runway is used up); `none` does neither (the control).
    public static let controller = #"""
        (function () {
          const stage = document.getElementById("stage");
          if (!stage) { return; }
          const runway = document.getElementById("runway");
          const S = { urls: [], mode: "anchor", views: [], log: [], anchor: null, anchorDoc: 0, probe: null, auto: null, pad: 0 };
          function logEv(o) { o.t = Date.now(); o.scrollY = window.scrollY; S.log.push(o); }
          function frames(n) {
            return new Promise(function (resolve) {
              (function step(k) { if (k <= 0) { resolve(); } else { requestAnimationFrame(function () { step(k - 1); }); } })(n);
            });
          }
          function corrects() { return S.mode === "manual" || S.mode === "runway"; }
          function setMode(mode) {
            S.mode = mode;
            document.documentElement.classList.toggle("no-anchor", mode !== "anchor");
          }
          function contentHeight(el) {
            const d = el.contentDocument;
            if (!d || !d.documentElement) { return 0; }
            return Math.ceil(d.documentElement.getBoundingClientRect().height);
          }

          // --- an element near the top of the viewport, and where it is ---
          function findAnchor() {
            const x = Math.min(window.innerWidth / 2, 200);
            const ys = [4, 24, 60, 120, 200, 320];
            for (let i = 0; i < ys.length; i++) {
              const frame = document.elementFromPoint(x, ys[i]);
              if (!frame || frame.tagName !== "IFRAME" || !frame.contentDocument) { continue; }
              const r = frame.getBoundingClientRect();
              const doc = frame.contentDocument;
              const e = doc.elementFromPoint(x - r.left, ys[i] - r.top);
              if (!e || e === doc.documentElement || e === doc.body) { continue; }
              if (e.getBoundingClientRect().height > 2 * window.innerHeight) { continue; }   // a container, not a line of text
              return { frame: frame, el: e };
            }
            return null;
          }
          function position(a) {
            if (!a || !a.frame.isConnected || !a.el.isConnected) { return null; }
            return a.frame.getBoundingClientRect().top + a.el.getBoundingClientRect().top;
          }
          // The anchor is remembered by its place in the document (viewport position + scrollY), not in the viewport.
          // During a touch or momentum scroll on iOS the scroll position belongs to the UI process: a position it sent
          // before it received a `scrollBy` overwrites the page's own, so for a moment the page sees its correction
          // undone. A rule that compares viewport positions then corrects a second time (measured: a 26,559 px jump
          // where -2,528 px was due). The place in the document does not depend on the scroll position at all.
          function documentPosition(a) {
            const y = position(a);
            return y === null ? null : y + window.scrollY;
          }
          function refreshAnchor() {
            const y = position(S.anchor);
            if (y === null || y < -0.5 * window.innerHeight || y > window.innerHeight) { S.anchor = findAnchor(); }
            S.anchorDoc = documentPosition(S.anchor) || 0;
          }
          // Manual mode: scroll by as much as the layout moved the anchor element.
          // Runway mode: take it out of the runway instead (a change of layout only: the scroll position, which the
          // UI process owns while a finger or its momentum scrolls, is not written), and scroll by what the runway
          // could not give.
          function correct(reason) {
            if (S.mode !== "manual" && S.mode !== "runway") { return 0; }
            const y = documentPosition(S.anchor);
            if (y === null) { refreshAnchor(); return 0; }
            const d = y - S.anchorDoc;
            if (Math.abs(d) < 0.5) { return 0; }
            let rest = d;
            if (S.mode === "runway") {
              const pad = Math.max(0, S.pad - d);
              const taken = S.pad - pad;
              S.pad = pad;
              runway.style.height = pad + "px";
              rest = d - taken;
              logEv({ ev: "shift", reason: reason, by: taken, runway: pad });
            }
            if (Math.abs(rest) >= 0.5) {
              window.scrollBy(0, rest);
              logEv({ ev: "correct", reason: reason, by: rest });
            }
            S.anchorDoc = y - (d - rest);
            return d;
          }
          // The runway's height, set while nothing scrolls: the scroll position moves with it.
          function setRunway(px) {
            const d = px - S.pad;
            S.pad = px;
            runway.style.height = px + "px";
            if (d !== 0) { window.scrollBy(0, d); }
            S.anchor = null;
            return frames(3).then(function () { if (S.mode !== "anchor" && S.mode !== "none") { refreshAnchor(); } return window.scrollY; });
          }

          function setHeight(v, h, reason) {
            const old = v.height;
            if (h === old) { return; }
            v.el.style.height = h + "px";
            v.height = h;
            logEv({ ev: "height", index: v.index, old: old, h: h, reason: reason });
            correct(reason);
          }

          function add(index, where, preset) {
            return new Promise(function (resolve) {
              if (corrects() && !S.anchor) { refreshAnchor(); }
              const el = document.createElement("iframe");
              el.setAttribute("scrolling", "no");
              el.style.height = "0px";
              const v = { index: index, el: el, height: 0, ro: null, loaded: false };
              const t0 = performance.now();
              el.addEventListener("load", function () {
                const t1 = performance.now();
                const h = contentHeight(el);
                const t2 = performance.now();
                v.loaded = true;
                setHeight(v, h, "load");
                try {
                  v.ro = new ResizeObserver(function () {
                    const nh = contentHeight(el);
                    if (nh !== v.height) { setHeight(v, nh, "resize"); }
                  });
                  v.ro.observe(el.contentDocument.documentElement);
                } catch (e) {}
                logEv({ ev: "loaded", index: index, where: where, loadMs: t1 - t0, measureMs: t2 - t1, h: h, preset: preset || 0 });
                resolve({ index: index, loadMs: t1 - t0, measureMs: t2 - t1, height: h });
              }, { once: true });
              logEv({ ev: "add", index: index, where: where, preset: preset || 0 });
              // The source is set before the frame joins the document: a frame inserted without one loads
              // about:blank first and fires `load` for it.
              el.src = S.urls[index];
              if (where === "prepend") { stage.insertBefore(el, stage.firstChild); S.views.unshift(v); }
              else { stage.appendChild(el); S.views.push(v); }
              if (preset > 0) { setHeight(v, preset, "preset"); }
            });
          }

          function remove(index) {
            const i = S.views.findIndex(function (v) { return v.index === index; });
            if (i < 0) { return false; }
            const v = S.views[i];
            if (v.ro) { v.ro.disconnect(); }
            // Runway mode, a chapter above the text being read: the runway grows by the chapter's height in the same
            // layout in which the chapter leaves. Growing it afterwards (in `correct`) is too late at the end of the
            // document: the layout in between makes the document shorter than the scroll position, the scroll
            // position is clamped, and the correction then moves the text a second time.
            const at = S.views.findIndex(function (x) { return S.anchor && x.el === S.anchor.frame; });
            if (S.mode === "runway" && at >= 0 && i < at) {
              S.pad += v.height;
              runway.style.height = S.pad + "px";
              logEv({ ev: "shift", reason: "remove", by: -v.height, runway: S.pad });
            }
            v.el.remove();
            S.views.splice(i, 1);
            logEv({ ev: "remove", index: index, h: v.height });
            correct("remove");
            return true;
          }

          // Height of a chapter measured off stage (what a background measuring pass would know beforehand).
          function measureOnly(index) {
            return new Promise(function (resolve) {
              const el = document.createElement("iframe");
              el.setAttribute("scrolling", "no");
              el.style.cssText = "position:absolute;left:0;top:0;width:100%;height:0;visibility:hidden;";
              // After the fonts. `load` does not wait for a web font that only the first layout asks for, and
              // `fonts.ready` is still resolved right after that layout: two frames later the font is on its way and
              // `fonts.ready` waits for it. Measured at `load` alone, the longest chapter of the fixture is 28,974 px;
              // with the book's font it is 26,446 px.
              el.addEventListener("load", function () {
                contentHeight(el);
                frames(2).then(function () {
                  const fonts = el.contentDocument.fonts;
                  return fonts && fonts.ready ? fonts.ready : null;
                }).then(function () { return frames(1); }).then(function () {
                  const h = contentHeight(el); el.remove(); resolve(h);
                });
              }, { once: true });
              el.src = S.urls[index];
              document.body.appendChild(el);
            });
          }

          // A block appearing late at the top of a chapter (an image that finished loading, a font swap).
          function insertBlock(index, px) {
            const v = S.views.find(function (x) { return x.index === index; });
            if (!v || !v.el.contentDocument) { return Promise.resolve(false); }
            const doc = v.el.contentDocument;
            const div = doc.createElementNS("http://www.w3.org/1999/xhtml", "div");
            div.setAttribute("style", "height:" + px + "px;background:#cde;");
            doc.body.insertBefore(div, doc.body.firstChild);
            logEv({ ev: "insertBlock", index: index, px: px });
            return frames(4).then(function () { return true; });
          }

          // A plain block added to the wrapper itself, above every chapter: tells scroll anchoring on ordinary
          // content apart from scroll anchoring on iframes.
          function insertSpacer(px) {
            const div = document.createElement("div");
            div.className = "spacer";
            div.style.cssText = "height:" + px + "px;background:#edc;";
            document.body.insertBefore(div, stage);
            logEv({ ev: "insertSpacer", px: px });
            correct("spacer");
            return frames(4).then(function () { return true; });
          }

          function reset() {
            document.querySelectorAll(".spacer").forEach(function (e) { e.remove(); });
            S.views.forEach(function (v) { if (v.ro) { v.ro.disconnect(); } v.el.remove(); });
            S.views = []; S.log = []; S.anchor = null; S.anchorDoc = 0; S.probe = null;
            S.pad = 0; runway.style.height = "0px";
            window.scrollTo(0, 0);
          }

          // --- measuring where the text is ---
          function mark() { S.probe = findAnchor(); return position(S.probe); }
          function probe() { return { y: position(S.probe), scrollY: window.scrollY, docHeight: document.documentElement.scrollHeight }; }
          function sampleFrames(ms) {
            return new Promise(function (resolve) {
              const t0 = performance.now(); const ys = [];
              (function step() {
                const y = position(S.probe);
                if (y !== null) { ys.push(y); }
                if (performance.now() - t0 >= ms) {
                  resolve({ n: ys.length, min: Math.min.apply(null, ys), max: Math.max.apply(null, ys) });
                } else { requestAnimationFrame(step); }
              })();
            });
          }

          // --- a sliding window of chapters that follows the scroll position (spike 9) ---
          function autoWindow(opts) {
            let busy = false;
            function check() {
              if (corrects()) { refreshAnchor(); }
              if (busy || S.views.length === 0) { return; }
              const first = S.views[0], last = S.views[S.views.length - 1];
              const above = -first.el.getBoundingClientRect().top;
              const below = last.el.getBoundingClientRect().bottom - window.innerHeight;
              let p = null;
              if (above < opts.margin && first.index > 0) {
                const preset = opts.heights ? (opts.heights[String(first.index - 1)] || 0) : 0;
                p = add(first.index - 1, "prepend", preset);
              } else if (below < opts.margin && last.index < S.urls.length - 1) {
                p = add(last.index + 1, "append", 0);
              }
              if (p) { busy = true; p.then(function () { busy = false; check(); }); }
            }
            window.addEventListener("scroll", check, { passive: true });
            check();
          }

          window.__cs = {
            configure: function (urls, mode) { S.urls = urls; setMode(mode || "anchor"); return S.urls.length; },
            setMode: setMode, add: add, remove: remove, measureOnly: measureOnly, insertBlock: insertBlock, insertSpacer: insertSpacer, reset: reset,
            mark: mark, probe: probe, sampleFrames: sampleFrames, frames: frames, autoWindow: autoWindow,
            refreshAnchor: refreshAnchor,
            setRunway: setRunway,
            scrollTo: function (y) { window.scrollTo(0, y); if (corrects()) { S.anchor = null; refreshAnchor(); } return frames(3).then(function () { if (corrects()) { S.anchor = null; refreshAnchor(); } return window.scrollY; }); },
            state: function () {
              return { mode: S.mode, runway: S.pad, scrollY: window.scrollY, docHeight: document.documentElement.scrollHeight,
                       innerHeight: window.innerHeight, innerWidth: window.innerWidth,
                       views: S.views.map(function (v) { return { index: v.index, height: v.height, loaded: v.loaded }; }) };
            },
            log: function () { return S.log; },
            supportsAnchor: function () { return CSS.supports("overflow-anchor", "auto"); },
          };
        })();
        """#
}
