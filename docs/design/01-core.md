# 01. EPUBCore

UI にも WebKit にも依存しない層。EPUB ファイルを開き、構造を解釈し、位置と検索を提供する。

## 1. ZIP 読み出し

Apple 標準に ZIP コンテナを扱う API はないので自前で実装する。EPUB の OCF は ZIP の
サブセット（Stored と Deflate のみ、暗号化なし）なので、対応範囲を絞れる。

### 1.1 `ZIPArchive`

- `Data(contentsOf:options: .mappedIfSafe)` でファイルをメモリマップする。
- 末尾から End of Central Directory を探し、ZIP64 の場合は ZIP64 EOCD Locator を辿る。
- Central Directory を走査して `[path: ZIPEntry]` を作る。`ZIPEntry` は `localHeaderOffset`、
  `compressedSize`、`uncompressedSize`、`method`、`crc32` を持つ。
- エントリ読み出し時に Local File Header を読み、データ位置を確定する（Central Directory の
  サイズ情報を信用し、Local Header の値は矛盾があれば警告）。
- Deflate は Compression フレームワークの `compression_stream` を `COMPRESSION_ZLIB` で使う。
  これは raw deflate を扱うので ZIP のデータをそのまま渡せる。
- `mimetype` エントリが先頭にない、または内容が `application/epub+zip` でない場合は警告のみ。

パス正規化: Central Directory のファイル名は UTF-8 として扱い、`./` や `//` を除去する。
OPF からの参照は OPF のディレクトリを基準に解決し、パーセントデコードしてから一致させる。

### 1.2 `EPUBContainer`（actor）

- `init(url: URL) async throws`。ZIP を開き、container.xml → OPF → nav → encryption.xml の順に解析して
  `Publication` を作る。
- `func data(at path: String) async throws -> Data`。難読化対象なら解除して返す。
- `func contentDocument(at path: String) async throws -> ContentDocument`。spine item の XHTML を §4.1 の手順にかけ、
  配信すべきバイト列と `mediaType`（`application/xhtml+xml` または `text/html`）、状態（`wellFormed` / `repaired` / `unrepairable`）、
  警告を返す。`EPUBSchemeHandler` はこれを使う。
- `init(data: Data) async throws` も持つ（テストとメモリ上の EPUB 用）。
- 小さいエントリ（OPF、nav、CSS、XHTML）は読んだ結果を `NSCache` に入れる。画像はキャッシュしない。
- `publicationID: PublicationID` を保持する。

## 2. OCF と OPF

### 2.1 container.xml

`META-INF/container.xml` の `rootfiles` から `media-type="application/oebps-package+xml"` の
最初の `full-path` を採用する。複数あっても最初だけを使う（マルチレンディションは非対応）。

### 2.2 OPF（Package Document）

Foundation の `XMLParser`（SAX）で読む。OPF は整形式 XML であることが実質的に保証されるので
libxml2 の recover は使わない。読めなければ `EPUBError.invalidPackage` を投げる。

解釈する要素:

| 要素 | 取り込む内容 |
|---|---|
| `package` | `version`、`unique-identifier`、`dir`、`xml:lang` |
| `metadata` | `dc:title`、`dc:creator`、`dc:language`、`dc:identifier`（unique-identifier のものを主に）、`dc:publisher`、`dc:date`、`meta[property]`（`dcterms:modified`、`rendition:layout`、`rendition:orientation`、`rendition:spread`、`rendition:flow` は読むが flow は使わない）、`meta[refines]` による `title-type`、`file-as`、`role` |
| `manifest/item` | `id`、`href`、`media-type`、`properties`（`nav`、`cover-image`、`scripted`、`svg`、`mathml`、`remote-resources`）、`fallback`、`media-overlay`（読むだけ） |
| `spine` | `page-progression-direction`、`toc`（NCX 参照。無視）、`itemref` の `idref`、`linear`、`properties`（`page-spread-left`、`page-spread-right`、`page-spread-center`、`rendition:layout-*`、`rendition:spread-*`、`rendition:orientation-*`） |

`linear="no"` の itemref は reading order に含めるが `isLinear = false` を付ける。ページ番号の
計算には含めず、リンクで到達したときだけ表示する。

### 2.3 nav 文書

`properties="nav"` の manifest item を XHTML として読み、`nav[epub:type]` のうち `toc`、
`page-list`、`landmarks` を `[TOCEntry]` として木構造で保持する。各 entry は `label`、
`href`（OPF 相対で解決済み）、`spineIndex?`、`fragment?`、`children` を持つ。
nav が存在しない、または読めない場合は spine の順に manifest の href をラベルにした平坦な目次を
生成し、警告を積む。

