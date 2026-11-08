# EPUB-Swift

A WebView-based EPUB 3 viewer library for iOS 27+ and macOS 27+, written in Swift 6 with strict concurrency.
Rendering is delegated to WKWebView; the library owns container parsing, EPUB CFI positions, full-text search,
pagination bookkeeping, and SwiftUI integration.

## Design documents

Read `docs/design/` before changing architecture. The documents are written in Japanese.

- `00-overview.md`: goals, decisions, non-goals, target layering
- `01-core.md`: EPUBCore (ZIP, OPF, nav, font obfuscation, CFI, search)
- `02-rendering.md`: EPUBRenderer (WKWebView, URL scheme, CSS injection, JS bridge, pagination, snapshots)
- `03-api.md`: public API
- `04-roadmap.md`: milestones, spikes, test plan

## Layout

Planned targets (M1 splits the current single `EPUB` target):

- `Sources/EPUBCore`: Foundation / Compression / libxml2 only. No UI, no WebKit.
- `Sources/EPUBRenderer`: WebKit. No SwiftUI.
- `Sources/EPUBUI`: SwiftUI views, gestures, page transitions.
- `Sources/EPUB`: umbrella module re-exporting the three above.
- `Tests/Fixtures`: IDPF epub3-samples used by tests (see `04-roadmap.md` §3).

## Commands

```bash
swift build
swift test
```

Run `swift test` before every commit. Renderer tests use a real WKWebView and run on macOS.

## Rules

- Dependencies: Apple frameworks only (Foundation, Compression, CryptoKit, WebKit, libxml2). Do not add SwiftPM dependencies.
- EPUB 3 only. Do not add EPUB 2 (NCX, OPF 2.0) code paths.
- Content JavaScript stays disabled (`allowsContentJavaScript = false`). Only the bundled `reader.js` runs, in its own `WKContentWorld`.
- Positions are EPUB CFI strings. Do not introduce a second position format.
- EPUBCore must not import WebKit, UIKit, AppKit, or SwiftUI. Keep it testable with `swift test` without a WebView.
- Public API must not expose WebKit types.
- Documents under `docs/` are written in Japanese. This file is written in English.
- Commit messages include the task context that led to the change.
