# 03. 公開 API

アプリから見える型とプロトコル。名前は暫定で、実装時に変えてよい。
利用者は自分のアプリだけなので後方互換は考えず、使いやすさを優先する。

M1 時点の実装状態を「M1 実装済み」「M3 で追加」のように記す。CFI に依存する API（位置、ハイライト、選択、検索）は
M3 で入り、それまで `ReaderSession` は spine index とページ index を公開する。

## 1. 使い方の全体像

```swift
import EPUB

struct BookScreen: View {
    @State private var session: ReaderSession?

    var body: some View {
        Group {
            if let session {
                EPUBReaderView(session: session)
                    .pageTransition(.slide)
                    .selectionActions([
                        SelectionAction(title: "ハイライト", systemImage: "highlighter") { selected in
                            highlights.append(Highlight(range: selected.range, style: .background(.yellow)))
                        },
                    ])
                    .onReaderEvent { event in
                        switch event {
                        case .noteref(let note): presentedNote = note
                        case .imageTapped(let image): presentedImage = image
                        case .externalLink(let url): openURL(url)
                        default: break
                        }
                    }
            }
        }
        .task {
            let container = try await EPUBContainer(url: fileURL)
            session = ReaderSession(container: container, settings: settings)
            session?.highlights = highlights
            if let last = lastPosition { await session?.go(to: last) }
        }
    }
}
```

## 2. EPUBCore

### 2.1 `EPUBContainer`

```swift
public actor EPUBContainer {
    public init(url: URL) async throws
    public init(data: Data) async throws
    public nonisolated let publication: Publication
    public nonisolated let id: PublicationID
    public nonisolated let url: URL?
    public nonisolated var paths: [String]
    public nonisolated func contains(path: String) -> Bool
    public nonisolated func mediaType(forPath path: String) -> String
    public func data(at path: String) async throws -> Data
    public func coverImageData() async throws -> Data?
    public func contentDocument(at path: String) async throws -> ContentDocument   // 01-core §4.1 の修復込み
}
```

M1 実装済み。`ContentDocument` は配信するバイト列、`mediaType`、状態（`wellFormed` / `repaired` / `unrepairable`）、警告を持つ。

### 2.2 `Publication` と関連型

01-core §3 のとおり。`Metadata` は `title`、`authors: [String]`、`language`、`identifier`、
`publisher`、`modified: Date?`、`rawMetadata: [String: [String]]`（property → 値）を持つ。

### 2.3 `CFI` / `CFIRange`

01-core §5。`Codable` は文字列 1 つにエンコードする（`"epubcfi(...)"`）。
アプリの永続化はこの文字列をそのまま保存すればよい。

### 2.4 `ReadingPosition`

```swift
public struct ReadingPosition: Codable, Hashable, Sendable {
    public let cfi: CFI
    public let spineIndex: Int
    public let chapterTitle: String?          // toc から逆引き
    public let progressionInChapter: Double   // 0...1
    public let totalProgression: Double       // 0...1。ページ化が推定中なら推定値
}
```

### 2.5 `Highlight` / `Bookmark`

```swift
public struct ReaderColor: Codable, Hashable, Sendable {
    public var red, green, blue, alpha: Double
}

public struct Highlight: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var range: CFIRange
    public var style: Style
    public var note: String?
    public enum Style: Codable, Hashable, Sendable {
        case background(ReaderColor)
        case underline(ReaderColor)
    }
}

public struct Bookmark: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var position: ReadingPosition
    public var createdAt: Date
}
```

EPUBCore は SwiftUI を import しないので色は `ReaderColor`。EPUBUI に `Color` との相互変換を置く。

### 2.6 `SearchService`

01-core §6。`ReaderSession.search(_:)` から間接的に使えるが、Core 単体でも呼べる。

## 3. EPUBRenderer

### 3.1 `ReaderSettings`

```swift
public struct ReaderSettings: Codable, Hashable, Sendable {
    public var font: FontChoice = .publisher
    public var fontScale: Double = 1.0          // 1.0 = 出版社指定のサイズ
    public var lineHeight: Double = 1.6
    public var pageMargins: PageMargins = .init(horizontal: 24, vertical: 20)
    public var theme: ReaderTheme = .light
    public var spreadPolicy: SpreadPolicy = .auto   // auto / never / always
    public var respectsPublisherFonts: Bool { font == .publisher }

    public enum FontChoice: Codable, Hashable, Sendable {
        case publisher
        case system(name: String)
        case custom(FontResource)
    }
}

public struct FontResource: Codable, Hashable, Sendable {
    public var familyName: String
    public var fileURL: URL        // アプリバンドルまたはドキュメント内のフォントファイル
}

public struct ReaderTheme: Codable, Hashable, Sendable {
    public var foreground: ReaderColor
    public var background: ReaderColor
    public var link: ReaderColor
    public var isDark: Bool            // 画像の減光と color-scheme に使う
    public static let light, sepia, dark: ReaderTheme
}
```

