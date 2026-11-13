# Test fixtures

## IDPF epub3-samples

Source: https://github.com/IDPF/epub3-samples (commit 7651e2002b631e6577fadf7e9e0692fa6efb8746, 2023-07-07).
The repository stores each sample as an unpacked directory under `30/`. The `.epub` files here were packed with
`zip` (`mimetype` first, stored; everything else deflated).

| File | Source directory | License (from the OPF) |
|---|---|---|
| `moby-dick.epub` | `30/moby-dick` | Herman Melville, *Moby-Dick*. Text from Project Gutenberg. Shared under Creative Commons Attribution-ShareAlike 3.0 Unported (CC BY-SA 3.0), http://creativecommons.org/licenses/by-sa/3.0/. Attribution URL: http://code.google.com/p/epub-samples/ |
| `childrens-literature.epub` | `30/childrens-literature` | Curry & Clippinger, *Children's Literature*. Source: http://www.gutenberg.org/files/25545/25545-h/25545-h.htm. "Public domain in the USA." |
| `kusamakura-japanese-vertical-writing.epub` | `30/kusamakura-japanese-vertical-writing` | 夏目漱石『草枕』. Text from 青空文庫 (http://www.aozora.gr.jp/cards/000148/card776.html), public domain. The EPUB is shared by the EPUB日本語拡張仕様策定プロジェクト under CC0 1.0 (`dcterms:license` = http://creativecommons.org/publicdomain/zero/1.0/); the narration (`OPS/audio/*.mp3`, Assistive Technology Development Organization, CC BY-NC-SA 3.0) is **omitted** from this copy to keep the repository small (media overlays are a non-goal). The two `audio/*.mp3` manifest items therefore produce `missingResource` warnings. |
| `wasteland-otf-obf.epub` | `30/wasteland-otf-obf` | T.S. Eliot, *The Waste Land*. CC BY-SA 3.0 (http://creativecommons.org/licenses/by-sa/3.0/), attribution URL http://code.google.com/p/epub-samples/. Fonts: Old Standard TT (SIL Open Font License), obfuscated with the IDPF algorithm (`META-INF/encryption.xml`). |
| `cole-voyage-of-life.epub` | `30/cole-voyage-of-life` | Jesse Dylan, *Thomas Cole - The Voyage of Life*. CC BY-SA 3.0 (http://creativecommons.org/licenses/by-sa/3.0/), attribution URL http://en.wikipedia.org/wiki/The_Voyage_of_Life. Mixed layout: reflowable text chapters and pre-paginated painting pages (`rendition:layout-pre-paginated rendition:orientation-landscape rendition:spread-none` on the itemrefs). Unmodified (M4). |
| `haruko-html-jpeg.epub` | `30/haruko-html-jpeg` | 『ハルコさんの彼氏』. Fixed layout manga (`rendition:layout` pre-paginated, `rendition:spread` landscape, `page-progression-direction="rtl"`, `page-spread-left/right` on every itemref). The OPF declares no license; `OPS/xhtml/AboutThisDocument.xhtml` credits the source JPEGs (http://www.haruko-n.com/data/jpegs.zip, 倉塚りこ氏). The 12 page JPEGs were **re-encoded at JPEG quality 35** (same pixel size 600×837) to shrink the file from 2.3 MB to 1.2 MB (M4). |
| `page-blanche.epub` | `30/page-blanche` | Boulet & Pénélope Bagieu, *Page Blanche*, éditions Delcourt. CC BY-SA 3.0 (http://creativecommons.org/licenses/by-sa/3.0/). Fixed layout (`rendition:spread` auto, `page-spread-right` on the cover, then alternating left/right). The 9 JPEGs were **re-encoded at JPEG quality 30** (same pixel size 1200×1577) to shrink the file from 3.2 MB to 0.85 MB (M4). |
| `regime-anticancer-arabic.epub` | `30/regime-anticancer-arabic` | Pr David Khayat, Nathalie Hutter-Lardeau, Marina Khalil Fayad, *Le Vrai Régime anti-cancer* (Arabic edition), Hachette Antoine. CC BY-SA 3.0 (http://creativecommons.org/licenses/by-sa/3.0/), per `dc:rights` in the OPF. Right-to-left horizontal text (`<html dir="rtl">`), `page-progression-direction="rtl"`. Unmodified (M5). |

## malformed/

Hand-written XHTML documents that are not well-formed XML, copied from `Spikes/Sources/SpikeKit/Fixtures.swift`
(`Fixtures.brokenDocs`). Written for this project; no external source.

## Hand-written EPUBs

| File | Source | Purpose |
|---|---|---|
| `cfi-sample.epub` | `cfi-sample/` (see its README) | CFI test vectors and search (M3). Written for this project. |
| `links-sample.epub` | `links-sample/` (see its README) | Links, noterefs, hidden notes and image taps, including a fixed-layout page (M5). Written for this project; `picture.png` is a generated gradient. |
| `url-sample.epub` | `url-sample/` (see its README) | Links whose text is their URL inside justified paragraphs (02-rendering §3.7). Written for this project. |
