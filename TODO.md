# TODO

## M1 の積み残し（2026-11-08 の Codex 敵対的レビューで確認した不具合）

- [ ] `Sources/EPUBCore/ZIP/ZIPArchive.swift`: アーカイブ由来の UInt64（ZIP64 EOCD オフセット、ローカルヘッダオフセット、圧縮/非圧縮サイズ）を検証前に `Int(...)` へ変換しており、`UInt64.max` などの不正値でトラップして落ちる（`locateEndOfCentralDirectory` と `data(for:)`）。`Int(exactly:)` と加算のオーバーフロー検査で `EPUBError.notAZIPArchive` / `corruptEntry` を投げるようにし、不正アーカイブのテストを追加する。
- [ ] `Sources/EPUBRenderer/ContentInjector.swift` + `Reader/reader.js`: フォント設定の切り替えが読み込み済み文書に完全には反映されない。`rootStyle` が `<style id="__reader_settings">` に `font-family !important` を無条件で書き込むため、`.system` から `.publisher` に戻しても上書きが残る（`applySettings` は `--reader-font-family` 変数と属性しか触らない）。また読み込み後に `.custom(FontResource)` へ変えても `@font-face` が追加されない。`applySettings` で `__reader_settings` の中身を差し替えるか、`!important` 規則を reader-after.css の属性セレクタ側に一本化する。
- [ ] `Sources/EPUBUI/ReaderPlatformView.swift`: `updateUIView` / `updateNSView` が `session.platformView` の差し替えをしないため、同じビュー位置で `EPUBReaderView(session:)` の session だけが変わると古い本が表示され続ける（イベント購読と PageTurnController は新 session を見る）。update 時に `content` が異なれば入れ替える。
- [ ] `Sources/EPUBRenderer/ReaderSession.swift` `goForward`: `goToPageInChapter` が JS 失敗（WebContent 終了など）を握りつぶして `currentPageIndex` を変えないため、失敗時に「章末に達した」と誤判定して次章へ進む。`goToPageInChapter` に成否を返させ、失敗時は章を跨がない。
- [ ] `Sources/EPUBCore/XHTML/XHTMLRepair.swift` + `ContentInjector.inject`: UTF-16（BOM 付き）で整形式な XHTML は `prepare` がバイト列をそのまま返し、`inject` が UTF-8 デコードに失敗して CSS/viewport 注入なしで配信される（段組みされず 1 ページ扱い）。整形式でも UTF-8 以外なら UTF-8 に変換して返す。
- [ ] `Sources/EPUBRenderer/ContentInjector.swift` `range(ofTag:)`: `<x:html>` / `<x:head>` のように接頭辞付きの要素名を認識できず、フォールバックで文書の前に `<head>` を付けてルート要素が 2 つになり WebKit が XML エラーにする。接頭辞付きタグ名にも一致させる。
- [ ] `Sources/EPUBRenderer/EPUBSchemeHandler.swift` と `ReaderSession.handleLink`: `url.path` は Foundation が既にパーセントデコード済みなのに再度 `removingPercentEncoding` しており、ファイル名に `%` を含む資源（`a%20b.xhtml`）が 404 になる。二重デコードをやめる。
- [ ] `Sources/EPUBRenderer/EPUBSchemeHandler.swift` `PublicationRegistry`: 同じ `EPUBContainer` を使う `ReaderSession` が複数あると、1 つの deinit で `unregister` され残りのセッションの資源要求が 404 になる。登録数を数えるか、セッションごとのハンドラにコンテナを直接持たせる。

## M1 の積み残し（その他）

- [ ] iOS の狭い列幅で letter-spacing の大きな見出し（moby-dick の "TRANSCRIBER'S" など）が列からはみ出す。コンテンツ側のスタイルなので reader-after.css で `overflow-wrap` / `word-break` を当てるかどうか方針を決める。
- [ ] Renderer の自動テストは macOS のみ。iOS 固有だった `WebViewSpineRenderer.syncNativeScroll`（UI プロセス側のスクロールクランプ対策）はシミュレータ上の手動確認だけなので、iOS で動く回帰テスト（XCTest/xcodebuild test）の置き場を決める。
- [ ] `Examples/ReaderDemo/Sources/ReaderDemo/Books/` に `Tests/Fixtures` の epub をコピーしている（1.7 MB の重複）。SwiftPM のリソースでシンボリックリンクが使えるか確認し、使えるなら共有する。
- [ ] 設計文書に反映すべき事実（`docs/design/` は本セッションでは編集していない）: 余白を `html` の padding + `column-gap = 2×余白` で実装したこと、iOS の UI プロセスがスクロール要求を古い contentSize でクランプすること（02-rendering §1.2）、画像遅延読み込みでページ数が後から増えるため `goForward` が文書に先に問い合わせること。詳細は共有ノート `m1-implementation-handover.md`。
