# 05. スパイク検証結果

`04-roadmap.md` §2「先に検証する項目」の 7 項目を、`Spikes/` の最小コードで検証した結果。
設計文書（00〜04）の前提が崩れている箇所には、直すべき場所と案を添える。

## 0. 実行環境と方法

| 項目 | 値 |
|---|---|
| macOS | 27.0.1 (26A434)、Apple Silicon |
| Xcode / Swift | Xcode 27.2、Swift 6.4.2 |
| libxml2 | SDK 付属 2.9.13（実行時 `xmlParserVersion` = 20913） |
| iOS | iOS Simulator 27.0、iPhone 17 Pro（項目 1〜4・7。5 と 6 は macOS のみ） |

- コード: `Spikes/`（独立した Swift Package。本体の `Package.swift` には組み込まない）
- macOS: `cd Spikes && swift run spike-run [--out output] [項目番号...]`。1 枚の小さなウィンドウに WKWebView を置き、
  `epub://spike/...` を `WKURLSchemeHandler` でメモリから配信する（設計と同じ経路）。
- iOS: `cd Spikes && scripts/run-ios.sh [項目番号...]`。SpikeKit と最小の UIScene アプリを `swiftc` で 1 モジュールに
  コンパイルし、`.app` に包んで `simctl` で起動する（iOS 27 SDK は UIScene ライフサイクルが必須で、旧来の `UIWindow` だけでは起動を拒否される）。
  `xcodebuild test -scheme EPUBSpikes -only-testing:SpikeKitTests` の論理テスト（ホストアプリなし）でも実行はできるが、
  最初の試行では `takeSnapshot` が真っ黒の画像を返した（`UIWindowScene` に属さない `UIWindow` を使っていたため。描画の判定にはアプリとして動かす方が確実）。
- 出力: `Spikes/output/results-macos.md` / `Spikes/output/ios/results-ios.md`（全ログ）、`Spikes/output/**/*.png`（スクリーンショット）、
  `Spikes/output/spike5-*.txt`（DOM ダンプ）
- 検証用 HTML はすべて `Spikes/Sources/SpikeKit/Fixtures.swift` に自前で書いた。IDPF サンプルは使っていない。

ピクセル判定は `takeSnapshot(with:)` の画像を RGBA に展開し、主色（16 階調に量子化した最頻色）や非白ピクセル比で機械的に行った。

## 1. 総括

| # | 項目 | 判定 | 要点 |
|---|---|---|---|
| 1 | `allowsContentJavaScript = false` と `WKUserScript` | 成立 | 専用 `WKContentWorld` のブリッジは動き、`callAsyncJavaScript` と reply 付き `postMessage` が往復する。コンテンツ JS（`<script>`、インライン属性ハンドラ）は止まる |
| 2 | CSS Custom Highlight API | 成立 | `CSS.highlights` / `Highlight` / `::highlight()` が使え、背景色と文字色が描画される |
| 3 | 3 ページ幅フレームのスナップショット | 条件付き | クリップ外のページも `rect` 指定で撮れる（macOS 0.4 ms、iOS 8 ms）。ただし `scrollWidth` ベースの `pageCount` はビューポート幅（3 ページ）が下限になる。iOS は `<meta name="viewport">` の注入が必須 |
| 4 | 縦書き多段組 | 成立 | 段は縦に積まれ、`scrollHeight` はページ高の整数倍。3 ページ高フレームでも同じ値 |
| 5 | XML エラー文書の `text/html` 配信 | 不成立 | libxml2 2.9 の HTML パーサは HTML5 の木構築規則を持たず、`tbody` 補完・adoption agency・HTML5 要素の `p` 自動終了で要素インデックスがずれる |
| 6 | 縦書き + 見開きのラッパー | 成立 | 2 つの iframe を親から `scrollTop` で隣接ページに合わせられる。メモリ増分は単独の 1.6 倍（小さな文書） |
| 7 | `isScrollEnabled = false` と多段組の `scrollLeft` | 成立 | JS の `scrollLeft` / `scrollTop` / `window.scrollTo` に描画が追従し、末尾でクランプされる。iOS でも同じ |

## 2. 各項目の詳細

### 2.1 `allowsContentJavaScript = false` と `WKUserScript` — 成立

