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
M2: `data(at:)` は `encryption.xml` に登録されたフォントの難読化（IDPF / Adobe）を解除して返し、未対応のアルゴリズムで
暗号化された資源には `EPUBError.encryptedResource` を投げる。`ObfuscationAlgorithm` と `FontObfuscation` も公開型。

### 2.2 `Publication` と関連型

01-core §3 のとおり。`Metadata` は `title`、`authors: [String]`、`language`、`identifier`、
`publisher`、`modified: Date?`、`rawMetadata: [String: [String]]`（property → 値）を持つ。

M4 で追加: `Publication.orientation: RenditionOrientation`、`SpineItem.spread: RenditionSpread?` /
`orientation: RenditionOrientation?` / `viewport: FixedLayoutViewport?` / `isFixedLayout`、`FixedLayoutViewport`
（`width` / `height`、`init?(metaContent:)`）、`PublicationWarning.missingViewport(path:)`（01-core §3、§7）。

### 2.3 `CFI` / `CFIRange`

01-core §5。`Codable` は文字列 1 つにエンコードする（`"epubcfi(...)"`）。
アプリの永続化はこの文字列をそのまま保存すればよい。M3 実装済み。文字オフセットは UTF-16 コードユニット
（01-core §5.1）。`Publication.spineIndex(of:)` で CFI から spine index を引く。

### 2.4 `ReadingPosition`

```swift
public struct ReadingPosition: Codable, Hashable, Sendable {
    public var cfi: CFI
    public var spineIndex: Int
    public var chapterTitle: String?          // toc から逆引き（その spine item を指す最後の目次項目）
    public var progressionInChapter: Double   // 0...1
    public var totalProgression: Double       // 0...1。ページ化が推定中なら推定値
}
```

M3 実装済み。位置は CFI だけで決まり、残りは記録時点の表示用の値。復元は `ReaderSession.go(to:)` に渡す。
アプリが開いた直後に前回位置へ戻すには、最初の章が表示された（最初の `positionChanged`）あとで `go(to:)` を呼ぶ
（`ReaderDemo` の `BookView` 参照）。読み込み前に `go(to:)` を受け付ける API は M3 では作っていない（`TODO.md`）。

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

EPUBCore は SwiftUI を import しないので色は `ReaderColor`。EPUBUI に `Color` との相互変換を置く
（`Color(_ readerColor:)`）。M3 実装済み: `Highlight` の既定スタイルは黄色の背景（`0xFFE066`、alpha 0.6）、
`spineIndex` を `range` から返す。`Bookmark` は型だけで、ライブラリは何もしない。

### 2.6 `SearchService`

01-core §6。`ReaderSession.search(_:)` から間接的に使えるが、Core 単体でも呼べる。M3 実装済み。

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
    public private(set) var writingMode: WritingMode   // M2 で String から列挙型に変更（horizontalTB / verticalRL / verticalLR）
    public var isRightToLeft: Bool                 // M2。pageProgression が rtl、または default で縦書き（vertical-rl）のとき true
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

M3 で追加（CFI 依存。実装済み）:

```swift
extension ReaderSession {
    public var highlights: [Highlight]             // 変更で現在章の分を setHighlights。章の表示前にも適用
    public private(set) var position: ReadingPosition?   // 章の表示後は常に非 nil（02-rendering §5.3）
    public private(set) var currentSelection: SelectedText?
    public var selectionActions: [SelectionAction] // M3 で変更: EPUBUI の .selectionActions がここに転送する
    public func go(to position: ReadingPosition) async
    public func go(to cfi: CFI) async              // 同じ章なら pageFor、別の章なら読み込んでから。未知の spine は無視
    public func pageIndex(for position: ReadingPosition) -> Int?   // M3 で追加: 書籍全体のページ index（推定中は近似）
    public func search(_ query: String, options: SearchOptions = .default)
        -> AsyncThrowingStream<SearchResult, Error>
    public func show(_ result: SearchResult) async     // 位置へ移動し一時ハイライト。次のページ移動で消える
    public func clearSelection()
    public func rects(for range: CFIRange) async -> [CGRect]   // 可視ページ座標。他章なら空
}
```

