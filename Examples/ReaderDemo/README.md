# ReaderDemo

Minimal SwiftUI app for trying EPUB-Swift by hand (docs/design/04-roadmap.md M1 §7, M2 §8). It bundles the IDPF
`moby-dick`, `childrens-literature` and `kusamakura-japanese-vertical-writing` (vertical writing, right-to-left)
samples, can open any `.epub` with the folder button, and has a settings sheet (font, size, line height, margins,
theme), a table of contents, a "Go to page" prompt (book-wide page numbers from `BookPagination`), and a Debug
menu with "Jump to last chapter" and "Read through to the end" (turns every page programmatically and reports
chapters, pages, time and errors in the status bar). The status bar's second line shows the book-wide page
number and total: `≈` and "estimating" until the pre-pagination service has measured every chapter.

```bash
scripts/run-macos.sh   # swift build + .app bundle + open
scripts/run-ios.sh     # xcodebuild for the booted iOS Simulator + install + launch (UDID=... to pick one)
```

`swift run` also works on macOS (the process then has no bundle identifier).
