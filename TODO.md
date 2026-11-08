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
