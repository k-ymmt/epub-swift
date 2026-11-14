# 08. スクロール表示（連続スクロール）

章をまたいで縦に読み続けられる表示の設計。ページめくり（以下「ページ表示」）と並ぶもう 1 つの表示方式として足す。
方式の根拠は `07-continuous-scroll-spike.md` の実測。2026-11-14 設計、未実装。

## 0. 決定事項

利用者が決めたこと（2026-11-14 の質問）。

| 項目 | 決定 |
|---|---|
| 位置づけ | 切り替え式。`ReaderSettings` に表示方式を足す。ライブラリの既定はページ表示のまま |
| 対象の本 | 横書きリフローだけ。縦書きの本と固定レイアウト（FXL）の本は、スクロールを選んでいてもページ表示で開く |
| OS | iOS と macOS の両方 |
| ページ番号 | 表示領域 1 枚分の高さを 1 ページと数える。`BookPagination`、進捗スライダー、ページ指定の移動はそのまま使う |
| 端のタップ | スクロールしない。どこをタップしても中央のタップとして扱う |
| 章の境目 | 一定の余白を挟んで続ける。区切り線も改ページも入れない |
| 広い画面 | 中央に 1 段。本文の最大幅は文字サイズに比例し、`ReaderSettings` で変えられる。`spreadPolicy` は無視する |
| スクロールインジケータ | 出さない |
| キー（macOS） | ↑ ↓ は数行分。space / PageDown / → は 1 画面分進み、⇧space / PageUp / ← は戻る。Home / End は章の先頭 / 末尾 |
| 横スワイプ | 何もしない |
| 画面の端 | 本文はバーや安全領域の下まで流れる（iOS、macOS とも）。読み始めの行と位置の復元は、アプリが渡す上下のインセットの内側に置く |
| 実機での確認 | 最初のマイルストーン（S1）の直後に、利用者が手で確かめる。問題があればそこで方式を見直す |

アプリ（Laperm）側の決定は Laperm の ADR 0056 の追記に書く。

## 1. 範囲

- スクロール表示になるのは、次を全部満たす本。
  - 固定レイアウトの spine item を 1 つも含まない。
  - `page-progression-direction` が `rtl` でない。
  - 読み込んだ章が縦書き（`vertical-rl` / `vertical-lr`）でない。
- 最後の条件は章を読むまで分からない。スクロール表示で読み込んだ章が縦書きだと分かったら、セッションはその本をページ表示に
  切り替え、`position` の CFI を保って読み直す。同じセッションの間は戻さない。
- どちらで表示しているかは `ReaderSession.layout` で分かる（§3.2）。アプリは `settings.layout == .scrolled` なのに
  `session.layout == .paged` の本で「この本はページ表示のみ」と示せる。
- 線形でない spine item（`linear="no"`）は流れに入れない。リンクや `go(toSpineIndex:)` で開いたときは、その文書 1 つだけの
  スクロール文書として見せ、スクロールで前後の章へは続かない（ページ表示で単独の章として開くのと同じ扱い）。
- ページ表示の動作は変えない。

## 2. 用語

| 用語 | 意味 |
|---|---|
| スクロール文書 | ライブラリが生成するラッパー文書。メインフレームが縦にスクロールし、章ごとの iframe を縦に並べる |
| 窓 | スクロール文書に読み込んである、連続した章の並び |
| 上の余白（runway） | 窓の先頭の章の上に置く空のブロック。高さは「窓より前の章の高さの合計」 |
| 下の余白 | 窓の末尾の章の下に置く空のブロック。高さは「窓より後の章の高さの合計」 |
| 読む行 | 表示領域の上端から上のインセットだけ下がった位置。位置（CFI）とページ番号はこの行で決める |
| ページの高さ P | 表示領域の高さから上下のインセットを引いた値。スクロール表示の 1 ページ |

## 3. 公開 API

### 3.1 `ReaderSettings`

