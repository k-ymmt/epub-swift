# TODO

## M1 の積み残し（その他）

- [ ] iOS の狭い列幅で letter-spacing の大きな見出し（moby-dick の "TRANSCRIBER'S" など）が列からはみ出す。コンテンツ側のスタイルなので reader-after.css で `overflow-wrap` / `word-break` を当てるかどうか方針を決める。
- [ ] Renderer の自動テストは macOS のみ。iOS 固有だった `WebViewSpineRenderer.syncNativeScroll`（UI プロセス側のスクロールクランプ対策）はシミュレータ上の手動確認だけなので、iOS で動く回帰テスト（XCTest/xcodebuild test）の置き場を決める。
- [ ] `Examples/ReaderDemo/Sources/ReaderDemo/Books/` に `Tests/Fixtures` の epub をコピーしている（1.7 MB の重複）。SwiftPM のリソースでシンボリックリンクが使えるか確認し、使えるなら共有する。

## M2 の積み残し（2026-11-08）

- [ ] iOS で `PaginationService`（ウィンドウに載せていない非表示 WKWebView）の章ページ数が表示用 WebView の計測と数ページずれる。iPhone 17 Pro Simulator の草枕で非表示側の合計 264 ページに対し、表示側で全章を表示し直すと 270 ページになった（macOS では全章一致）。原因候補: 非表示ビューでは `ready` 後にフォント / ルビの描画が確定しておらず、表示側だけが `pageCountChanged` で補正している。非表示ビューでも `pageCountChanged` を受けて `PaginationCache` を更新するか、計測前に 1 フレーム待つかを検証する。
- [ ] `PaginationService` は章の `pageCountChanged`（遅延画像で章が伸びる）を追わない。計測後に増えた分は表示側が章を開いたときに上書きされるだけ。
- [ ] `SpineItem.characterCount` を `EPUBContainer` を開くときに全章分計算している（moby-dick で約 20 ms、大きな本では開く時間に効く）。遅延計算や検索インデックス（M3）との統合を検討する。
- [ ] 04-roadmap §3.3 の計測（最初のページまでの時間、事前ページ化の完了時間、メモリ）を Instruments で記録していない。草枕の事前ページ化は macOS のテストで約 0.7 秒、iOS Simulator で約 1 秒（目視）。
- [ ] `EPUBReaderView` の周囲の UI の高さが変わると `viewportSize` が変わり全章の再計測になる（デモではステータスバーの高さを固定して回避）。数 pt の変化を無視する、または高さ変化を遅延して適用するなどライブラリ側で吸収するか検討する。

## M3 の積み残し（2026-11-09）

- [ ] `ReaderSession` に読み込み前の初期位置を渡す手段がない（`go(to:)` は `viewportSize` が決まり章が読み込まれてから有効）。アプリは最初の `positionChanged` を待って `go(to:)` を呼ぶ必要があり、最初の章が一瞬見える。`ReaderSession(container:settings:initialPosition:)` か `loadIfNeeded(at:)` を検討する。
- [ ] `cfiForPage` はページ先頭の「見えている最初のテキスト」を `caretRangeFromPoint` の数点のプローブと矩形走査で決めるため、浮動要素や多段のテーブルではページ先頭より後ろの文字を返すことがある。`cfiForVisibleRange()`（02-rendering §4.1）と合わせて、ページ内の全テキスト矩形から厳密に先頭を選ぶ実装を検討する。
- [ ] iOS の `buildMenu(with:)` による編集メニュー追加はシミュレータの手動確認のみ（Renderer の自動テストは macOS の `willOpenMenu` 経路だけ）。iOS で動く回帰テストの置き場（M1 の積み残し）と合わせて決める。
- [ ] `ReaderSession.highlights` の変更は毎回現在章の全ハイライトを `setHighlights` で描き直す（差分適用なし）。数百件規模で設定変更やタップのたびに全件を解決するコストを測り、必要なら id ごとの追加・削除に分ける。
- [ ] `SelectedText.rects` / `highlightTapped` の矩形は `selectionChanged` 受信時点の可視ページ座標で、その後ページ移動や再レイアウトがあると古くなる。アプリがメニューを出すときは `rects(for:)` で取り直す運用にしているが、ライブラリ側で位置変更時に `currentSelection` を更新するか検討する。
- [ ] `SearchService` の抽出結果（`TextMap`）は spine item ごとに actor 内へ無期限にキャッシュする。大きな本では本文全体をメモリに持つことになるので、上限を検討する（M2 の `contentDocuments` の積み残しと同じ話。メモリ警告での破棄は M5 で入れた: `ReaderSession` がサービスごと捨てる）。
- [ ] 検索は線形 spine item のみ。非線形（`linear="no"`）の文書は対象外にしている。必要なら `SearchOptions` にフラグを足す。

