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
//   highlightTap {id, rects}        click/tap inside a highlight set with setHighlights
//   tap {x, y}                      click/tap on anything that is not a link (viewport coordinates)
//   selectionChanged {cfiRange, text, rects} | null   the selection changed (debounced)
// Positions are EPUB CFI strings; the CFI module below mirrors EPUBCore (docs/design/01-core.md §5).
(function () {
  "use strict";
  if (window.__epubReader) { return; }

  const SENTINEL_ID = "__reader_end";
  const state = {
    pageWidth: 0,
    pageHeight: 0,
    pageCount: 1,
    writingMode: "horizontal-tb",
    readySent: false,
    // Spine steps of this document ("/6/14[xchapter_001]"), set by `layout`; prefixed to every generated CFI.
    spineSteps: [],
    // [{id, range}] of the highlights currently drawn, for hit testing.
    highlights: [],
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
    return wm;
  }

  function isVertical() { return state.writingMode.indexOf("vertical") === 0 || state.writingMode.indexOf("sideways") === 0; }

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
    if (params && typeof params.spineSteps === "string") {
      const parsed = CFI.parse("epubcfi(" + params.spineSteps + "!/2)");
      state.spineSteps = parsed ? parsed[0].spineSteps : [];
    }
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
    // nearest text position so the point is a text location when possible.
    function boundaryToPoint(container, offset) {
      let node = container, off = offset;
      if (!isText(node)) {
        const children = node.childNodes;
        if (off < children.length) {
          let child = children[off];
          // Descend to the first text in the child, else use the element itself.
          const first = firstTextIn(child);
          if (first) { node = first; off = 0; }
          else if (child.nodeType === Node.ELEMENT_NODE) { node = child; off = null; }
          else { return null; }
        } else if (children.length) {
          const last = lastTextIn(node);
          if (last) { node = last; off = last.data.length; }
          else { node = node; off = null; }
        } else {
          off = null;
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
            if (el && el !== document.body && el !== root() && el.id !== SENTINEL_ID) { fallbackElement = el; }
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

  // Draws [{id, cfiRange, color, style: "background" | "underline"}]. Replaces the previous set. Returns the ids
  // whose range resolved.
  function setHighlights(list) {
    if (typeof CSS === "undefined" || !CSS.highlights) { return []; }
    for (const key of Array.from(CSS.highlights.keys())) {
      if (key.indexOf(HIGHLIGHT_PREFIX) === 0) { CSS.highlights.delete(key); }
    }
    state.highlights = [];
    const rules = [];
    const applied = [];
    for (const item of list || []) {
      const range = CFI.toRange(item.cfiRange);
      if (!range || range.collapsed) { continue; }
      const key = cssIdent(item.id);
      CSS.highlights.set(key, new Highlight(range));
      if (item.style === "underline") {
        rules.push("::highlight(" + key + ") { text-decoration: underline; text-decoration-color: " + item.color + "; text-decoration-thickness: 2px; text-underline-offset: 2px; }");
      } else {
        rules.push("::highlight(" + key + ") { background-color: " + item.color + "; }");
      }
      state.highlights.push({ id: item.id, range: range });
      applied.push(item.id);
    }
    highlightStyleElement().textContent = rules.join("\n");
    return applied;
  }

  // A single temporary highlight (search result). null removes it. Styled by reader-before.css.
  function setTransientHighlight(cfiRange) {
    if (typeof CSS === "undefined" || !CSS.highlights) { return false; }
    CSS.highlights.delete(TRANSIENT_KEY);
    if (!cfiRange) { return true; }
    const range = CFI.toRange(cfiRange);
    if (!range || range.collapsed) { return false; }
    CSS.highlights.set(TRANSIENT_KEY, new Highlight(range));
    return true;
  }

  function highlightAt(x, y) {
    for (const h of state.highlights) {
      const rects = h.range.getClientRects();
      for (let k = 0; k < rects.length; k++) {
        const r = rects[k];
        if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) { return h; }
      }
    }
    return null;
  }

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
  };

  Promise.all([whenLoaded(), fontsReady]).then(function () {
    state.readySent = true;
    watchForChanges();
    // href lets Swift drop a `ready` from a document that was replaced by a newer load before it finished.
    post("ready", { writingMode: detectWritingMode(), readyState: document.readyState, href: location.href });
  });
})();