**方法**: XHTML（`application/xhtml+xml`）に `<script>` 2 本と `onerror` 属性を仕込み、
`defaultWebpagePreferences.allowsContentJavaScript = false` で読み込む。ブリッジ JS は `WKUserScript`
（`.atDocumentStart` と `.atDocumentEnd`、`forMainFrameOnly: true`、`WKContentWorld.world(name: "reader")`）で注入し、
`WKScriptMessageHandlerWithReply` を同じ world に `reader` の名前で登録する。対照として `true` でも実行した。

**結果**:

| 観測 | `false` | `true`（対照） |
|---|---|---|
| `ready` メッセージ（`.atDocumentEnd` から `postMessage`） | 受信。`readyState = "interactive"` | 受信 |
| `postMessage` の Promise（reply） | Swift の `replyHandler` の値 `{pong: true}` が JS に届く | 同じ |
| `callAsyncJavaScript("return window.__epubReader.ping(value)", arguments: ["value": 42], contentWorld: reader)` | `{ok: true, echo: 42, title: "bridge"}` | 同じ |
| `<script>` が `document.title` を書き換えたか | 書き換わらない（`"bridge"`） | `"content-js-ran"` |
| `<script>` が `body` に属性を付けたか | 付かない（`null`） | `"ran"` |
| `onerror` 属性ハンドラ | 動かない | 動く |
| page world から `window.__epubReader` | `undefined`（world が分離） | `undefined` |
| `.atDocumentStart` 時点の `readyState` | `"loading"` | `"loading"` |

**設計への影響**: 02-rendering §1.1 と §4 の前提はそのまま成り立つ。補足が 2 点。

- `.atDocumentEnd` は `DOMContentLoaded` 相当（`readyState = "interactive"`）で動く。画像・フォントの読み込み前なので、
  初回 `layout` の `pageCount` は `document.fonts.ready` と `load` の後に確定させるか、設計どおり `pageCountChanged` で補正する（§4.2）。
- `allowsContentJavaScript = false` はインライン属性ハンドラも止める。コンテンツ側の `onclick` 等に頼る EPUB は動かないが、これは非目標（00-overview §3）。

### 2.2 CSS Custom Highlight API — 成立

**方法**: reader world から `new Highlight(range)` を `CSS.highlights.set("spike", h)` し、
`<style>::highlight(spike) { background-color: #ffff00; color: #ff0000 }</style>` を `<head>` に追加。スナップショットで色を数える。

**結果**:

| 観測 | 値 |
|---|---|
| `typeof CSS.highlights` / `typeof Highlight` / `CSS.supports("selector(::highlight(x))")` | `object` / `function` / `true` |
| Range の矩形（pt） | x=78, y=23.9, w=117, h=28.3 |
| 黄色ピクセル（画像全体 / 矩形内） | 9065 / 9065（矩形外は 0） |
| 赤ピクセル（矩形内） | 2964（文字色も効く） |

スクリーンショット: `Spikes/output/spike2-highlight.png`。

**設計への影響**: 02-rendering §4.1 `setHighlights` と §10 のタップ判定はこの API で実装できる。
分離 world からの DOM / CSSOM 変更は共有されるので、スタイルは `reader-before.css` に静的に書いておけばよい。

### 2.3 3 ページ幅フレームのスナップショット — 条件付き

**方法**: 可視領域 300×400 の親ビュー（`masksToBounds` / `clipsToBounds`）に、幅 900 の WKWebView を x = −300 で置く。
横書き 6 ページ（各ページを単色の 300×400 ブロックにした多段組）を読み込み、`scrollLeft = 300` でページ 1・2・3 をビューポートに入れ、
中央（ページ 2）だけが見えている状態で `takeSnapshot(with:)` の `rect` に 3 つのスロットを指定する。

**結果（macOS）**:

| `rect`（pt） | 可視性 | 得られた画像 | 主色 | 期待 |
|---|---|---|---|---|
| (0, 0, 300, 400) | クリップ外 | 600×800 px（2x） | `#27ae60` | ページ 1 = `#27ae60` ✓ |
| (300, 0, 300, 400) | クリップ内 | 600×800 px | `#2980b9` | ページ 2 = `#2980b9` ✓ |
| (600, 0, 300, 400) | クリップ外 | 600×800 px | `#e67e22` | ページ 3 = `#e67e22` ✓ |

- 所要時間（クリップ外ページ、10 回）: min 0.3 ms / median 0.4 ms / max 0.6 ms。`snapshotWidth` を 2 倍にした 1200×1600 px でも 1.8 ms。
  演出のために毎回撮っても問題ない。
