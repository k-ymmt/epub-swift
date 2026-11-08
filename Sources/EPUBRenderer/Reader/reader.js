// EPUB-Swift reader.js
// The only script that runs in a content document. Injected as a WKUserScript at document end in the
// dedicated `reader` WKContentWorld; content JavaScript is disabled (docs/design/02-rendering.md §4).
//
// Swift -> JS: window.__epubReader.{layout, goToPage, captureAnchor, pageForAnchor, pageForFragment, applySettings}
// JS -> Swift: webkit.messageHandlers.reader.postMessage({type, payload})
//   ready {writingMode}             after `load` and `document.fonts.ready`
//   pageCountChanged {pageCount}    when late image loads change the layout
//   link {href, isExternal}         click on <a>; the default is prevented, Swift decides navigation
//   tap {x, y}                      click/tap on anything that is not a link (viewport coordinates)
(function () {
  "use strict";
  if (window.__epubReader) { return; }

  const SENTINEL_ID = "__reader_end";
  const state = {
    pageWidth: 0,
    pageHeight: 0,
    pageCount: 1,
    writingMode: "horizontal-tb",
    anchor: null,
    readySent: false,
  };

  function root() { return document.documentElement; }
  function scroller() { return document.scrollingElement || document.documentElement; }
  function setVar(name, value) { root().style.setProperty(name, value); }

  function post(type, payload) {
    try {
      return window.webkit.messageHandlers.reader.postMessage({ type: type, payload: payload || {} });
    } catch (e) {
      return Promise.reject(e);
    }
  }

  function ensureSentinel() {
    let s = document.getElementById(SENTINEL_ID);
    if (!s && document.body) {
      s = document.createElement("span");
      s.id = SENTINEL_ID;
      s.setAttribute("aria-hidden", "true");
      document.body.appendChild(s);
    }
    return s;
  }

  // writing-mode is not forced. If the publisher put it on body only, promote it to html so the
  // column axis follows (02-rendering §3.4).
  function detectWritingMode() {
    let wm = getComputedStyle(root()).writingMode || "horizontal-tb";
    if (wm === "horizontal-tb" && document.body) {
      const bodyWM = getComputedStyle(document.body).writingMode;
      if (bodyWM && bodyWM !== "horizontal-tb") {
        root().style.writingMode = bodyWM;
        wm = bodyWM;
      }
    }
    return wm;
  }

  function isVertical() { return state.writingMode.indexOf("vertical") === 0; }

  // Page count from the end sentinel's document position (not scrollWidth: in the 3-page-wide frame
  // scrollWidth never goes below the viewport width; 05-spike-results §2.3).
  function computePageCount() {
    if (!state.pageWidth || !state.pageHeight) { return 1; }
    const s = ensureSentinel();
    if (!s) { return 1; }
    const r = s.getBoundingClientRect();
    const sc = scroller();
    if (isVertical()) {
      const endY = r.top + sc.scrollTop;
      return Math.max(1, Math.floor(endY / state.pageHeight) + 1);
    }
    const endX = r.left + sc.scrollLeft;
    return Math.max(1, Math.floor(endX / state.pageWidth) + 1);
  }

  function applyParams(p) {
    if (!p) { return; }
    if (p.pageWidth) { state.pageWidth = p.pageWidth; setVar("--reader-page-width", p.pageWidth + "px"); }
    if (p.pageHeight) { state.pageHeight = p.pageHeight; setVar("--reader-page-height", p.pageHeight + "px"); }
    if (p.margins) {
      setVar("--reader-margin-h", p.margins.horizontal + "px");
      setVar("--reader-margin-v", p.margins.vertical + "px");
    }
    if (p.fontScale !== undefined && p.fontScale !== null) { setVar("--reader-font-size", String(p.fontScale)); }
    if (p.lineHeight !== undefined && p.lineHeight !== null) { setVar("--reader-line-height", String(p.lineHeight)); }
    if (p.theme) {
      setVar("--reader-fg", p.theme.foreground);
      setVar("--reader-bg", p.theme.background);
      setVar("--reader-link", p.theme.link);
      root().setAttribute("data-reader-theme", p.theme.isDark ? "dark" : "light");
    }
    if (p.fontFamily !== undefined) {
      if (p.fontFamily) {
        setVar("--reader-font-family", p.fontFamily);
        root().setAttribute("data-reader-font", "override");
      } else {
        root().style.removeProperty("--reader-font-family");
        root().removeAttribute("data-reader-font");
      }
    }
    if (typeof p.rootStyle === "string") {
      // The settings <style> injected at load time carries first-paint overrides (font-family !important,
      // @font-face for custom fonts). Replace it so that a later change can undo or extend them.
      let el = document.getElementById("__reader_settings");
      if (!el) {
        el = document.createElement("style");
        el.id = "__reader_settings";
        (document.head || root()).appendChild(el);
      }
      el.textContent = p.rootStyle;
    }
  }

  // Apply layout parameters and measure. Returns {pageCount, writingMode}.
  function layout(params) {
    applyParams(params);
    state.writingMode = detectWritingMode();
    ensureSentinel();
    void root().offsetWidth; // flush layout
    state.pageCount = computePageCount();
    return { pageCount: state.pageCount, writingMode: state.writingMode };
  }

  // Scroll so that page `index` is visible. The frame may be wider than one page (three slots, the
  // middle one visible). The desired scroll position keeps the page in the middle slot when possible;
  // at the ends the scroll position is clamped and the page ends up in another slot. The returned
  // `slot` tells Swift where the page is so it can offset the web view (02-rendering §1.2).
  function goToPage(index) {
    // Re-measure first: late image/font loads may have changed the page count since the last call.
    state.pageCount = computePageCount();
    const i = Math.max(0, Math.min(Math.floor(index), state.pageCount - 1));
    const sc = scroller();
    const pageSize = isVertical() ? state.pageHeight : state.pageWidth;
    const clientSize = isVertical() ? sc.clientHeight : sc.clientWidth;
    const slots = pageSize > 0 ? Math.max(1, Math.round(clientSize / pageSize)) : 1;
    const middle = Math.floor(slots / 2);
    const desired = Math.max(0, (i - middle) * pageSize);
    if (isVertical()) {
      sc.scrollTop = desired;
      // scrollTop is also clamped to the document end; the slot is derived from the actual value.
      const slot = i - Math.round(sc.scrollTop / pageSize);
      return { pageIndex: i, slot: slot, pageCount: state.pageCount, scrollLeft: sc.scrollLeft, scrollTop: sc.scrollTop };
    }
    sc.scrollLeft = desired;
    const slot = i - Math.round(sc.scrollLeft / pageSize);
    // scrollLeft/scrollTop are returned so that the native scroll view can be kept in step on iOS, where
    // scroll requests are applied asynchronously by the UI process and may be clamped against a stale content size.
    return { pageIndex: i, slot: slot, pageCount: state.pageCount, scrollLeft: sc.scrollLeft, scrollTop: sc.scrollTop };
  }

  function pageForDocumentX(x) {
    if (!state.pageWidth) { return 0; }
    return Math.max(0, Math.min(state.pageCount - 1, Math.floor((x + 0.5) / state.pageWidth)));
  }
  function pageForDocumentY(y) {
    if (!state.pageHeight) { return 0; }
    return Math.max(0, Math.min(state.pageCount - 1, Math.floor((y + 0.5) / state.pageHeight)));
  }
  function pageForRect(rect) {
    const sc = scroller();
    if (isVertical()) { return pageForDocumentY(rect.top + sc.scrollTop); }
    return pageForDocumentX(rect.left + sc.scrollLeft);
  }

  // Remember what is at the top of the page currently in `slot`, so that the same text can be found
  // again after a relayout (settings change, resize). The anchor is a DOM Range held in this world;
  // it is not a position format and never leaves the page.
  function captureAnchor(slot, margins) {
    state.anchor = null;
    if (!state.pageWidth || !state.pageHeight) { return false; }
    const mh = (margins && margins.horizontal) || 0;
    const mv = (margins && margins.vertical) || 0;
    const originX = (slot || 0) * state.pageWidth;
    const xs = [mh + 2, mh + state.pageWidth / 4, mh + state.pageWidth / 2];
    const ys = [mv + 2, mv + 16, mv + 48, mv + 96, mv + state.pageHeight / 3, mv + state.pageHeight / 2, state.pageHeight - mv - 8];
    let fallbackElement = null;
    for (const y of ys) {
      for (const x of xs) {
        const cx = originX + x;
        const cy = y;
        const range = document.caretRangeFromPoint ? document.caretRangeFromPoint(cx, cy) : null;
        if (range && range.startContainer && range.startContainer.nodeType === Node.TEXT_NODE) {
          const text = range.startContainer.data || "";
          if (text.trim().length > 0) {
            state.anchor = { kind: "range", node: range.startContainer, offset: range.startOffset };
            return true;
          }
        }
        if (!fallbackElement) {
          const el = document.elementFromPoint(cx, cy);
          if (el && el !== document.body && el !== root() && el.id !== SENTINEL_ID) { fallbackElement = el; }
        }
      }
    }
    // No text at the probe points (e.g. a page with only an image or a short last page): take the first text node
    // that has a box inside the page. Walking the text nodes is slower but only happens on relayout.
    const inPage = firstTextInPage(originX);
    if (inPage) {
      state.anchor = inPage;
      return true;
    }
    // Last resort: an element, but only one that fits in a page. A container that spans many columns
    // (a chapter <div>) would restore to the page where it starts, far from the current page.
    if (fallbackElement) {
      let el = fallbackElement;
      while (el && el !== document.body && el !== root()) {
        const r = el.getBoundingClientRect();
        if (r.width <= state.pageWidth + 1 && r.height <= state.pageHeight + 1) {
          state.anchor = { kind: "element", node: el };
          return true;
        }
        el = el.parentElement;
      }
    }
    return false;
  }

  function firstTextInPage(originX) {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const r = document.createRange();
    const right = originX + state.pageWidth;
    let node;
    while ((node = walker.nextNode())) {
      if (!node.data || node.data.trim().length === 0) { continue; }
      r.selectNodeContents(node);
      const rects = r.getClientRects();
      for (let k = 0; k < rects.length; k++) {
        const rect = rects[k];
        if (rect.width <= 0 || rect.height <= 0) { continue; }
        if (rect.right <= originX || rect.left >= right || rect.bottom <= 0 || rect.top >= state.pageHeight) { continue; }
        const caret = document.caretRangeFromPoint ? document.caretRangeFromPoint(Math.max(rect.left, originX) + 1, rect.top + rect.height / 2) : null;
        if (caret && caret.startContainer === node) {
          return { kind: "range", node: node, offset: caret.startOffset };
        }
        return { kind: "range", node: node, offset: 0 };
      }
    }
    return null;
  }

  // Page index that now contains the captured anchor, or null when there is none.
  function pageForAnchor() {
    const a = state.anchor;
    if (!a || !a.node || !a.node.isConnected) { return null; }
    let rect = null;
    if (a.kind === "range") {
      const r = document.createRange();
      const len = (a.node.data || "").length;
      const off = Math.min(a.offset, len);
      r.setStart(a.node, off);
      r.setEnd(a.node, Math.min(len, off + 1));
      const rects = r.getClientRects();
      rect = rects.length > 0 ? rects[0] : r.getBoundingClientRect();
    } else {
      rect = a.node.getBoundingClientRect();
    }
    if (!rect || (rect.width === 0 && rect.height === 0 && rect.left === 0 && rect.top === 0)) { return null; }
    return pageForRect(rect);
  }

  // Page index of the element with the given id (URL fragment), or null.
  function pageForFragment(fragment) {
    if (!fragment) { return null; }
    let id = fragment;
    try { id = decodeURIComponent(fragment); } catch (e) { /* keep raw */ }
    const el = document.getElementById(id) || document.querySelector('[name="' + CSS.escape(id) + '"]');
    if (!el) { return null; }
    return pageForRect(el.getBoundingClientRect());
  }

  // Update CSS variables / font override and re-measure. Returns {pageCount}.
  function applySettings(params) {
    applyParams(params);
    void root().offsetWidth;
    state.pageCount = computePageCount();
    return { pageCount: state.pageCount, writingMode: state.writingMode };
  }

  // --- events -----------------------------------------------------------------------------------

  function resolveHref(a) {
    let raw = a.getAttribute("href");
    if (raw === null && a.href && typeof a.href === "object" && a.href.baseVal !== undefined) { raw = a.href.baseVal; }
    if (raw === null || raw === undefined) { return null; }
    try { return new URL(raw, document.baseURI).href; } catch (e) { return raw; }
  }

  document.addEventListener("click", function (e) {
    const target = e.target;
    const a = target && target.closest ? target.closest("a[href], a[*|href]") : null;
    if (a) {
      e.preventDefault();
      e.stopPropagation();
      const href = resolveHref(a);
      if (href) {
        post("link", { href: href, isExternal: /^(https?|mailto|tel|sms):/i.test(href) });
      }
      return;
    }
    post("tap", { x: e.clientX, y: e.clientY, viewportWidth: window.innerWidth, viewportHeight: window.innerHeight });
  }, true);

  let changeTimer = null;
  function scheduleRecount() {
    if (changeTimer) { clearTimeout(changeTimer); }
    changeTimer = setTimeout(function () {
      changeTimer = null;
      if (!state.readySent || !state.pageWidth) { return; }
      const before = state.pageCount;
      state.pageCount = computePageCount();
      if (state.pageCount !== before) {
        post("pageCountChanged", { pageCount: state.pageCount });
      }
    }, 50);
  }

  function watchForChanges() {
    document.addEventListener("load", function (e) {
      const t = e.target;
      if (t && (t.tagName === "IMG" || t.tagName === "image" || t.tagName === "VIDEO")) { scheduleRecount(); }
    }, true);
    if (document.fonts && document.fonts.addEventListener) {
      document.fonts.addEventListener("loadingdone", scheduleRecount);
    }
  }

  function whenLoaded() {
    if (document.readyState === "complete") { return Promise.resolve(); }
    return new Promise(function (resolve) { window.addEventListener("load", function () { resolve(); }, { once: true }); });
  }

  const fontsReady = (document.fonts && document.fonts.ready) ? document.fonts.ready.catch(function () {}) : Promise.resolve();

  window.__epubReader = {
    version: 1,
    layout: layout,
    goToPage: goToPage,
    captureAnchor: captureAnchor,
    pageForAnchor: pageForAnchor,
    pageForFragment: pageForFragment,
    applySettings: applySettings,
    pageCount: function () { return state.pageCount; },
  };

  Promise.all([whenLoaded(), fontsReady]).then(function () {
    state.readySent = true;
    watchForChanges();
    post("ready", { writingMode: detectWritingMode(), readyState: document.readyState });
  });
})();
