# EPUB-Swift

An EPUB 3 reader library for iOS 27+ and macOS 27+, written in Swift 6 with strict concurrency.

WKWebView renders the content. The library handles everything else:

- Container parsing: ZIP, OPF, nav, and font de-obfuscation.
- Positions as EPUB CFI.
- Pagination for horizontal and vertical writing, right-to-left books, fixed layout, and two-page spreads.
- Highlights, full-text search, footnote popups, and image taps.
- A SwiftUI reader view with page-turn transitions, gestures, keyboard and trackpad input.

It depends on Apple frameworks only (Foundation, Compression, CryptoKit, WebKit, libxml2). EPUB 2 (NCX, OPF 2.0) is not supported.

## Installation

Add the package with Swift Package Manager and depend on the `EPUB` product.

```swift
// Package.swift
dependencies: [
    .package(url: "<repository URL>", branch: "main"),
    // or, for a local checkout: .package(path: "../epub-swift"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "EPUB", package: "EPUB-Swift")]),
]
```

In Xcode, use File > Add Package Dependencies… and choose the `EPUB` library.

`EPUB` re-exports three modules, which can also be used on their own:

| Module | Contents | Imports |
|---|---|---|
| `EPUBCore` | Container, OPF / nav, CFI, text extraction, search | Foundation, Compression, CryptoKit, libxml2 |
| `EPUBRenderer` | `ReaderSession`, settings, events, pagination | + WebKit |
| `EPUBUI` | `EPUBReaderView`, page transitions, gestures | + SwiftUI |

## Minimal usage

```swift
import SwiftUI
import EPUB

struct BookScreen: View {
    let fileURL: URL
    @State private var session: ReaderSession?
    @State private var note: NoteContent?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let session {
                EPUBReaderView(session: session)
                    .pageTransition(.slide)
                    .onReaderEvent { event in
                        switch event {
                        case .positionChanged(let position):
                            save(position)                       // ReadingPosition is Codable; its CFI is the position
                        case .noteref(let content):
                            note = content                       // show content.text / content.html in a popover
                        case .externalLink(let url):
                            openURL(url)                         // the reader never leaves the book by itself
                        default:
                            break
                        }
                    }
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                let container = try await EPUBContainer(url: fileURL)
                let session = ReaderSession(container: container, settings: ReaderSettings())
                self.session = session
                if let last = loadSavedPosition() { await session.go(to: last) }
            } catch {
                // not an EPUB 3 file, or the container is damaged
            }
        }
    }

    private func save(_ position: ReadingPosition) { /* persist */ }
    private func loadSavedPosition() -> ReadingPosition? { nil }
}
```

Common next steps:

- Navigation: `session.goForward()`, `goBackward()`, `go(to: TOCEntry)`, `go(to: CFI)`, and `go(toPage:)`. The book-wide
  page numbers come from `session.pagination`.
- Appearance: change `session.settings` (font scale, line height, margins, theme, spread policy). The current position
  is kept across the relayout.
- Highlights: set `session.highlights` to `[Highlight]`. Add a text menu with `.selectionActions([SelectionAction(...)])`.
- Search: iterate `session.search("query")`, then call `session.show(result)`.
- Images: `.imageTapped(TappedImage)` carries the image bytes through `try await image.data()`.
- Gestures: `.readerGestures(.disabled)` turns off built-in tap, swipe and keyboard handling, so the app drives the
  session itself.

The complete example is `Examples/ReaderDemo`, a SwiftUI app for iOS and macOS. It shows the table of contents,
search, highlights, settings, footnote popovers, an image viewer and link handling.

```bash
cd Examples/ReaderDemo && scripts/run-macos.sh
```

```bash
cd Examples/ReaderDemo && scripts/run-ios.sh
```

## Development

```bash
swift build
```

```bash
swift test
```

Renderer tests drive a real WKWebView and run on macOS.

The design documents are in `docs/design/`, written in Japanese:

- `00-overview.md`
- `01-core.md`
- `02-rendering.md`
- `03-api.md`
- `04-roadmap.md`
- `05-spike-results.md`

Known gaps and follow-ups are listed in `TODO.md`.

## Test fixtures

`Tests/Fixtures` holds samples from [IDPF epub3-samples](https://github.com/IDPF/epub3-samples) under their own
licenses (see `Tests/Fixtures/LICENSES.md`), plus small hand-written books for CFI vectors and links.
