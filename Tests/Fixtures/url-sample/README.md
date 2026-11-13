# url-sample

Source of `Tests/Fixtures/url-sample.epub`: justified paragraphs (the publisher's `style.css`) with links whose text
is their URL (plain, inside a `span`, starting with `www.` and padded with spaces), a link of ordinary words, a link
whose text only starts with a URL, and an `a` without `href` whose text is a URL. The reader lets the first group wrap
inside the URL, so that the line before it is not stretched (`data-reader-url`, docs/design/02-rendering.md §3.7).
Written for this project; no external source.

Rebuild the EPUB after editing (mimetype first and stored):

```bash
cd Tests/Fixtures/url-sample && rm -f ../url-sample.epub && zip -X0 ../url-sample.epub mimetype && zip -Xr ../url-sample.epub META-INF OPS
```
