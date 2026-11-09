# cfi-sample

Source of `Tests/Fixtures/cfi-sample.epub`, the document the CFI test vectors (`cfi-vectors.json`) refer to.
It exercises comments and CDATA that split text nodes in the browser DOM, ruby, nested inline elements,
whitespace-only text nodes, a surrogate pair, an empty element and full-width / diacritic text for the search tests.

Rebuild the EPUB after editing (mimetype first and stored):

```bash
cd Tests/Fixtures/cfi-sample && rm -f ../cfi-sample.epub && zip -X0 ../cfi-sample.epub mimetype && zip -Xr ../cfi-sample.epub META-INF OPS
```
