# 04. ロードマップとテスト方針

個人・数ヶ月で実用レベルに到達することを前提に、動くものを早く出す順に並べる。

## 1. マイルストーン

### M1. コンテナ解析と横書きリフロー表示

- Package.swift を EPUBCore / EPUBRenderer / EPUBUI + umbrella `EPUB` に分割。libxml2 は SDK のモジュールを直接 `import`（system library target は不要）
- `ZIPArchive`（Stored / Deflate / ZIP64）、`EPUBContainer`、container.xml / OPF / nav の解析、`PublicationWarning`
- 壊れた XHTML の修復（libxml2 で回復して整形式 XML に直列化、名前空間と SVG 要素名の補正、再検証と `text/html` への諦め）。01-core §4.1
- `EPUBSchemeHandler`、viewport meta と CSS の注入、`reader.js` の `layout`（末尾センチネルでページ数を算出）/ `goToPage` / `ready`（`fonts.ready` と `load` の後）
- `ReaderSession` の読み込み、`goForward` / `goBackward`、章またぎ
- `EPUBReaderView` と `.slide` 演出、標準ジェスチャ（タップ・スワイプ）
- `ReaderSettings` のフォント・サイズ・行間・余白・テーマ

完了条件: `moby-dick` と `childrens-literature` を開いて最後まで読め、設定変更で再レイアウトされる。

**完了（2026-11-08、コミット 334a982〜9cf8351）。** 完了条件は iOS 27 Simulator と macOS 27 の `Examples/ReaderDemo` で確認した。
実装中に設計を変えた点は各文書に反映済み（02-rendering §1.2 / §3.1 / §3.4 / §4.1 / §5.1 / §5.3、03-api §2.1 / §3.2 / §3.4 / §4.2、
01-core §1.2 / §4.1）。位置の復元は M3 の CFI まで `reader.js` の DOM アンカーで代替している。
積み残しは `TODO.md` に置く（UTF-16 文書への注入、接頭辞付き `<html>` の注入、パーセントデコードの重複、
複数セッションでのコンテナ登録解除、iOS の狭い段での letter-spacing 見出しのはみ出し、iOS 上で動く Renderer テストの置き場、
デモアプリへの fixtures 複製）。

### M2. 縦書きと事前ページ化

- `writing-mode` 判定と縦書き用の多段組、右綴じのジェスチャ反転
- フォント難読化の解除
- `PaginationService`、`PaginationCache`、`BookPagination` と推定値
- 隣接章のスナップショット、3 ページ幅フレーム
- リサイズ追従（iPad の回転、macOS のウィンドウ）

完了条件: `kusamakura-japanese-vertical-writing` を縦書きで読め、総ページ数が確定し、設定を戻すと即座に確定値に戻る。

**完了（2026-11-08、コミット 4f24ca6〜8e23ff6 と、その後の文書・仕上げコミット）。** 完了条件は iOS 27 Simulator（iPhone 17 Pro）の
`Examples/ReaderDemo` で確認した: 草枕 15 章を縦書き・右綴じで最後まで読め（263 回のめくりで 1.1 秒）、総ページ数は約 1 秒で
確定値（270 ページ）になり、フォントサイズ 1.8 で 766 ページに再計測されたあと Reset で即座に 270 に戻る。ページジャンプも動く。
macOS 27 は `swift test`（実 WKWebView）で縦書きのページ数・`scrollTop`・章またぎ、事前ページ化の完了、レイアウト変更の
無効化と復元、リサイズ時のスナップショットを検証した（デモアプリの画面操作による確認は未実施）。
実装中に設計を変えた点は各文書に「M2 で変更」として反映済み（01-core §2.4 / §3 / §7、02-rendering §3.4 / §4.2 / §5.2 / §5.3 /
§7.1 / §8、03-api §2.1 / §3.2 / §3.3 / §3.4 / §4.3 / §4.5）。主な変更: `characterCount` は開いた時点で軽量 DOM から数える、
`ready` は `href` を返し `load` ごとに一意なクエリを付けて古い文書の `ready` を捨てる、推定比率は 500 文字以上の章だけが教える、
再レイアウト中は `relayoutSnapshot` を重ねる、リサイズのデバウンスは macOS のみ。
積み残しは `TODO.md` に置く（iOS で非表示 WebView の計測が表示側と数ページずれる、非表示 WebView の `pageCountChanged` 追従、
`characterCount` の算出を開く処理から外す選択肢、見開き時の `layoutKey`、計測 §3.3 の記録）。

