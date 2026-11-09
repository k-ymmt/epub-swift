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
- [ ] `LayoutKey` に見開き有無が入っていない（M4 の見開きで追加する）。
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