`SearchService` はセッションが遅延生成して保持する。`go(to:)` 系はすべて操作キューで直列化され、移動が
完了するまで待つ。

M2 で追加（実装済み）:

```swift
extension ReaderSession {
    public private(set) var pagination: BookPagination     // 計測が進むたびに更新。ReaderEvent.paginationUpdated と同じ値
    public var currentPage: Int?                           // 書籍全体の 0 始まりページ index。未読み込み / 非線形の章では nil
    public private(set) var relayoutSnapshot: PageSnapshot? // 再レイアウト中だけ非 nil（§4.5）
    public func go(toPage index: Int) async                // BookPagination の番号で移動。推定中の章では章内ページが近似になる
}
```

`totalProgression` は `BookPagination` のページ番号から求める。`writingMode` は `reader.js` の判定値で、
`WritingMode(cssValue:)` が `sideways-*` を縦書きに寄せる。

M4 で追加（FXL と見開き。実装済み）:

```swift
extension ReaderSession {
    public var visibleSpineIndices: [Int]      // 今の面に含まれる spine item（読み順）。単ページなら [currentSpineIndex]
    public var isShowingSpread: Bool           // 今の面が 2 ページ（FXL のペア、リフローの 2 段 / 2 フレーム）か
    public private(set) var isZoomed: Bool     // FXL の面がピンチで拡大されているか。true の間 EPUBUI はめくりを止める
    public func resetZoom()                    // 倍率 1 に戻す（面の読み込み時にも戻る）
}
```

`currentSpineIndex` は面の先頭（読み順で最初）の spine item。`chapterPageCount` / `currentPageIndex` は「面」の数と index
（FXL の面は常に 1 ページ。縦書き見開きは ceil(ページ数 / 2)）。`position` は面の先頭ページ側の CFI で、見開きの右ページへ
`go(toSpineIndex:)` / `go(to cfi:)` しても面は読み直さず、`position` だけ動く。`currentPage` / `BookPagination` は FXL の各ページを
書籍ページ 1 つと数えるので、ペアの面を進めると 2 ページ進む。

`go(to:)` 系は移動が完了（`ready` 受信と位置確定）するまで待つ。ジェスチャ中の先読みは
`pageSnapshot(.next)` で行う。`PageSnapshot` は `image: CGImage`、`scale`、`size`（pt）、`spineIndex`、`pageIndex` を持つ。

EPUBUI への WebView の受け渡しは `@_spi(EPUBUI)` 付きの `platformView`（`NSView` / `UIView` の typealias `PlatformView`）で行う。
通常の `import EPUBRenderer` からは見えず、WebKit の型も出ない。

### 3.3 `BookPagination`

M2 実装済み（M2 で形を変更）:

```swift
public struct BookPagination: Sendable, Hashable {
    public struct Chapter: Sendable, Hashable {            // 線形の spine item ごと
        public let spineIndex: Int
        public let pageCount: Int
        public let isEstimated: Bool
        public let firstPage: Int                          // 書籍全体の先頭ページ index
        public var pageRange: Range<Int>
    }
    public struct Location: Sendable, Hashable { public let spineIndex: Int; public let pageIndex: Int }

    public let chapters: [Chapter]                         // spine 順
    public let totalPages: Int
    public let charactersPerPage: Double                   // 推定に使った比率
    public var isEstimated: Bool                           // 1 章でも推定なら true
    public var estimatedChapterCount: Int

    public static func defaultCharactersPerPage(writingMode: WritingMode) -> Double   // 600 / 縦書き 500
    public static func make(publication: Publication, measured: [Int: Int], defaultCharactersPerPage: Double) -> BookPagination
    public static let empty: BookPagination

    public func chapter(spineIndex: Int) -> Chapter?
    public func pageRange(ofSpineIndex index: Int) -> Range<Int>          // 非線形・不明なら空
    public func isEstimated(spineIndex: Int) -> Bool
    public func pageIndex(spineIndex: Int, pageIndex: Int) -> Int?        // 章内 → 書籍全体（章の範囲にクランプ）
    public func location(ofPageIndex index: Int) -> Location?            // 書籍全体 → 章と章内ページ
    public func progression(spineIndex: Int, pageIndex: Int) -> Double?  // 0...1
}
```