### M3. 位置・選択・ハイライト・検索

- `CFI` のパース・生成・比較と、`reader.js` 側の同一実装。テストベクタ
- `ReadingPosition` の記録と復元。M1 の DOM アンカー（`captureAnchor` / `pageForAnchor`）を `cfiForPage` / `pageFor(cfi)` に置き換え、
  `ReaderEvent.pageChanged` を `positionChanged` に統合する
- 選択メニューへの `SelectionAction` 追加（iOS / macOS）
- `Highlight` の描画（CSS Custom Highlight API）、ハイライトのタップ
- `SearchService` と `show(_:)`

完了条件: ハイライトを保存して再起動後に同じ位置に出る。検索結果から該当ページへ飛べる。

**完了（2026-11-09、コミット d2da1e2〜3640747 と、その後の文書・仕上げコミット）。** 完了条件は iOS 27 Simulator（iPhone 17 Pro）の
`Examples/ReaderDemo` で確認した: moby-dick で "Call me Ishmael" を検索して結果をタップすると Chapter 1 の該当ページに移動し
一時ハイライトが出る。長押しの編集メニューに Highlight / Underline が並び、Highlight で単語に黄色のハイライトが付く。
アプリを終了して再起動し同じ本を開くと、同じ章・ページ（Chapter 6 / Page 1）に戻り、ハイライトが再描画される。
ハイライト一覧からのジャンプと、ハイライトのタップ → 削除アラートも動く。macOS 27 は `swift test`（実 WKWebView）で
選択 → `selectionChanged` と CFI 範囲、ハイライトの章ごとの適用と削除、ハイライトのタップ、検索結果への移動と一時ハイライト
（横書き・縦書き）、コンテキストメニューへの項目追加とハンドラ呼び出しを検証した（デモアプリの画面操作による確認は
今回もセッションに画面操作の許可がなく未実施）。
実装中に設計を変えた点は各文書に「M3 で変更」として反映済み（01-core §5.1 / §5.2 / §5.3 / §6.1 / §6.2、
02-rendering §4.1 / §4.2 / §4.3 / §5.3 / §10、03-api §2.3〜§2.6 / §3.2 / §3.4 / §4.1 / §4.4）。主な変更: CFI の文字オフセットは
UTF-16 コードユニット、`CFI` は spine ステップを保持し `Publication.spineIndex(of:)` が idref を優先して解決する、
`SelectionAction` は EPUBRenderer に置き `ReaderSession.selectionActions` を公開する、選択メニューは `currentSelection()` を
その場で呼ばずデバウンス済みの `currentSelection` を使う、`cfiForVisibleRange` は未実装、`TextLength` は `TextMap` に統合、
`SearchResult.matchedText` と `ReaderSession.pageIndex(for:)` を追加。
積み残しは `TODO.md` に置く（読み込み前の初期位置指定（M6 後に `ReaderSession(container:settings:initialPosition:)` で解消）、`cfiForPage` の確率的な先頭判定、iOS の選択メニューの自動テスト、
ハイライトのスタイル更新時の差分適用など）。

### M4. FXL と見開き

- ラッパー文書と `SpreadBuilder`、`page-spread-*` の尊重
- FXL のスケーリングとピンチズーム
- 横書きリフローの見開き（多段組 2 本）、縦書きリフローの見開き（ラッパー）

完了条件: `cole-voyage-of-life` と `haruko-html-jpeg` が見開きで表示され、iPad 縦では単ページに切り替わる。

