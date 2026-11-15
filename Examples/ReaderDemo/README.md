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

## Scrolled layout

The settings sheet has a "Layout" picker (Pages / Scroll) and, for Scroll, a "Text width" slider (em). The status
bar shows `scroll <spine indices on screen>` while a book is in the scrolled layout, and `scrolling <…>` in the
tint colour while the reader's own scrolling is under way (`ReaderSession.isScrolling`: a finger and its momentum,
a trackpad, a wheel, the ↑ ↓ keys; not jumps or the steps of one screen). The note popover closes when that
scrolling begins (docs/design/08-continuous-scroll.md).

### Recording mode

Recording mode writes what the reader showed while somebody scrolled, for `Spikes/scripts/analyse-fling.py`
(08 §13): per sample the scroll position, whether the reader's hands were on the document, and how far the
picture moved since the previous sample (measured from the pixels of a 400 pt wide column), plus the scroll
controller's log (chapters added and removed, heights, corrections taken out of the runway, settlements).

- By hand: open a book in the scrolled layout, Debug menu, "Record scrolling for 20 s", and scroll. On macOS
  "Record 20 s of trackpad flings" scrolls by itself with synthesized trackpad events.
- From the shell, with environment variables (on the Simulator prefix each with `SIMCTL_CHILD_`):

  | Variable | Meaning |
  |---|---|
  | `READERDEMO_BOOK` | a bundled sample (`moby-dick`, …) to open at launch |
  | `READERDEMO_LAYOUT` | `scrolled` or `paged` |
  | `READERDEMO_START` | spine index to jump to after opening |
  | `READERDEMO_RECORD` | seconds to record, starting once the book is open |
  | `READERDEMO_FLING` | `1`: macOS scrolls by itself during the recording |
  | `READERDEMO_RECORD_DIR` | where the file goes (default: the app's Documents) |
  | `READERDEMO_RECORD_FRAMES` | `1`: also saves the pictures around samples that do not match their scroll, in `frames/` |
  | `READERDEMO_FLOAT` | `1`: macOS keeps the window above other apps' windows |
  | `READERDEMO_HEIGHTS` | `1`: runs the height check (below) once the book is open |

```bash
SIMCTL_CHILD_READERDEMO_BOOK=moby-dick SIMCTL_CHILD_READERDEMO_LAYOUT=scrolled SIMCTL_CHILD_READERDEMO_START=40 \
  SIMCTL_CHILD_READERDEMO_RECORD=60 xcrun simctl launch --terminate-running-process booted net.kymmt.epub.ReaderDemo
# swipe in the Simulator (by hand or with a tool that injects touches), then:
python3 ../../Spikes/scripts/analyse-fling.py \
  "$(xcrun simctl get_app_container booted net.kymmt.epub.ReaderDemo data)/Documents/scroll-recording-ios.json"
```

The file is `scroll-recording-ios.json` / `scroll-recording-macos.json`. Reading the result:

- "WRITTEN DURING INTERACTION" must not appear: the controller writes the scroll position only at rest.
- "SLIPPED samples" is the text jumping; it should be 0. Samples that are late by part of a sample and catch up,
  samples with unpainted rows (tiles that were not there yet) and samples too fast to compare are counted apart.
- While a jump rebuilds the window the web view itself is blank for a moment ("blank-screen episodes"); on screen
  the session's `relayoutSnapshot` covers it.
- On macOS the picture comes from `WKWebView.takeSnapshot`, which lays the page out when asked and can show a state
  no frame shows, and the page's `scrollY` lags the picture; judge macOS recordings by the picture's own movement,
  not by the SLIPPED count (docs/design/07-continuous-scroll-spike.md §4.2).

### Height check

The scrolled layout numbers its pages from the chapters' heights, which a hidden web view measures for every chapter
right after the book opens (docs/design/08-continuous-scroll.md §6.2, §18). The status bar's second line says
`(estimating n of m chapters)` until that is done, then `(measured)`.

Debug menu, "Compare measured and shown heights" (or `READERDEMO_HEIGHTS=1` at launch): waits for the measurement,
shows every chapter once, and writes `scroll-heights-ios.json` / `scroll-heights-macos.json` next to the recordings:
per chapter the height the hidden web view measured and the height the display laid it out with, and how often the
page numbers moved while the chapters were shown. The status line says the same in short. Both heights should be
equal and the page numbers should not move. A run that compared no chapter fails (a book whose chapters were all in
the display's window before the hidden web view came to them has nothing to compare); `chaptersNotShown` counts the
chapters the display told no height for.

```bash
SIMCTL_CHILD_READERDEMO_BOOK=moby-dick SIMCTL_CHILD_READERDEMO_LAYOUT=scrolled SIMCTL_CHILD_READERDEMO_HEIGHTS=1 \
  xcrun simctl launch --terminate-running-process booted net.kymmt.epub.ReaderDemo
```