### 2.4 encryption.xml とフォント難読化

`META-INF/encryption.xml` の `EncryptedData` を読み、`EncryptionMethod/@Algorithm` が次のときに
対象 `CipherReference/@URI` を難読化テーブルに登録する。

| Algorithm | 方式 | 鍵 | 対象バイト数 |
|---|---|---|---|
| `http://www.idpf.org/2008/embedding` | IDPF | `unique-identifier` の値（空白除去）を SHA-1 したもの | 先頭 1040 バイトを XOR |
| `http://ns.adobe.com/pdf/enc#RC` | Adobe | `unique-identifier` の `urn:uuid:` を除いた UUID を 16 バイトにしたもの | 先頭 1024 バイトを XOR |

それ以外のアルゴリズム（LCP、ADEPT など）は `PublicationWarning.unsupportedEncryption` を積み、
そのリソースの読み出しは `EPUBError.encryptedResource` を投げる。

SHA-1 は CryptoKit の `Insecure.SHA1` を使う（Apple 標準）。

M2 実装済み。`encryption.xml` は `EPUBContainer` を開くときに解析し（`EncryptionParser`）、`CipherReference/@URI` は
コンテナルートからの相対パスとしてパーセントデコードと正規化を行う。難読化の解除は `EPUBContainer.data(at:)` が
透過的に行い、`contentDocument(at:)` やスキームハンドラから見えるのは解除済みのバイト列だけになる。
`encryption.xml` 自体が XML として読めないときは `PublicationWarning.malformedEncryptionXML` を積み、
暗号化なしとして続行する（M2 で追加）。鍵の派生は `ObfuscationAlgorithm.key(uniqueIdentifier:)`、
XOR は `FontObfuscation.apply(to:)` で、どちらも公開型（テストとアプリ側の検証用）。

## 3. モデル

```swift
public struct PublicationID: Hashable, Sendable { let uuid: UUID }

public struct Publication: Sendable {
    public let id: PublicationID
    public let metadata: Metadata
    public let manifest: [ManifestItem]           // id で引ける
    public let readingOrder: [SpineItem]          // spine 順
    public let toc: [TOCEntry]
    public let pageList: [TOCEntry]
    public let landmarks: [TOCEntry]
    public let layout: RenditionLayout            // reflowable / prePaginated（書籍既定）
    public let spread: RenditionSpread            // auto / none / landscape / both
    public let pageProgression: PageProgression   // ltr / rtl / default
    public let coverImagePath: String?
    public let warnings: [PublicationWarning]
}

public struct SpineItem: Sendable, Identifiable {
    public let id: String                 // idref
    public let index: Int                 // spineIndex
    public let path: String               // コンテナ内パス
    public let mediaType: String
    public let isLinear: Bool
    public let layout: RenditionLayout    // itemref で上書きされた値を反映
    public let spreadPosition: SpreadPosition?   // left / right / center
    public let characterCount: Int?       // 開いた時点で埋まる。ページ数推定に使う
}
```

`characterCount` は `EPUBContainer` を開くときに全 spine item の XHTML を軽量 DOM（§4）で読み、`TextLength.characterCount`
で数えて埋める（M2 で変更。当初は検索インデックス構築時に埋める予定だった）。`body` 配下のテキストノードの文字数で、
`rt` / `rp`（ルビ）、`script`、`style`、`template` は除き、連続する空白は 1 文字に畳む。XHTML でない spine item や
パースに失敗した文書は nil のまま（ページ数推定では 0 文字 = 1 ページとして扱う）。`moby-dick` 全章で約 20 ms。
同じ走査は M3 の検索インデックスにも使う。

## 4. XHTML の軽量 DOM

CFI の生成・解決と検索のために、spine item の XHTML を DOM 木として持つ。
WebKit の DOM と同じ木でなければ CFI が食い違う。WebKit には常に XML 構文で解析させ、Core の木と 1 対 1 に対応させる。

### 4.1 パース

1. `XMLParser` で整形式 XML として読む。EPUB 3 の spine item は XHTML（XML 構文）なので通常はこれで足りる。
   成功した文書は ZIP のバイト列をそのまま配信対象にし、以降の手順は行わない。
   注意: `XMLParser` は外部 DTD を解決しないため、XHTML 1.1 の DOCTYPE を付けたまま `&nbsp;` などの名前付き実体を使う文書を
   「未定義の実体」として拒否する。こうした文書は XHTML としては正しいが、本ライブラリでは手順 2 以降の修復経路に回り
   （libxml2 の HTML パーサが実体を文字に解決する）、`malformedXHTML` 警告が付く。WebKit の XML パーサも同じ実体を
   エラーにするので、修復して配信する方が表示上も正しい。