## M4 の積み残し（2026-11-09）

- [ ] 縦書きリフローの見開き（`_reader/spread?kind=vertical`、同じ文書を 2 つの iframe に読む）は macOS の `swift test` だけで確認した。iOS 27 Simulator の草枕を横向きにして、2 フレームの `scrollTop` 合わせ・ページ数・位置復元・選択が動くか確認する（iOS の iframe は内容に合わせて伸びることがある）。
- [ ] FXL のピンチズームは WKWebView 全体（3 スロット幅のフレーム）に掛かるので、iOS のパンは面の外（空白のスロット）まで動ける。ズーム中は `contentInset` / `contentSize` を面に合わせるか、ラッパー文書側で `transform` によるズームに切り替えるか検討する。macOS の `magnification` も同様。
- [ ] 見開きラッパーでは選択が iframe をまたげない（設計どおりの制限）。縦書き見開きで右フレーム末尾から左フレーム先頭に続く文を選べない。必要なら 2 つの選択を 1 つの `CFIRange` に合成する。
- [ ] `rendition:orientation`（書籍・itemref）は読んで `Publication.orientation` / `SpineItem.orientation` に入れるだけで、端末の向きの固定や「横向き専用」の表示（縦向きで 2 ページを縮めて見開きにする）はしていない。
- [ ] 見開きの面で先頭ページに CFI を作れるテキストがないと（page-blanche の p01 のような白紙）、`cfiForPage` が次の iframe に進むので `position` / `currentSpineIndex` が面の 2 ページ目になる。Spread ポリシーを Never に切り替えると 2 ページ目（title）が表示される。先頭ページの spine ステップだけの CFI（`/6/2[p01]!`）を返すことを検討する。
- [ ] `BookPagination` は FXL の各ページを書籍ページ 1 つと数えるので、見開きの面を 1 回めくると `currentPage` が 2 進む。面を単位にした進捗（`totalProgression`）を出すか、UI 側で「面」の番号を出すかを決める。
- [ ] FXL の面には `ReaderSettings.theme` を当てない（出版社のページそのまま）ので、ダークテーマでは FXL の面だけ白く光る。ダークテーマ時の減光（`filter: brightness`）を FXL にも当てるか検討する。ラッパーの背景色も白固定。
- [ ] 見開きラッパーは章内の前後の面を隣のスロットに置かないので、FXL の面のめくりはすべて destinationPending（到着後に撮る）経路になり、スナップショットでのめくり演出が 1 テンポ遅れる。隣の面を事前に 2 つ目のラッパーへ読み込むか、`PaginationService` の隣接面スナップショット（02-rendering §8.3）を面単位に広げる。
- [ ] `Examples/ReaderDemo/Sources/ReaderDemo/Books/` の fixture の重複（M1 の積み残し）が FXL の 3 冊分（約 5 MB）増えた。
- [ ] macOS のトラックパッドのピンチ（FXL のズーム）は実機で未確認。見開き表示とウィンドウリサイズでの単ページ ⇄ 見開きは 2026-11-09 に macOS 27 の ReaderDemo で確認した。

## M4 の積み残し（2026-11-09 の Codex 敵対的レビューで確認した不具合。未修正のもの）

- [ ] `Sources/EPUBRenderer/ReaderSession.swift` `go(toSpineIndex:)` / `go(to cfi:)` / `refreshPosition`: 表示中の FXL 見開きの 2 ページ目へ移動しても `position` は面の先頭フレームの CFI のまま（`reader.js` の `cfiForPage` は FXL では最初の iframe の CFI を返す）。はるこの [1,2] 表示中に `go(toSpineIndex: 2)` してから Spread を Never にすると spine 1 が開く。FXL の面では「最後に要求されたページ」を覚えて `position` に反映するか、`cfiForPage` にページ（iframe）を指定できるようにする。上の「白紙の先頭ページ」の項目と同じ箇所。

## M5 の積み残し（2026-11-09）