- macOS では `snapshotWidth` は pt 指定で、返る `NSImage` の `CGImage` はバッキングスケール（2x）のピクセルを持つ。
  `PageSnapshot` は pt サイズと scale を別に持つ必要がある。
- フレーム全体のスナップショット: `Spikes/output/spike3-whole-frame.png`（ページ 1・2・3 が横に並ぶ）。

**結果（iOS Simulator 27.0）**: クリップ外の 2 ページも同じ色で撮れた（§3）。所要時間は median 8 ms、最大 25 ms と macOS より一桁遅い。

**条件**: 3 ページ幅のビューポートでは `document.scrollingElement.scrollWidth` がビューポート幅を下回らない。
2 ページしかない文書で `scrollWidth = 900`、`ceil(900 / 300) = 3` ページと誤る（計測値: `scrollWidth: 900, clientWidth: 900`）。
`<body>` 末尾に置いた空の `<span>` の位置からは正しく求まった（`left = 300` → `floor(300 / 300) + 1 = 2` ページ）。

**設計への提案**:

- 02-rendering §5.1: `pageCount = ceil(scrollWidth / pageWidth)` をやめ、`body` 末尾のセンチネル要素（`reader.js` が追加する）の
  `getBoundingClientRect()` から `floor((left + scrollLeft) / pageWidth) + 1`（縦書きは `top` / `pageHeight`）で求める。
  `scrollWidth` は「ビューポート幅以上」という下限付きの値としてだけ使う。
- 02-rendering §1.2: 先頭ページと末尾ページではビューポートに前後ページがないので、親ビューに対する WebView のオフセットを
  `−pageWidth` 固定ではなく「ビューポート内での現在ページの位置」から決める（ページ 0 のときはオフセット 0）。

### 2.4 縦書き多段組 — 成立

**方法**: 自前の日本語本文（ルビ・縦中横を含む約 1,600 字）に
`html { writing-mode: vertical-rl; width: 300px; height: 400px; overflow: hidden; column-width: 400px; column-gap: 0; column-fill: auto }`
を当て、300×400 の WebView で計測。`scrollTop = i × 400` でページを送りスナップショットを撮る。3 ページ高（300×1200）のフレームでも計測した。

**結果**:

| 観測 | 値 |
|---|---|
| `getComputedStyle(html).writingMode` | `vertical-rl` |
| `scrollHeight` / `scrollWidth` / `clientHeight` | 4400 / 300 / 400 |
| `pageCount = ceil(4400 / 400)` | 11（剰余 0。横方向のあふれなし） |
| 各ページ右上の先頭文字（`caretRangeFromPoint`） | 「山路」「茶屋の」「夜になると、宿の二階から」「二〇二五年の春、一二三四」 |
| 3 ページ高フレーム（300×1200） | `scrollHeight` 4400、`pageCount` 11（同じ）。`html` のボックスは y = 0 から始まる |

スクリーンショット: `Spikes/output/spike4-page{0,1,2,10}.png`、`spike4-three-page-frame.png`。
行が段の境界で分断されず、ルビも段内に収まっている。

**設計への影響**: 02-rendering §3.4 の縦書き CSS と「ページ i は `scrollTop = i × pageHeight`」はそのまま使える。
補足: WebView の幅をページ幅より広くすると（項目 6 で 600 幅に 300 幅の `html` を置いたとき）、
`vertical-rl` の `html` ボックスはビューポートの**右端**（x = 300〜600）に寄る。縦書きの 3 ページフレームは設計どおり
高さ方向にだけ伸ばし、幅はページ幅に揃えること。

### 2.5 XML エラー文書の `text/html` 配信 — 不成立

**方法**: XML として壊れた XHTML を 3 種類書き（`unclosed-and-entities`: 未閉鎖 `<p>`、`<br>`、`&nbsp;`、交差した `<b><i>`、
`<p>` 内の `<p>`、`<li>` の省略、`tbody` なしの `<table>`、`ruby`；`single-missing-close`: `</span>` 1 つの欠落；
`html5-elements-and-svg`: `article` / `aside` / `figure` / インライン SVG）、WebKit に `text/html` で読ませた DOM と
libxml2 `htmlReadMemory(HTML_PARSE_RECOVER | NOERROR | NOWARNING)` の DOM を、CFI の規則（要素は偶数、テキスト塊は奇数、
隣接テキストは結合、コメントは空テキスト扱い）で `パス 要素名#id` / `パス "テキスト"` の行に落として比較した。

**結果**:

| 文書 | 厳密一致 | 空白無視で一致 | 差分 |
|---|---|---|---|
| `single-missing-close` | ✗ | ✓ | libxml2 だけ `<head>` の前に `"\n"` テキストを置く（奇数 index なので CFI に影響なし） |
| `unclosed-and-entities` | ✗ | ✗ | `<b>bold <i>both</b> italic only</i> tail`: WebKit は adoption agency で `<i>` を再構築し `/4/2/6/4 i` と `/4/2/6/5 "tail"` になるが、libxml2 は `/4/2/6/3 " italic only tail"`。`<table><tr>`: WebKit は `tbody` を補完（`/4/2/18/2 tbody`）、libxml2 は補完しない |
| `html5-elements-and-svg` | ✗ | ✗ | `<p>text<span>a</span>b<aside>`: WebKit は `aside` で `<p>` を閉じ `/4/2/8 aside`、libxml2 は `aside` を知らず `<p>` の中に入れる（`/4/2/6/4 aside`） |

一方、`<p>` 内の `<p>`、`<li>` の省略、未閉鎖の `<p>` / `<br>` / `<img>`、`&nbsp;` / `&copy;`、余分な `</span>`、`section`、
`ruby`、インライン SVG は一致した。ダンプは `Spikes/output/spike5-*-{webkit,libxml2}.txt`。

対照として同じ文書を `application/xhtml+xml` で配信すると `document.querySelector("parsererror")` が立ち、エラー箇所までの内容だけが描画された
（`text/html` へのフォールバック自体は必要）。

**判定の理由**: SDK の libxml2 は 2.9.13 で HTML4 時代のパーサ。HTML5 の木構築アルゴリズム（adoption agency、`tbody` の暗黙挿入、
HTML5 のセクショニング要素による `p` の自動終了）を持たないので、01-core §4.1 と 02-rendering §3.3 の
「WebKit の DOM は libxml2 の HTML パーサと同じ規則で構築されるため CFI が揃う」は成り立たない。
表や交差タグを含む壊れた文書では、同じ CFI が別の要素を指す。

**設計への提案**（推奨順）:

1. **libxml2 の木を正とし、整形式 XHTML に直して配信する**。EPUBCore が `htmlReadMemory` で読んだ木を
   `xmlSaveToBuffer(..., XML_SAVE_AS_XML)` で XML として直列化し、`EPUBSchemeHandler` はそれを `application/xhtml+xml` で返す。
   WebKit は XML パーサで読むので DOM は直列化した木と 1 対 1 になり、CFI が構造的に一致する。HTML5 の規則を Swift 側で再現する必要がない。
   注意点:
   - libxml2 の HTML パーサは名前空間を扱わないので、`xmlns="http://www.w3.org/1999/xhtml"` が根要素にあることを確認して付け直す。
     `epub:type` や `xlink:href` のような接頭辞付き属性を見つけたら、根要素に `xmlns:epub` / `xmlns:xlink` を宣言する（未宣言だと WebKit が XML エラーにする）。
   - インライン SVG / MathML の要素名は小文字化される（`foreignObject` → `foreignobject`）。SVG 内の大文字小文字を持つ要素名は既知の表で戻す。
   - `<script>` は無効化しているので中身の直列化は気にしなくてよい。`<style>` の中身は XML エスケープされても CSS として等価。
   - 01-core §4.1 の手順 2 と 02-rendering §3.3 をこの方式に書き換える。`PublicationWarning.malformedXHTML` はそのまま。
2. 代替: Swift 側で HTML5 の木構築を部分的に再現する（`tbody` 補完、セクショニング要素の `p` 終了、adoption agency）。
   仕様が大きく、将来の WebKit の挙動差にも追従が必要なので勧めない。
3. 補足: `import libxml2` は SDK 付属の module map でそのまま通る（`CLibXML2` の system library target は不要だった）。
   01-core §4.1 の「`module.modulemap` で `link "xml2"`」は「SDK の `libxml2` モジュールを直接 import する」に簡略化できる。

### 2.6 縦書き + 見開きのラッパー — 成立

**方法**: 600×400 の WebView に、300×400 の `<iframe>` 2 つを `display: flex` で並べたラッパー HTML を読み込み、両方に項目 4 の縦書き文書（6 回繰り返し、21 ページ）を
`epub://spike/vertical.xhtml` で読ませる。親文書の reader world から `iframe.contentDocument.scrollingElement.scrollTop` を右 = ページ 1、左 = ページ 2 に設定する。
メモリは WebContent プロセス（`_webProcessIdentifier` で特定）の RSS を `ps` で、空文書 → 単独読み込み → ラッパー + iframe×2 の順に同じプロセスで計測した。