```swift
public enum ReaderLayout: String, Codable, Hashable, Sendable {
    case paged          // ページ表示（既定）
    case scrolled       // スクロール表示
}

public struct ReaderSettings {
    public var layout: ReaderLayout = .paged
    public var scrolledTextWidth: Double = 36    // スクロール表示の本文の最大幅。本文の文字サイズの倍数（em）
}
```

- `scrolledTextWidth` は本文の基準の文字サイズ（`fontScale` を掛けた後）に対する倍数。36 は欧文でおよそ 70 字、和文で 36 字。
  表示領域がこれより狭ければ、幅は表示領域から左右の余白（`pageMargins.horizontal`）を引いた値になる。
- `pageMargins.horizontal` は本文の左右の余白。`pageMargins.vertical` は章の上下の余白に使う（§4.2）。
- `spreadPolicy` はスクロール表示では使わない。
- どちらも `layoutKey` に入る（§6.3）。`layout` の無い古い JSON は `.paged` で読む。

### 3.2 `ReaderSession`

```swift
extension ReaderSession {
    public private(set) var layout: ReaderLayout       // 今この本を表示している方式（§1）
    public var contentInsets: ReaderInsets             // 上下のインセット（pt）。EPUBReaderView が設定する
    public private(set) var isScrolling: Bool          // 読者のスクロールが続いている間 true
}

public struct ReaderInsets: Hashable, Sendable {
    public var top: Double = 0
    public var bottom: Double = 0
}
```

既存のプロパティは、スクロール表示では次の意味になる。

| プロパティ | スクロール表示での意味 |
|---|---|
| `position` | 読む行にある最初のテキストの CFI（§7） |
| `currentSpineIndex` | 読む行のある章 |
| `visibleSpineIndices` | 表示領域（インセットの内側）に一部でも入っている章。読み順 |
| `currentPageIndex` / `chapterPageCount` | 読む行のある章の中の仮想ページと、その章の仮想ページ数（§6.1） |
| `currentPage` / `visiblePages` | 書籍全体の仮想ページ。`visiblePages` は表示領域に一部でも入っているページで、ふつう 2 つ |
| `chapterProgression` / `totalProgression` | ページ表示と同じ計算（`BookPagination.progression`） |
| `isAtStart` / `isAtEnd` | 最初の章の先頭 / 最後の章の末尾までスクロールしている |
| `isShowingSpread` / `isZoomed` | 常に false |
| `relayoutSnapshot` | ページ表示と同じ（再レイアウトと窓の作り直しの間だけ非 nil。§11） |
| `pageSnapshot(_:)` | 常に nil（めくり演出が無い） |

移動の API:

| API | スクロール表示での動作 |
|---|---|
| `go(to:)`（CFI、`ReadingPosition`、目次、検索結果）、`go(toSpineIndex:)`、`go(toPage:)`、`go(toPageInChapter:)` | 行き先を読む行に合わせる（§8.1）。アニメーションなし |
| `goForward()` / `goBackward()` | 1 画面分（P から重なり分を引いた量）をアニメーションでスクロールする（§8.2） |

### 3.3 `ReaderEvent`

```swift
public enum ReaderEvent {
    case scrolling(Bool)        // 読者のスクロールが始まった（true）/ 止まった（false）。ReaderSession.isScrolling と同じ値
}

public struct ReaderNavigation {
    public enum Cause { case pageTurn, jump, link, scroll }   // scroll を追加
}
```

- `scrolling(true)` は、指・慣性・トラックパッド・ホイール・↑ ↓ キーによるスクロールで本文が動き始めたときに 1 回出る。
  `go(to:)` 系と `goForward()` / `goBackward()` では出ない。アプリはこれでバーを隠し、矩形に結び付けたポップオーバーを閉じる。
- `scrolling(false)` はスクロールが止まったとき（`scrollend`、無ければ最後の `scroll` から 150 ms）。その前に
  `positionChanged` が出て、可視ページが変わっていれば `navigated(cause: .scroll, from:, to:)` が出る。
