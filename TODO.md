# TODO

## M1 の積み残し（2026-11-08 の Codex 敵対的レビューで確認した不具合）

- [ ] `Sources/EPUBCore/XHTML/XHTMLRepair.swift` + `ContentInjector.inject`: UTF-16（BOM 付き）で整形式な XHTML は `prepare` がバイト列をそのまま返し、`inject` が UTF-8 デコードに失敗して CSS/viewport 注入なしで配信される（段組みされず 1 ページ扱い）。整形式でも UTF-8 以外なら UTF-8 に変換して返す。
- [ ] `Sources/EPUBRenderer/ContentInjector.swift` `range(ofTag:)`: `<x:html>` / `<x:head>` のように接頭辞付きの要素名を認識できず、フォールバックで文書の前に `<head>` を付けてルート要素が 2 つになり WebKit が XML エラーにする。接頭辞付きタグ名にも一致させる。
- [ ] `Sources/EPUBRenderer/EPUBSchemeHandler.swift` と `ReaderSession.handleLink`: `url.path` は Foundation が既にパーセントデコード済みなのに再度 `removingPercentEncoding` しており、ファイル名に `%` を含む資源（`a%20b.xhtml`）が 404 になる。二重デコードをやめる。
- [ ] `Sources/EPUBRenderer/EPUBSchemeHandler.swift` `PublicationRegistry`: 同じ `EPUBContainer` を使う `ReaderSession` が複数あると、1 つの deinit で `unregister` され残りのセッションの資源要求が 404 になる。登録数を数えるか、セッションごとのハンドラにコンテナを直接持たせる。

## M1 の積み残し（その他）

- [ ] iOS の狭い列幅で letter-spacing の大きな見出し（moby-dick の "TRANSCRIBER'S" など）が列からはみ出す。コンテンツ側のスタイルなので reader-after.css で `overflow-wrap` / `word-break` を当てるかどうか方針を決める。
- [ ] Renderer の自動テストは macOS のみ。iOS 固有だった `WebViewSpineRenderer.syncNativeScroll`（UI プロセス側のスクロールクランプ対策）はシミュレータ上の手動確認だけなので、iOS で動く回帰テスト（XCTest/xcodebuild test）の置き場を決める。
- [ ] `Examples/ReaderDemo/Sources/ReaderDemo/Books/` に `Tests/Fixtures` の epub をコピーしている（1.7 MB の重複）。SwiftPM のリソースでシンボリックリンクが使えるか確認し、使えるなら共有する。

## M2 の積み残し（2026-11-08）

- [ ] iOS で `PaginationService`（ウィンドウに載せていない非表示 WKWebView）の章ページ数が表示用 WebView の計測と数ページずれる。iPhone 17 Pro Simulator の草枕で非表示側の合計 264 ページに対し、表示側で全章を表示し直すと 270 ページになった（macOS では全章一致）。原因候補: 非表示ビューでは `ready` 後にフォント / ルビの描画が確定しておらず、表示側だけが `pageCountChanged` で補正している。非表示ビューでも `pageCountChanged` を受けて `PaginationCache` を更新するか、計測前に 1 フレーム待つかを検証する。
- [ ] `PaginationService` は章の `pageCountChanged`（遅延画像で章が伸びる）を追わない。計測後に増えた分は表示側が章を開いたときに上書きされるだけ。
- [ ] `SpineItem.characterCount` を `EPUBContainer` を開くときに全章分計算している（moby-dick で約 20 ms、大きな本では開く時間に効く）。遅延計算や検索インデックス（M3）との統合を検討する。
- [ ] 04-roadmap §3.3 の計測（最初のページまでの時間、事前ページ化の完了時間、メモリ）を Instruments で記録していない。草枕の事前ページ化は macOS のテストで約 0.7 秒、iOS Simulator で約 1 秒（目視）。
- [ ] `Examples/ReaderDemo` の macOS 版は M2 ではビルドと起動のみで、画面操作による確認（縦書き表示、設定の往復、ウィンドウリサイズ）は未実施。
- [ ] `EPUBReaderView` の周囲の UI の高さが変わると `viewportSize` が変わり全章の再計測になる（デモではステータスバーの高さを固定して回避）。数 pt の変化を無視する、または高さ変化を遅延して適用するなどライブラリ側で吸収するか検討する。