2. 失敗したら libxml2 の HTML パーサ（`htmlReadMemory` + `HTML_PARSE_RECOVER | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING`）で読み、
   `PublicationWarning.malformedXHTML(path)` を積む。
3. 回復した木に次の補正だけを行う。これ以外の差異は直さない。
   - 名前空間: HTML パーサは名前空間を扱わないので、根要素に `xmlns="http://www.w3.org/1999/xhtml"` がなければ付ける。
     `epub:type` や `xlink:href` のような接頭辞付き属性を見つけたら、根要素に対応する `xmlns:epub` / `xmlns:xlink` を宣言する
     （未宣言のまま配信すると WebKit が XML エラーにする）。
   - SVG / MathML: HTML パーサは要素名と属性名を小文字化する。`foreignObject`、`viewBox`、`clipPathUnits` など
     大文字小文字を持つ名前を既知の表で戻す。
4. 木を `xmlSaveToBuffer(..., XML_SAVE_AS_XML)` で整形式 XML として直列化し、「修復済み XHTML」として
   `EPUBSchemeHandler` に `application/xhtml+xml` で配信させる（02-rendering §3.3）。WebKit は XML パーサで読むので、
   WebKit の DOM と Core の木が構造的に一致する。HTML5 の木構築規則を Swift 側で再現しない。
5. 修復済み XHTML を `XMLParser` で読み直す。失敗した文書は修復を諦め、原文を `text/html` で配信する（02-rendering §3.3）。
   この文書では Core の木と WebKit の DOM が一致しないため、CFI の解決は文字列アサーション（§5.3）による再解決に頼る。

壊れた文書の修復は努力目標で、上の手順を上限とする。SDK の libxml2（2.9 系）は HTML5 の木構築規則
（`tbody` の暗黙挿入、adoption agency、セクショニング要素による `p` の自動終了）を持たないため、
`text/html` で WebKit に読ませて DOM を揃える方式は成り立たない（05-spike-results §2.5）。

修復結果は決定的なので `(publicationID, path)` をキーに 1 回だけ計算し、事前ページ化キャッシュ（02-rendering §8）と同じ場所に置く。
修復後の木に対して付いた CFI は、OS 更新で libxml2 の回復規則が変わるとずれうる。正常な文書には影響しない。
壊れた文書については文字列アサーションで近傍に戻れることをもって受け入れる。

libxml2 は SDK 付属の `libxml2` モジュールを EPUBCore から直接 `import libxml2` する。
system library target（`CLibXML2`）は不要（05-spike-results §2.5）。

### 4.2 ノード規則

- 要素ノードと テキストノードだけを保持する。コメント、処理命令、CDATA はテキストに畳む（CFI の規則に合わせる）。
- 隣接するテキストノードは 1 つに結合する。
- 要素の `id` 属性は CFI の ID アサーションに使うので保持する。
- 空白だけのテキストノードも保持する。XML パーサはこれを落とさないため、WebKit の XML DOM と一致する。

## 5. CFI

EPUB CFI 1.1 のサブセットを実装する。

### 5.1 対応範囲

| 機能 | 対応 |
|---|---|
| spine ステップ `/6/4[chap01]!` | 対応。パッケージ文書内の `spine` 要素の子 index から spineIndex を求める |
| 要素ステップ `/4/2` | 対応（偶数 = 要素、奇数 = テキスト） |
| ID アサーション `[id]` | 対応。index が合わない場合は id を優先して復元する |
| 文字オフセット `:12` | 対応 |
| テキストアサーション `[before,after]` | 生成時に前後 10 文字を付け、解決時に照合して補正する |
| 範囲 `,start,end` | 対応（`CFIRange`） |
| 時間・空間オフセット `~` `@` | 非対応（パースは通し無視する） |
| サイドバイアス `;s=` | 非対応 |

### 5.2 型

```swift
public struct CFI: Hashable, Codable, Sendable, Comparable, LosslessStringConvertible {
    public let spineIndex: Int
    public let steps: [Step]            // 文書内のステップ
    public let characterOffset: Int?
    public let textAssertion: TextAssertion?
    public init?(_ description: String)
    public var description: String      // "epubcfi(/6/4[chap01]!/4/2/1:10)"
}

public struct CFIRange: Hashable, Codable, Sendable {
    public let start: CFI
    public let end: CFI
}
```

`Comparable` は spineIndex、各ステップの index、文字オフセットの順で比較する。
同じ文書内のハイライトの並び替えやページ内判定に使う。