- `navigated` の `pageTurn` は `goForward()` / `goBackward()`、`jump` / `link` はページ表示と同じ。
- `positionChanged` はスクロール中にも出るが、1 秒に 1 回まで。止まったときには必ず出る。
- `tapped(_, zone:)` の `zone` は常に `.center`。`imageTapped` は位置によらず常にアプリへ渡す（めくりに使う帯が無い）。
- 矩形（`SelectedText.rects`、`annotationTapped` の `rects`、`NoteContent.sourceRect`、`TappedImage.rect`、
  `rects(for:)`）は `EPUBReaderView` の枠の座標で、イベントの時点のもの。スクロールすると古くなる。

### 3.4 EPUBUI

```swift
extension View {
    public func readerContentInsets(top: Double, bottom: Double) -> some View
}
```

- `EPUBReaderView` はこの値を `ReaderSession.contentInsets` に入れる。既定は 0。ページ表示では使わない（アプリが今までどおり
  枠の大きさで決める）。
- スクロール表示では、アプリは `EPUBReaderView` をバーや安全領域の下まで広げて置き、隠れる分をこの修飾子で渡す。
  本文は枠の端まで流れ、読む行・位置の復元・1 ページの高さはインセットの内側で数える。
- インセットを変えても章は組み直さない（幅が変わらないので）。ページの高さ P が変わるだけで、ページ番号は計測済みの高さから
  数え直す（§6.3）。アプリは、バーの出し入れのたびにインセットが変わる作りにしない（出し入れのたびにページ番号が変わる）。
- `pageTransition` はスクロール表示では使わない。`ReaderGestures` は `keyboardEnabled` だけが効く（`swipeEnabled` と
  `tapToTurnEnabled` は無視）。
- `ReaderProgressSlider` は変えない。仮想ページの番号で今までどおり動く。

## 4. 構成

### 4.1 WebView とスクロール文書

表示用の WKWebView は 1 つのまま、ページ表示と同じものを使う。スクロール表示では次のように設定する。

- フレームは `EPUBReaderView` の枠と同じ大きさ（3 ページ幅にしない。クリップ用の親ビューのずらしもしない）。
- iOS: `scrollView.isScrollEnabled = true`、`bounces = true`、`showsVerticalScrollIndicator = false`、`scrollsToTop = false`、
  `contentInsetAdjustmentBehavior = .never`。ピンチズームは無効のまま。
- macOS: スクローラを出さない（ラッパーの CSS で `scrollbar-width: none`）。`allowsMagnification = false`。
- 読み込むのは `epub://<id>/_reader/scroll?start=<spineIndex>`。`ScrollDocument`（EPUBRenderer、`SpreadDocument` の隣）が生成する
  `text/html` の文書で、`<html data-reader-scroll>` の下に上の余白 `#__reader_runway`、章の iframe を並べる `#__reader_stage`、
  下の余白 `#__reader_tail` を持つ。`overflow-anchor: none`（スクロールアンカリングは使わない。07 §2.3）。
- 章の iframe は `scrolling="no"`、`display: block; width: 100%; border: 0`、高さは章の内容の高さ。`data-spine-index` /
  `data-spine-steps` を持つ（見開きラッパーと同じ属性）。
- `reader.js` はラッパー文書（`html[data-reader-scroll]`）で「スクロールコントローラ」として動く。見開きコントローラ
  （02-rendering §4.1）と同じ形で、Swift には今までと同じ API と、§4.3 の追加分を見せる。iframe の中の `reader.js` は
  今までどおり Swift にメッセージを送らず、ホスト（コントローラ）に渡す。

### 4.2 章の CSS

章の文書には今までどおり `reader-before.css` / `reader-after.css` を注入する。`layout` の引数に `scrolled: true` を足し、
`reader.js` が `<html data-reader-layout="scrolled">` を付ける。この属性があるとき:

- 多段組を外す。`html { height: auto; overflow: hidden }`（iframe の中ではスクロールしない）。
- `body` は左右中央、`max-width` は `scrolledTextWidth` em、左右の `padding` は `pageMargins.horizontal`。
- 章の上下に `pageMargins.vertical × 2` の余白（既定 20 → 40 px。章と章の間は 80 px）。区切り線は引かない。
- 画像と SVG は `max-width: 100%`、`max-height` はページの高さ P（1 画面に収まる）。
- 改ページの指定（`break-before` など）は効かない（多段組が無いので何も起きない）。

出版物の CSS がビューポート単位（`vh` など）で高さを指定している場合の扱いは未検証（§14）。

### 4.3 コントローラの API（Swift → JS、追加分）

| 関数 | 役割 |
|---|---|
| `layout({…, scrolled: true, insets, pageHeight, heights})` | 窓の全 iframe に `layout` を転送し、高さを取り直す。`heights` は章ごとの高さの見積もり（§5.2）。`{writingMode}` を返す |
| `showLocation({spineIndex, cfi \| fragment \| offset})` | 行き先が窓の中ならその位置へスクロールし、外なら窓を作り直す（§8.1）。`{spineIndex, offset}` を返す |
| `scrollBy({pages \| lines, animated})` | 1 画面分 / 数行分のスクロール（§8.2） |
| `locationAtReadingLine()` | 読む行の `{spineIndex, offset, chapterHeight, cfi}` |
| `setEstimates(heights)` | 計測が進んだときの見積もりの更新。余白は静止しているときに直す（§5.4） |
| `trimWindow()` | 窓を今の章の前後だけに縮める（メモリ警告。§12） |

JS → Swift の追加メッセージ:

| type | payload | 発火 |
|---|---|---|
| `scrolled` | `{spineIndex, offset, chapterHeight, visible: [spineIndex]}` | スクロール中、100 ms に 1 回まで。Swift がページ番号と進捗を更新する |
| `scrolling` | `{active, user}` | スクロールの始まりと終わり。`user` は読者の操作によるものか |
| `chapterHeight` | `{spineIndex, height}` | 章の高さが決まった / 変わった（読み込み、フォント、画像、再レイアウト）。Swift がキャッシュに書く |
| `chapterWritingMode` | `{spineIndex, writingMode}` | 章の `ready`。縦書きならセッションがページ表示に切り替える（§1） |

`pageFor` / `rectsFor` / `setHighlights` / `setTransientHighlight` / `currentSelection` などは、見開きコントローラと同じく
CFI の spine ステップで iframe を選んで転送する。窓に無い章への `setHighlights` は覚えておき、その章を読み込んだときに描く。

## 5. 窓と余白

### 5.1 窓

- 窓は連続した線形の章。開いた直後は、行き先の章 1 つと、その前後 1 章ずつ。
- **足す**: 表示領域の上端から窓の先頭までが 2P より近くなったら前の章を、下端から窓の末尾までが 2P より近くなったら
  次の章を読み込む。1 つ読み込み終わってから次を判断する。
- **外す**: 表示領域から 8P より遠い章を外す。外すのはスクロールが止まっているときだけ。読む行のある章とその前後 1 章は
  外さない。
- 1 章が巨大でも 1 つの iframe のまま（07 §2.1: 高さ 578,714 px の章で +32 MB、描画は見えている所だけ）。
- 窓にある章の数に上限は設けない（短い章が続く本では 8P の中に多くの章が入るが、合計の高さは変わらない）。

### 5.2 余白

- 上の余白の高さは「窓より前にある線形の章の高さの合計」、下の余白は「窓より後の章の高さの合計」。各章の高さは、
  計測済みならその値、未計測なら見積もり（§6.2）。
- これでスクロール位置は本全体の中の位置にほぼ一致し、文書の高さは本全体の高さにほぼ一致する。

### 5.3 位置の補正

読んでいる行より上のレイアウトが変わったとき（上に章を足す、上の章の高さが変わる、読んでいる章の中で読む行より上が伸び縮みする、
上の章を外す）、読んでいる行が動かないようにする。