ページ index は全て 0 始まりで、表示には `+ 1` する。`pageNumber(for: ReadingPosition)` は M3 で CFI と一緒に加える。

### 3.4 `ReaderEvent`

```swift
public enum ReaderEvent: Sendable {
    // M1 実装済み
    // case pageChanged(...)                // M3 で削除し positionChanged に統合
    case externalLink(URL)                  // 移動しない。アプリが開く
    case tapped(CGPoint, zone: TapZone)     // ジェスチャをアプリが処理するとき用
    case warning(PublicationWarning)
    case error(ReaderError)
    // M2 実装済み
    case paginationUpdated(BookPagination)  // 章の計測が進むたび。ReaderSession.pagination と同じ値
    // M3 実装済み
    case positionChanged(ReadingPosition)   // ページ・章の移動と、同じテキストのままの再レイアウト。ReaderSession.position と同じ値
    case highlightTapped(Highlight.ID, rects: [CGRect])   // 矩形は可視ページ座標
    case selectionChanged(SelectedText?)    // nil は解除。ReaderSession.currentSelection と同じ値
    // M4 実装済み
    case zoomChanged(Bool)                  // FXL の面のピンチズーム。true の間 EPUBUI はめくりジェスチャを止める。ReaderSession.isZoomed と同じ値
    // M5 実装済み
    case internalLink(CFI)                  // 移動はライブラリが行う。通知のみ。CFI はフラグメントの要素か文書先頭
    case noteref(NoteContent)               // epub:type="noteref" のタップ。セッションは移動しない
    case imageTapped(TappedImage)           // リフローのページ上の img / SVG image（リンク内を除く）のタップ
}

public enum ReaderError: Error, Sendable {
    case loadTimeout(spineIndex: Int)                   // ready が 10 秒以内に来ない。再試行はアプリに任せる
    case loadFailed(spineIndex: Int, underlying: String)
    case scriptFailed(String)                           // ブリッジ JS の失敗
    case webContentTerminated                           // セッションは現在章を再読み込みする
}

public struct SelectedText: Sendable, Hashable {
    public let range: CFIRange
    public let text: String
    public let rects: [CGRect]              // 可視ページ座標
}
```

M5 で追加（実装済み）:

```swift
public struct NoteContent: Sendable, Hashable {
    public let path: String                 // 脚注のある文書のコンテナパス
    public let fragment: String?            // リンクのフラグメント（脚注要素の id）
    public let spineIndex: Int?             // 脚注の文書が spine にないと nil
    public let cfi: CFI?                    // 脚注要素。解決できなければ nil。go(to:) で脚注へ移動できる
    public let html: String?                // 同じ文書の脚注だけ: 要素の innerHTML
    public let text: String?                // 空白を詰めたテキスト。別文書の脚注は EPUBCore の解析から
    public let isInSameDocument: Bool
    public let sourceRect: CGRect           // noteref の矩形（可視ページ座標）。ポップオーバーの起点
}

public struct TappedImage: Sendable {
    public let url: URL                     // 文書が解決した URL（出版物の資源は epub://…）
    public let path: String?                // コンテナパス。data: URL などでは nil
    public let alt: String?                 // alt、SVG なら aria-label / <title>
    public let rect: CGRect                 // 画像の矩形（可視ページ座標。ページからはみ出すことがある）
    public let point: CGPoint               // タップ位置（可視ページ座標）
    public let data: @Sendable () async throws -> Data   // 画像のバイト列（コンテナから読む / data: URL を復号）
}
```

M5 で変更・確定した点:

- 設計時の「`NoteContent` は html / text / 参照先 CFI」に、パス・フラグメント・spine index・同一文書かどうか・起点の矩形を足した。
  別文書の脚注（rearnote など）は `html` を持たない（描画済みの DOM がないため）。アプリは `text` を表示するか `cfi` へ移動する。