**完了（2026-11-09、コミット 990a1de〜b7ee780 と、その後の文書・仕上げコミット）。** 完了条件は iOS 27 Simulator
（iPad Pro 11-inch (M4)）の `Examples/ReaderDemo` で確認した: `haruko-html-jpeg` は横向きで p01 が左半分に単独、めくると
p02（右）+ p03（左）の右綴じ見開きになり、縦向きに回すと面全体の単ページに切り替わる。`page-blanche` は表紙が右に単独、
次が 1+2 の見開き。`cole-voyage-of-life` は本文が 2 段の見開きで、絵画のページ（`rendition:spread-none`）は単独の全面。
設定の Spread ピッカーで Never → 単ページ、Auto → 見開きに戻る。FXL の面ではピンチで拡大（ステータスバーに ZOOM）、
拡大中はタップめくりが止まりパンでき、ピンチアウトで戻る。iPhone 17 Pro では縦が単ページ、横が見開きの面になる。
macOS 27 は `swift test`（実 WKWebView、120 件）で FXL の配置・スケール・CFI 保持・リサイズでの単ページ ⇄ 見開き切り替え・
スナップショットと、横書きリフローの 2 段 / 縦書きリフローの 2 フレーム、`allowsMagnification` の切り替えを検証した
（デモアプリの画面操作による確認は今回もセッションに画面操作の許可がなく未実施）。
実装中に設計を変えた点は各文書に「M4 で変更」として反映済み（01-core §2.2 / §3 / §7、02-rendering §1.2 / §2.1 / §3.2 / §4.1 /
§4.2 / §5.2 / §6.1〜§6.3 / §8.2 / §11、03-api §2.2 / §3.2 / §3.4 / §4.3 / §4.5）。主な変更: ラッパー URL は
`_reader/spread?kind=fixed|vertical&pages=1r,2l` の形、`reader.js` を iframe 内でも動かしラッパーが同じ API を Swift に見せる、
FXL 文書には `reader-fixed.css` だけを注入し出版社のデザインに手を入れない、`page-spread-*` のない FXL ページは綴じの
反対側から交互に置く、`LayoutKey.isSpread` と `SpreadPlan` 単位の事前ページ化、ズームは iOS では viewport meta と
ピンチ認識器で制御する（`zoomScale` の KVO はピンチ中に出ない）、`missingViewport` は Core が開いた時点で出す。
積み残しは `TODO.md` に置く（iOS での縦書きラッパーの確認、ズーム中のパン範囲、iframe をまたぐ選択、`rendition:orientation`
の扱い、空ページを先頭に持つ面の `position` など）。

### M5. 脚注・画像・macOS 入力・仕上げ

- `noteref` のポップアップ用イベント、内部リンク、外部リンク
- 画像タップのイベントと画像データ取得
- macOS のキーボード、トラックパッドのスワイプ
- WebContent プロセス終了からの復旧、メモリ警告時の挙動
- VoiceOver 動作確認（演出中にフォーカスが飛ばない）

完了条件: 自分のアプリに組み込み、日常の読書に使える。