- **スクロール位置は書き換えない。上の余白の高さで帳尻を合わせる。** 指や慣性でスクロールしている間、スクロール位置は
  UI プロセスが決めていて、ページが書いた位置は古い値で上書きされる。その間ページは要らない章を読み込み、違う場所を描き、
  基準を取り違える（07 §2.4: 空白の画面、2,528 px のずれ）。余白の高さを変えるのはレイアウトだけの変更で、この競合が起きない。
- 手順: 読む行の近くの要素を 1 つ基準として覚えておく。レイアウトが変わったら、基準の要素が文書の中で動いた量 d を求め、
  上の余白を d だけ縮める（d が負なら伸ばす）。
- **基準の要素の位置は文書座標（ビューポート内の位置 + `scrollY`）で比べる。** スクロール中の `scrollY` は古い値に戻る
  ことがあるので、ビューポート内の位置を比べると同じ補正を 2 回かける（07 §2.3）。窓を動かす判断（§5.1 の距離）も、
  章の iframe と基準の要素の文書座標から求め、`scrollY` 単独の値に頼らない。
- 基準の要素は `scroll` のたびに、読む行の近くに無ければ選び直す。表示領域に章が 1 つも無いとき（窓を追い越した。§5.5）は、
  窓の先頭の章の上端を基準にする。
- **上の章を外すときは、外すのと同じレイアウトの中で、上の余白を章の高さだけ先に伸ばす。** 後から伸ばすと、間のレイアウトで
  文書が縮み、最下端付近ではスクロール位置が切り詰められて行が飛ぶ（07 §2.3）。
- 章の高さは、各章の `documentElement` を `ResizeObserver` で見て合わせ直す。`load` の後にフォントが当たって高さが変わるのは
  ほぼ全章で起きる（07 §2.2）。
- 読んでいる行より下の変化（下に章を足す、下の章の高さが変わる、下の章を外す）は、下の余白の高さを同じ量だけ逆に変える。
  文書の高さが変わらないので、読んでいる行には何も起きない。

### 5.4 余白の清算

章を足すとき、上の余白は実際の高さだけ縮む。その章の見積もりが実際と違っていれば、余白は「窓より前の章の高さの合計」から
その差だけずれる。計測が進んで見積もりが変わったときも、窓の中の章の高さが読む行より上で変わったとき（§5.3。余白で
受けた分だけ、余白が合計からずれる）も同じ。

- ずれは、スクロールが止まっているときに直す: 上の余白を正しい値にし、同じ量だけ `window.scrollBy` で位置を動かす。
  静止中のこの操作は、iOS と macOS の両方で 0 px・ちらつきなしと実測している（07 §2.3 の manual の列）。
- 全章の高さが計測済みなら、見積もりは実際の高さなので、ずれはほぼ出ない（計測は本を開いて数秒で終わる。§6.2）。
- 本の先頭の章が窓に入った時点で余白が余っている（見積もりが大きかった）と、最初の章の上に空白が残る。止まっていれば
  その場で清算する。スクロール中なら止まるまで残り、止まったときに清算する（空白を見ていた場合は最初の章の先頭に寄る）。
- 余白が足りなくなった（見積もりが小さく、余白が 0 になった後も上に章がある）ときは、足りない分だけ `scrollBy` で補う。
  スクロール中のこの書き換えは §5.3 の競合を起こしうる。起きるのは「見積もりのままの章を、止まらずに本の先頭近くまで
  スクロールした」ときだけで、頻度は S1 で確かめる（§14）。

### 5.5 窓を追い越したとき

速いスクロールで、章の読み込みより先に表示領域が余白へ入ることがある。その間は背景色が見える。窓は今までどおり 1 章ずつ
表示領域へ向かって伸ばす（窓は連続したまま）。離れた場所だけを先に読み込むことはしない。空白がどれだけ出るかは S1 の実機確認で
見る（07 §2.5 の「極端に速いスクロール」）。

## 6. 高さの計測とページ番号

### 6.1 仮想ページ

