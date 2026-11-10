# cfi-sample

Source of `Tests/Fixtures/cfi-sample.epub`, the document the CFI test vectors (`cfi-vectors.json`) refer to.
It exercises comments and CDATA that split text nodes in the browser DOM, ruby, nested inline elements,
whitespace-only text nodes, a surrogate pair, an empty element and full-width / diacritic text for the search tests.
The end of `c1.xhtml` has `script` elements (inside a paragraph, at body level, in SVG) and a `template`: WebKit removes
the scripts and keeps template children out of the tree, and EPUBCore's default tree does the same.
The end of `c2.xhtml` repeats one paragraph four times (`q3`–`q6`) so that an annotation quote in `q4` is not unique
with 32 or 64 code points of context (`annotation-vectors.json`).

Rebuild the EPUB after editing (mimetype first and stored):

```bash
cd Tests/Fixtures/cfi-sample && rm -f ../cfi-sample.epub && zip -X0 ../cfi-sample.epub mimetype && zip -Xr ../cfi-sample.epub META-INF OPS
```