### 3.2 `ReaderSession`

表示状態の中心。SwiftUI からは `@Observable` として観測する。

M1 実装済み:

```swift
@MainActor @Observable
public final class ReaderSession {
    public init(container: EPUBContainer, settings: ReaderSettings = .init())

    public let publication: Publication
    public let container: EPUBContainer
    public var settings: ReaderSettings            // 変更で再レイアウトと位置復元
    public var viewportSize: CGSize                // EPUBReaderView が設定。変更で再レイアウトと位置復元

    public private(set) var currentSpineIndex: Int
    public private(set) var currentPageIndex: Int  // 章内のページ index
    public private(set) var chapterPageCount: Int
    public private(set) var writingMode: String    // "horizontal-tb" など。reader.js の判定値
    public private(set) var isLoading: Bool
    public private(set) var hasLoaded: Bool
    public var chapterProgression: Double          // 0...1
    public var totalProgression: Double            // 0...1。M2 の BookPagination までは章数ベースの近似
    public var isAtStart: Bool
    public var isAtEnd: Bool

    public var events: AsyncStream<ReaderEvent>

    public func loadIfNeeded() async
    public func goForward() async
    public func goBackward() async
    public func go(toSpineIndex index: Int) async
    public func go(to entry: TOCEntry) async       // spine item + #fragment
    public func go(toPageInChapter index: Int) async

    public func pageSnapshot(_ which: PageSnapshotTarget) async -> PageSnapshot?  // EPUBUI の演出用

    @_spi(EPUBUI) public var platformView: PlatformView   // EPUBUI だけが使う。WebView を直接は出さない
}
```

M3 で追加（CFI 依存）:

```swift
extension ReaderSession {
    public var highlights: [Highlight]             // 変更で setHighlights
    public private(set) var position: ReadingPosition?
    public private(set) var currentSelection: SelectedText?
    public func go(to position: ReadingPosition) async
    public func go(to cfi: CFI) async
    public func search(_ query: String, options: SearchOptions = .default)
        -> AsyncThrowingStream<SearchResult, Error>
    public func show(_ result: SearchResult) async     // 位置へ移動し一時ハイライト
    public func clearSelection()
    public func rects(for range: CFIRange) async -> [CGRect]   // ビュー座標
}
```

M2 で追加: `public private(set) var pagination: BookPagination` と `go(toPage:)`（`BookPagination` の番号）。

`go(to:)` 系は移動が完了（`ready` 受信と位置確定）するまで待つ。ジェスチャ中の先読みは
`pageSnapshot(.next)` で行う。`PageSnapshot` は `image: CGImage`、`scale`、`size`（pt）、`spineIndex`、`pageIndex` を持つ。

EPUBUI への WebView の受け渡しは `@_spi(EPUBUI)` 付きの `platformView`（`NSView` / `UIView` の typealias `PlatformView`）で行う。
通常の `import EPUBRenderer` からは見えず、WebKit の型も出ない。

### 3.3 `BookPagination`

```swift
public struct BookPagination: Sendable {
    public let totalPages: Int
    public let isEstimated: Bool
    public func pageNumber(for position: ReadingPosition) -> Int
    public func pageRange(ofSpineIndex index: Int) -> Range<Int>
    public func isEstimated(spineIndex: Int) -> Bool
}
```

### 3.4 `ReaderEvent`

```swift
public enum ReaderEvent: Sendable {
    // M1 実装済み
    case pageChanged(spineIndex: Int, pageIndex: Int, pageCount: Int)   // M3 で positionChanged に統合
    case externalLink(URL)                  // 移動しない。アプリが開く
    case tapped(CGPoint, zone: TapZone)     // ジェスチャをアプリが処理するとき用
    case warning(PublicationWarning)
    case error(ReaderError)
    // M2 で追加
    case paginationUpdated(BookPagination)
    // M3 以降で追加
    case positionChanged(ReadingPosition)
    case internalLink(CFI)                  // 移動はライブラリが行う。通知のみ
    case noteref(NoteContent)               // html / text / 参照先 CFI（M5）
    case imageTapped(TappedImage)           // src / alt / 画像データ取得クロージャ / 矩形（M5）
    case highlightTapped(Highlight.ID, rects: [CGRect])
    case selectionChanged(SelectedText?)
}

public enum ReaderError: Error, Sendable {
    case loadTimeout(spineIndex: Int)                   // ready が 10 秒以内に来ない。再試行はアプリに任せる
    case loadFailed(spineIndex: Int, underlying: String)
    case scriptFailed(String)                           // ブリッジ JS の失敗
    case webContentTerminated                           // セッションは現在章を再読み込みする
}

public struct SelectedText: Sendable {
    public let range: CFIRange
    public let text: String
    public let rects: [CGRect]
}
```