**結果**:

| 観測 | 値 |
|---|---|
| 親から `contentDocument` にアクセス | 可能（同一オリジン `epub://spike`） |
| `scrollTop` の読み戻し | 右 400、左 800（設定どおり） |
| iframe 内の `writingMode` / `pageCount` | `vertical-rl` / 21（単独読み込みと同じ） |
| ページ先頭の文字 | 右 =「茶屋の」、左 =「夜になると、宿の二階」= 単独読み込みのページ 1・2 と一致 |
| スナップショットのインク率 | 左 0.092、右 0.088（両面に描画あり） |
| RSS（MB） | 空文書 28.6 → 単独 32.8（+4.2）→ iframe×2 35.4（+6.8）。増分比 1.6 倍 |

スクリーンショット: `Spikes/output/spike6-spread.png`（右にページ 1、左にページ 2）。

**設計への影響**: 02-rendering §6.1 の方式で組める。`forMainFrameOnly: true` の `WKUserScript` は iframe では動かないので、
設計どおり親文書の `reader.js` が iframe の DOM を操作する。メモリは本文のみの小さな文書での値であり、画像の多い章や
iPad の実機での計測（§3.3）は M4 で行う。2 倍ではなく 1.6 倍だったのは、リソース（フォント・CSS）がプロセス内で共有されるため。

### 2.7 `isScrollEnabled = false` と多段組の `scrollLeft` — 成立

**方法**: 項目 3 の横書き 6 ページ文書を 300×400 の WebView で開き、JS から 6 通りの方法でスクロール位置を設定し、読み戻し値と描画の主色を照合した。
縦書き文書でも `scrollTop = 400` の前後でスナップショットを比較した。iOS では `scrollView.isScrollEnabled = false`、`bounces = false`、
`contentInsetAdjustmentBehavior = .never` を設定して同じ手順を実行した。

**結果（macOS）**:

| 操作 | `scrollLeft` 読み戻し | `window.scrollX` | 描画の主色 | 期待 |
|---|---|---|---|---|
| `scrollingElement.scrollLeft = 300` | 300 | 300 | `#27ae60` | ページ 1 ✓ |
| `window.scrollTo(600, 0)` | 600 | 600 | `#2980b9` | ページ 2 ✓ |
| `scrollTo({left: 900, behavior: "instant"})` | 900 | 900 | `#e67e22` | ページ 3 ✓ |
| `documentElement.scrollLeft = 1200` | 1200 | 1200 | `#8e44ad` | ページ 4 ✓ |
| `scrollLeft = 99999` | 1500（`scrollWidth − clientWidth` でクランプ） | 1500 | `#16a085` | ページ 5 ✓ |
| `scrollLeft = 0` | 0 | 0 | `#c0392b` | ページ 0 ✓ |

`document.body.scrollLeft` は常に 0（標準モードでは `scrollingElement` = `html`）。縦書きの `scrollTop = 400` も読み戻し 400 で描画が変わった。

**結果（iOS Simulator 27.0）**: `scrollView.isScrollEnabled = false` でも 6 操作すべて同じ結果（§3）。JS でスクロールした後の
`scrollView.contentOffset` は `(0, 400)` と JS 側の値に同期していた。

**設計への影響**: 02-rendering §1.1 と §4.1 `goToPage` の前提はそのまま。`reader.js` は `document.scrollingElement` を使う。

## 3. iOS Simulator での結果（項目 3・7）

`SpikeKitTests` を iPhone 17 Pro（iOS 27.0）の Simulator で実行した。macOS と同じスパイクコードを `UIWindow` + `clipsToBounds` の親ビューで動かしている。

`scripts/run-ios.sh` で iPhone 17 Pro（iOS 27.0、@3x）の Simulator 上のアプリとして項目 1〜4・7 を実行した。
macOS と同じスパイクコードを `UIWindow` + `clipsToBounds` の親ビューで動かし、`scrollView.isScrollEnabled = false`、
`bounces = false`、`contentInsetAdjustmentBehavior = .never` を設定している。全ログは `Spikes/output/ios/results-ios.md`。