## M2 の積み残し（2026-11-08 の Codex 敵対的レビューで確認した不具合。いずれも未修正）

- [ ] `Sources/EPUBCore/Container/EPUBContainer.swift` Loader: `characterCount` を数えるために全 spine 文書を読んで `XHTMLRepair.prepareAndParse` した結果（`ContentDocument`）を `contentDocuments` に種として保持しているので、開いた時点で全章の展開済みバイト列をメモリに持ち続ける（上限なし。M1 では章の配信時に都度 prepare していた）。文字数だけ数えて `ContentDocument` は保持しない（配信時に再度 prepare する）か、合計サイズに上限を付ける。
- [ ] 同じ箇所: 種として入れた `contentDocuments` は `encryption.xml` の解析より前に作られ、`contentDocument(at:)` はキャッシュを優先するため、未対応アルゴリズムで暗号化された spine 文書が `EPUBError.encryptedResource` を投げずに（暗号文のまま）配信される。`data(at:)` だけが拒否する。種を入れるのをやめるか、`unsupportedEncryptedPaths` を除外し、`contentDocument(at:)` にも拒否のテスト（`FontObfuscationTests.unsupportedAlgorithmsWarnAndRefuseToServe` の `contentDocument` 版）を足す。
- [ ] `Sources/EPUBRenderer/PaginationService.swift` `configure`: `pause()` 後（iOS メモリ警告）に設定変更で `configure` が呼ばれても `isPaused` が残り `startWorkerIfNeeded` が動かないので、章を移動するまで他章が推定のまま。`configure` で `isPaused = false` にする（02-rendering §8.4 の記述もそれに合わせる）。
- [ ] `Sources/EPUBRenderer/ReaderSession.swift` `loadChapter` / `viewportSizeDidChange`: 初回読み込みの `ready` 待ちの間に `viewportSize` が変わると、`hasLoaded == false` のためページサイズだけ適用されて `selectLayout()` が呼ばれず、新しいサイズで計測した章ページ数が古い `LayoutKey` に記録される。`ready` 後に `selectLayout()` を呼び直すか、未読み込み時のサイズ変更でもキーを選び直す。
- [ ] `Sources/EPUBRenderer/ReaderSession.swift` `settingsDidChange`: テーマだけの変更は `LayoutKey` を変えないので `PaginationService.configure` が呼ばれず、隣接章のスナップショットが旧テーマの色のまま残り、非表示 WebView の背景色も更新されない。章またぎのめくりで旧テーマの画像が一瞬見える。テーマ変更時にサービスの背景色を更新してスナップショットだけ撮り直す。
- [ ] `Examples/ReaderDemo/Sources/ReaderDemo/BookView.swift` Go to page: `Int(text)` が `Int.min` を受け付け、`page - 1` でオーバーフローして落ちる。1 以上 `totalPages` 以下に制限する。

## M3 の積み残し（2026-11-09）

- [ ] `ReaderSession` に読み込み前の初期位置を渡す手段がない（`go(to:)` は `viewportSize` が決まり章が読み込まれてから有効）。アプリは最初の `positionChanged` を待って `go(to:)` を呼ぶ必要があり、最初の章が一瞬見える。`ReaderSession(container:settings:initialPosition:)` か `loadIfNeeded(at:)` を検討する。
- [ ] `cfiForPage` はページ先頭の「見えている最初のテキスト」を `caretRangeFromPoint` の数点のプローブと矩形走査で決めるため、浮動要素や多段のテーブルではページ先頭より後ろの文字を返すことがある。`cfiForVisibleRange()`（02-rendering §4.1）と合わせて、ページ内の全テキスト矩形から厳密に先頭を選ぶ実装を検討する。
- [ ] iOS の `buildMenu(with:)` による編集メニュー追加はシミュレータの手動確認のみ（Renderer の自動テストは macOS の `willOpenMenu` 経路だけ）。iOS で動く回帰テストの置き場（M1 の積み残し）と合わせて決める。
- [ ] `ReaderSession.highlights` の変更は毎回現在章の全ハイライトを `setHighlights` で描き直す（差分適用なし）。数百件規模で設定変更やタップのたびに全件を解決するコストを測り、必要なら id ごとの追加・削除に分ける。
- [ ] `SelectedText.rects` / `highlightTapped` の矩形は `selectionChanged` 受信時点の可視ページ座標で、その後ページ移動や再レイアウトがあると古くなる。アプリがメニューを出すときは `rects(for:)` で取り直す運用にしているが、ライブラリ側で位置変更時に `currentSelection` を更新するか検討する。
- [ ] `SearchService` の抽出結果（`TextMap`）は spine item ごとに actor 内へ無期限にキャッシュする。大きな本では本文全体をメモリに持つことになるので、上限や `didReceiveMemoryWarning` での破棄を検討する（M2 の `contentDocuments` の積み残しと同じ話）。
- [ ] 検索は線形 spine item のみ。非線形（`linear="no"`）の文書は対象外にしている。必要なら `SearchOptions` にフラグを足す。
- [ ] `Examples/ReaderDemo` の macOS 版は M3 でもビルドと `swift test` のみで、画面操作（右クリックメニューの Highlight、検索シート）は未確認。