- 1 ページ = ページの高さ P。章 i の高さを h とすると、その章のページ数は `max(1, ceil(h / P))`。章の中のページ j は、
  章の上端からの距離が `[jP, (j+1)P)` の範囲。
- 章ごとに切り上げるので、章の最後のページは P より短いことがある（ページ表示で章末のページに空きがあるのと同じ）。
- `BookPagination` の形は変えない（章ごとの `pageCount`、`firstPage`、推定かどうか）。`currentPage` は読む行のあるページ。
- `go(toPage:)` は、そのページの上端（章の上端から jP）を読む行に合わせる。

### 6.2 計測

- `PaginationService`（事前ページ化用の非表示 WebView）が、スクロール表示のときは各章を `scrolled: true` で `layout` し、
  内容の高さを `PaginationCache` に書く。順序と打ち切りはページ表示と同じ（02-rendering §8.1）。隣接章のスナップショットは撮らない。
- 表示用 WebView が読み込んだ章の高さ（`chapterHeight`）もキャッシュに書く。両方ある章は表示用の値を優先する。
- 未計測の章の高さは見積もり: `BookPagination` の今の推定（文字数 ÷ 1 ページあたり文字数）で出したページ数 × P。
  1 ページあたり文字数は、計測済みの章の「文字数 ÷ (高さ ÷ P)」から学習する（規則は 02-rendering §5.2 のまま）。
- 計測が進むたびに `paginationUpdated` を出し、コントローラに `setEstimates` を送る。

非表示の WebView で測った高さが、表示したときの高さと一致するかは未検証（スパイクでは、画面外の iframe で測った高さが
フォント適用前の値のままだった。07 §2.2）。ずれても §5.3 と §5.4 が吸収するが、ページ数が後から少し動く。S3 で確かめる。

### 6.3 キャッシュのキー

`LayoutKey` に表示方式を足す。スクロール表示のキーは「本文の幅（整数 px に丸める）と `ReaderSettings.layoutKey`
（フォント、サイズ、行間、余白、`scrolledTextWidth`）」で、**ページの高さ P は入れない**。キャッシュに置くのは章の高さで、
ページ数は読むときに P で割って出す。表示領域の高さやインセットだけが変わったときは、計測をやり直さずにページ数だけ数え直す。

## 7. 位置

- 読書位置は今までどおり CFI。スクロール表示では、読む行にある最初のテキストの CFI（章の iframe の中で、読む行のすぐ下を
  `caretRangeFromPoint` で引く。テキストが無ければ今の `cfiForPage` と同じ順で要素へ下がる）。
- 位置の復元（開いたとき、設定変更、リサイズ、方式の切り替え、WebContent の復旧）は、その CFI の文字の上端を読む行に合わせる。
- ページ表示とスクロール表示の間で位置は互換（どちらも CFI）。他の端末がどちらの方式で保存した位置でも開ける。
- `position` の更新と `positionChanged` は §3.3 の頻度。`ReadingPosition` の章内・全体の進捗は仮想ページから。

## 8. 移動

### 8.1 ジャンプ

`go(to:)` 系は `showLocation` を呼ぶ。

- 行き先の章が窓にあれば、その章の中の位置を求めて、そこが読む行に来るようにスクロールする。慣性スクロールの途中なら
  先に止める（iOS は `setContentOffset(現在値, animated: false)`）。止まっている間の位置の書き換えは安全（§5.4）。
- 窓に無ければ、窓を作り直す: 今の画面を `relayoutSnapshot` に置き、章の iframe を全部外し、上下の余白を行き先の章に合わせ、
  行き先の章（と前後 1 章）を読み込み、位置を合わせてから画像を外す。
- 終わったら `positionChanged`、可視ページが変わっていれば `navigated`。

### 8.2 1 画面分・数行分

- `goForward()` / `goBackward()`: `P − 重なり` だけアニメーションでスクロールする。重なりは本文 1 行分（文字サイズ × 行間）。
  本の先頭 / 末尾では止まる。動いた量が 0 なら `navigated` は出さない。
