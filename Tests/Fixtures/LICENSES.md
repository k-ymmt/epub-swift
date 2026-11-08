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

## malformed/

Hand-written XHTML documents that are not well-formed XML, copied from `Spikes/Sources/SpikeKit/Fixtures.swift`
(`Fixtures.brokenDocs`). Written for this project; no external source.
