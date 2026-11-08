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

### M2. 縦書きと事前ページ化

- `writing-mode` 判定と縦書き用の多段組、右綴じのジェスチャ反転
- フォント難読化の解除
- `PaginationService`、`PaginationCache`、`BookPagination` と推定値
- 隣接章のスナップショット、3 ページ幅フレーム
- リサイズ追従（iPad の回転、macOS のウィンドウ）

完了条件: `kusamakura-japanese-vertical-writing` を縦書きで読め、総ページ数が確定し、設定を戻すと即座に確定値に戻る。

### M3. 位置・選択・ハイライト・検索

- `CFI` のパース・生成・比較と、`reader.js` 側の同一実装。テストベクタ
- `ReadingPosition` の記録と復元
- 選択メニューへの `SelectionAction` 追加（iOS / macOS）
- `Highlight` の描画（CSS Custom Highlight API）、ハイライトのタップ
- `SearchService` と `show(_:)`

完了条件: ハイライトを保存して再起動後に同じ位置に出る。検索結果から該当ページへ飛べる。

### M4. FXL と見開き

- ラッパー文書と `SpreadBuilder`、`page-spread-*` の尊重
- FXL のスケーリングとピンチズーム
- 横書きリフローの見開き（多段組 2 本）、縦書きリフローの見開き（ラッパー）

完了条件: `cole-voyage-of-life` と `haruko-html-jpeg` が見開きで表示され、iPad 縦では単ページに切り替わる。

### M5. 脚注・画像・macOS 入力・仕上げ

- `noteref` のポップアップ用イベント、内部リンク、外部リンク
- 画像タップのイベントと画像データ取得
- macOS のキーボード、トラックパッドのスワイプ
- WebContent プロセス終了からの復旧、メモリ警告時の挙動
- VoiceOver 動作確認（演出中にフォーカスが飛ばない）

完了条件: 自分のアプリに組み込み、日常の読書に使える。

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
| `kusamakura-japanese-vertical-writing` | 縦書き、ルビ、右綴じ |
| `wasteland-otf-obf` | フォント難読化（IDPF 方式） |
| `cole-voyage-of-life` | FXL、`page-spread-*` |
| `haruko-html-jpeg` | FXL 漫画、右綴じの見開き |
| `page-blanche` | FXL、SVG |
| `regime-anticancer-arabe` | RTL 言語、`dir` 属性 |

Adobe 方式の難読化は公開サンプルがないので、テスト内で IDPF サンプルのフォントを Adobe 方式で難読化し直して検証する。

### 3.2 層ごとのテスト

| 層 | 方法 | 実行環境 |
|---|---|---|
| EPUBCore | Swift Testing。フィクスチャを開いてモデルを検証。CFI はテストベクタ。壊れた XHTML は `Spikes/Sources/SpikeKit/Fixtures.swift` の 3 文書を `Tests/Fixtures/malformed/` に移し、修復済み XHTML が `XMLParser` で読めることと、名前空間・SVG 名の補正を検証 | `swift test`（macOS） |
| EPUBRenderer | Swift Testing + 実 WKWebView。`@MainActor` のテストで `ready` を待つ。`reader.js` の CFI は Core と同じベクタで JS 側を検証。修復済み XHTML を読み込み、WebKit の DOM ダンプが Core の軽量 DOM と一致することを検証（スパイク 5 の比較方法を流用） | `swift test`（macOS）。WKWebView は macOS のテストプロセスで動く |
| EPUBUI | 手動確認用の `Examples/ReaderDemo` アプリ（M1 で作る）。自動テストは持たない | Xcode |

`swift test` は M1 からリポジトリの標準コマンドとし、作業の終わりに必ず通す。

### 3.3 計測

M2 以降、`Examples/ReaderDemo` で次を Instruments またはログで記録する。

- 書籍を開いてから最初のページが出るまで（目標 500 ms 以下、`moby-dick`）
- 全章の事前ページ化完了まで（`moby-dick`、記録のみ）
- めくり 1 回のフレーム落ち（60 fps 維持）
- 読書中のメモリ（表示用 + 事前ページ化用 WebView、目標 150 MB 以下）

## 4. 将来の拡張点（今回は作らない）

- `SpineRenderer` を公開し、ネイティブ描画（Core Text）を日本語小説向けに差し替える
- 連続スクロールモード
- EPUB 2 の NCX フォールバック
- 永続化ヘルパー（SwiftData モデルの提供）