- ↑ ↓: 本文 3 行分。読者のスクロールとして扱う（`scrolling` が出る）。
- Home / End: 読む行のある章の先頭 / 末尾へのジャンプ。
- アニメーション中に上へ章が足されても、位置の補正は余白で行うので、アニメーションは途切れない。

## 9. 入力

- iOS のスクロールは WKWebView の `UIScrollView` にそのまま任せる（慣性、端でのバウンス）。EPUBUI はスワイプの
  ジェスチャを付けない。タップは `reader.js` の `tap` をそのまま `tapped(_, zone: .center)` にする。
- macOS のトラックパッド / ホイールも WKWebView に任せる。EPUBUI の「スワイプをめくりのドラッグに変える」処理
  （03-api §4.3）はスクロール表示では入れない。横方向の動きは捨てる。
- キーは `ReaderKeyAction` に「数行スクロール」を足し、対応表を §0 のとおりにする。進捗スライダーにフォーカスがある間は
  リーダーがキーを取らない規則は同じ。
- VoiceOver は WKWebView 標準のスクロールに任せる。ページ表示で入れている `accessibilityScroll` の差し替えは使わない。

## 10. 既存の機能

| 機能 | スクロール表示での扱い |
|---|---|
| 選択 | 章の iframe の中の選択をそのまま使う。章をまたぐ選択はできない（縦書き見開きと同じ制限）。編集メニューへの項目追加は同じ |
| 注釈の描画 | 章ごとに `setHighlights`。窓に入った章に、その章の分を描く |
| 注釈のタップ | 同じ（`annotationTapped`）。矩形は枠の座標 |
| 検索 | 検索は EPUBCore なので同じ。`show(_:)` は結果の位置へジャンプして一時ハイライトを描く。次のジャンプか、ハイライトが表示領域から出たスクロールの終わりで消す |
| 内部リンク | ジャンプ（`navigated(.link)` → `internalLink`） |
| 脚注 | 同じ（`noteref`）。同じ文書の脚注の `aside` を隠す規則も同じ |
| 画像のタップ | 常に `imageTapped` |
| 同梱の注釈 | 同じ |

## 11. 再レイアウトと切り替え

- **設定の変更、幅の変更**: 今の CFI を覚え、画面を `relayoutSnapshot` に置き、窓の全章を `layout` し直し、余白を新しい
  見積もりで作り直し、CFI を読む行に合わせて、画像を外す。`layoutKey` が変わるので計測は新しいキーでやり直す。
- **高さだけ、インセットだけの変更**: 章は組み直さない。P を更新し、読む行の位置を合わせ直し、ページ番号を数え直す。
- **表示方式の切り替え**（`settings.layout` の変更、§1 の縦書きの検出）: 今の CFI を覚え、`relayoutSnapshot` を置き、
  WebView の設定（§4.1 / 02-rendering §1）を切り替え、もう一方の文書（章の文書 / 見開きラッパー / スクロール文書）を
  読み込んで CFI で位置を戻す。
- macOS のウィンドウリサイズ中の 150 ms デバウンスは同じ。

## 12. 復旧とメモリ

- WebContent プロセスが落ちたら、`position` の CFI でスクロール文書を読み直す（回数の上限は 02-rendering §9 と同じ）。
- メモリ警告では、窓を読む行のある章とその前後 1 章に縮め（`trimWindow`。スクロール中なら止まってから）、計測を一時停止する。

## 13. マイルストーン

