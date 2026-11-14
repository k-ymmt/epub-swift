# EPUB-Swift

A WebView-based EPUB 3 viewer library for iOS 26+ and macOS 26+, written in Swift 6 with strict concurrency.
Rendering is delegated to WKWebView; the library owns container parsing, EPUB CFI positions, full-text search,
pagination bookkeeping, and SwiftUI integration.

## Design documents

Read `docs/design/` before changing architecture. The documents are written in Japanese.

- `00-overview.md`: goals, decisions, non-goals, target layering
- `01-core.md`: EPUBCore (ZIP, OPF, nav, font obfuscation, CFI, search)
- `02-rendering.md`: EPUBRenderer (WKWebView, URL scheme, CSS injection, JS bridge, pagination, snapshots)
- `03-api.md`: public API
- `04-roadmap.md`: milestones, spikes, test plan
- `05-spike-results.md`: results of the pre-M1 spikes (what held, what did not, and the design changes made)
- `06-annotations.md`: highlights and bookmarks as EPUB Annotations 1.0 (M6)
- `07-continuous-scroll-spike.md`: measurements for the scrolled layout (the spike, and §4 the product code after S1)
- `08-continuous-scroll.md`: the scrolled layout (continuous vertical scroll): design, milestones S1–S4, what S1
  implemented and where it departs from the design (§16)

## Layout

Planned targets (M1 splits the current single `EPUB` target):

- `Sources/EPUBCore`: Foundation / Compression / libxml2 only. No UI, no WebKit.
- `Sources/EPUBRenderer`: WebKit. No SwiftUI.
- `Sources/EPUBUI`: SwiftUI views, gestures, page transitions.
- `Sources/EPUB`: umbrella module re-exporting the three above.
- `Tests/Fixtures`: IDPF epub3-samples used by tests (see `04-roadmap.md` §3).
- `Spikes/`: standalone package with the pre-M1 verification spikes and their outputs. Not part of the root package.

## Commands

```bash
swift build
swift test
```

Run `swift test` before every commit. Renderer tests use a real WKWebView and run on macOS.

## Rules

- Dependencies: Apple frameworks only (Foundation, Compression, CryptoKit, WebKit, libxml2). Do not add SwiftPM dependencies.
- libxml2 comes from the SDK module (`import libxml2`). Do not add a system library target for it.
- Malformed XHTML is best effort: repair in EPUBCore and serve as `application/xhtml+xml`; never serve `text/html` to align DOMs with libxml2 (see `05-spike-results.md` §2.5).
- EPUB 3 only. Do not add EPUB 2 (NCX, OPF 2.0) code paths.
- Content JavaScript stays disabled (`allowsContentJavaScript = false`). Only the bundled scripts run (`reader.js`, and
  `scroll-core.js` before it in the scrolled layout's wrapper), in their own `WKContentWorld`.
- Scrolled layout: the page writes the scroll position only at rest (no finger, no momentum, no program scroll). A
  layout change above the reading line is corrected through the height of the runway, never with `scrollBy` /
  `scrollTo` (`08-continuous-scroll.md` §5.3, §5.6). Arithmetic that needs no WebView goes into `scroll-core.js` and
  is tested in `ScrollCoreTests`.
- Position-stability tests (`ScrollStabilityTests`) read the pixels from the window server, not from
  `WKWebView.takeSnapshot`: on macOS that snapshot forces a layout and can show a state no frame shows
  (`07-continuous-scroll-spike.md` §4.2). A trial that finds the page hidden or gets no frames must fail.
- Positions are EPUB CFI strings. Do not introduce a second position format. The one exception is the EPUB Annotations
  exchange selectors (CssSelector, TextPositionSelector, TextQuoteSelector, FragmentSelector): they are generated from and
  resolved to CFIs at import/export, and imported originals are only kept for lossless round trips (`06-annotations.md` §2.1).
- EPUBCore must not import WebKit, UIKit, AppKit, or SwiftUI. Keep it testable with `swift test` without a WebView.
- Public API must not expose WebKit types. (`@_spi(Diagnostics)` in `ReaderSession+Diagnostics.swift` hands the web
  view to ReaderDemo's recording mode and to tests; apps do not import it.)
- Documents under `docs/` are written in Japanese. This file is written in English.
- Commit messages include the task context that led to the change.
