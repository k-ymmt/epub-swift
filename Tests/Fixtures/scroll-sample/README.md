# scroll-sample

Source of `Tests/Fixtures/scroll-sample.epub`: a small horizontal book for the scrolled layout
(docs/design/08-continuous-scroll.md).

| Spine | File | What it is for |
|---|---|---|
| 0 | `cover.xhtml` | A cover `height: 100vh` tall with a caption below it: its height depends on the height of its frame (§4.2) |
| 1 | `c1.xhtml` | 60 paragraphs |
| 2 | `c2.xhtml` | A block image near the top (`#c2-block`), and a long paragraph that starts with an inline image (`#c2-long`, `#c2-inline`): the tests change their heights to move the text below them |
| 3 | `c3.xhtml` | 60 paragraphs |
| 4 | `c4.xhtml` | Shorter than a page: at the end of the book the reading line is still in chapter 3 (§6.1) |
| 5 | `side.xhtml` | `linear="no"`: shown alone, outside the flow (§1) |

Every paragraph has an id (`c<chapter>-p<number>`) and its own words, so two pictures of different places differ.
Written for this project (the text is generated from a word list); `picture.png` is the generated gradient of
`links-sample`.

Rebuild the EPUB after editing (mimetype first and stored):

```bash
cd Tests/Fixtures/scroll-sample && rm -f ../scroll-sample.epub && zip -X0 ../scroll-sample.epub mimetype && zip -Xr ../scroll-sample.epub META-INF OPS
```