**完了（2026-11-09、コミット aba827e〜bd2393d と、その後の文書・仕上げコミット）。** 組み込み先として `Examples/ReaderDemo` に
脚注ポップオーバー（「Go to note」付き）、内部リンクの戻るスタック、外部リンクの確認ダイアログ、ピンチ・ダブルタップで拡大できる
画像ビューア、macOS のキー・トラックパッドを入れ、iOS 27 Simulator で通し確認した。iPhone 17 Pro では links-sample の章内・章間・
外部リンクと戻る、同一文書 / 別文書の脚注・後注のポップオーバーと「Go to note」、FXL ページ内のリンク、中央タップでの画像ビューア
（左右のタップゾーンではめくり）、アラビア語（`regime-anticancer-arabic`）の右綴じのタップ方向・段の位置・章内の脚注リンクと戻る・
横向きでの右綴じ見開き・回転での位置保持、The Waste Land の難読化フォントの表示と検索（結果から該当ページへ移動して一時
ハイライト）を確認した。iPad Pro 11-inch (M4) の横向きでは links-sample が 2 段の見開きになり、脚注ポップオーバーと最後の見開きの
位置を確認した。通し確認で見つけた不具合（横書きの章の最後の数ページが余白 1 つ分ずれる。WebKit の多段組のスクロール範囲が
末尾 padding を含まないため）は 02-rendering §3.4 のとおり直し、`PageAlignmentTests` を足した。
macOS 27 は `swift test`（実 WKWebView。4 つのテストターゲットで計 142 件）で、リンク・脚注・画像タップ（`LinksNotesImagesTests`）、
キー対応表とスワイプ判定（`KeyboardAndTrackpadTests`）、WebContent の実クラッシュからの復旧とメモリ警告（`RecoveryTests`）、
右から左の言語（`RightToLeftTests`）、ページ位置（`PageAlignmentTests`）を検証した。デモアプリの macOS での画面操作による確認は
画面操作の許可が得られず未実施で、ビルドと起動までにとどめた。VoiceOver は実装（02-rendering §7.3）までで、
VoiceOver を有効にした通し確認はしていない。
実装中に設計を変えた点は各文書に「M5 で変更」「M5 で追加」として反映済み（01-core §5.3、02-rendering §3.4 / §4.2 / §6.2 / §7.3 /
§8.4 / §9、03-api §3.4 / §4.3 / §5）。主な変更: noteref は `epub:type="noteref"` だけを対象にし、同じ文書の脚注は本文から隠して
ポップアップで読む、別文書の脚注は EPUBCore で解決する（`NoteContent.html` は nil）、`TappedImage` はバイト列を非同期クロージャで
渡す、左右のタップゾーンでは画像のタップよりめくりを優先する、右綴じの横書きリフローの見開きは 2 フレームのラッパーで表示する、
`dir="rtl"` のルートは `ltr` で組んで `body` に `rtl` を移す、WebContent の終了では 30 秒以内に 3 回まで自動で読み直す、
メモリ警告からの再開を設定変更でも行い検索インデックスも捨てる、読み込み中は WebView を隠さず幕を被せる（VoiceOver のため）、
M4 で `public` になっていた `SpreadBuilder` / `SpreadPlan` を `internal` に戻した。
積み残しは `TODO.md` に置く（macOS の画面操作による確認、VoiceOver の実機確認、`loadTimeout` のテスト、
`role="doc-noteref"` の扱い、別文書の脚注の書式など）。

### M6. 注釈（EPUB Annotations 1.0）

設計は 06-annotations。基準は W3C Working Draft 2026-10-15。

- 06-annotations §12 の検証（`textContent` の一致、`line-through`、重ね描きレイヤー）。**2026-11-10 に成立を確認**（`AnnotationPrerequisiteTests`）。
  WebKit が `script` 要素を DOM から除くことが分かったので、EPUBCore の軽量 DOM からも除いた（2026-11-10。01-core §4.2）
- `Annotation` / `AnnotationSet` と JSON の符号化・復号（storage / export）。`Highlight` / `Bookmark` を削除する
- CFI ⇄ CssSelector / TextPositionSelector / TextQuoteSelector の生成と解決（EPUBCore）。`epubswift:CfiSelector` の併記
- 書籍との照合、取り込みのマージ計画
- `ZIPWriter` と `.annotations` の読み書き、EPUB 同梱の `META-INF/annotations.json` の遅延読み込み
- `ReaderSession.annotations` / `publicationAnnotations`、4 つのスタイルの描画、色パレット、`annotationTapped`
- `Examples/ReaderDemo` の移行（保存ファイル、色ラベルのメニュー、`.annotations` の書き出しと取り込み）

完了条件: ReaderDemo で付けたハイライトとしおりを `.annotations` に書き出し、別の端末（または注釈を消した状態）で取り込むと
同じ位置・色・スタイルで出る。CFI セレクタを除いて書き出したファイルからも同じ位置に戻る。