### 5.3 生成と解決

- `CFIGenerator`（EPUBCore）は軽量 DOM 上のノード + オフセットから CFI を作る。検索結果に使う。
- `CFIResolver`（EPUBCore）は CFI を軽量 DOM 上のノード + オフセットに解決する。テスト用と、
  検索スニペットの切り出しに使う。
- 文字列アサーション（`[text]`）は生成時に常に付け、解決時はステップが指す位置のテキストと照合する。
  一致しなければ同じ spine item 内で前後に近いテキストを探して再解決する（修復を諦めた文書と、
  libxml2 の回復規則が変わった後の壊れた文書のための後ろ盾。§4.1）。
- 同じアルゴリズムを `reader.js` に実装し、WebView 内では DOM `Range` と相互変換する（02-rendering §5）。
- 両実装は同じテストベクタで検証する（`Tests/Fixtures/cfi-vectors.json`）。

spine ステップの生成には OPF の `package` 要素の子要素順が必要なので、`Publication` は
`spineElementIndex`（`package` 直下での `spine` の位置から計算した偶数 index）と、各 itemref の
偶数 index と id を保持する。

## 6. テキスト抽出と全文検索

### 6.1 抽出

spine item ごとに軽量 DOM を深さ優先で走査し、テキストノードを連結する。
`TextMap` として「連結文字列上のオフセット → (ノードパス, ノード内オフセット)」の対応表を持つ。
ブロック要素（p, div, h1-h6, li, td, br など）の境界には改行を挟み、スニペットが行をまたがないようにする。
`ruby` の `rt` / `rp` は検索対象から除く（本文は親文字だけ）。

### 6.2 検索

```swift
public actor SearchService {
    public init(container: EPUBContainer)
    public func search(_ query: String, options: SearchOptions = .default)
        -> AsyncThrowingStream<SearchResult, Error>
}

public struct SearchOptions: Sendable {
    public var caseInsensitive = true
    public var diacriticInsensitive = true
    public var widthInsensitive = true     // 全角半角を同一視
}

public struct SearchResult: Sendable, Identifiable {
    public let id: UUID
    public let spineIndex: Int
    public let range: CFIRange
    public let snippet: String             // 前後 40 文字程度
    public let matchRangeInSnippet: Range<String.Index>
}
```

- `NSString.range(of:options:range:locale:)` に `.caseInsensitive`、`.diacriticInsensitive`、
  `.widthInsensitive` を渡す。Foundation の比較はロケール対応で、日本語の全角半角を扱える。
- 抽出結果は spine item ごとに actor 内でキャッシュする。初回検索時に順に構築し、
  `AsyncThrowingStream` で章ごとに結果を流す。UI は到着順に表示できる。
- 構築した `characterCount` を `SpineItem` に反映し、ページ数推定の精度を上げる。
- 検索の起動を待たずに `SearchService.prepare()` でバックグラウンド構築を始められる。

## 7. 警告

```swift
public enum PublicationWarning: Sendable {
    case missingMimetype
    case missingNavigation
    case malformedXHTML(path: String)
    case missingResource(path: String, referencedFrom: String)
    case unsupportedEncryption(path: String, algorithm: String)
    case malformedEncryptionXML                              // M2 で追加。encryption.xml が XML として読めない
    case unknownMediaType(path: String)
    case duplicateManifestID(id: String)
}
```

## 8. テスト

- `Tests/Fixtures/` に IDPF epub3-samples から選んだ EPUB を置く（04-roadmap §3）。
- ZIP: Stored / Deflate / ZIP64 の最小ファイルをフィクスチャとして持ち、CRC を照合する。
- OPF / nav: 各サンプルで `readingOrder.count`、`toc` の深さ、`layout` が期待どおりか。
- 難読化: IDPF サンプルのフォント（`wasteland-otf-obf`）を解除し、OpenType のマジック `OTTO` / `0x00010000` で確認する。
  Adobe 方式はテスト内で生成した最小 EPUB（`MiniEPUB`）にフォントを Adobe 方式で難読化して入れ、解除後のバイト列が元と一致することを見る（M2 実装済み）。
- `characterCount`: ルビ・空白の扱いを小さな文書で検証し、`kusamakura` の各章が正の値を持つことを見る（M2 実装済み）。
- CFI: `cfi-vectors.json` の各ケースでパース → 文字列化の往復と、DOM 上の解決位置を検証する。
- 検索: 縦書きサンプル（`kusamakura-japanese-vertical-writing`）で全角半角を同一視した検索がヒットする。
