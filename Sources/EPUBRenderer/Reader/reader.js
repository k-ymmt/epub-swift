// EPUB-Swift reader.js
// The only script that runs in a content document. Injected as a WKUserScript at document end in the
// dedicated `reader` WKContentWorld; content JavaScript is disabled (docs/design/02-rendering.md §4).
//
// Swift -> JS: window.__epubReader.{layout, goToPage, pageForFragment, applySettings, cfiForPage, pageFor, rectsFor,
//               setHighlights, setTransientHighlight, currentSelection, clearSelection}
// JS -> Swift: webkit.messageHandlers.reader.postMessage({type, payload})
//   ready {writingMode, href}       after `load` and `document.fonts.ready` (writingMode: computed value, e.g. "vertical-rl")
//   pageCountChanged {pageCount}    when late image loads change the layout
//   link {href, isExternal}         click on <a>; the default is prevented, Swift decides navigation
//   noteref {href, rect, sameDocument, html?, text?, cfi?, hidden?}   click on <a epub:type="noteref"> (M5); the note's content
//                                   when it is in the same document
//   imageTap {src, alt, rect, x, y} click on <img> / SVG <image> outside a link (M5); not on fixed-layout pages
//   highlightTap {id, rects}        click/tap inside a highlight set with setHighlights (the topmost one)
//   tap {x, y}                      click/tap on anything that is not a link (viewport coordinates)
//   selectionChanged {cfiRange, text, rects} | null   the selection changed (debounced)
// Positions are EPUB CFI strings; the CFI module below mirrors EPUBCore (docs/design/01-core.md §5).
//
// Spreads (M4, 02-rendering §6.2): the script also runs in the iframes of the `_reader/spread` wrapper document.
// A framed document does not talk to Swift; it exposes `setHost` / `whenReady` and the wrapper's copy of this
// script (the spread controller, `installSpreadController` below) presents the same API to Swift, proxying the
// calls to the frames and mapping coordinates. `layout({fixedLayout: true})` turns a pre-paginated page into a
// single page without columns.
(function () {
  "use strict";
  if (window.__epubReader) { return; }

  const SENTINEL_ID = "__reader_end";
  // The overlay layer for outline highlights: the last child of <html>, after <body>, so that no CFI step inside
  // <body> changes (06-annotations §10.3).
  const OVERLAY_ID = "__reader_overlay";
  const state = {
    pageWidth: 0,
    pageHeight: 0,
    pageCount: 1,
    writingMode: "horizontal-tb",
    readySent: false,
    // Spine steps of this document ("/6/14[xchapter_001]"), set by `layout`; prefixed to every generated CFI.
    spineSteps: [],
    // [{id, range}] of the highlights currently drawn, bottom first, for hit testing.
    highlights: [],
    // [{range, color}] of the outline highlights, drawn as boxes in the overlay layer (06-annotations §10.3).
    outlines: [],
    // Pre-paginated document inside a spread wrapper: one page, no columns (M4).
    fixedLayout: false,
    // Columns per page asked for (2 for a reflowable spread in horizontal writing; vertical writing ignores it, M4).
    columnsPerPage: 1,
    // Inside a spread wrapper: the controller's callback that receives this document's events (M4).
    host: null,
  };
  // In an iframe (a spread wrapper's page, or an iframe inside a content document). Framed documents never post to
  // Swift: the wrapper proxies for them, and an iframe inside a chapter has no say in the chapter's pagination.
  const framed = (function () { try { return window.top !== window; } catch (e) { return true; } })();

  const OPS_NS = "http://www.idpf.org/2007/ops";
  const XLINK_NS = "http://www.w3.org/1999/xlink";
  // `epub:type` tokens: the namespaced attribute in XHTML, a plain `epub:type` attribute in a document parsed as HTML.
  function hasEpubType(el, type) {
    if (!el || !el.getAttributeNS) { return false; }
    const value = el.getAttributeNS(OPS_NS, "type") || el.getAttribute("epub:type") || "";
    return value.split(/\s+/).indexOf(type) >= 0;
  }

  function root() { return document.documentElement; }
  function scroller() { return document.scrollingElement || document.documentElement; }
  function setVar(name, value) { root().style.setProperty(name, value); }

  function post(type, payload) {
    if (framed) {
      if (state.host) {
        try { state.host(type, payload || {}); } catch (e) { /* the wrapper handles its own errors */ }
        return Promise.resolve(true);
      }
      return Promise.resolve(false);
    }
    try {
      return window.webkit.messageHandlers.reader.postMessage({ type: type, payload: payload || {} });
    } catch (e) {
      return Promise.reject(e);
    }
  }

  function setHost(fn) { state.host = typeof fn === "function" ? fn : null; }

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
  // column axis follows (02-rendering §3.4). The result is mirrored into a root attribute that switches
  // reader-before.css to the vertical column rules.
  function detectWritingMode() {
    let wm = getComputedStyle(root()).writingMode || "horizontal-tb";
    if (wm === "horizontal-tb" && document.body) {
      const bodyWM = getComputedStyle(document.body).writingMode;
      if (bodyWM && bodyWM !== "horizontal-tb") {
        root().style.writingMode = bodyWM;
        wm = bodyWM;
      }
    }
    const vertical = wm.indexOf("vertical") === 0 || wm.indexOf("sideways") === 0;
    root().setAttribute("data-reader-writing-mode", vertical ? "vertical" : "horizontal");
    detectDirection(vertical);
    return wm;
  }

  // Right-to-left horizontal text (Arabic, Hebrew: `dir="rtl"` on html). With an rtl root the columns flow to the
  // left of the first one (negative scroll positions), which the page arithmetic does not handle. The root is laid
  // out left-to-right and the text direction moves to body (reader-before.css, `data-reader-direction`); the page
  // order of a right-bound book is the spread's business (first page on the right, 02-rendering §6.2, M5).
  function detectDirection(vertical) {
    if (vertical) { root().removeAttribute("data-reader-direction"); return; }
    if (root().getAttribute("data-reader-direction") === "rtl") { return; }
    if (getComputedStyle(root()).direction === "rtl") { root().setAttribute("data-reader-direction", "rtl"); }
  }

  function isVertical() { return state.writingMode.indexOf("vertical") === 0 || state.writingMode.indexOf("sideways") === 0; }

  // Two columns per page only make sense in horizontal writing (vertical columns stack along y; a vertical
  // spread is two frames, 02-rendering §6.2). Returns the columns in effect.
  function applyColumns() {
    const columns = isVertical() ? 1 : state.columnsPerPage;
    setVar("--reader-columns", String(columns));
    return columns;
  }

  // Page count from the end sentinel's document position (not scrollWidth: in the 3-page-wide frame
  // scrollWidth never goes below the viewport width; 05-spike-results §2.3).
  function computePageCount() {
    if (state.fixedLayout) { return 1; }
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

  // Stretches the scroll area to exactly `pageCount` pages along the page axis (reader-before.css `html::after`).
  function applyExtent() {
    if (state.fixedLayout || !state.pageWidth || !state.pageHeight) {
      root().style.removeProperty("--reader-extent-x");
      root().style.removeProperty("--reader-extent-y");
      return;
    }
    if (isVertical()) {
      setVar("--reader-extent-x", "1px");
      setVar("--reader-extent-y", (state.pageCount * state.pageHeight) + "px");
    } else {
      setVar("--reader-extent-x", (state.pageCount * state.pageWidth) + "px");
      setVar("--reader-extent-y", "1px");
    }
  }

  function applyParams(p) {
    if (!p) { return; }
    if (p.pageWidth) { state.pageWidth = p.pageWidth; setVar("--reader-page-width", p.pageWidth + "px"); }
    if (p.pageHeight) { state.pageHeight = p.pageHeight; setVar("--reader-page-height", p.pageHeight + "px"); }
    if (p.margins) {
      setVar("--reader-margin-h", p.margins.horizontal + "px");
      setVar("--reader-margin-v", p.margins.vertical + "px");
    }
    if (p.columnsPerPage) { state.columnsPerPage = Math.max(1, Math.min(2, Math.floor(p.columnsPerPage))); }
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
    if (params && typeof params.spineSteps === "string") {
      const parsed = CFI.parse("epubcfi(" + params.spineSteps + "!/2)");
      state.spineSteps = parsed ? parsed[0].spineSteps : [];
    }
    state.fixedLayout = !!(params && params.fixedLayout);
    state.writingMode = detectWritingMode();
    if (state.fixedLayout) {
      // The page is the publisher's fixed design: no sentinel, no columns, exactly one page (02-rendering §6.1).
      state.pageCount = 1;
      drawOverlay();
      return { pageCount: 1, writingMode: state.writingMode, columnsPerPage: 1 };
    }
    const columns = applyColumns();
    ensureSentinel();
    void root().offsetWidth; // flush layout
    state.pageCount = computePageCount();
    applyExtent();
    drawOverlay();
    return { pageCount: state.pageCount, writingMode: state.writingMode, columnsPerPage: columns };
  }

  // Scroll so that page `index` is visible. The frame may be wider than one page (three slots, the
  // middle one visible). The desired scroll position keeps the page in the middle slot when possible;
  // at the ends the scroll position is clamped and the page ends up in another slot. The returned
  // `slot` tells Swift where the page is so it can offset the web view (02-rendering §1.2).
  function goToPage(index) {
    if (state.fixedLayout) {
      const sc0 = scroller();
      sc0.scrollLeft = 0;
      sc0.scrollTop = 0;
      return { pageIndex: 0, slot: 0, pageCount: 1, scrollLeft: 0, scrollTop: 0 };
    }
    // Re-measure first: late image/font loads may have changed the page count since the last call.
    state.pageCount = computePageCount();
    applyExtent();
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

  // Page index of the element with the given id, or null. `id` is already percent-decoded (Swift decodes link and
  // table-of-contents fragments once); decoding again would miss ids that contain "%".
  function pageForFragment(id) {
    if (!id) { return null; }
    const el = document.getElementById(id) || document.querySelector('[name="' + CSS.escape(id) + '"]');
    if (!el) { return null; }
    return pageForRect(el.getBoundingClientRect());
  }

  // Update CSS variables / font override and re-measure. Returns {pageCount}.
  function applySettings(params) {
    applyParams(params);
    const columns = state.fixedLayout ? 1 : applyColumns();
    void root().offsetWidth;
    state.pageCount = computePageCount();
    applyExtent();
    drawOverlay();
    return { pageCount: state.pageCount, writingMode: state.writingMode, columnsPerPage: columns };
  }

  // --- CFI ------------------------------------------------------------------------------------
  // Same rules as EPUBCore's CFI / CFIGenerator / CFIResolver (docs/design/01-core.md §5, 02-rendering §4.3):
  // even steps are elements, odd steps the text between elements; adjacent text / CDATA nodes (and the comments
  // and processing instructions between them) count as one text node, as in the Core DOM; offsets are UTF-16
  // code units; an ID assertion wins over the index; a text assertion re-finds the position when the structure
  // does not match. Both implementations are checked against Tests/Fixtures/cfi-vectors.json.
  const CFI = (function () {
    const CONTEXT = 10;

    function escape(s) { return String(s).replace(/[\^\[\]\(\),;=]/g, function (c) { return "^" + c; }); }

    // --- parsing ---
    function splitTopLevel(str) {
      const parts = [""];
      let depth = 0;
      for (let i = 0; i < str.length; i++) {
        const c = str[i];
        if (c === "^" && i + 1 < str.length) { parts[parts.length - 1] += c + str[i + 1]; i++; continue; }
        if (c === "[") { depth++; } else if (c === "]") { depth = Math.max(0, depth - 1); }
        if (c === "," && depth === 0) { parts.push(""); } else { parts[parts.length - 1] += c; }
      }
      return parts;
    }

    function parseComponents(str) {
      const out = [];
      let i = 0;
      function readInteger() {
        let digits = "";
        while (i < str.length && str[i] >= "0" && str[i] <= "9") { digits += str[i++]; }
        return digits.length ? parseInt(digits, 10) : null;
      }
      function readNumber() {
        let any = false;
        while (i < str.length && ((str[i] >= "0" && str[i] <= "9") || str[i] === ".")) { i++; any = true; }
        return any;
      }
      function readAssertion() {
        if (str[i] !== "[") { return null; }
        i++;
        const values = [""];
        let inParameters = false;
        while (i < str.length) {
          const c = str[i];
          if (c === "^" && i + 1 < str.length) { if (!inParameters) { values[values.length - 1] += str[i + 1]; } i += 2; continue; }
          if (c === "]") { i++; return values; }
          if (c === ";") { inParameters = true; }
          else if (c === "," && !inParameters) { values.push(""); }
          else if (!inParameters) { values[values.length - 1] += c; }
          i++;
        }
        return null;
      }
      while (i < str.length) {
        const c = str[i];
        if (c === "/") {
          i++;
          const index = readInteger();
          if (index === null) { return null; }
          let id = null;
          if (str[i] === "[") {
            const values = readAssertion();
            if (values === null) { return null; }
            id = values[0] || null;
          }
          out.push({ kind: "step", index: index, id: id });
        } else if (c === "!") {
          i++;
          out.push({ kind: "indirection" });
        } else if (c === ":") {
          i++;
          const offset = readInteger();
          if (offset === null) { return null; }
          let assertion = null;
          if (str[i] === "[") {
            const values = readAssertion();
            if (values === null) { return null; }
            assertion = { before: values[0] || "", after: values.length > 1 ? values[1] : "" };
            if (!assertion.before && !assertion.after) { assertion = null; }
          }
          out.push({ kind: "offset", offset: offset, assertion: assertion });
        } else if (c === "~") {
          i++;
          if (!readNumber()) { return null; }
        } else if (c === "@") {
          i++;
          if (!readNumber()) { return null; }
          if (str[i] !== ":") { return null; }
          i++;
          if (!readNumber()) { return null; }
        } else {
          return null;
        }
      }
      return out;
    }

    function assemble(components) {
      let spine = [], steps = [], sawIndirection = false, offset = null, assertion = null;
      for (const c of components) {
        if (c.kind === "step") {
          if (offset !== null) { return null; }
          (sawIndirection ? steps : spine).push({ index: c.index, id: c.id });
        } else if (c.kind === "indirection") {
          if (sawIndirection || offset !== null) { return null; }
          sawIndirection = true;
        } else {
          if (offset !== null) { return null; }
          offset = c.offset;
          assertion = c.assertion;
        }
      }
      if (!sawIndirection) { steps = spine; spine = []; }
      if (!steps.length && !spine.length) { return null; }
      return { spineSteps: spine, steps: steps, offset: offset, assertion: assertion };
    }

    // "epubcfi(...)" → [point] or [start, end], or null.
    function parse(string) {
      const trimmed = String(string).trim();
      if (!trimmed.startsWith("epubcfi(") || !trimmed.endsWith(")")) { return null; }
      const inner = trimmed.slice(8, -1);
      if (!inner.length) { return null; }
      const parts = splitTopLevel(inner);
      if (parts.length === 1) {
        const components = parseComponents(parts[0]);
        if (!components) { return null; }
        const point = assemble(components);
        return point ? [point] : null;
      }
      if (parts.length === 3) {
        const parent = parseComponents(parts[0]), s = parseComponents(parts[1]), e = parseComponents(parts[2]);
        if (!parent || !s || !e || !parent.length || !s.length || !e.length) { return null; }
        const start = assemble(parent.concat(s)), end = assemble(parent.concat(e));
        return start && end ? [start, end] : null;
      }
      return null;
    }

    // --- rendering ---
    function renderSteps(steps) {
      let out = "";
      for (const s of steps) { out += "/" + s.index; if (s.id) { out += "[" + escape(s.id) + "]"; } }
      return out;
    }
    function renderLocal(point) {
      let out = renderSteps(point.steps);
      if (point.offset !== null && point.offset !== undefined) {
        out += ":" + point.offset;
        if (point.assertion && (point.assertion.before || point.assertion.after)) {
          out += "[" + escape(point.assertion.before) + "," + escape(point.assertion.after) + "]";
        }
      }
      return out;
    }
    function render(point) {
      return "epubcfi(" + renderSteps(point.spineSteps) + (point.spineSteps.length ? "!" : "") + renderLocal(point) + ")";
    }
    function sameSteps(a, b) { return a.length === b.length && a.every(function (s, i) { return s.index === b[i].index && (s.id || null) === (b[i].id || null); }); }
    function renderRange(start, end) {
      if (render(start) === render(end)) { return render(start); }
      if (!sameSteps(start.spineSteps, end.spineSteps)) { return render(start); }
      let common = 0;
      while (common < start.steps.length && common < end.steps.length &&
             start.steps[common].index === end.steps[common].index && (start.steps[common].id || null) === (end.steps[common].id || null)) { common++; }
      if (common === start.steps.length && start.steps.length) { common--; }
      if (common === end.steps.length && end.steps.length) { common = Math.min(common, end.steps.length - 1); }
      const parent = renderSteps(start.spineSteps) + (start.spineSteps.length ? "!" : "") + renderSteps(start.steps.slice(0, common));
      const s = renderLocal({ steps: start.steps.slice(common), offset: start.offset, assertion: start.assertion });
      const e = renderLocal({ steps: end.steps.slice(common), offset: end.offset, assertion: end.assertion });
      return "epubcfi(" + parent + "," + s + "," + e + ")";
    }

    // --- DOM ---
    function isText(node) { return node.nodeType === Node.TEXT_NODE || node.nodeType === Node.CDATA_SECTION_NODE; }
    function isTransparent(node) { return node.nodeType === Node.COMMENT_NODE || node.nodeType === Node.PROCESSING_INSTRUCTION_NODE; }

    // Logical children of an element: elements, and runs of adjacent text nodes (comments between them do not
    // split a run). Each entry has its CFI step index.
    function logicalChildren(parent) {
      const out = [];
      let elements = 0;
      let run = null;
      for (let n = parent.firstChild; n; n = n.nextSibling) {
        if (n.nodeType === Node.ELEMENT_NODE) {
          run = null;
          elements++;
          out.push({ kind: "element", node: n, step: 2 * elements });
        } else if (isText(n)) {
          if (run) { run.nodes.push(n); } else { run = { kind: "text", nodes: [n], step: 2 * elements + 1 }; out.push(run); }
        } else if (!isTransparent(n)) {
          run = null;
        }
      }
      return out;
    }
    function runLength(run) { return run.nodes.reduce(function (sum, n) { return sum + n.data.length; }, 0); }
    function runText(run) { return run.nodes.map(function (n) { return n.data; }).join(""); }

    // Steps (and merged offset) for a node, from the document element.
    function stepsFor(node, offset) {
      const steps = [];
      let mergedOffset = null;
      let current = node;
      if (isText(node)) {
        const run = logicalChildren(node.parentNode).find(function (c) { return c.kind === "text" && c.nodes.indexOf(node) >= 0; });
        if (!run) { return null; }
        let before = 0;
        for (const n of run.nodes) { if (n === node) { break; } before += n.data.length; }
        mergedOffset = Math.min(before + Math.max(0, offset || 0), runLength(run));
        steps.unshift({ index: run.step, id: null });
        current = node.parentNode;
      }
      while (current && current !== document.documentElement) {
        const parent = current.parentNode;
        if (!parent || parent.nodeType !== Node.ELEMENT_NODE) { return null; }
        const entry = logicalChildren(parent).find(function (c) { return c.kind === "element" && c.node === current; });
        if (!entry) { return null; }
        const id = current.getAttribute && current.getAttribute("id");
        steps.unshift({ index: entry.step, id: id || null });
        current = parent;
      }
      if (current !== document.documentElement) { return null; }
      return { steps: steps, offset: mergedOffset };
    }

    function assertionFor(run, offset) {
      const text = runText(run);
      const before = text.slice(Math.max(0, offset - CONTEXT), offset);
      const after = text.slice(offset, Math.min(text.length, offset + CONTEXT));
      return (before || after) ? { before: before, after: after } : null;
    }

    // The CFI string of a node (+ offset for text), with the current document's spine steps.
    function fromNode(node, offset) {
      const located = stepsFor(node, offset);
      if (!located) { return null; }
      let assertion = null;
      if (located.offset !== null) {
        const run = logicalChildren(node.parentNode).find(function (c) { return c.kind === "text" && c.nodes.indexOf(node) >= 0; });
        assertion = assertionFor(run, located.offset);
      }
      return render({ spineSteps: state.spineSteps, steps: located.steps, offset: located.offset, assertion: assertion });
    }

    // Maps a merged offset within a run to a concrete text node and local offset.
    function locate(run, mergedOffset) {
      let remaining = Math.min(Math.max(0, mergedOffset), runLength(run));
      for (let k = 0; k < run.nodes.length; k++) {
        const n = run.nodes[k];
        if (remaining <= n.data.length && (remaining < n.data.length || k === run.nodes.length - 1)) {
          return { node: n, offset: remaining };
        }
        remaining -= n.data.length;
      }
      const last = run.nodes[run.nodes.length - 1];
      return { node: last, offset: last.data.length };
    }

    function resolveSteps(point) {
      let element = document.documentElement;
      for (let p = 0; p < point.steps.length; p++) {
        const step = point.steps[p];
        const children = logicalChildren(element);
        if (step.index % 2 === 0) {
          const elements = children.filter(function (c) { return c.kind === "element"; });
          const k = step.index / 2 - 1;
          let chosen = (k >= 0 && k < elements.length) ? elements[k].node : null;
          if (step.id && (!chosen || chosen.getAttribute("id") !== step.id)) {
            const byID = document.getElementById(step.id);
            if (byID) { element = byID; continue; }
          }
          if (!chosen) { return null; }
          element = chosen;
        } else {
          if (p !== point.steps.length - 1) { return null; }
          const run = children.find(function (c) { return c.kind === "text" && c.step === step.index; });
          if (!run) { return null; }
          return Object.assign({ run: run }, locate(run, point.offset === null ? 0 : point.offset));
        }
      }
      return { node: element, offset: null, run: null };
    }

    function matchesAssertion(resolved, assertion) {
      if (!resolved || resolved.offset === null || !resolved.run) { return false; }
      const text = runText(resolved.run);
      let before = 0;
      for (const n of resolved.run.nodes) { if (n === resolved.node) { break; } before += n.data.length; }
      const at = before + resolved.offset;
      if (at - assertion.before.length < 0 || at + assertion.after.length > text.length) { return false; }
      return text.slice(at - assertion.before.length, at) === assertion.before && text.slice(at, at + assertion.after.length) === assertion.after;
    }

    function allTextNodes() {
      const walker = document.createTreeWalker(document.documentElement, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_CDATA_SECTION);
      const nodes = [];
      let n;
      while ((n = walker.nextNode())) { nodes.push(n); }
      return nodes;
    }

    // Finds before+after in the document text; nearest occurrence to `near` ({node, offset}) wins.
    function searchAssertion(assertion, near) {
      const nodes = allTextNodes();
      if (!nodes.length) { return null; }
      const starts = [];
      let combined = "";
      for (const n of nodes) { starts.push(combined.length); combined += n.data; }
      const needle = assertion.before + assertion.after;
      if (!needle.length) { return null; }
      const candidates = [];
      let from = 0;
      while (true) {
        const at = combined.indexOf(needle, from);
        if (at < 0) { break; }
        candidates.push(at + assertion.before.length);
        from = at + 1;
      }
      if (!candidates.length) { return null; }
      let target = candidates[0];
      if (near && near.node) {
        const nearIndex = nodes.indexOf(near.node);
        if (nearIndex >= 0) {
          const nearGlobal = starts[nearIndex] + (near.offset || 0);
          target = candidates.reduce(function (best, c) { return Math.abs(c - nearGlobal) < Math.abs(best - nearGlobal) ? c : best; }, target);
        }
      }
      let nodeIndex = 0;
      for (let k = 0; k < starts.length; k++) { if (starts[k] <= target) { nodeIndex = k; } }
      return { node: nodes[nodeIndex], offset: target - starts[nodeIndex], run: null };
    }

    // CFI point → {node, offset|null, usedTextAssertion}, or null.
    function resolvePoint(point) {
      const structural = resolveSteps(point);
      if (!point.assertion) {
        return structural ? { node: structural.node, offset: structural.offset, usedTextAssertion: false } : null;
      }
      if (structural && matchesAssertion(structural, point.assertion)) {
        return { node: structural.node, offset: structural.offset, usedTextAssertion: false };
      }
      const repaired = searchAssertion(point.assertion, structural);
      if (repaired) { return { node: repaired.node, offset: repaired.offset, usedTextAssertion: true }; }
      return structural ? { node: structural.node, offset: structural.offset, usedTextAssertion: false } : null;
    }

    function resolve(string) {
      const parsed = parse(string);
      if (!parsed) { return null; }
      return resolvePoint(parsed[0]);
    }

    function setBoundary(range, resolved, start) {
      if (resolved.offset === null) {
        if (start) { range.setStartBefore(resolved.node); } else { range.setEndAfter(resolved.node); }
      } else if (start) { range.setStart(resolved.node, resolved.offset); } else { range.setEnd(resolved.node, resolved.offset); }
    }

    // CFI (point or range) → DOM Range, or null.
    function toRange(string) {
      const parsed = parse(string);
      if (!parsed) { return null; }
      const start = resolvePoint(parsed[0]);
      const end = parsed.length > 1 ? resolvePoint(parsed[1]) : start;
      if (!start || !end) { return null; }
      const range = document.createRange();
      try {
        setBoundary(range, start, true);
        setBoundary(range, end, false);
      } catch (e) { return null; }
      if (range.collapsed && parsed.length > 1 && (start.node !== end.node || start.offset !== end.offset)) {
        // end before start (e.g. assertion repair moved one of them): give the start alone
        range.collapse(true);
      }
      return range;
    }

    // DOM Range → CFI range string.
    function fromRange(range) {
      if (!range) { return null; }
      const s = boundaryToPoint(range.startContainer, range.startOffset);
      const e = boundaryToPoint(range.endContainer, range.endOffset);
      if (!s || !e) { return null; }
      return renderRange(s, e);
    }

    // A (container, offset) boundary as a CFI point. An element container with a child offset is moved into the
    // nearest text position so the point is a text location when possible. Children that are neither text nor
    // elements (comments, processing instructions) have no CFI and are skipped.
    function boundaryToPoint(container, offset) {
      let node = container, off = offset;
      if (!isText(node)) {
        const children = node.childNodes;
        let placed = false;
        for (let k = off; k < children.length && !placed; k++) {
          const child = children[k];
          // Descend to the first text in the child, else use the element itself.
          const first = firstTextIn(child);
          if (first) { node = first; off = 0; placed = true; }
          else if (child.nodeType === Node.ELEMENT_NODE) { node = child; off = null; placed = true; }
        }
        if (!placed) {
          // Nothing addressable after the boundary: the end of the last text in the container, else the container.
          const last = children.length ? lastTextIn(node) : null;
          if (last) { node = last; off = last.data.length; }
          else { off = null; }
        }
      }
      const located = stepsFor(node, off === null ? 0 : off);
      if (!located) { return null; }
      let assertion = null;
      if (isText(node)) {
        const run = logicalChildren(node.parentNode).find(function (c) { return c.kind === "text" && c.nodes.indexOf(node) >= 0; });
        assertion = assertionFor(run, located.offset);
      } else {
        located.offset = null;
      }
      return { spineSteps: state.spineSteps, steps: located.steps, offset: located.offset, assertion: assertion };
    }
    function firstTextIn(node) {
      if (isText(node)) { return node; }
      if (node.nodeType !== Node.ELEMENT_NODE) { return null; }
      const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_CDATA_SECTION);
      return walker.nextNode();
    }
    function lastTextIn(node) {
      const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_CDATA_SECTION);
      let last = null, n;
      while ((n = walker.nextNode())) { last = n; }
      return last;
    }

    // Test hooks (Tests/EPUBRendererTests/CFIScriptTests.swift): describe what a CFI resolves to.
    function describe(string) {
      const r = resolve(string);
      if (!r) { return null; }
      const out = { usedTextAssertion: r.usedTextAssertion };
      if (r.offset === null) {
        out.elementId = r.node.getAttribute("id");
        out.generated = fromNode(r.node, null);
      } else {
        const run = logicalChildren(r.node.parentNode).find(function (c) { return c.kind === "text" && c.nodes.indexOf(r.node) >= 0; });
        let before = 0;
        for (const n of run.nodes) { if (n === r.node) { break; } before += n.data.length; }
        out.text = runText(run);
        out.offset = before + r.offset;
        out.generated = fromNode(r.node, r.offset);
      }
      return out;
    }
    function canonical(string) {
      const parsed = parse(string);
      if (!parsed) { return null; }
      return parsed.length === 1 ? render(parsed[0]) : renderRange(parsed[0], parsed[1]);
    }
    function rangeParts(string) {
      const parsed = parse(string);
      if (!parsed) { return null; }
      return { start: render(parsed[0]), end: render(parsed[parsed.length - 1]), canonical: canonical(string) };
    }

    return { parse: parse, render: render, fromNode: fromNode, resolve: resolve, resolvePoint: resolvePoint, toRange: toRange,
             fromRange: fromRange, describe: describe, canonical: canonical, rangeParts: rangeParts, escape: escape };
  })();

  // --- positions (CFI) ------------------------------------------------------------------------------

  // Page origin in viewport coordinates (the frame is three pages along the paging axis).
  function pageOrigin(index) {
    const sc = scroller();
    if (isVertical()) { return { x: 0, y: index * state.pageHeight - sc.scrollTop }; }
    return { x: index * state.pageWidth - sc.scrollLeft, y: 0 };
  }

  // First text position (node, offset) on page `index`: caret probes near the page's start corner when the page
  // is inside the frame, else (or when the probes find nothing) the first text node with a box inside the page.
  // Horizontal: the page starts at its top-left. Vertical (vertical-rl): at its top-right.
  function firstTextPosition(index, margins) {
    if (!state.pageWidth || !state.pageHeight) { return null; }
    const mh = (margins && margins.horizontal) || 0;
    const mv = (margins && margins.vertical) || 0;
    const vertical = isVertical();
    const origin = pageOrigin(index);
    const sc = scroller();
    const inFrame = vertical ? (origin.y >= -0.5 && origin.y + state.pageHeight <= sc.clientHeight + 0.5)
                             : (origin.x >= -0.5 && origin.x + state.pageWidth <= sc.clientWidth + 0.5);
    let fallbackElement = null;
    if (inFrame && document.caretRangeFromPoint) {
      let xs, ys;
      if (vertical) {
        const right = state.pageWidth - mh;
        xs = [right - 2, right - 16, right - 48, right - 96, right - state.pageWidth / 3, state.pageWidth / 2, mh + 8];
        ys = [mv + 2, mv + state.pageHeight / 4, mv + state.pageHeight / 2];
      } else {
        xs = [mh + 2, mh + state.pageWidth / 4, mh + state.pageWidth / 2];
        ys = [mv + 2, mv + 16, mv + 48, mv + 96, mv + state.pageHeight / 3, mv + state.pageHeight / 2, state.pageHeight - mv - 8];
      }
      const outer = vertical ? xs : ys;
      const inner = vertical ? ys : xs;
      for (const o of outer) {
        for (const i of inner) {
          const cx = origin.x + (vertical ? o : i);
          const cy = origin.y + (vertical ? i : o);
          const range = document.caretRangeFromPoint(cx, cy);
          if (range && range.startContainer && (range.startContainer.nodeType === Node.TEXT_NODE || range.startContainer.nodeType === Node.CDATA_SECTION_NODE)) {
            const text = range.startContainer.data || "";
            if (text.trim().length > 0 && range.startContainer.id !== SENTINEL_ID) {
              return { node: range.startContainer, offset: range.startOffset };
            }
          }
          if (!fallbackElement) {
            const el = document.elementFromPoint(cx, cy);
            if (el && el !== document.body && el !== root() && el.id !== SENTINEL_ID && !isInOverlay(el)) { fallbackElement = el; }
          }
        }
      }
    }
    const inPage = firstTextInPage(origin.x, origin.y);
    if (inPage) { return inPage; }
    // Last resort: an element, but only one that fits in a page. A container that spans many columns (a chapter
    // <div>) would restore to the page where it starts, far from the current page.
    if (fallbackElement) {
      let el = fallbackElement;
      while (el && el !== document.body && el !== root()) {
        const r = el.getBoundingClientRect();
        if (r.width <= state.pageWidth + 1 && r.height <= state.pageHeight + 1) { return { node: el, offset: null }; }
        el = el.parentElement;
      }
      // A leaf (an image taller than a page) has nothing finer to point at; its start is the nearest position.
      if (fallbackElement.children.length === 0) { return { node: fallbackElement, offset: null }; }
    }
    return null;
  }

  function firstTextInPage(originX, originY) {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_CDATA_SECTION);
    const r = document.createRange();
    const right = originX + state.pageWidth;
    const bottom = originY + state.pageHeight;
    const vertical = isVertical();
    let node;
    while ((node = walker.nextNode())) {
      if (!node.data || node.data.trim().length === 0) { continue; }
      r.selectNodeContents(node);
      const rects = r.getClientRects();
      for (let k = 0; k < rects.length; k++) {
        const rect = rects[k];
        if (rect.width <= 0 || rect.height <= 0) { continue; }
        if (rect.right <= originX || rect.left >= right || rect.bottom <= originY || rect.top >= bottom) { continue; }
        const px = vertical ? rect.left + rect.width / 2 : Math.max(rect.left, originX) + 1;
        const py = vertical ? Math.max(rect.top, originY) + 1 : rect.top + rect.height / 2;
        const caret = document.caretRangeFromPoint ? document.caretRangeFromPoint(px, py) : null;
        if (caret && caret.startContainer === node) { return { node: node, offset: caret.startOffset }; }
        // The point is outside the frame (caretRangeFromPoint only works inside the viewport): find the first
        // character of the node whose box is inside the page by bisection along the paging axis.
        const offset = firstOffsetInPage(node, originX, originY);
        return { node: node, offset: offset === null ? 0 : offset };
      }
    }
    return null;
  }

  // First offset of `node` whose character box starts inside the page at (originX, originY), or null.
  function firstOffsetInPage(node, originX, originY) {
    const len = node.data.length;
    if (len === 0) { return null; }
    const vertical = isVertical();
    const r = document.createRange();
    function charStart(o) {
      r.setStart(node, o);
      r.setEnd(node, Math.min(len, o + 1));
      const rects = r.getClientRects();
      const rect = rects.length ? rects[0] : r.getBoundingClientRect();
      return vertical ? rect.top : rect.left;
    }
    const pageStart = vertical ? originY : originX;
    const pageEnd = pageStart + (vertical ? state.pageHeight : state.pageWidth);
    // Boxes of later characters start at the same or a later page; bisect for the first one at or past pageStart.
    let lo = 0, hi = len - 1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (charStart(mid) < pageStart - 0.5) { lo = mid + 1; } else { hi = mid; }
    }
    const start = charStart(lo);
    return (start >= pageStart - 0.5 && start < pageEnd) ? lo : null;
  }

  // CFI of the first text visible on page `index` (02-rendering §4.1), or null when the page has no content.
  function cfiForPage(index, margins) {
    const i = Math.max(0, Math.min(Math.floor(index || 0), state.pageCount - 1));
    const position = firstTextPosition(i, margins);
    if (!position) { return null; }
    return CFI.fromNode(position.node, position.offset);
  }

  // Rectangle (viewport coordinates) of a resolved CFI point: the character after the offset, or the element.
  function rectForResolved(resolved) {
    if (!resolved) { return null; }
    if (resolved.offset === null) { return resolved.node.getBoundingClientRect(); }
    const r = document.createRange();
    const len = resolved.node.data.length;
    const off = Math.min(resolved.offset, len);
    if (off < len) { r.setStart(resolved.node, off); r.setEnd(resolved.node, off + 1); }
    else if (len > 0) { r.setStart(resolved.node, len - 1); r.setEnd(resolved.node, len); }
    else { r.selectNodeContents(resolved.node); }
    const rects = r.getClientRects();
    return rects.length > 0 ? rects[0] : r.getBoundingClientRect();
  }

  // Page index that contains the position a CFI (point, or the start of a range) addresses, or null.
  function pageFor(cfiString) {
    const parsed = CFI.parse(cfiString);
    if (!parsed) { return null; }
    const resolved = CFI.resolvePoint(parsed[0]);
    const rect = rectForResolved(resolved);
    if (!rect || (rect.width === 0 && rect.height === 0 && rect.left === 0 && rect.top === 0)) { return null; }
    return pageForRect(rect);
  }

  function rectList(rects) {
    const out = [];
    for (let k = 0; k < rects.length; k++) {
      const r = rects[k];
      if (r.width <= 0 && r.height <= 0) { continue; }
      out.push({ x: r.left, y: r.top, width: r.width, height: r.height });
    }
    return out;
  }

  // Client rectangles (viewport coordinates) of a CFI range.
  function rectsFor(cfiRange) {
    const range = CFI.toRange(cfiRange);
    return range ? rectList(range.getClientRects()) : [];
  }

  // --- highlights (CSS Custom Highlight API, 02-rendering §4.1 / §10) ----------------------------------

  const HIGHLIGHT_PREFIX = "reader-h-";
  const TRANSIENT_KEY = "reader-transient";

  function highlightStyleElement() {
    let el = document.getElementById("__reader_highlights");
    if (!el) {
      el = document.createElement("style");
      el.id = "__reader_highlights";
      (document.head || root()).appendChild(el);
    }
    return el;
  }

  function cssIdent(id) { return HIGHLIGHT_PREFIX + String(id).replace(/[^A-Za-z0-9_-]/g, "_"); }

  // Draws [{id, cfiRange, color, style: "solid" | "underline" | "strikethrough" | "outline"}] (06-annotations §10.2).
  // Replaces the previous set. Later items are drawn above earlier ones and win the hit test. Returns the ids whose
  // range resolved.
  function setHighlights(list) {
    if (typeof CSS === "undefined" || !CSS.highlights) { return []; }
    for (const key of Array.from(CSS.highlights.keys())) {
      if (key.indexOf(HIGHLIGHT_PREFIX) === 0) { CSS.highlights.delete(key); }
    }
    state.highlights = [];
    state.outlines = [];
    const rules = [];
    const applied = [];
    let priority = 0;
    for (const item of list || []) {
      const range = CFI.toRange(item.cfiRange);
      if (!range || range.collapsed) { continue; }
      if (item.style === "outline") {
        state.outlines.push({ range: range, color: item.color });
      } else {
        const key = cssIdent(item.id);
        const h = new Highlight(range);
        h.priority = priority++;
        CSS.highlights.set(key, h);
        if (item.style === "underline" || item.style === "strikethrough") {
          const line = item.style === "underline" ? "underline" : "line-through";
          const offset = item.style === "underline" ? " text-underline-offset: 2px;" : "";
          rules.push("::highlight(" + key + ") { text-decoration: " + line + "; text-decoration-color: " + item.color + "; text-decoration-thickness: 2px;" + offset + " }");
        } else {
          rules.push("::highlight(" + key + ") { background-color: " + item.color + "; }");
        }
      }
      state.highlights.push({ id: item.id, range: range });
      applied.push(item.id);
    }
    highlightStyleElement().textContent = rules.join("\n");
    drawOverlay();
    return applied;
  }

  function isInOverlay(node) {
    for (let n = node; n; n = n.parentNode) { if (n.id === OVERLAY_ID) { return true; } }
    return false;
  }

  // (Re)draws the outline boxes: one 2px frame per client rect of each range, in document coordinates (client
  // rects plus the scroll offset). The boxes do not follow the text by themselves, so layout, applySettings and late
  // reflows call this again (06-annotations §10.3, §12.3). The layer is removed when there is nothing to draw.
  function drawOverlay() {
    let o = document.getElementById(OVERLAY_ID);
    if (!state.outlines.length) {
      if (o) { o.remove(); }
      return;
    }
    if (!o) {
      o = document.createElement("div");
      o.id = OVERLAY_ID;
      o.setAttribute("aria-hidden", "true");
      o.setAttribute("style", "position: absolute; left: 0; top: 0; width: 0; height: 0; margin: 0; padding: 0; border: 0; pointer-events: none;");
    }
    // Always the last child of <html>, also when the document added nodes after it.
    if (o.parentNode !== root() || root().lastChild !== o) { root().appendChild(o); }
    while (o.firstChild) { o.removeChild(o.firstChild); }
    const sx = window.scrollX, sy = window.scrollY;
    for (const outline of state.outlines) {
      const rects = outline.range.getClientRects();
      for (let k = 0; k < rects.length; k++) {
        const c = rects[k];
        if (c.width <= 0 || c.height <= 0) { continue; }
        const b = document.createElement("div");
        b.setAttribute("style", "position: absolute; box-sizing: border-box; margin: 0; padding: 0; border: 2px solid " + outline.color
          + "; border-radius: 2px; left: " + (c.left + sx) + "px; top: " + (c.top + sy) + "px; width: " + c.width + "px; height: " + c.height + "px;");
        o.appendChild(b);
      }
    }
  }

  // Whether a CFI's spine steps name this document (a CFI without spine steps, or a document laid out without
  // them, is taken as this one). Compared by itemref id when both carry one, else by step index.
  function addressesThisDocument(cfiString) {
    const parsed = CFI.parse(cfiString);
    if (!parsed || !parsed[0].spineSteps.length || !state.spineSteps.length) { return true; }
    const a = parsed[0].spineSteps, b = state.spineSteps;
    if (a.length !== b.length) { return false; }
    for (let k = 0; k < a.length; k++) {
      if (a[k].id && b[k].id) { if (a[k].id !== b[k].id) { return false; } }
      else if (a[k].index !== b[k].index) { return false; }
    }
    return true;
  }

  // A single temporary highlight (search result). null removes it. Styled by reader-before.css. A range of another
  // document is refused (its steps would resolve to unrelated text here).
  function setTransientHighlight(cfiRange) {
    if (typeof CSS === "undefined" || !CSS.highlights) { return false; }
    CSS.highlights.delete(TRANSIENT_KEY);
    if (!cfiRange) { return true; }
    if (!addressesThisDocument(cfiRange)) { return false; }
    const range = CFI.toRange(cfiRange);
    if (!range || range.collapsed) { return false; }
    CSS.highlights.set(TRANSIENT_KEY, new Highlight(range));
    return true;
  }

  function highlightAt(x, y) {
    for (let i = state.highlights.length - 1; i >= 0; i--) {
      const h = state.highlights[i];
      const rects = h.range.getClientRects();
      for (let k = 0; k < rects.length; k++) {
        const r = rects[k];
        if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) { return h; }
      }
    }
    return null;
  }

  // --- spread wrapper (M4, 02-rendering §6.2) ----------------------------------------------------------
  // The wrapper document (`_reader/spread`, SpreadDocument.swift) holds one or two same-origin iframes, in reading
  // order (`data-order`). This controller presents the document API to Swift: it lays the frames out (fixed-layout
  // pages scaled into the visible area, `transform: scale()`), proxies the calls to the frames' own reader.js
  // (reachable as `iframe.contentWindow.__epubReader`, same content world) and maps coordinates between a frame and
  // the wrapper. kind "fixed": one page per frame, page count 1. kind "vertical": the same vertical-writing
  // document in both frames, scrolled to adjacent pages; wrapper page k shows document pages 2k and 2k+1.
  function installSpreadController() {
    const kind = root().getAttribute("data-reader-spread") || "fixed";
    const frames = Array.from(document.querySelectorAll("iframe[data-spine-index]")).map(function (el) {
      const steps = el.getAttribute("data-spine-steps") || "";
      return {
        el: el,
        spineIndex: parseInt(el.getAttribute("data-spine-index"), 10),
        stepsString: steps,
        spineSteps: parseSpineSteps(steps),
        declaredWidth: parseFloat(el.getAttribute("data-width")) || 0,
        declaredHeight: parseFloat(el.getAttribute("data-height")) || 0,
        placement: el.getAttribute("data-placement") || "f",
        order: parseInt(el.getAttribute("data-order"), 10) || 0,
        x: 0, y: 0, width: 0, height: 0, scale: 1, hidden: false, bridge: null,
      };
    }).sort(function (a, b) { return a.order - b.order; });
    const sp = { pageWidth: 0, pageHeight: 0, pageCount: 1, childPageCount: 1, writingMode: "horizontal-tb", readySent: false };

    function parseSpineSteps(str) {
      if (!str) { return []; }
      const parsed = CFI.parse("epubcfi(" + str + "!/2)");
      return parsed ? parsed[0].spineSteps : [];
    }
    function bridgeOf(frame) {
      try { return (frame.el.contentWindow && frame.el.contentWindow.__epubReader) || null; } catch (e) { return null; }
    }
    // Resolves (with the frame's writing mode, or null) once the frame's document has loaded and its reader.js is
    // ready. A page that fails to load, or never answers, resolves null after a grace period so the wrapper still
    // becomes ready (the Swift side has its own load timeout).
    function frameReady(frame) {
      return new Promise(function (resolve) {
        let done = false;
        function finish(mode) { if (!done) { done = true; resolve(mode || null); } }
        function attach() {
          const bridge = bridgeOf(frame);
          if (bridge && bridge.whenReady) {
            bridge.whenReady().then(function (r) { finish(r && r.writingMode); }, function () { finish(null); });
          } else {
            finish(null);
          }
        }
        let doc = null;
        try { doc = frame.el.contentDocument; } catch (e) { doc = null; }
        if (doc && doc.readyState === "complete" && bridgeOf(frame)) { attach(); }
        else { frame.el.addEventListener("load", attach, { once: true }); }
        setTimeout(function () { finish(null); }, 8000);
      });
    }
    const ready = Promise.all(frames.map(frameReady)).then(function (modes) {
      frames.forEach(function (frame) {
        frame.bridge = bridgeOf(frame);
        if (frame.bridge && frame.bridge.setHost) { frame.bridge.setHost(hostFor(frame)); }
      });
      sp.writingMode = (kind === "vertical" && modes[0]) ? modes[0] : "horizontal-tb";
      return sp.writingMode;
    });

    // --- geometry ---
    function twoPageLayout() { return kind === "vertical" || frames.some(function (f) { return f.placement !== "f"; }); }
    // The size the page is laid out at before scaling: the declared viewport, or the available area when the
    // document has none (PublicationWarning.missingViewport).
    function naturalSize(frame) {
      const two = twoPageLayout();
      return {
        w: frame.declaredWidth > 0 ? frame.declaredWidth : (two ? sp.pageWidth / 2 : sp.pageWidth),
        h: frame.declaredHeight > 0 ? frame.declaredHeight : sp.pageHeight,
      };
    }
    function place(frame, x, y, w, h, s) {
      frame.x = x; frame.y = y; frame.width = w; frame.height = h; frame.scale = s;
      const st = frame.el.style;
      st.left = x + "px"; st.top = y + "px"; st.width = w + "px"; st.height = h + "px";
      st.transform = s === 1 ? "none" : "scale(" + s + ")";
      st.visibility = frame.hidden ? "hidden" : "visible";
    }
    function setHidden(frame, hidden) {
      frame.hidden = !!hidden;
      frame.el.style.visibility = frame.hidden ? "hidden" : "visible";
    }
    function layoutFrames() {
      const W = sp.pageWidth, H = sp.pageHeight;
      if (!W || !H) { return; }
      root().style.width = W + "px"; root().style.height = H + "px";
      document.body.style.width = W + "px"; document.body.style.height = H + "px";
      const stage = document.getElementById("__reader_stage");
      if (stage) { stage.style.width = W + "px"; stage.style.height = H + "px"; }
      if (kind === "vertical") {
        frames.forEach(function (f) { place(f, f.placement === "l" ? 0 : W / 2, 0, W / 2, H, 1); });
        return;
      }
      if (frames.length === 2) {
        // Both pages share one scale so the spread reads as one picture; the pair is centered.
        const L = frames.find(function (f) { return f.placement === "l"; }) || frames[0];
        const R = frames.find(function (f) { return f !== L; });
        const ls = naturalSize(L), rs = naturalSize(R);
        const s = Math.min(W / (ls.w + rs.w), H / Math.max(ls.h, rs.h));
        const x0 = (W - (ls.w + rs.w) * s) / 2;
        place(L, x0, (H - ls.h * s) / 2, ls.w, ls.h, s);
        place(R, x0 + ls.w * s, (H - rs.h * s) / 2, rs.w, rs.h, s);
        return;
      }
      const f = frames[0];
      if (!f) { return; }
      const n = naturalSize(f);
      if (f.placement === "f") {
        const s = Math.min(W / n.w, H / n.h);
        place(f, (W - n.w * s) / 2, (H - n.h * s) / 2, n.w, n.h, s);
      } else {
        // A lone page of a two-page face sits on its half, against the spine (the center line).
        const s = Math.min((W / 2) / n.w, H / n.h);
        place(f, f.placement === "l" ? W / 2 - n.w * s : W / 2, (H - n.h * s) / 2, n.w, n.h, s);
      }
    }
    function toParent(frame, x, y) { return { x: frame.x + x * frame.scale, y: frame.y + y * frame.scale }; }
    // Frame viewport rects → wrapper coordinates. `clip` keeps only the part inside the frame's box (the other pages
    // of a vertical-writing document lie outside it).
    function mapRects(frame, rects, clip) {
      const out = [];
      const right = frame.x + frame.width * frame.scale, bottom = frame.y + frame.height * frame.scale;
      for (const r of rects || []) {
        let x = frame.x + r.x * frame.scale, y = frame.y + r.y * frame.scale;
        let x2 = x + r.width * frame.scale, y2 = y + r.height * frame.scale;
        if (clip) {
          x = Math.max(x, frame.x); y = Math.max(y, frame.y); x2 = Math.min(x2, right); y2 = Math.min(y2, bottom);
          if (x2 - x <= 0 || y2 - y <= 0) { continue; }
        }
        out.push({ x: x, y: y, width: x2 - x, height: y2 - y });
      }
      return out;
    }
    function withRects(frame, selection) {
      return { cfiRange: selection.cfiRange, text: selection.text, rects: mapRects(frame, selection.rects, kind === "vertical") };
    }
    function visibleFrames() { return frames.filter(function (f) { return f.bridge && !f.hidden; }); }

    // --- events from the frames ---
    function hostFor(frame) {
      return function (type, payload) {
        payload = payload || {};
        switch (type) {
          case "link":
            post("link", payload);
            break;
          case "noteref": {
            const out = Object.assign({}, payload);
            if (payload.rect) { out.rect = mapRects(frame, [payload.rect], false)[0] || null; }
            post("noteref", out);
            break;
          }
          case "imageTap": {
            const p = toParent(frame, payload.x || 0, payload.y || 0);
            const rect = payload.rect ? (mapRects(frame, [payload.rect], kind === "vertical")[0] || null) : null;
            post("imageTap", { src: payload.src, alt: payload.alt, rect: rect, x: p.x, y: p.y });
            break;
          }
          case "tap": {
            const p = toParent(frame, payload.x || 0, payload.y || 0);
            post("tap", { x: p.x, y: p.y, viewportWidth: sp.pageWidth, viewportHeight: sp.pageHeight });
            break;
          }
          case "highlightTap":
            post("highlightTap", { id: payload.id, rects: mapRects(frame, payload.rects, kind === "vertical") });
            break;
          case "selectionChanged": {
            // Each frame has its own selection; when one frame loses its selection another may still hold one.
            let selection = payload.selection ? withRects(frame, payload.selection) : null;
            if (!selection) {
              for (const other of frames) {
                if (other === frame || !other.bridge) { continue; }
                const s = other.bridge.currentSelection();
                if (s) { selection = withRects(other, s); break; }
              }
            }
            post("selectionChanged", { selection: selection });
            break;
          }
          case "pageCountChanged":
            if (kind === "vertical" && frame === frames[0]) {
              const before = sp.pageCount;
              sp.childPageCount = payload.pageCount || 1;
              sp.pageCount = Math.max(1, Math.ceil(sp.childPageCount / 2));
              if (sp.pageCount !== before && sp.readySent) { post("pageCountChanged", { pageCount: sp.pageCount }); }
            }
            break;
          default:
            break;
        }
      };
    }
    document.addEventListener("click", function (e) {
      // Outside every frame (the area around the pages).
      post("tap", { x: e.clientX, y: e.clientY, viewportWidth: sp.pageWidth, viewportHeight: sp.pageHeight });
    }, true);

    // --- the document API ---
    function applyWrapperParams(params) {
      if (!params) { return; }
      if (params.pageWidth) { sp.pageWidth = params.pageWidth; }
      if (params.pageHeight) { sp.pageHeight = params.pageHeight; }
      if (params.theme) {
        setVar("--reader-bg", params.theme.background);
        setVar("--reader-fg", params.theme.foreground);
        root().setAttribute("data-reader-theme", params.theme.isDark ? "dark" : "light");
      }
    }
    function childParams(frame, params) {
      const p = Object.assign({}, params || {});
      p.pageWidth = frame.width;
      p.pageHeight = frame.height;
      p.spineSteps = frame.stepsString;
      if (kind !== "vertical") {
        p.fixedLayout = true;
        p.margins = { horizontal: 0, vertical: 0 };
        // The page keeps the publisher's design (reader-fixed.css only): no settings style, no font override.
        delete p.rootStyle;
        delete p.fontFamily;
      } else {
        p.columnsPerPage = 1;
      }
      return p;
    }
    function layout(params) {
      applyWrapperParams(params);
      return ready.then(function () {
        layoutFrames();
        return Promise.all(frames.map(function (f) { return f.bridge ? f.bridge.layout(childParams(f, params)) : null; }));
      }).then(function (results) {
        if (kind === "vertical") {
          const r = results[0];
          sp.childPageCount = (r && r.pageCount) || 1;
          if (r && r.writingMode) { sp.writingMode = r.writingMode; }
          sp.pageCount = Math.max(1, Math.ceil(sp.childPageCount / 2));
        } else {
          sp.pageCount = 1;
        }
        return { pageCount: sp.pageCount, writingMode: sp.writingMode, columnsPerPage: 1 };
      });
    }
    function goToPage(index) {
      if (kind !== "vertical" || !frames[0] || !frames[0].bridge) {
        return { pageIndex: 0, slot: 0, pageCount: sp.pageCount, scrollLeft: 0, scrollTop: 0 };
      }
      const a = frames[0].bridge;
      const b = frames[1] ? frames[1].bridge : null;
      let r = a.goToPage(2 * Math.max(0, Math.floor(index || 0)));
      sp.childPageCount = r.pageCount;
      sp.pageCount = Math.max(1, Math.ceil(r.pageCount / 2));
      const i = Math.max(0, Math.min(Math.floor(index || 0), sp.pageCount - 1));
      if (r.pageIndex !== 2 * i) { r = a.goToPage(2 * i); }
      if (b) {
        if (2 * i + 1 < sp.childPageCount) { b.goToPage(2 * i + 1); setHidden(frames[1], false); }
        else { setHidden(frames[1], true); }
      }
      return { pageIndex: i, slot: 0, pageCount: sp.pageCount, scrollLeft: 0, scrollTop: 0 };
    }
    function pageForFragment(fragment) {
      if (kind === "vertical") {
        const p = frames[0] && frames[0].bridge ? frames[0].bridge.pageForFragment(fragment) : null;
        return p === null || p === undefined ? null : Math.floor(p / 2);
      }
      for (const f of frames) {
        if (f.bridge && f.bridge.pageForFragment(fragment) !== null) { return 0; }
      }
      return null;
    }
    function cfiForPage(index, margins) {
      if (kind === "vertical") {
        const i = Math.max(0, Math.min(Math.floor(index || 0), sp.pageCount - 1));
        const a = frames[0] && frames[0].bridge ? frames[0].bridge.cfiForPage(2 * i, margins) : null;
        if (a) { return a; }
        return frames[1] && frames[1].bridge && !frames[1].hidden ? frames[1].bridge.cfiForPage(2 * i + 1, margins) : null;
      }
      for (const f of frames) {
        const cfi = f.bridge ? f.bridge.cfiForPage(0, { horizontal: 0, vertical: 0 }) : null;
        if (cfi) { return cfi; }
      }
      return null;
    }
    function stepsMatch(a, b) {
      if (a.length !== b.length) { return false; }
      for (let k = 0; k < a.length; k++) {
        if (a[k].id && b[k].id) { if (a[k].id !== b[k].id) { return false; } }
        else if (a[k].index !== b[k].index) { return false; }
      }
      return true;
    }
    // The frame whose document a CFI addresses (by spine steps; a CFI without them goes to the first frame). null
    // for a CFI of a document that is not in the wrapper.
    function frameFor(cfiString) {
      const parsed = CFI.parse(cfiString);
      if (parsed && parsed[0].spineSteps.length) {
        const found = frames.find(function (f) { return f.bridge && stepsMatch(f.spineSteps, parsed[0].spineSteps); });
        if (found) { return found; }
        if (kind !== "vertical") { return null; }
      }
      return frames.find(function (f) { return f.bridge; }) || null;
    }
    function pageFor(cfiString) {
      const frame = frameFor(cfiString);
      if (!frame) { return null; }
      const p = frame.bridge.pageFor(cfiString);
      if (p === null || p === undefined) { return null; }
      return kind === "vertical" ? Math.floor(p / 2) : 0;
    }
    function rectsFor(cfiRange) {
      if (kind === "vertical") {
        let out = [];
        for (const f of visibleFrames()) { out = out.concat(mapRects(f, f.bridge.rectsFor(cfiRange), true)); }
        return out;
      }
      const frame = frameFor(cfiRange);
      return frame ? mapRects(frame, frame.bridge.rectsFor(cfiRange), false) : [];
    }
    function setHighlights(list) {
      list = list || [];
      let applied = [];
      for (const f of frames) {
        if (!f.bridge) { continue; }
        const mine = kind === "vertical" ? list : list.filter(function (item) { return frameFor(item.cfiRange) === f; });
        for (const id of f.bridge.setHighlights(mine)) { if (applied.indexOf(id) < 0) { applied.push(id); } }
      }
      return applied;
    }
    function setTransientHighlight(cfiRange) {
      let any = false;
      const target = cfiRange && kind !== "vertical" ? frameFor(cfiRange) : null;
      for (const f of frames) {
        if (!f.bridge) { continue; }
        const own = !cfiRange || kind === "vertical" || f === target;
        if (f.bridge.setTransientHighlight(own ? cfiRange : null) && own) { any = true; }
      }
      return any;
    }
    function currentSelection() {
      for (const f of frames) {
        const s = f.bridge ? f.bridge.currentSelection() : null;
        if (s) { return withRects(f, s); }
      }
      return null;
    }
    function clearSelection() {
      for (const f of frames) { if (f.bridge) { f.bridge.clearSelection(); } }
      return true;
    }

    window.__epubReader = {
      version: 1,
      isSpreadWrapper: true,
      kind: kind,
      layout: layout,
      goToPage: goToPage,
      pageForFragment: pageForFragment,
      applySettings: layout,
      cfiForPage: cfiForPage,
      pageFor: pageFor,
      rectsFor: rectsFor,
      setHighlights: setHighlights,
      setTransientHighlight: setTransientHighlight,
      currentSelection: currentSelection,
      clearSelection: clearSelection,
      cfi: CFI,
      pageCount: function () { return sp.pageCount; },
      // Tests / diagnostics: where the frames are.
      frameInfo: function () {
        return frames.map(function (f) {
          return { spineIndex: f.spineIndex, placement: f.placement, x: f.x, y: f.y, width: f.width, height: f.height, scale: f.scale, hidden: f.hidden, hasBridge: !!f.bridge };
        });
      },
    };

    ready.then(function (mode) {
      sp.readySent = true;
      post("ready", { writingMode: mode, readyState: document.readyState, href: location.href });
    });
  }

  if (root().hasAttribute("data-reader-spread")) {
    installSpreadController();
    return;
  }

  // --- notes (M5) ----------------------------------------------------------------------------------
  // Footnote / endnote / rearnote asides that a noteref in this document points at are read in a popup, so they
  // are taken out of the page flow (`data-reader-note`, display: none in reader-before.css). Notes that nothing
  // here refers to (a separate notes document, notes reached only by plain links) stay visible. The DOM itself is
  // unchanged, so CFIs are not affected.
  function hideReferencedNotes() {
    const NOTE_TYPES = ["footnote", "endnote", "rearnote"];
    const anchors = document.querySelectorAll("a[href], a[*|href]");
    for (let k = 0; k < anchors.length; k++) {
      const a = anchors[k];
      if (!hasEpubType(a, "noteref")) { continue; }
      const target = sameDocumentTarget(resolveHref(a) || "");
      const aside = target && target.closest ? target.closest("aside") : null;
      if (aside && NOTE_TYPES.some(function (t) { return hasEpubType(aside, t); })) {
        aside.setAttribute("data-reader-note", "hidden");
      }
    }
  }
  try { hideReferencedNotes(); } catch (e) { /* never block the document on this */ }

  // --- selection ----------------------------------------------------------------------------------

  function selectionPayload() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) { return null; }
    const range = selection.getRangeAt(0);
    const text = selection.toString();
    if (!text || text.trim().length === 0) { return null; }
    const cfiRange = CFI.fromRange(range);
    if (!cfiRange) { return null; }
    return { cfiRange: cfiRange, text: text, rects: rectList(range.getClientRects()) };
  }

  function currentSelection() { return selectionPayload(); }

  function clearSelection() {
    const selection = window.getSelection();
    if (selection) { selection.removeAllRanges(); }
    return true;
  }

  let selectionTimer = null;
  document.addEventListener("selectionchange", function () {
    if (selectionTimer) { clearTimeout(selectionTimer); }
    selectionTimer = setTimeout(function () {
      selectionTimer = null;
      post("selectionChanged", { selection: selectionPayload() });
    }, 120);
  });

  // --- events -----------------------------------------------------------------------------------

  // `href` (HTML) or `xlink:href` / `href` (SVG `a` and `image`), resolved against the document.
  function resolveHref(el) {
    let raw = el.getAttribute("href");
    if (raw === null) { raw = el.getAttributeNS(XLINK_NS, "href"); }
    if (raw === null && el.href && typeof el.href === "object" && el.href.baseVal !== undefined) { raw = el.href.baseVal; }
    if (raw === null || raw === undefined) { return null; }
    try { return new URL(raw, document.baseURI).href; } catch (e) { return raw; }
  }

  // The client rect of `el` under the point (an inline link can wrap onto several lines), else its bounding box.
  function rectAt(el, x, y) {
    const rects = el.getClientRects();
    for (let k = 0; k < rects.length; k++) {
      const r = rects[k];
      if (x >= r.left - 1 && x <= r.right + 1 && y >= r.top - 1 && y <= r.bottom + 1) { return r; }
    }
    return rects.length ? rects[0] : el.getBoundingClientRect();
  }
  function rectObject(r) { return { x: r.left, y: r.top, width: r.width, height: r.height }; }

  // Element of this document a same-document URL's fragment names, or null (another document, no fragment).
  function sameDocumentTarget(href) {
    let url;
    try { url = new URL(href); } catch (e) { return null; }
    if (url.origin !== location.origin || url.pathname !== location.pathname || !url.hash) { return null; }
    let id = url.hash.slice(1);
    try { id = decodeURIComponent(id); } catch (e) { /* keep raw */ }
    return document.getElementById(id);
  }

  // The element whose content a note popup shows: the note itself, or the block around an inline anchor that only
  // marks where the note starts (`<p><a id="fn1"/>1. Text</p>`).
  function noteElement(target) {
    if (!target) { return null; }
    const inline = /^(a|span|sup|sub|b|i|em|strong|small)$/i;
    if (inline.test(target.localName)) {
      const block = target.parentElement && target.parentElement.closest("aside, li, p, dd, dt, div, section, blockquote, td");
      if (block && block !== document.body) { return block; }
    }
    return target;
  }

  // noteref click (02-rendering §4.2, M5): the note's markup and text when it is in this document.
  function noteref(a, href, x, y) {
    const payload = { href: href, rect: rectObject(rectAt(a, x, y)), sameDocument: false };
    const target = sameDocumentTarget(href);
    if (target) {
      const note = noteElement(target);
      payload.sameDocument = true;
      payload.html = note.innerHTML;
      payload.text = (note.textContent || "").replace(/\s+/g, " ").trim();
      payload.cfi = CFI.fromNode(note, null);
      // Not laid out (the aside hideReferencedNotes took out of the flow, or the publication's own `display: none`):
      // there is no place on a page to go to, the note can only be read from this message.
      payload.hidden = note.getClientRects().length === 0;
    }
    post("noteref", payload);
  }

  // img / SVG image tap (M5). Not on a fixed-layout page: the picture is the page, and taps there turn pages.
  function imageTap(img, x, y) {
    let src = null;
    if (img.localName === "img") { src = img.currentSrc || img.src || resolveHref(img); }
    else { src = resolveHref(img); }
    if (!src) { return false; }
    let alt = img.getAttribute("alt");
    if (!alt) { alt = img.getAttribute("aria-label"); }
    if (!alt) {
      const svg = img.closest("svg");
      const title = svg && svg.querySelector("title");
      if (title) { alt = (title.textContent || "").trim(); }
    }
    post("imageTap", { src: src, alt: alt || null, rect: rectObject(img.getBoundingClientRect()), x: x, y: y });
    return true;
  }

  document.addEventListener("click", function (e) {
    const target = e.target;
    const a = target && target.closest ? target.closest("a[href], a[*|href]") : null;
    if (a) {
      e.preventDefault();
      e.stopPropagation();
      const href = resolveHref(a);
      if (href) {
        if (hasEpubType(a, "noteref")) { noteref(a, href, e.clientX, e.clientY); }
        else { post("link", { href: href, isExternal: !/^(epub|about|data|blob):/i.test(href) }); }
      }
      return;
    }
    const img = target && target.closest && !state.fixedLayout ? target.closest("img, image") : null;
    if (img && imageTap(img, e.clientX, e.clientY)) { return; }
    const highlight = highlightAt(e.clientX, e.clientY);
    if (highlight) {
      post("highlightTap", { id: highlight.id, rects: rectList(highlight.range.getClientRects()) });
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
      applyExtent();
      drawOverlay();
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

  const readyPromise = Promise.all([whenLoaded(), fontsReady]).then(function () {
    state.readySent = true;
    watchForChanges();
    const writingMode = detectWritingMode();
    // href lets Swift drop a `ready` from a document that was replaced by a newer load before it finished.
    // A framed document does not post: the spread wrapper waits for `whenReady` instead.
    if (!framed) { post("ready", { writingMode: writingMode, readyState: document.readyState, href: location.href }); }
    return { writingMode: writingMode };
  });

  window.__epubReader = {
    version: 1,
    layout: layout,
    goToPage: goToPage,
    pageForFragment: pageForFragment,
    applySettings: applySettings,
    cfiForPage: cfiForPage,
    pageFor: pageFor,
    rectsFor: rectsFor,
    setHighlights: setHighlights,
    setTransientHighlight: setTransientHighlight,
    currentSelection: currentSelection,
    clearSelection: clearSelection,
    cfi: CFI,
    pageCount: function () { return state.pageCount; },
    // Spread wrapper support (M4): the wrapper installs itself as the host of a framed document's events and waits
    // for the document to be ready.
    setHost: setHost,
    whenReady: function () { return readyPromise; },
    isFramed: framed,
  };
})();