EPUB への埋め込み書き出しと、画像の領域（`xywh`）の描画は M6 に含めない（06-annotations §9.4、§6.2）。

**完了（2026-11-10、コミット ad3596f〜b6ea1b6 と文書のコミット）。** EPUBCore に注釈のモデルと JSON の符号化（storage / export）、
CFI ⇄ 標準セレクタの生成と解決（`.source` の木で数え `.rendered` の木の CFI に対応させる）、書籍との照合、マージ計画、
`ZIPWriter` と `.annotations` の読み書き、同梱注釈の遅延読み込みを入れた。EPUBRenderer は `ReaderSession.annotations` /
`publicationAnnotations` で 4 つのスタイルを描き（outline は `<html>` 末尾の重ね描きレイヤー）、テーマにパレットを持たせ、
`Highlight` / `Bookmark` を削除した。`Examples/ReaderDemo` は保存ファイルを注釈に移し、色ラベルとスタイルの編集、しおり、
`.annotations` の書き出し（CFI あり・なし）と取り込み（解決・照合・マージの確認）を持つ。
完了条件は `AnnotationRenderingTests.exportDeleteImportRestoresTheDrawing` で、ReaderDemo と同じ呼び出し（セレクタ生成 →
`AnnotationArchive` → 全削除 → 読み込み → `resolve` → `AnnotationMergePlan`）を Moby-Dick の 4 スタイルのハイライトと
しおりに対して CFI あり・なしの両方で行い、同じ id・位置・色・スタイルと同じ描画（`::highlight()` の規則と枠の数）に戻ることを
確かめた。macOS 27 の `swift test` は 4 つのテストターゲットで計 217 件が通る。ReaderDemo はビルドまでで、画面を操作しての
書き出し・取り込みの確認はしていない（`TODO.md`）。
実装中に設計を変えた点は各文書に「M6 で変更」「M6 で追加」「M6 で確定」として反映した（01-core §1、03-api §2.5 / §3.1 /
§3.2 / §3.4、02-rendering §4.1 / §4.2、06-annotations §3 / §4.3 / §6.2 / §7 / §8 / §9.2 / §9.3 / §10 / §14）。主な変更:
`Selector` は Foundation と衝突するので `AnnotationSelector` に、`AnnotationArchive.set` は `annotationSet` にした。
標準セレクタは `Target.generatedSelectors` に生成してから書き出す。CFI セレクタは書き出しのたびに現在の位置から作り直す。
マージの「同じ内容」は日時と作成者を比べない。Text Fragment の前後の文脈の間の空白を許す。
積み残しは `TODO.md` に置く。

## 2. 先に検証する項目（検証済み）

実装前に `Spikes/` の小さなコードで確かめた。詳細と根拠は `05-spike-results.md`。設計文書には反映済み。

| 項目 | 懸念 | 判定 | 設計への反映 |
|---|---|---|---|
| `allowsContentJavaScript = false` と `WKUserScript` | コンテンツ JS を止めた状態でブリッジ JS が動くか、`WKContentWorld` 指定で `callAsyncJavaScript` が通るか | 成立 | `.atDocumentEnd` は `DOMContentLoaded` 時点。初回 `layout` は `fonts.ready` / `load` 後に確定（02 §4.2） |
| CSS Custom Highlight API | WKWebView（iOS 27 / macOS 27）で `CSS.highlights` と `::highlight()` が使えるか | 成立 | 変更なし |
| 3 ページ幅フレームのスナップショット | `takeSnapshot(with:)` の `rect` でクリップ外の領域が撮れるか、描画コストは許容範囲か | 条件付き | ページ数は `scrollWidth` でなく末尾センチネルから求める（02 §5.1）。先頭 / 末尾ページのオフセット（02 §1.2）。iOS は viewport meta 必須（02 §3.2）。`PageSnapshot` に scale、iOS は合成後の見た目を撮る（02 §7.1） |
| 縦書き多段組 | `column-width` が縦方向に効き、段が縦に積まれるか。`scrollHeight` が総段数を反映するか | 成立 | 縦書きフレームは幅をページ幅に固定（02 §1.2） |
| XML エラー文書の `text/html` 配信 | HTML パーサで開いたときの CFI が EPUBCore 側と一致するか | 不成立 | libxml2 2.9 は HTML5 の木構築規則を持たない。壊れた文書は Core が整形式 XML に直列化して `application/xhtml+xml` で配信し、直らなければ `text/html` で諦める（01 §4.1、02 §3.3）。`CLibXML2` target は不要 |
| 縦書き + 見開きのラッパー | 2 つの iframe で同一文書を隣接ページに合わせられるか、メモリ | 成立 | 変更なし。メモリ増分は単独の約 1.6 倍（小さな文書） |
| `scrollView.isScrollEnabled = false` と多段組の `scrollLeft` | JS から `scrollLeft` を設定して描画が追従するか、iOS で `window.scrollTo` が無視されないか | 成立 | 変更なし |