| # | 判定 | iOS での観測 |
|---|---|---|
| 1 | 成立 | macOS と同じ。`ready` / `callAsyncJavaScript` / reply が通り、コンテンツ JS とインライン属性ハンドラは止まる |
| 2 | 成立 | 黄色 23,148 px（範囲外 0）、赤 1,178 px。`Spikes/output/ios/spike2-highlight.png` |
| 3 | 条件付き | クリップ外 2 ページの主色が期待色と一致（`#28ae60` / `#e87f22`、誤差 ±2）。所要 min 6.7 / median 8.0 / max 24 ms。2 ページ文書の `scrollWidth` は 900（下限）|
| 4 | 成立 | `scrollHeight` 4400、`scrollWidth` 300、`pageCount` 11、3 ページ高フレームでも同じ。インク率 0.06〜0.09 |
| 7 | 成立 | 6 操作とも読み戻しと描画が一致。`scrollView.contentOffset` が JS の値に同期（縦書き `scrollTop = 400` → `(0, 400)`） |

iOS 固有の発見が 2 つある。

1. **`<meta name="viewport">` がないとレイアウトビューポートが 980 px になる。** 最初の実行（meta なし）では 300×400 の WebView でも
   `clientWidth = 980`、`clientHeight = 1307` となり、ページ幅 300 の多段組が縮小表示されて `maxScroll = 820`、`contentOffset = (0, 122)` と
   ページ境界が崩れた。`<meta name="viewport" content="width=device-width, initial-scale=1"/>` を `<head>` に入れると macOS と同じ値になる。
   EPUB のリフロー文書は通常この meta を持たないので、`EPUBSchemeHandler` の CSS 注入（02-rendering §3.2）と同時に meta を注入する。
   FXL 文書は自前の viewport meta を持つのでそのまま通す。
2. **iOS の `takeSnapshot` は画面に合成された見た目を撮る。** ウィンドウの出現アニメーション中に撮ると全体がぼやけ、
   ステータスバーと重なる領域には素材の滲みが写った（`Spikes/output/ios/spike3-whole-frame.png` の上端）。
   macOS は WebContent プロセスが描画した画像を返すので（0.4 ms）この影響がない。演出用画像や他のビューを WebView に重ねる前に撮り、
   WebView をステータスバーの下に置かない（セーフエリア内に収める）こと。

## 4. 設計文書への反映（まとめ）

反映済み。項目 5 は提案 1 を「壊れた文書に限定」して採った。整形式な文書は ZIP のバイト列をそのまま配信し、
修復は `XMLParser` で読めなかった文書だけに行う。修復済み XHTML も XML として読めない文書は原文を `text/html` で配信して諦め、
CFI は文字列アサーションで再解決する（01-core §4.1、02-rendering §3.3）。壊れた文書への対応は努力目標であり、
正常な文書の配信経路と保守対象に影響を出さないことを優先した。

| 文書 | 箇所 | 変更 |
|---|---|---|
| 01-core | §4.1 手順 2 | libxml2 で読んだ木を `XML_SAVE_AS_XML` で直列化し、`application/xhtml+xml` で配信する方式に変更。名前空間と SVG 要素名の補正を追記 |
| 01-core | §4.1 末尾 | `CLibXML2` system library target は不要。SDK の `libxml2` モジュールを直接 import する |
| 02-rendering | §3.3 | 「HTML パーサに切り替えて開く」を「Core が整形した XHTML を配信する」に変更 |
| 02-rendering | §5.1 | `pageCount` を `scrollWidth` ではなく末尾センチネルの位置から求める（3 ページ幅フレームでは `scrollWidth` に下限が付く） |
| 02-rendering | §1.2 | 先頭 / 末尾ページでの WebView オフセットの扱いを追記。縦書きのフレームは幅をページ幅に固定 |
| 02-rendering | §3.2 | リフロー文書に `<meta name="viewport" content="width=device-width, initial-scale=1">` を注入する（iOS のレイアウトビューポートが 980 px になるのを防ぐ） |
| 02-rendering | §4.2 `ready` | `.atDocumentEnd` は `DOMContentLoaded` 時点。初回 `layout` は `document.fonts.ready` / `load` 後に確定させる |
| 02-rendering | §7.1 | `takeSnapshot` の `snapshotWidth` は pt、画像はバッキングスケールのピクセル。`PageSnapshot` に scale を持たせる。iOS では画面合成後の見た目を撮るので、演出画像を重ねる前に撮り、WebView をセーフエリア内に置く |
| 04-roadmap | §2 | 本ファイルの判定を反映。項目 5 の設計変更を M1 の作業に加える |