- [ ] macOS 27 の ReaderDemo の画面確認（2026-11-09）で未確認のまま残ったもの: ↑ ↓ PageUp Home/End のキー、トラックパッドの 1 スワイプ 1 ページ（操作ツールの合成スクロールにはフェーズがない）、画像ビューア、外部リンクのダイアログ。確認済み: → ← space ⇧space PageDown（章またぎ、右綴じでの ← が次）、タップめくり、検索シート、右クリックの Highlight、内部リンクと戻る、脚注ポップオーバー、テーマと見開き設定の往復、縦書き・FXL・アラビア語の見開き。
- [ ] macOS でページ左右 4 分の 1 の単語をダブルクリックすると、1 回目のクリックがタップめくりとして扱われ、ページがめくれてから単語が選択される。タップめくりをダブルクリックの判定時間だけ遅らせるか、`clickCount` が 2 以上ならめくりを取り消すかを決める（`EPUBReaderView.turnForTap`）。
- [ ] 画像タップはページ中央の領域でだけ画像ビューアを開き、左右 4 分の 1 ではめくりになる（M5 の判断）。macOS の見開きや本文の左寄せ画像ではほとんどの画像が左右の領域に入り、画像ビューアを開けない。画像の大部分が中央にかかるなら開く、修飾キー付きクリックで開くなどを検討する。
- [ ] VoiceOver を実際に有効にした確認（読み込み中にフォーカスが飛ばないこと、3 本指スワイプでのページ送りと「Page n of m」の読み上げ）は未実施。iOS 27 Simulator には VoiceOver がないので、実機か Accessibility Inspector で確かめる。
- [ ] デモアプリでの WebContent プロセス終了からの復旧は未確認（`RecoveryTests` が macOS の実 WKWebView で SIGKILL を送って検証しているだけ）。iOS の実際のメモリ圧迫による終了と、メモリ警告からの再開も手動では見ていない。
- [ ] 読み込みタイムアウト（`ReaderError.loadTimeout`）には専用のテストがない。`ready` を返さない文書を作るのは難しいので、`SpineRenderer` のテスト用実装で `ready` を止めて確かめるか検討する。
- [ ] noteref は `epub:type="noteref"` のリンクだけを脚注として扱う。`role="doc-noteref"` だけのリンクや、`<sup><a href="#fn1">1</a></sup>` のような普通のリンクは `internalLink` として脚注の位置へ移動する。DPUB-ARIA の `role` も見るか、`aside` を指す短いリンクを脚注とみなすかを決める。
- [ ] 別文書の脚注（rearnote など）は `NoteContent.html` が nil で、テキストだけになる（EPUBCore の解析結果から作るため）。書式付きで見せたいなら Core 側で要素を XHTML 断片として直列化する。
- [ ] 横書き多段組のスクロール範囲を `html::after` で広げる対策（02-rendering §3.4）は WebKit の挙動に依存している。WebKit が末尾 padding を含めるように変わっても箱がページ数ちょうどなので害はないが、`PageAlignmentTests` が落ちたら最初に疑う。
- [ ] iOS 27 Simulator の通し確認（iPhone 17 Pro / iPad Pro 11-inch）は、この M5 では links-sample・アラビア語・The Waste Land（難読化フォント、検索）を中心に行い、Moby-Dick・草枕・はるこ・Page blanche・Voyage of Life は M4 までの確認に頼った。

## M5 の積み残し（2026-11-09 の Codex 敵対的レビューで確認した不具合。未修正のもの）

- [ ] `reader.js` `hideReferencedNotes` と `SearchService`: noteref から参照される aside は `display: none` で隠すが、検索の索引（EPUBCore の `TextMap`）には aside の本文が入るので、links-sample で「first footnote」を検索して `show(_:)` しても注は表示されず、ページも動かず、一時ハイライトも見えない。検索で隠れた注に当たったら noteref と同じ `NoteContent` を出すか、索引から隠れる注を除くか、`show` の間だけ注を表示するかを決める。

## 判断不要の不具合の修正（2026-11-09）の積み残し

- [ ] `Sources/EPUBUI/EPUBReaderView.swift`: `selectionActions` を body の評価ごとに `ReaderSession.selectionActions`（`@ObservationIgnored` にした）へ代入するようにしたが、自動テストはない（EPUBUITests に SwiftUI をホストする仕組みがない）。id が同じでハンドラだけ変わった配列で新しいハンドラが呼ばれることを、デモか UI テストで確認する。
