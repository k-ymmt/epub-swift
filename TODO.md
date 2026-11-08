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