## 3. テスト方針

### 3.1 フィクスチャ

IDPF epub3-samples（https://github.com/IDPF/epub3-samples）から次を `Tests/Fixtures/` に置く。
ライセンスは各サンプルの OPF に記載があり、Tests/Fixtures/LICENSES.md に転記する。

| サンプル | 用途 |
|---|---|
| `childrens-literature` | 横書きリフロー、nav の階層、`page-list` |
| `moby-dick` | 横書きリフロー、長い書籍のページ化 |
| `kusamakura-japanese-vertical-writing` | 縦書き、ルビ、右綴じ（M2 で追加。音声 mp3 は省いて 232 KB にしてあり、`missingResource` 警告が 2 件出る） |
| `wasteland-otf-obf` | フォント難読化（IDPF 方式。M2 で追加） |
| `cole-voyage-of-life` | リフロー本文 + FXL の絵画 4 ページ（itemref の `rendition:layout-pre-paginated` / `spread-none` / `orientation-landscape`、viewport 1024×697）。`page-spread-*` は使っていない（M4 で追加） |
| `haruko-html-jpeg` | FXL 漫画（JPEG）、右綴じ、`rendition:spread landscape`、p01〜p12 に `page-spread-left` / `right`、最後に リフローの About（M4 で追加） |
| `page-blanche` | FXL（JPEG、viewport 1200×1577）、`page-spread-left` / `right`、`page-progression-direction` なし（M4 で追加。SVG ではない） |
| `regime-anticancer-arabic` | アラビア語の横書きリフロー、`<html dir="rtl">`、`page-progression-direction="rtl"`（M5 で追加。IDPF での名前は `arabe` ではなく `arabic`。無加工で 111 KB） |

IDPF 以外に、この計画のために書いた小さな EPUB も置く（ソースは同じ名前のディレクトリ）。

| フィクスチャ | 用途 |
|---|---|
| `cfi-sample` | CFI のテストベクタと検索（M3） |
| `links-sample` | 章内・章間・外部リンク、同一文書 / 別文書の noteref、隠す脚注、画像タップ、FXL ページ（viewport 600×800）内のリンクと noteref（M5） |

Adobe 方式の難読化は公開サンプルがないので、テスト内で IDPF サンプルのフォントを Adobe 方式で難読化し直して検証する。

### 3.2 層ごとのテスト

| 層 | 方法 | 実行環境 |
|---|---|---|
| EPUBCore | Swift Testing。フィクスチャを開いてモデルを検証。CFI はテストベクタ。壊れた XHTML は `Spikes/Sources/SpikeKit/Fixtures.swift` の 3 文書を `Tests/Fixtures/malformed/` に移し、修復済み XHTML が `XMLParser` で読めることと、名前空間・SVG 名の補正を検証 | `swift test`（macOS） |
| EPUBRenderer | Swift Testing + 実 WKWebView。`@MainActor` のテストで `ready` を待つ。`reader.js` の CFI は Core と同じベクタで JS 側を検証。修復済み XHTML を読み込み、WebKit の DOM ダンプが Core の軽量 DOM と一致することを検証（スパイク 5 の比較方法を流用） | `swift test`（macOS）。WKWebView は macOS のテストプロセスで動く。iOS 固有の挙動（スクロール同期）は M1 時点では Simulator での手動確認のみで、iOS 上で動く回帰テストの置き場は未決（`TODO.md`） |
| EPUBUI | 手動確認用の `Examples/ReaderDemo` アプリ（M1 で作る）。自動テストは持たない | Xcode |