| | 内容 | 終わりの条件 |
|---|---|---|
| S1 | スクロールで読める: `ReaderSettings.layout`、スクロール文書とコントローラ（窓、余白、補正、清算）、章の CSS と本文の幅、インセット、位置（取得と復元）、ジャンプ、1 画面分のスクロールとキー、タップ、再レイアウトと方式の切り替え、対象外の本の振り分け。ReaderDemo に切り替えを足す | 自動テスト（下記）が通り、macOS の検証項目（§14）を確かめ、**利用者が実機で手で確かめる**。問題があれば方式を見直す |
| S2 | 機能をそろえる: 選択、注釈、検索結果の表示、脚注、画像、リンク、`scrolling` と `navigated(.scroll)`、復旧、メモリ警告 | ページ表示のテストに対応するスクロール表示のテストが通る |
| S3 | ページ番号: 高さの計測、キャッシュ、仮想ページ、`currentPage` / `visiblePages` / `go(toPage:)`、進捗スライダー | 全章の計測後にページ数が動かない。計測値と表示時の高さの差を測る |
| S4 | Laperm への組み込み（Laperm の ADR 0056 の追記） | Laperm の UI テストが通り、設定に出す |

S1 では見積もりに文字数だけを使う（計測は S3）。S2 と S3 は入れ替えてよい。

テスト:

- 位置の安定は、スパイクと同じ方法（読む行の要素の位置 + 帯のスナップショット）を `EPUBRendererTests` に移す: 上に章を足す、
  上の章の高さが変わる、読んでいる章の中で上が伸びる、上の章を外す（下に続きがある / 最下端）。
- 窓の規則（どの章を足す / 外すか）、仮想ページの算術、余白の清算量は、WebView 無しで検証できる純粋な関数に分ける。
- 指でのスクロールは自動テストにしない（Simulator へのスワイプ注入は外の道具が要る）。スパイク 9 を回帰の確認に使う。

## 14. 検証していないこと

S1 の中で確かめる。結果によって設計を直す。

| 項目 | 分かっていること / 確かめ方 |
|---|---|
| 実機での滑らかさと空白 | Simulator でしか測っていない。S1 の直後に利用者が手で確かめる |
| macOS のトラックパッドの慣性スクロール中の補正 | 未計測。macOS でもスクロール位置が UI プロセス側にあるなら余白方式が要り、無いなら余白方式でも害は無い。S1 で実際にスクロールして見る |
| macOS: 読んでいる章の中で読む行より上が伸び縮みしたときのちらつき | 静止中に 1〜2 フレーム、伸びた分が描かれてから補正が効く（07 §2.3。iOS では出ない）。起きるのは、章の途中へジャンプした後に上の画像が遅れて読み込まれる場合など。`ResizeObserver` を章の文書側で作っても変わらなかった。S1 で原因を調べる（候補: 章の `layout` 後の高さの変化をコントローラが同じフレームで受ける経路、画像の大きさを先に確保する CSS） |
| 極端に速いスクロール | 約 50,000 pt / 秒で白い画面が続いた記録がある（`scrollBy` 方式）。余白方式では未計測（§5.5） |
| 余白が足りなくなったときのスクロール中の書き換え | §5.4。頻度と見え方 |
| `vh` などのビューポート単位 | iframe の中の `vh` は iframe の高さ（= 内容の高さ）を指すので、`height: 100vh` の要素があると高さが伸び続ける恐れがある。表紙でよく使われる。対処の候補: 高さが増え続ける章は伸びを打ち切る / 配信時に出版物の CSS の単位を書き換える |
| 文書の高さの上限 | 余白を本全体の高さにすると、長い本では数百万 px になる。WebKit が扱える上限と、超える本での扱い（余白に上限を設けて清算で足し直す） |
| 非表示の WebView で測った高さの正しさ | §6.2 |
| `scrollend` イベントの有無 | 無ければ 150 ms のデバウンスだけで止まったと判断する |
| スクロールアンカリングが効かない原因 | 未特定（07 §2.3）。効くようになっても `overflow-anchor: none` なので影響しない |

## 15. 他の文書への反映

- 00-overview: 「表示モード」の決定を「paged と見開き、スクロール表示（08）」に、§3 の非目標から「連続スクロール表示」を外す。
- 04-roadmap: 将来の拡張点から「連続スクロールモード」を外し、§4 としてマイルストーン S1〜S4 への参照を足す。
- 02-rendering / 03-api: 実装したマイルストーンごとに、該当箇所へ反映する（今は 08 への参照だけ）。
