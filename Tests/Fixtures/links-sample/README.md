# links-sample

Source of `Tests/Fixtures/links-sample.epub` (M5): links inside the publication (to another chapter with and
without a fragment, within the chapter), an external link, noterefs to a same-document footnote and to rearnotes in a
non-linear notes document (one an `aside`, one an empty anchor inside a paragraph), a noteref at the end of chapter one
to a note that is an ordinary paragraph of the same document (it stays on the page), a footnote no noteref points at,
an element with the `hidden` attribute, a plain image and an image inside a link, and a fixed-layout page with a link,
a noteref and an image. Written for this project; no external source.

Rebuild the EPUB after editing (mimetype first and stored):

```bash
cd Tests/Fixtures/links-sample && rm -f ../links-sample.epub && zip -X0 ../links-sample.epub mimetype && zip -Xr ../links-sample.epub META-INF OPS
```