## 4. EPUBUI

### 4.1 `EPUBReaderView`

```swift
public struct EPUBReaderView: View {
    public init(session: ReaderSession)
}

extension View {
    public func pageTransition(_ transition: some PageTransition) -> some View
    public func readerGestures(_ gestures: ReaderGestures) -> some View
    public func selectionActions(_ actions: [SelectionAction]) -> some View
    public func onReaderEvent(_ handler: @escaping @MainActor (ReaderEvent) -> Void) -> some View
}
```

修飾子は SwiftUI の `Environment` で `EPUBReaderView` に届ける。既定は `.slide`、`.default` ジェスチャ、
選択アクションなし。M1 実装済み（`selectionActions` は M3）。

### 4.2 `PageTransition`

```swift
public protocol PageTransition: Sendable {
    associatedtype Body: View
    @ViewBuilder func body(_ context: PageTransitionContext) -> Body
}

public struct PageTransitionContext {
    public let from: Image                  // 現在ページのスナップショット
    public let to: Image                    // 移動先ページ（未取得なら背景色の矩形）
    public let direction: PageDirection     // forward / backward
    public let progress: Double             // 0...1。ジェスチャ追従中は指の位置、確定後はアニメーション
    public let axis: Axis                   // 横書き横方向、縦書きは右綴じで横方向（スクロール軸とは別）
    public let layoutDirection: LayoutDirection   // 右綴じでは .rightToLeft。演出が進む向きを反転するのに使う
    public let size: CGSize
    public let isInteractive: Bool
    public var outgoingSign: CGFloat        // direction と layoutDirection から求めた、現在ページが抜ける方向（-1 / +1）
}

public struct SlidePageTransition: PageTransition { public var duration: Double = 0.28 }
public struct FadePageTransition: PageTransition { public var duration: Double = 0.2 }
public struct NoPageTransition: PageTransition { }
extension PageTransition where Self == SlidePageTransition { public static var slide: Self }
extension PageTransition where Self == FadePageTransition { public static var fade: Self }
extension PageTransition where Self == NoPageTransition { public static var none: Self }
```

M1 実装済み。

演出は 2 枚の画像だけで描く。`progress` が 1 に到達した時点で EPUBUI が画像を外し、WebView を見せる
（02-rendering §7.2）。

### 4.3 `ReaderGestures`

```swift
public struct ReaderGestures: Sendable {
    public var tapZones: TapZones            // 左 / 右 / 中央の幅比率。既定 0.25 / 0.5 / 0.25
    public var swipeEnabled: Bool            // 横スワイプでめくる
    public var tapToTurnEnabled: Bool        // 端のタップでめくる
    public var keyboardEnabled: Bool         // macOS: ←→ space PageUp/PageDown
    public static let `default`: ReaderGestures
    public static let disabled: ReaderGestures      // アプリが自分で go* を呼ぶ
}
```

右綴じ（縦書き、`page-progression-direction="rtl"`）では右タップと右方向スワイプが「進む」になる。
`ReaderSession.publication.pageProgression` に従って EPUBUI が反転する。

macOS のトラックパッドの 2 本指スワイプは `NSEvent.scrollWheel` の `phase` と `momentumPhase` から
ドラッグ進捗に変換し、iOS のスワイプと同じ `PageTransitionContext.progress` を駆動する。

### 4.4 `SelectionAction`

```swift
public struct SelectionAction: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var systemImage: String?
    public var handler: @MainActor (SelectedText) -> Void
}
```

### 4.5 リサイズ

`EPUBReaderView` はサイズ変更を `onGeometryChange` で受け、`ReaderSession.viewportSize` を更新する。
セッションは現在の CFI を記録 → 再レイアウト → `pageFor(cfi)` で復元し、その間は直前のスナップショットを
クロスフェードで見せる。macOS のウィンドウリサイズ中は 150 ms デバウンスする。
M3 までは CFI の代わりに `reader.js` の DOM アンカーで復元する（02-rendering §5.3）。

## 5. 公開しない型

`EPUBSchemeHandler`、`PaginationService`、`SpreadBuilder`、`reader.js` のメッセージ型、WKWebView の
サブクラスは `internal`。将来のネイティブ描画への差し替え点として `internal protocol SpineRenderer` を置き、
`ReaderSession` はそれ越しに WebView を操作する（M1 では `WebViewSpineRenderer` が唯一の実装）。
EPUBUI だけが必要とする WebView のホスト用ビューは `@_spi(EPUBUI)` で渡す（§3.2）。