- 同じ文書の noteref が指す `aside`（footnote / endnote / rearnote）は本文から隠す。ポップアップで読む前提のため
  （02-rendering §4.2）。`epub:type="noteref"` のないリンクは脚注番号の形でも `internalLink` として移動する。
- `TappedImage` は Hashable にしない（データ取得クロージャを持つため）。FXL のページでは送らない。
- `externalLink` の扱いは変わらない（移動せず通知のみ）。`internalLink` は移動の後に出る。
- `ReaderError.loadTimeout` は従来どおり再試行をアプリに任せる。`webContentTerminated` ではセッションが表示中の面を
  `position` の CFI で読み直す（30 秒以内に 3 回まで。02-rendering §9）。

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
選択アクションなし。M1 実装済み。`selectionActions` は M3 実装済みで、`EPUBReaderView` が環境値を
`ReaderSession.selectionActions` に転送する（§4.4）。

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
public struct ReaderGestures: Sendable, Hashable {
    public var tapZones: TapZones            // 左 / 右 / 中央の幅比率。既定 0.25 / 0.5 / 0.25
    public var swipeEnabled: Bool            // 横スワイプでめくる
    public var tapToTurnEnabled: Bool        // 端のタップでめくる
    public var keyboardEnabled: Bool         // macOS: ←→ ↑↓ space PageUp/PageDown Home/End（M5）
    public init(tapZones: TapZones = .default, swipeEnabled: Bool = true, tapToTurnEnabled: Bool = true, keyboardEnabled: Bool = true)
    public static let `default`: ReaderGestures
    public static let disabled: ReaderGestures      // アプリが自分で go* を呼ぶ
}

