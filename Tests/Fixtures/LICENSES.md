# Test fixtures

## IDPF epub3-samples

Source: https://github.com/IDPF/epub3-samples (commit 7651e2002b631e6577fadf7e9e0692fa6efb8746, 2023-07-07).
The repository stores each sample as an unpacked directory under `30/`. The `.epub` files here were packed with
`zip` (`mimetype` first, stored; everything else deflated).

| File | Source directory | License (from the OPF) |
|---|---|---|
| `moby-dick.epub` | `30/moby-dick` | Herman Melville, *Moby-Dick*. Text from Project Gutenberg. Shared under Creative Commons Attribution-ShareAlike 3.0 Unported (CC BY-SA 3.0), http://creativecommons.org/licenses/by-sa/3.0/. Attribution URL: http://code.google.com/p/epub-samples/ |
| `childrens-literature.epub` | `30/childrens-literature` | Curry & Clippinger, *Children's Literature*. Source: http://www.gutenberg.org/files/25545/25545-h/25545-h.htm. "Public domain in the USA." |

## malformed/

Hand-written XHTML documents that are not well-formed XML, copied from `Spikes/Sources/SpikeKit/Fixtures.swift`
(`Fixtures.brokenDocs`). Written for this project; no external source.