`swift test` は M1 からリポジトリの標準コマンドとし、作業の終わりに必ず通す。

### 3.3 計測

M2 以降、`Examples/ReaderDemo` で次を Instruments またはログで記録する。

- 書籍を開いてから最初のページが出るまで（目標 500 ms 以下、`moby-dick`）
- 全章の事前ページ化完了まで（`moby-dick`、記録のみ）
- めくり 1 回のフレーム落ち（60 fps 維持）
- 読書中のメモリ（表示用 + 事前ページ化用 WebView、目標 150 MB 以下）

### 3.4 マイルストーン後の追加

- **2026-11-12: 進捗スライダーと移動のイベント。** 組み込み先（Laperm）の要望で、EPUBUI に `ReaderProgressSlider`（03-api §4.6）、
  `ReaderEvent.navigated`（03-api §3.4）、`Publication.chapterTitle(forSpineIndex:)` を足した。`Examples/ReaderDemo` は
  ステータスバーにスライダーを置き、戻るスタックを印として出す（リンクの移動元は `navigated` から取る）。テストは
  `EPUBUITests/ProgressSliderTests`（算術）と `EPUBRendererTests/NavigationEventTests`（実 WKWebView）。
  同日の codex レビュー（5967cbe）で直したこと: ドラッグ中のラベルが常に中央に出た（枠が提案の幅いっぱいに広がり、その幅を
  測っていた）、macOS でフォーカスのあるスライダーより先にリーダーが ← → を取った、見開きで増減が進まなかった
  （`ReaderSession.visiblePages` を足した）、移動を始めた順に行わなかった、前の押下の取り消しが次の押下を終わらせえた、
  押している間に外されると `onEditingChanged(false)` が出なかった、読み直しの上限の後の移動に `navigated` が出なかった、
  ReaderDemo の戻りの印を移動の成功前に書き換えていた。見送り: ドラッグ中のページ数の測り直しへの追従、章名の索引化
  （03-api §4.6 の既知の制限）。

## 4. スクロール表示（S1 実装済み、S2 以降は未実装）

縦の連続スクロールは `08-continuous-scroll.md` に設計した（2026-11-14。方式の根拠は `07-continuous-scroll-spike.md` の実測）。
マイルストーンは 08 §13 の S1〜S4: S1 スクロールで読める（終わりに利用者が実機で確かめ、問題があれば方式を見直す）、
S2 機能をそろえる、S3 ページ番号、S4 Laperm への組み込み。

- **S1**（2026-11-14 実装）: 自動テストと macOS / iOS Simulator での実測まで済み（結果は 07 §4、設計と違えた点は 08 §16）。
  残りは利用者による実機での確認。
- テスト: `ScrollCoreTests`（WebView 無しの算術）、`ScrollPagingTests`（仮想ページ、対象の本の振り分け）、`ScrollLayoutTests`
  （位置、ジャンプ、キー、再レイアウト、切り替え）、`ScrollStabilityTests`（位置の安定。ウィンドウの実画面を読む）、
  `ScrollWheelTests`（macOS のトラックパッド。合成したホイールイベント）。指でのスクロールは ReaderDemo の記録モード。

## 5. 将来の拡張点（今回は作らない）

- `SpineRenderer` を公開し、ネイティブ描画（Core Text）を日本語小説向けに差し替える
- EPUB 2 の NCX フォールバック
- 永続化ヘルパー（SwiftData モデルの提供）
