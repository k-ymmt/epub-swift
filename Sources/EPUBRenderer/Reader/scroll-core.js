// EPUB-Swift scroll-core.js
// The rules of the scrolled layout that need no DOM (docs/design/08-continuous-scroll.md §5): which chapter joins or
// leaves the window, how a correction is split between the runway and the negative margin, what the runway and the
// tail should be, how a frame is fitted to its content, where a page / line step lands. `reader.js` (the scroll
// controller) calls them with numbers it measured; the tests call them in JavaScriptCore without a web view
// (Tests/EPUBRendererTests/ScrollCoreTests.swift). Injected before reader.js, in the same content world.
(function (global) {
  "use strict";
  if (global.__epubScrollCore) { return; }

  // A chapter joins when the window ends closer than this many pages to the viewport (§5.1).
  const LOOKAHEAD_PAGES = 2;
  // A chapter leaves, at rest, when it is further than this many pages from the viewport (§5.1).
  const FAR_PAGES = 8;
  // The window never keeps more chapters than this, also while scrolling (§5.1).
  const WINDOW_LIMIT = 24;
  // A frame whose content grows again right after being fitted, this many times in a row, depends on its own
  // height (`100vh`): its height is pinned to the first one (§4.2).
  const VIEWPORT_DEPENDENT_GROWS = 3;

  // The space above the first chapter of the window is `pad - neg`: the runway's height, or, when a correction
  // needs more than the runway has, the stage's negative top margin (§5.4).
  function splitUpper(upper) {
    return { pad: Math.max(0, upper), neg: Math.max(0, -upper) };
  }

  // The layout moved the text at the reading line down by `d` px in the document (negative: up). The same distance
  // comes out of the space above, so the text is where it was without the scroll position being written (§5.3).
  function correction(pad, neg, d) {
    return splitUpper((pad - neg) - d);
  }

  function sum(heights, from, to) {
    let total = 0;
    for (let k = Math.max(0, from); k < Math.min(heights.length, to); k++) { total += Math.max(0, heights[k] || 0); }
    return total;
  }

  // The space above and the space below the window are each at most this tall. The engine cannot lay out a document
  // taller than 2^25 px (33,554,432; measured: 30,000,000 px works, at 40,000,000 the settlement never arrives), and
  // a long book at a large font size is taller than that. The spaces only have to absorb what changes between two
  // rests (the chapters that join the window), which is far less; the scroll position is not a position in the book
  // (there is no scroll indicator, and every position is a chapter and an offset in it).
  const MAX_SPACE = 8000000;

  // The runway is as tall as the chapters before the window (§5.2), up to MAX_SPACE. `heights` is by spine position.
  function runwayTarget(heights, firstPos) {
    return Math.min(MAX_SPACE, sum(heights, 0, firstPos));
  }

  // The tail is as tall as the chapters after the window (up to MAX_SPACE), and gone once the last chapter is in
  // the window (§5.2).
  function tailTarget(heights, lastPos) {
    if (lastPos >= heights.length - 1) { return 0; }
    return Math.min(MAX_SPACE, sum(heights, lastPos + 1, heights.length));
  }

  // Whether the space above differs from what it should be (§5.4). The settlement itself sets `pad` to the target
  // and `neg` to 0, then moves the scroll position by as much as that moved the text in the viewport.
  function settlement(pad, neg, target) {
    return { needed: Math.abs(pad - target) >= 0.5 || neg !== 0, pad: target, neg: 0 };
  }

  // The scroll position that puts the text back where it was: `before` / `after` are the text's positions in the
  // viewport before and after the space above changed (after the layout, so a clamp at the document's end is
  // already in `scrollY` and `after`).
  function settledScrollTop(scrollY, before, after, maxScroll) {
    return Math.min(Math.max(0, scrollY + (after - before)), Math.max(0, maxScroll));
  }

  // Which end of the window gets a chapter (§5.1). `above` is the distance from the top of the viewport up to the
  // window's first chapter, `below` from the bottom of the viewport down to the end of its last one. A chapter joins
  // when that distance is under two pages, and always next to a chapter that is in the viewport (`firstVisible` /
  // `lastVisible`: the window holds the visible chapters and one more on each side, however long they are). One
  // chapter at a time: nothing while one is loading.
  function windowAction(input) {
    if (input.busy) { return null; }
    const near = LOOKAHEAD_PAGES * Math.max(1, input.pageHeight);
    const up = !!input.hasPrevious && (input.above < near || !!input.firstVisible);
    const down = !!input.hasNext && (input.below < near || !!input.lastVisible);
    if (up && down) { return input.above < input.below ? "prepend" : "append"; }
    if (up) { return "prepend"; }
    if (down) { return "append"; }
    return null;
  }

  // The chapters to take out of the window (§5.1, §12), as spine positions, in the order to remove them.
  // `views`: the window in order, each `{pos, top, bottom, keep}` with `top` / `bottom` in viewport coordinates and
  // `keep` for a chapter that must stay (it holds the selection, or it is still loading). A chapter in the viewport
  // and its two neighbours always stay, so the window stays one run of chapters: only its ends are removed.
  // - at rest (and without `holdFar`: VoiceOver is running), the chapters further than 8 pages away go;
  // - at any time, the furthest ones go until at most 24 are left;
  // - `trim` (a memory warning): everything that is not protected goes.
  function removals(input) {
    const views = input.views || [];
    const n = views.length;
    if (n === 0) { return []; }
    const height = input.viewportHeight;
    const page = Math.max(1, input.pageHeight);
    const limit = input.limit || WINDOW_LIMIT;
    function distance(v) { return v.bottom <= 0 ? -v.bottom : (v.top >= height ? v.top - height : 0); }
    const visible = views.map(function (v) { return v.bottom > 0 && v.top < height; });
    if (!visible.some(function (x) { return x; })) {
      // The viewport ran past the window (§5.5): the chapter nearest to it is the one to grow from.
      let nearest = 0;
      for (let k = 1; k < n; k++) { if (distance(views[k]) < distance(views[nearest])) { nearest = k; } }
      visible[nearest] = true;
    }
    const keep = views.map(function (v, k) {
      return !!v.keep || visible[k] || (k > 0 && visible[k - 1]) || (k < n - 1 && visible[k + 1]);
    });
    const out = [];
    let lo = 0, hi = n - 1;
    const far = input.trim ? 0 : FAR_PAGES * page;
    if (input.trim || (input.atRest && !input.holdFar)) {
      while (lo < hi && !keep[lo] && distance(views[lo]) > far) { out.push(views[lo].pos); lo++; }
      while (hi > lo && !keep[hi] && distance(views[hi]) > far) { out.push(views[hi].pos); hi--; }
    }
    while (hi - lo + 1 > limit) {
      const a = keep[lo] ? -1 : distance(views[lo]);
      const b = keep[hi] ? -1 : distance(views[hi]);
      if (a < 0 && b < 0) { break; }   // more chapters in the viewport than the limit: they stay
      if (a >= b) { out.push(views[lo].pos); lo++; } else { out.push(views[hi].pos); hi--; }
    }
    return out;
  }

  // Whether a chapter may join at `where` ("prepend" / "append") a window that is full (§5.1). With chapters much
  // shorter than a page the two-page lookahead wants more chapters than the limit allows: the chapter that joins at
  // one end would be the furthest one and leave again at once, be wanted again, and so on without the reader doing
  // anything. So at the limit a chapter joins only when the limit then takes the chapter at the other end.
  // `views` / `viewportHeight` / `pageHeight` / `limit` as for `removals`.
  function admits(input) {
    const views = input.views || [];
    const limit = input.limit || WINDOW_LIMIT;
    if (views.length < limit) { return true; }
    const first = views[0], last = views[views.length - 1];
    // Only the edge next to the window matters for how far the new chapter is: its height is not known yet.
    const added = input.where === "prepend"
      ? { pos: first.pos - 1, top: first.top - 1, bottom: first.top, keep: false }
      : { pos: last.pos + 1, top: last.bottom, bottom: last.bottom + 1, keep: false };
    const next = input.where === "prepend" ? [added].concat(views) : views.concat([added]);
    const out = removals({ views: next, viewportHeight: input.viewportHeight, pageHeight: input.pageHeight, atRest: false, limit: limit });
    return out.indexOf(added.pos) < 0;
  }

  // Makes a chapter's frame as tall as its content (§4.2). `measure()` is the content's height with the frame as
  // it is now; `apply(h)` sets the frame's height. Content sized in viewport units grows every time its frame is
  // fitted: after three such steps in a row the frame is pinned to `first` (the content's height when the frame was
  // one page tall). Returns `{height, fixed}`.
  function fit(frameHeight, first, measure, apply) {
    let current = frameHeight;
    let h = measure();
    let grows = 0;
    let steps = 0;
    while (h !== current) {
      apply(h);
      current = h;
      const next = measure();
      if (next > current) {
        grows += 1;
        if (grows >= VIEWPORT_DEPENDENT_GROWS) {
          apply(first);
          return { height: first, fixed: true };
        }
      } else {
        grows = 0;
      }
      h = next;
      steps += 1;
      if (steps > 16) { break; }   // a content that keeps changing its mind: leave the frame where it is
    }
    return { height: current, fixed: false };
  }

  // Where a step of whole pages or of lines ends (§8.2). A page step is one page minus one line of text, so the
  // last line read stays on screen; both stop at the ends of the document. A step is a whole number of pixels, the
  // same forward and backward: the scroll position is one, so a step forward and a step back end where they began.
  function scrollTarget(input) {
    const line = Math.max(1, input.lineHeight || 0);
    let delta = 0;
    if (input.pages) { delta = input.pages * Math.round(Math.max(line, input.pageHeight - line)); }
    else if (input.lines) { delta = (input.lines < 0 ? -1 : 1) * Math.round(Math.abs(input.lines) * line); }
    const from = input.from === undefined || input.from === null ? input.scrollY : input.from;
    const top = Math.min(Math.max(0, from + delta), Math.max(0, input.maxScroll));
    return { top: top, moved: Math.abs(top - input.scrollY) >= 0.5 };
  }

  global.__epubScrollCore = {
    LOOKAHEAD_PAGES: LOOKAHEAD_PAGES,
    FAR_PAGES: FAR_PAGES,
    WINDOW_LIMIT: WINDOW_LIMIT,
    splitUpper: splitUpper,
    correction: correction,
    maxSpace: MAX_SPACE,
    runwayTarget: runwayTarget,
    tailTarget: tailTarget,
    settlement: settlement,
    settledScrollTop: settledScrollTop,
    windowAction: windowAction,
    removals: removals,
    admits: admits,
    fit: fit,
    scrollTarget: scrollTarget,
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