## M3 の積み残し（2026-11-09 の Codex 敵対的レビューで確認した不具合。いずれも未修正）

- [ ] `Sources/EPUBRenderer/Reader/reader.js` `boundaryToPoint`: 選択範囲の境界が要素コンテナで、その子オフセットの位置がコメントノード（`<b>First</b><!-- c -->Second` で `selectNode(b)` の終点）だと null を返し、`fromRange` 全体が null になって選択が「なし」と報告される（ハイライトできない）。コメントや空白テキストを読み飛ばして次の要素 / テキストに寄せる。
- [ ] `Sources/EPUBRenderer/ReaderSession.swift` `show(_:)`: `go(to:)` の後の章の一致確認を操作キューの外で行い、一時ハイライトの適用を別の操作として積むので、その間に別の章への移動が割り込むと、検索結果の CFI 範囲が別の文書に対して解決され無関係な文字がハイライトされうる（`reader.js` の `resolveSteps` は spine ステップを見ない）。移動と一時ハイライトを 1 つの操作にまとめるか、適用直前に `currentSpineIndex` を再確認する。`reader.js` 側でも `spineSteps` の一致を確認すると二重に防げる。
- [ ] `Sources/EPUBCore/Model/Publication.swift` `spineIndex(of:)`: ID でもステップ index でも一致しないときに `index / 2 - 1` を reading order の添字として使うため、manifest にない itemref を読み飛ばした OPF では、存在しない章を指す CFI が別の章に解決される。最後のフォールバックをやめて nil を返す（`cfiStepIndex` の一致だけを認める）。
- [ ] `Sources/EPUBCore/CFI/CFIGenerator.swift` `textAssertion(in:offset:)`: 前後 10 ユニットしか使わないのにテキストノード全体を `Array(text.utf16)` に展開する。`SearchService.results(for:)` は一致ごとに 2 回呼ぶので、長いテキストノードに大量の一致がある章では二次関数的に遅くなり、その章が終わるまで結果が流れず、ループ内でキャンセルも見ない。`String.UTF16View` の index 演算で必要範囲だけ切り出し、`results(for:)` のループで `Task.checkCancellation()` を見る。
- [ ] `Sources/EPUBUI/EPUBReaderView.swift`: `.selectionActions` の転送が `onChange(of: ids)` なので、id が同じまま title / systemImage / handler だけ変わった配列はセッションに反映されない（古いハンドラが呼ばれ続ける）。`SelectionAction` を `Equatable` にする（handler を除く比較 + 変更世代）か、毎回代入する。
- [ ] `Examples/ReaderDemo/Sources/ReaderDemo/Annotations.swift` `BookStore.init`: 英数字以外をすべて `_` に置き換えてファイル名にするので、`A-B.epub` と `A_B.epub` のように異なる本が同じ JSON を共有し、ハイライトと位置を上書きし合う。ハッシュ（SHA-256）をファイル名にする。


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
- [ ] `Examples/ReaderDemo` の macOS 版は M4 でもビルドと `swift test` のみで、画面操作（見開き表示、ウィンドウリサイズでの単ページ ⇄ 見開き、トラックパッドのピンチ）は未確認。