public struct TapZones: Sendable, Hashable {
    public var leading: Double               // 既定 0.25
    public var center: Double                // 既定 0.5
    public var trailing: Double              // 既定 0.25
    public static let `default`: TapZones
    public func zone(forX x: Double, width: Double) -> TapZone   // ReaderEvent.tapped の zone と同じ判定
}
```

右綴じ（縦書き、`page-progression-direction="rtl"`）では右タップと右方向スワイプが「進む」になる。
EPUBUI は `ReaderSession.isRightToLeft` に従って `PageTransitionContext.layoutDirection` とタップゾーンの意味を反転する
（M2 実装済み）。`isRightToLeft` は `pageProgression` が `rtl` なら true、`ltr` なら false、`default` なら
`writingMode == .verticalRL` で決める。

macOS のトラックパッドの 2 本指スワイプは `NSEvent.scrollWheel` の `phase` と `momentumPhase` から
ドラッグ進捗に変換し、iOS のスワイプと同じ `PageTransitionContext.progress` を駆動する。

M4 で追加: `ReaderSession.isZoomed` が true の間（FXL の面をピンチで拡大中）は、スワイプ・トラックパッドスワイプ・
タップめくりのすべてを止め、ピンチとパンを WebView に渡す。倍率が 1 に戻ると再開する。

M5 で変更・確定した点（macOS の入力）:

- キー（`keyboardEnabled`）: ← → はページの進む向きに従う（右綴じと縦書き vertical-rl では ← が「次」）。↓ PageDown space は次、
  ↑ PageUp ⇧space は前、Home / End は章（面）の先頭 / 末尾。修飾キー付きの組み合わせは扱わない。
  対応表は内部型 `ReaderKey` / `ReaderKeyAction` で、イベントなしでテストする（公開しない）。
- ホストビューはウィンドウのローカルモニタでキーを受け、扱ったイベントだけを消費する。テキストフィールド・テーブル・
  他のスクロールビューがファーストレスポンダの間はキーを奪わない。FXL の面の拡大中はキーもスワイプも止める。
- トラックパッド: 差分を指の動きに正規化し（ナチュラルスクロールの設定によらない）、数点動いたところで軸を固定する。
  横の動きはめくりのドラッグを駆動し、その後の慣性イベントは捨てるので、1 回のスワイプで最大 1 ページ進む。縦の動きは素通しにする。
- 画像のタップ（`imageTapped`）は、タップ位置が左右のタップゾーンならめくりを優先し、中央ゾーンのときだけアプリに渡す
  （表紙や挿絵がページを覆うと、どこをタップしてもめくれなくなるため）。`tapToTurnEnabled` が false か拡大中ならゾーンによらず渡す。
- VoiceOver（iOS）の 3 本指スワイプはホストビューの `accessibilityScroll` でページ送りにする（02-rendering §7.3）。

### 4.4 `SelectionAction`

```swift
public struct SelectionAction: Identifiable, Sendable {
    public var id: String                   // 省略時は title
    public var title: String
    public var systemImage: String?
    public var handler: @MainActor (SelectedText) -> Void
    public init(id: String? = nil, title: String, systemImage: String? = nil, handler: @escaping @MainActor (SelectedText) -> Void)
}
```

M3 で変更: `SelectionAction` は EPUBUI ではなく EPUBRenderer に置く（umbrella の `EPUB` からは同じように見える）。
メニューを組み立てるのは WebView のサブクラス（02-rendering §10）で、SwiftUI を使わないアプリも
`ReaderSession.selectionActions` に直接設定できるようにするため。ハンドラには、メニューを開いた時点でセッションが
保持していた選択（`currentSelection`）が渡る。

### 4.5 リサイズ

`EPUBReaderView` はサイズ変更を `onGeometryChange` で受け、`ReaderSession.viewportSize` を更新する。
セッションは現在の CFI を記録 → 再レイアウト → `pageFor(cfi)` で復元し、その間は直前のスナップショットを
クロスフェードで見せる。macOS のウィンドウリサイズ中は 150 ms デバウンスする（iOS の回転や Split View は
1 回のサイズ変更なので即座に適用する。M2 で変更）。
M3 までは CFI の代わりに `reader.js` の DOM アンカーで復元する（02-rendering §5.3）。

M2 実装済み: セッションは再レイアウトの前に可視ページを撮って `relayoutSnapshot` に置き、WebView のページサイズ変更と
再レイアウトは同じ操作の中で行い、位置を復元したら nil に戻す。`EPUBReaderView` は非 nil の間その画像を
WebView の上に左上寄せで重ね、nil になったら 0.2 秒のフェードで外す。`layoutKey` も変わるので事前ページ化は
新しいキーで再開し、以前のキーの確定値はキャッシュに残る。

M4 で追加: サイズ変更で `SpreadPlan` も組み直し、単ページ ⇄ 見開きが変わる（iPad の回転など）ときは、現在の `position` の
spine item を含む新しい面を読み込んで `pageFor(cfi)` で復元する。横書きリフローの 1 段 ⇄ 2 段は同じ文書の再レイアウトで済む。
FXL 書籍では `relayoutSnapshot` は面全体の画像になる。

アプリ側の注意: `viewportSize` が数 pt でも変わるとレイアウトキーが変わり、全章の計測がやり直しになる。
ステータスバーなど `EPUBReaderView` の周囲の UI は、表示内容（推定中インジケータなど）で高さが変わらないようにする。

## 5. 公開しない型

`EPUBSchemeHandler`、`PaginationService`、`SpreadBuilder`、`reader.js` のメッセージ型、WKWebView の
サブクラスは `internal`。将来のネイティブ描画への差し替え点として `internal protocol SpineRenderer` を置き、
`ReaderSession` はそれ越しに WebView を操作する（M1 では `WebViewSpineRenderer` が唯一の実装）。
EPUBUI だけが必要とする WebView のホスト用ビューは `@_spi(EPUBUI)` で渡す（§3.2）。

M5 で確認: 実装の公開宣言とこの文書を突き合わせ、M4 で `public` になっていた `SpreadBuilder` / `SpreadPlan` を
`internal` に戻した（アプリから使う場面がなく、テストは `@testable import` で読む）。`ReaderKey` / `ReaderKeyAction`（§4.3）、
`LinkDestination`（リンク先の分類）、`BridgeMessage` も `internal`。`PageSnapshot` / `PageSnapshotTarget` / `PageDirection` /
`TapZone` は EPUBRenderer の公開型として残す（EPUBUI とアプリの演出が使う）。
