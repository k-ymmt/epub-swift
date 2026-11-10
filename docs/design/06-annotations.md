# 06. 注釈（EPUB Annotations 1.0）

ハイライトとしおりを W3C の EPUB Annotations 1.0 に沿って作り直す設計。M6 で実装する（04-roadmap §1）。
現在の `Highlight` / `Bookmark`（03-api §2.5）はこの文書の `Annotation` に置き換え、互換は残さない。

## 0. 基準とする版

- 基準: W3C Working Draft 2026-10-15（https://www.w3.org/TR/2026/WD-epub-anno-10-20261015/）。
- 参照: Editor's Draft（https://w3c.github.io/epub-specs/epub34/annotations/）、Web Annotation Data Model
  （https://www.w3.org/TR/annotation-model/。EPUB Annotations はこのプロファイル）。
- 勧告前なので仕様は変わりうる。曖昧な点と未確定の点は §2.3 に本設計の解釈を表で残し、仕様が改訂されたら
  その表と突き合わせる。読み込みは寛容（複数の解釈を受け付ける）、書き出しは厳格（仕様の形だけを出す）にする。

## 1. 仕様の要点

本ライブラリに関係する部分だけを要約する。プロパティ名は仕様のまま。

| 対象 | 内容 |
|---|---|
| AnnotationSet | `@context`（`https://www.w3.org/ns/epub-anno.jsonld`）、`id`（URN 形式の UUID を推奨）、`type: "AnnotationSet"`、`generated`、`about`（`dc:title` / `dc:creator` / `dc:publisher` / `dc:date`。他の DC 語も可）、`items` |
| Annotation | `id`、`type: "Annotation"`、`motivation`（`"highlighting"` / `"bookmarking"`。無ければしおり）、`created`（必須）、`modified`、`creator`、`target`（1 つ）、`body`（1 つ） |
| Creator | `id`（必須）、`type`（`Person` / `Organization` / `Software`）、`name` |
| Target | `source`（EPUB のトップレベル content document の相対 URL）、`selector`（配列。無ければ文書全体） |
| Selector | `FragmentSelector`（`conformsTo` は RFC 3236 / Media Fragments / SVG / Text Fragment の 4 つだけ。他の URI は MUST NOT）、`CssSelector`、`TextPositionSelector`（`textContent` 上の位置）、`refinedBy`（値は前の 3 型） |
| Body | `type`（`TextualBody` / `Image` / `Audio` / `Video`）、`value`（TextualBody では必須。平文のみ）、`id`（音声等の相対 URL）、`format`、`color`（`pink` / `orange` / `yellow` / `green` / `blue` / `purple`、既定 yellow）、`highlight`（`solid` / `underline` / `strikethrough` / `outline`、既定 solid）、`tags` |
| 文字列 | 文字列、または `{text, language, direction}`。既定の言語と方向は `@context` 配列の追加オブジェクトで与えられる |
| パッケージ | 分離ファイル: ZIP、拡張子 `.annotations`、ルートに `annotations.json`。同梱: EPUB の `META-INF/annotations.json` |
| セキュリティ・プライバシー | 本文を HTML として解釈しない、外部資源を同意なく取得しない、`source` のパス走査を防ぐ、サイズと評価の上限を設ける、作成者は検証されていないものとして扱う、書き出しは最小限の情報で、匿名・仮名を扱える |

## 2. 方針

### 2.1 位置の正は CFI、セレクタは交換用

- `Annotation` の位置は CFI（範囲は `CFIRange`、点は `CFI`）で持つ。描画（`reader.js`）、検索、選択、並べ替えはすべて CFI で
  動いており、CFI は DOM を開かずに比較・spine での絞り込みができ、解決は経路をたどるだけで済む。TextPositionSelector は
  解決のたびに `textContent` を走査するので、数百件の描画では CFI が速い。
- 他の Reading System から読み込んだ注釈は、元のセレクタ配列を **原本**（`Target.originalSelectors`）として保持する。
  位置を変えていなければ書き出しで原本をそのまま返し、他システムのデータを劣化させずに往復させる。
  位置を変えたら原本は捨て、CFI から生成し直す。
- CFI で表せない対象（画像の領域 `xywh`、SVG の視点、時間範囲 `t=`）や解決できなかった注釈は、位置を `.unresolved` にして
  原本だけを持つ。データは捨てない（§3.4）。
- 交換用のセレクタは EPUBCore（libxml2 の軽量 DOM）で生成・解決する。WebView なしで動き、大量の import / export を
  バックグラウンドで処理でき、`swift test` で検証できる。修復済み XHTML（01-core §4.1）では元ファイルの DOM とずれうるが、
  読み込んだ注釈は原本を保持するので往復では崩れない。

CLAUDE.md の「位置は CFI」の規則は「位置の正は CFI。EPUB Annotations の交換用セレクタは例外」と読み替える。

### 2.2 CFI の併記

- 仕様には CFI のセレクタがなく、`FragmentSelector` の `conformsTo` に CFI の URI を使うことは MUST NOT。
- 仕様 §5 は Reading System 固有の語の追加を許し、§7.2（非規範）は知らないセレクタ型を無視して残りで解決するよう
  勧めている。そこで CFI を独自のセレクタ型 `epubswift:CfiSelector` として selector 配列の **末尾** に置く。
  他の実装は標準のセレクタを先に評価し、知らない型は捨てる。
- 名前空間は `https://github.com/k-ymmt/epub-swift/ns/annotations#`、接頭辞 `epubswift`。`@context` 配列の 2 つ目の要素で
  宣言する（§4.1）。JSON-LD 処理系でなければ参照されない識別子なので、リポジトリ名が変わってもこの値を使い続ける。
- 書き出しでも既定で含める。CFI は他のセレクタと同じ位置しか表さず、個人情報は増えない。`ExportOptions.includesCFI` で外せる。
- 読み込みでは CFI を先に試し、標準のセレクタの結果と照合する（§6.2）。他システムが標準のセレクタだけを直して
  CFI を残した場合に古い位置を採らないため。

### 2.3 仕様の曖昧な点と本設計の解釈

| 点 | 仕様 | 本設計 |
|---|---|---|
| body の要否 | 冒頭は「1 つの body を要する」、表は任意 | 読み込みは body なしを受け付ける。書き出しは、しおりでメモがなければ body を省き、ハイライトには常に body を付ける |
| メモのないハイライト | 色とスタイルは body にしか書けないが、TextualBody の `value` は必須 | `{"type": "TextualBody", "value": "", "color": …, "highlight": …}` と書く。読み込みでは空文字列と `value` 欠落を「メモなし」とする |
| しおりの点 | 「1 点を指す」とだけあり書き方がない | CssSelector + `refinedBy` TextPositionSelector（`start == end`）と CFI セレクタ。TextQuoteSelector は付けない（`exact` が空の引用は定義が曖昧なため。内容の変化には CFI のテキストアサーションで備える）。範囲が来たら始点を使う（仕様どおり） |
| `source` の基準 | 「EPUB 3.4 の相対 URL」。例は `OEBPS/text/chapter1.html` | コンテナのルートからのパス（`SpineItem.path` をパーセントエンコード）で書く。読み込みはルート基準で解決し、失敗したらパッケージ文書のディレクトリ基準も試す |
| TextPositionSelector の単位 | 単位の明記なし。Web Annotation は Unicode コードポイント | コードポイントで数える。CFI は UTF-16 コードユニット（01-core §5.1）なので変換する |
| 内容に強いセレクタ | TextPositionSelector に「内容の変化に強いセレクタを添える」よう勧める。例は Text Fragment（AT RISK） | Web Annotation の `TextQuoteSelector` を selector 配列の独立した要素として付ける。`refinedBy` の値の型は 3 つに限られるので、その中には入れない |
| Text Fragment | AT RISK | 書き出さない。読み込みでは解決に使う（§6.2） |
| body / target の個数 | 1 つずつ（編集者注で議論中） | 書き出しは 1 つずつ。読み込みで配列が来たら最初の要素を使い、残りは未知のプロパティとして保持する |
| 書籍の識別 | 一意な識別子はなく推定に任せる | `about` に仕様が許す追加の DC 語として `dc:identifier`（OPF の unique-identifier）も書く。照合はアプリが判断する（§7） |
| ZIP の媒体型 | `application/zip;profile="https://www.w3.org/TR/epub-anno-10/"`（JSON-LD は `http://www.w3.org/ns/anno.jsonld`） | 文字列のまま定数にし、改訂に合わせて直す |
| 拡張子 | `.annotations`（issue 3099 で再検討中） | `.annotations`。読み込みは拡張子を見ず中身で判断する |
| ZIP のルート | issue 3083 で未定義とされる | ZIP の中央ディレクトリで先頭の `/` を持たない `annotations.json` |
| JSON Schema | §8 は T.B.D. | 本文の表を正とする |
| 色・スタイルの未知の値 | §7.7 は灰色などへの退避を勧める | 値は保持し、描画は灰色の solid にする（§10.2） |

## 3. データモデル（EPUBCore）

すべて `Sendable` / `Hashable`。`Codable` は仕様の JSON そのもの（§4）。

### 3.1 AnnotationSet

```swift
public struct AnnotationSet: Hashable, Sendable {
    public var id: String                       // 既定 "urn:uuid:<小文字 UUID>"
    public var generated: Date?
    public var about: About
    public var items: [Annotation]
    public var defaultLanguage: String?         // @context の @language
    public var defaultDirection: TextDirection? // @context の @direction
    public var extensions: JSONObject           // 未知のプロパティ（§3.6）

    public struct About: Hashable, Sendable {
        public var title: LocalizableText?
        public var creators: [LocalizableText]
        public var publisher: LocalizableText?
        public var date: String?                // 仕様どおり文字列のまま
        public var identifier: String?          // dc:identifier（本設計で追加する DC 語）
        public var extensions: JSONObject       // その他の DC 語など
        public init(publication: Publication)   // Publication.metadata から作る
    }
}
```

### 3.2 Annotation

```swift
public struct Annotation: Identifiable, Hashable, Sendable {
    public enum Motivation: String, Sendable { case highlighting, bookmarking }

    public var id: String                       // URI。新規は "urn:uuid:…"。他システムの任意の URI も受ける
    public var motivation: Motivation           // 読み込みで欠落していたら .bookmarking。書き出しでは常に書く
    public var created: Date
    public var modified: Date?
    public var creator: Creator?
    public var target: Target
    public var body: Body?
    public var origin: Origin                   // ライブラリ内の情報。書き出しでは消す（§4.3）
    public var extensions: JSONObject

    public static func highlight(_ range: CFIRange, in publication: Publication,
                                 color: HighlightColor = .yellow, style: HighlightStyle = .solid,
                                 note: LocalizableText? = nil, tags: [String] = [], at date: Date = .now) -> Annotation
    public static func bookmark(at position: CFI, in publication: Publication,
                                note: LocalizableText? = nil, at date: Date = .now) -> Annotation

    public var spineIndex: Int?                 // 位置が解決済みなら CFI から
}

public struct Creator: Hashable, Sendable {
    public enum Kind: String, Sendable { case person = "Person", organization = "Organization", software = "Software" }
    public var id: String
    public var kind: Kind
    public var name: LocalizableText?
    public var extensions: JSONObject
}

public enum Origin: Hashable, Sendable {
    case local                                          // このアプリで作った
    case imported(setID: String, importedAt: Date)      // 分離ファイルから取り込んだ（仕様 §11.5 の区別に使う）
    case publication                                    // EPUB 同梱（読み取り専用。§9.3）
}
```

`Highlight` の `note` は M3 のデモで「選択時のテキスト」を入れていたが、`Body` のテキストはメモ（利用者の注記）であり、
選ばれた本文ではない。選ばれた本文は TextQuoteSelector の `exact` が持つ。

### 3.3 Target と位置

```swift
public struct Target: Hashable, Sendable {
    public enum Position: Hashable, Sendable {
        case range(CFIRange)        // ハイライト
        case point(CFI)             // しおり
        case resource               // セレクタなし。文書全体
        case unresolved             // 解決できない、または CFI で表せない（画像の領域など）
    }

    public var source: String                       // コンテナのルートからのパス（パーセントデコード済み）
    public var position: Position {
        didSet { if position != oldValue { originalSelectors = nil } }   // 位置を変えたら原本を捨てる（§2.1）
    }
    public private(set) var originalSelectors: [Selector]?   // 読み込んだときのセレクタ配列。自分で作ったものは nil
    public var extensions: JSONObject
}
```

### 3.4 Selector

読み込んだセレクタを失わずに持つための型。アプリが直接作る必要はない。

```swift
public indirect enum Selector: Hashable, Sendable {
    case fragment(value: String, conformsTo: String?, refinedBy: [Selector])
    case css(value: String, refinedBy: [Selector])
    case textPosition(start: Int, end: Int, refinedBy: [Selector])     // コードポイント
    case textQuote(exact: String, prefix: String?, suffix: String?)    // Web Annotation の型
    case cfi(String)                                                    // epubswift:CfiSelector
    case unknown(JSONObject)                                            // 知らない型。そのまま書き戻す
}
```

### 3.5 Body と色

```swift
public struct Body: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case text(LocalizableText)          // TextualBody
        case image(String)                  // 相対 URL（.annotations ZIP の中、または META-INF 以下）
        case audio(String)
        case video(String)
    }
    public var content: Content?            // nil はメモなし（書き出しでは value: ""）
    public var format: String?              // 媒体型。TextualBody では text/plain のみ有効
    public var color: HighlightColor        // 既定 .yellow
    public var style: HighlightStyle        // 既定 .solid
    public var tags: [String]
    public var extensions: JSONObject
    public var isExternal: Bool { get }     // 音声等の id が絶対 URL（ライブラリは取得しない。§11）
}

public enum HighlightColor: Hashable, Sendable, RawRepresentable {
    case pink, orange, yellow, green, blue, purple
    case other(String)                      // 仕様外の値。保持し、描画は灰色
}

public enum HighlightStyle: Hashable, Sendable, RawRepresentable {
    case solid, underline, strikethrough, outline
    case other(String)                      // 保持し、描画は solid
}

public struct LocalizableText: Hashable, Sendable, ExpressibleByStringLiteral {
    public var text: String
    public var language: String?            // BCP 47
    public var direction: TextDirection?    // ltr / rtl
}
```

`body` が無い注釈の色とスタイルは仕様の既定（yellow / solid）として扱う。

### 3.6 未知のプロパティ

`JSONObject` は `[String: JSONValue]`（`JSONValue` は null / bool / number / string / array / object）。仕様が定めない
プロパティを各オブジェクトの `extensions` に保持し、書き出しで同じ位置に戻す。他システムの拡張語を往復で失わないため。
`epubswift:` で始まる自前の語は `extensions` に入れず、型のプロパティとして読む。

## 4. JSON 直列化

### 4.1 形

```json
{
  "@context": [
    "https://www.w3.org/ns/epub-anno.jsonld",
    { "epubswift": "https://github.com/k-ymmt/epub-swift/ns/annotations#" }
  ],
  "id": "urn:uuid:3f0d6a2e-…",
  "type": "AnnotationSet",
  "generated": "2026-11-10T00:00:00Z",
  "about": {
    "dc:title": "Moby-Dick",
    "dc:creator": ["Herman Melville"],
    "dc:identifier": "code.google.com.epub-samples.moby-dick-basic"
  },
  "items": [
    {
      "id": "urn:uuid:9b1c…",
      "type": "Annotation",
      "motivation": "highlighting",
      "created": "2026-11-10T00:00:00Z",
      "target": {
        "source": "OPS/chapter_001.xhtml",
        "selector": [
          { "type": "CssSelector", "value": "#chapter_001 > :nth-child(3)",
            "refinedBy": { "type": "TextPositionSelector", "start": 0, "end": 15 } },
          { "type": "TextQuoteSelector", "exact": "Call me Ishmael", "suffix": ". Some years ago" },
          { "type": "epubswift:CfiSelector", "value": "epubcfi(/6/14[xchapter_001]!/4/2/6,/1:0,/1:15)" }
        ]
      },
      "body": { "type": "TextualBody", "value": "", "color": "yellow", "highlight": "solid" }
    }
  ]
}
```

- 例のセレクタと CFI の値は説明用で、fixture の実際の値ではない。
- `refinedBy` は 1 つなら単一のオブジェクト、複数なら配列で書く（Web Annotation の慣例）。読み込みはどちらも受ける。
- 日時は ISO 8601（UTC、`Z`）。精度は §4.3。
- 単独の `Annotation` を直列化するときは、その注釈にも `@context` を付ける。
- 既定の言語・方向（`AnnotationSet.defaultLanguage` / `defaultDirection`）は `@context` 配列の 2 つ目のオブジェクトに
  `@language` / `@direction` として名前空間の宣言と一緒に書く。

### 4.2 読み込みの寛容さ

- `@context` は検査しない（JSON-LD を展開しない）。`type` で判定する。
- `motivation` の欠落は `.bookmarking`。`body` / `target` が配列なら先頭を使う（§2.3）。
- `selector` が単一のオブジェクトでも配列として扱う。
- 文字列と `{text, language, direction}` の両方を受ける。
- 不正な注釈は 1 件ずつ捨てて `AnnotationImportWarning` に積み、全体は失敗させない。`AnnotationSet` 自体の必須項目
  （`type`、`items`）が欠けたときだけ失敗する。

### 4.3 符号化の 2 つのモード

```swift
public enum AnnotationEncodingMode: Sendable {
    case storage                    // アプリの保存用。すべて含める
    case export(ExportOptions)      // 他人・他アプリに渡す形
}

public struct ExportOptions: Sendable {
    public var includesCreator = false                  // 既定で作成者を消す（仕様 §10.2）
    public var timestampPrecision: TimestampPrecision = .day   // .day / .second
    public var includesCFI = true                       // §2.2
    public var filter: AnnotationFilter = .init()       // motivation / color / style / tags / creator / origin で絞り込む
}
```

- `storage` は `epubswift:origin`（出自）も書く。アプリの保存と交換の形を 1 つにし、保存分は読み込みで CFI を検証せず
  信頼する（§6.2 の照合を省くので速い）。
- `export` は `epubswift:origin` を書かない。`AnnotationFilter` の既定は `origin` が `.publication` のもの（同梱注釈）を除く。
- `timestampPrecision: .day` は `created` / `modified` / `generated` を UTC の日の始まりに丸める。

## 5. セレクタの生成（CFI → セレクタ、EPUBCore）

位置を変えていない読み込み済みの注釈は原本を書き出すので、生成は自分で作った注釈と位置を変えた注釈に対して行う。
章の軽量 DOM（`XMLDocument`）を開き、同じ章の注釈はまとめて処理する。

1. **解決**: `CFIResolver` で始点と終点を `DocumentLocation` にする。解決できなければ CFI セレクタだけを書く。
2. **scope 要素**: 始点と終点を含む最も深い共通祖先の **要素**（テキストノードなら親）。
3. **CssSelector**: scope 要素から祖先をたどり、最も近い `id` 付きの要素（その `id` が文書内で一意なもの。scope 要素自身を
   含む）を起点にする。無ければ `body`。起点から scope 要素までを `> :nth-child(n)` でつなぐ。
   - 例: `#ch3 > :nth-child(4) > :nth-child(2)`、起点が scope 要素なら `#ch3`、`id` が無ければ `body > :nth-child(5)`。
   - `id` は CSS の識別子としてエスケープする（`CSS.escape` と同じ規則）。
   - `nth-child` は要素の子だけを数える。軽量 DOM は要素とテキストだけを持つので、要素の子の index がそのまま使える。
4. **TextPositionSelector**: scope 要素の `textContent`（子孫のテキストノードを木の順に連結。`rt`・`script`・`style` も含める。
   検索用の `TextMap` は使わない）上で、始点と終点の位置をコードポイントで数える。CFI の UTF-16 オフセットは、テキストノード
   ごとにコードポイントへ変換する。軽量 DOM は CDATA を文字として含め、コメントを含めないので、DOM の `textContent` と
   同じ文字列になる（01-core §4.2。§12 で WebKit と一致することを確かめた）。
   - `script` 要素: 本ライブラリの WebView はコンテンツ JS を止めているため、WebKit は `script` 要素を DOM から取り除く（§12）。
     セレクタは出版物の DOM（`script` を含む。JS を動かす他の Reading System が見る木）で数える。手順 3 の `nth-child` と
     手順 4・5 の `textContent` は `XMLDocument(data:tree: .source)` の木で数え、CFI は既定の `.rendered` の木（WebKit と同じく
     `script` と `template` の子が無い）で扱う（01-core §4.2）。CFI の位置から `.source` の木の位置へは、両方の木を同じ順に
     たどって対応させる（`.rendered` は `.source` から要素を除き、テキストを結合しただけなので、対応は一意に決まる）。
5. **TextQuoteSelector**（範囲だけ）: `exact` は範囲の文字列。`prefix` / `suffix` は `body` の `textContent` 上の前後
   32 コードポイント。`prefix + exact + suffix` が `body` 内で一意になるまで 32 ずつ伸ばし、最大 256 で止める（残る重複は
   TextPositionSelector が区別する）。書籍の先頭・末尾で足りなければ短くてよい。
6. **CFI セレクタ**: `includesCFI` なら、`CFI` / `CFIRange` の文字列（テキストアサーション付き）を書く。
7. 文書全体（`.resource`）はセレクタを書かない。`.unresolved` は原本を書く（原本は必ずある）。

書記素クラスタの途中で始まる・終わる範囲は補正しない。範囲はブラウザの選択から来るので、通常は起きない。

## 6. セレクタの解決（セレクタ → CFI、EPUBCore）

### 6.1 source

1. パーセントデコードしてコンテナのルートからのパスとして正規化する。`..` でルートの外に出る、絶対 URL、`/` 始まりは拒否する
   （仕様 §11.3）。
2. spine に一致する項目が無ければ、パッケージ文書のディレクトリ基準でもう一度試す。
3. spine item（トップレベルの content document）に当たらなければ `.unresolved`。manifest にあっても spine に無い資源は対象外。

### 6.2 セレクタの評価順

| 順 | セレクタ | 処理 |
|---|---|---|
| 1 | `epubswift:CfiSelector` | `CFIResolver` で解決する。`storage` で保存した自分の注釈ならここで確定する。取り込みでは、2 以降の標準セレクタでも解決し、両者が覆うテキストが同じなら CFI を採る。異なれば標準の結果を採る。標準セレクタが無ければ CFI を採る |
| 2 | CssSelector → `refinedBy` TextPositionSelector | CSS の部分集合（§6.3）で scope を引き、`textContent` 上の位置で範囲にする。TextQuoteSelector があれば `exact` と照合し、違えば 3 に回す |
| 3 | TextQuoteSelector | `body` の `textContent` から `prefix + exact + suffix` を探す。複数あれば 2 が示した位置に最も近いもの。前後の文脈を少しずつ削って再検索し、`exact` だけでも見つからなければ失敗 |
| 4 | FragmentSelector（RFC 3236） | `id` の要素の内容全体を範囲にする。しおりはその始点 |
| 5 | FragmentSelector（Text Fragment） | `:~:text=[prefix-,]start[,end][,-suffix]` を 3 と同じ方法で解決する |
| 6 | FragmentSelector（Media Fragments / SVG） | 解決しない（`.unresolved`。描画は将来の拡張点） |
| 7 | 知らない型 | 無視する |

- 範囲が求まったら `CFIGenerator` でテキストアサーション付きの `CFIRange` にする。しおりは始点の `CFI`。
- どれでも決まらなければ `.unresolved` として原本を保持する。セレクタが空の配列、または `selector` が無ければ `.resource`。
- 取り込んだ注釈の位置は CFI に解決しても `originalSelectors` に原本を残す（§2.1）。

### 6.3 CSS の部分集合

`#id`、型セレクタ（`p`）、`:nth-child(n)`、`:nth-of-type(n)`、子結合子 `>` とその連結だけを解釈する。それ以外（クラス、属性、
子孫結合子、`An+B` の一般形など）を含むセレクタは失敗として次の順位に進む。DOM 全体を総当たりしないので、評価の時間は
セレクタの長さに比例する。必要になれば部分集合を広げる。

## 7. 書籍との照合

仕様に書籍の一意な識別子はない。ライブラリは照合の材料を返し、取り込むかどうかはアプリ（利用者）が決める。

```swift
public struct AnnotationSetMatch: Sendable {
    public var identifier: MatchResult          // dc:identifier と OPF の unique-identifier（.match / .mismatch / .absent）
    public var title: MatchResult               // 大文字小文字・空白・Unicode 正規化を揃えて比較
    public var creators: MatchResult
    public var publisher: MatchResult
    public var resolvedSourceRatio: Double      // source が spine item に当たった割合
    public var resolvedPositionRatio: Double    // 位置まで CFI に解決できた割合
}
```

`dc:identifier` は同じ値を別の本が使うことがある（00-overview §5.3 の `PublicationID` の理由と同じ）ので、一致だけで同じ本と
決めない。

## 8. 取り込みのマージ

取り込みは既存の注釈を直接書き換えず、マージ計画を返す。仕様 §7 は同じ `id` を重複させず、更新するか利用者に尋ねるよう
勧めている。

```swift
public struct AnnotationMergePlan: Sendable {
    public var added: [Annotation]              // 新しい id
    public var updated: [Annotation]            // 取り込んだ側の modified（無ければ created）が新しい
    public var unchanged: [Annotation.ID]       // 内容が同じ
    public var outdated: [Annotation.ID]        // 既存の方が新しい
    public var conflicts: [(existing: Annotation, incoming: Annotation)]   // 日時で決まらず内容が違う
    public func applying(to existing: [Annotation], resolvingConflicts: (Annotation, Annotation) -> Annotation) -> [Annotation]
}
```

既定の適用は `added` と `updated` を入れ、`conflicts` はアプリのクロージャで決める。取り込んだ注釈の `origin` は
`.imported(setID:importedAt:)` にする。既存の `origin` が `.local` の注釈を更新した場合も `.imported` に変わる。

## 9. パッケージ

### 9.1 JSON

```swift
public enum AnnotationCodec {
    public static func decode(_ data: Data, limits: AnnotationImportLimits = .default) throws -> (AnnotationSet, [AnnotationImportWarning])
    public static func encode(_ set: AnnotationSet, mode: AnnotationEncodingMode) throws -> Data
}
```

位置の解決は復号と分ける（`AnnotationResolver`、§6）。復号は DOM を開かないので速く、アプリの保存データの読み込みはこれだけで済む。

### 9.2 `.annotations` ZIP

```swift
public struct AnnotationArchive: Sendable {
    public static let mediaType = #"application/zip;profile="https://www.w3.org/TR/epub-anno-10/""#
    public static let pathExtension = "annotations"
    public var set: AnnotationSet
    public func resource(at relativeURL: String) async throws -> Data   // Image / Audio / Video の body
    public static func read(from url: URL, limits: AnnotationImportLimits = .default) async throws -> AnnotationArchive
    public static func write(_ set: AnnotationSet, options: ExportOptions,
                             resources: @Sendable (String) async throws -> Data, to url: URL) async throws
}
```

- 読み込みは既存の `ZIPArchive` を使い、`annotations.json` を探す。
- 書き出しのために EPUBCore に `ZIPWriter` を足す。stored と deflate（Compression）、UTF-8 名のフラグ、ZIP64 は 4 GiB か
  65,535 項目を超えたときだけ。ファイルに逐次書き、音声などの大きな資源を全部メモリに載せない。
- 音声等の body の `id` は ZIP 内の相対 URL として書く。アプリが `resources` で中身を渡す。

### 9.3 EPUB 同梱の注釈

- `EPUBContainer` は開くときに `META-INF/annotations.json` の有無だけを見る（`Publication.hasEmbeddedAnnotations`）。
  パースはしない。
- `container.embeddedAnnotations()` が要求時に読み、`origin` を `.publication` にして返す。結果はコンテナがキャッシュする。
- 同梱注釈は読み取り専用で、アプリの注釈とは別のレイヤーとして描く（§10.1）。

### 9.4 EPUB への埋め込み書き出し（将来）

今回は作らない。作るときの制約だけ残す: `mimetype` を先頭に無圧縮で置く、`encryption.xml` と `signatures.xml` を保つ
（署名対象を変えない）、元のファイルを上書きせず別ファイルに書く、仕様 §10.3 のとおり個人の注釈を入れる前にアプリが警告する。
`ZIPWriter` を共有する。

## 10. 描画（EPUBRenderer）

### 10.1 セッション

```swift
extension ReaderSession {
    public var annotations: [Annotation]                    // アプリの注釈（ハイライトもしおりも）。永続化はアプリ
    public private(set) var publicationAnnotations: [Annotation]   // 同梱注釈。開いたあとに遅延で読む
    public var showsPublicationAnnotations: Bool            // 既定 true
    public func resolve(_ set: AnnotationSet) async -> AnnotationResolution   // 位置の解決と照合（§6・§7）。バックグラウンド
}

public enum ReaderEvent {
    case annotationTapped(Annotation.ID, rects: [CGRect])  // highlightTapped を置き換える
}
```

- 描くのは `motivation == .highlighting` で位置が `.range` のものだけ。しおりは描かない。
- `annotations` を変えたら spine index ごとの辞書を作り直し、現在の面の分だけを `setHighlights` に渡す（`ReaderSession` の
  今の流れと同じ。差分適用は TODO.md の既存項目のまま）。
- アプリの注釈と同梱注釈が同じ範囲に重なったら、アプリの注釈を上に描く。
- 取り込んだ注釈を見た目で区別するかは、アプリが `origin` を見て決める。

### 10.2 色とスタイル

`ReaderTheme` に `annotationPalette: [HighlightColor: ReaderColor]` を足し、`light` / `sepia` / `dark` に既定のパレットを持たせる。
アプリはテーマごとに上書きできる。仕様外の色（`.other`）とパレットに無い色は `annotationFallbackColor`（灰色）で描く。
solid は背景色として半透明で、線のスタイルは不透明で描く。暗いテーマでは背景の明度を下げた色にする。

| スタイル | 描き方 |
|---|---|
| solid | `::highlight()` の `background-color` |
| underline | `::highlight()` の `text-decoration: underline`（現行と同じ） |
| strikethrough | `::highlight()` の `text-decoration: line-through` |
| outline | 重ね描きレイヤー（§10.3） |
| `.other` | solid |

### 10.3 重ね描きレイヤー

`::highlight()` は `outline` / `border` を受け付けないので、outline は `reader.js` が枠として描く。

- `<html>` の最後の子（`<body>` の後ろ）に `<div id="__reader_overlay">` を 1 つ置き、`position: absolute`、
  `pointer-events: none` にする。`<body>` より後ろなので `<body>` までの CFI のステップは変わらない。`reader.js` の CFI 生成と
  `cfiForPage` の走査はこの要素を飛ばす。
- 各範囲の `Range.getClientRects()` を文書座標（スクロール量を足す）に直し、行ごとの枠を描く。
- `layout`、`applySettings`、リサイズ、`pageCountChanged` のたびに矩形を取り直す。`CSS.highlights` と違って `Range` から自動では
  追従しない。
- タップの当たり判定は今の `highlightTap` と同じく `Range` の矩形で行うので、レイヤーは判定に関わらない。
- 縦書きの多段組、FXL の見開きラッパー内の iframe でも枠が文字に重なるかは §12 で先に確かめる。将来、画像の領域（`xywh`）を
  描くときもこのレイヤーを使う。

`setHighlights` の引数は `{id, cfiRange, color, style}` の `style` に `strikethrough` / `outline` を加える（02-rendering §4.1）。

## 11. セキュリティとプライバシー

- **上限**（`AnnotationImportLimits.default`。すべて変更可）: `annotations.json` 32 MB、注釈 10 万件、JSON の入れ子 32 段、
  文字列 1 MB、`refinedBy` の連鎖 8 段、ZIP の展開後の合計 512 MB。超えたら復号を失敗させる（件数と文字列は超えた分を
  捨てて警告にする）。CSS は §6.3 の部分集合だけを評価する。
- **パス**: `source` と body の `id` がコンテナ（または ZIP）の外を指したら拒否する（§6.1）。
- **外部資源**: body の `id` が絶対 URL なら保持するが、ライブラリは取得しない。`Body.isExternal` で示し、取得するかはアプリが
  利用者の同意を得て決める。
- **本文**: `LocalizableText.text` は平文としてだけ渡す。ライブラリは HTML として描かない。アプリ向けに、平文で表示すること、
  自動リンクは `https:` だけにすることを API ドキュメントに書く。
- **作成者**: 取り込んだ `creator` は検証されていない。`origin` で取り込み分を区別できる。
- **書き出し**: 既定で作成者を消し、日時を日単位に丸める（§4.3）。何が含まれるかを利用者に示す UI はアプリが
  `ExportOptions` から作る。

## 12. 先に検証する項目

2026-11-10 に macOS の `swift test`（実 WKWebView）で検証した。テストは `Tests/EPUBRendererTests/AnnotationPrerequisiteTests.swift`
に残し、M6 の回帰テストとして使う。

| 項目 | 結果 |
|---|---|
| `textContent` の一致 | **成立（`script` を除いて）**。下記 |
| `line-through` | **成立**。下記 |
| 重ね描きレイヤー | **成立**。下記 |
| 他実装との往復 | 未検証。他の Reading System が出した `.annotations` が手に入ったら、読み込んで同じ位置に出るか確かめる |

### 12.1 `textContent` の一致

**方法**: 各 spine item について、EPUBCore の軽量 DOM（`contentDocument(at:)` の配信用 XHTML を `XMLDocument` で読んだもの）と、
表示した WebKit の DOM（FXL は見開きラッパーの iframe の文書）で、`body` の `textContent` と、`body` 以下の全要素の
「要素名・`textContent` のコードポイント数・子要素の数」を文書順に比べた。`reader.js` の番兵（`__reader_end`）は除く。

**対象**: リフローの全 fixture（cfi-sample、links-sample、草枕、childrens-literature、アラビア語、The Waste Land、moby-dick 全 144 文書）、
FXL の全 fixture（haruko、page-blanche、cole）、修復済み XHTML 3 文書（`Tests/Fixtures/malformed`）。合計 222 文書、約 1.8 万要素。

**結果**: `script` 要素を除けば全文書で一致した（修正後は既定の木がそのまま一致する。下記）。修復済み XHTML も一致した（WebKit は修復後の XHTML を XML として読むため。01-core §4.1）。
サロゲートペアは cfi-sample にあり、コードポイントでの数えが WebKit（`for…of`）と一致した。

**判明したこと**: WebKit は `allowsContentJavaScript = false` のとき、`<head>` と `<body>` の `script` 要素を DOM から取り除く
（childrens-literature の `nav.xhtml` と合成文書で確認）。軽量 DOM は `script` を保持するので、`script` のある文書では
要素の index がずれる。

- 注釈への影響: セレクタは出版物の DOM（`script` を含む）で数える方針にした（§5 手順 4）。JS を動かす他の Reading System の
  DOM と一致させるため。軽量 DOM は `script` を含むので、生成と解決は EPUBCore だけで閉じる。
- 既存の CFI への影響: `script` の後ろの要素では、EPUBCore の CFI（検索結果など）と `reader.js` の CFI のステップがずれていた。
  合成文書では `/4/12[c]`（EPUBCore）と `/4/8[c]`（`reader.js`）になった。ID アサーションがあれば解決できるが、`id` の無い
  要素ではずれる。同じ調査で、WebKit は XHTML の `template` の子を DOM の木に置かない（content の文書断片に移す）ことと、
  取り除くのは XHTML と SVG の小文字の `script` だけ（大文字の `SCRIPT` や他の名前空間の `script` は残す）ことも確かめた。
- 修正（2026-11-10）: 軽量 DOM の既定の木（`XMLDocument.Tree.rendered`）から `script` と `template` の子を除いた（01-core §4.2）。
  `cfi-sample` の `c1.xhtml` に段落内の `script`、`body` 直下の `script` の後ろの `id` の無い段落、SVG の `script`、`template` を足し、
  `cfi-vectors.json` のベクタで EPUBCore と `reader.js` の両方を検証した（修正前の木ではこのベクタで 8 件失敗する）。
  `CFIScriptTests.searchResultAfterAScriptMatchesTheDOM` で、`script` の後ろの検索結果の CFI が `reader.js` の CFI と一致することを確かめた。

### 12.2 `line-through`

**方法**: `::highlight(probe) { text-decoration: line-through; text-decoration-color: rgb(255, 0, 0); text-decoration-thickness: 3px }`
を表示中のページの単語に当て、WebView のスナップショットで赤い画素を数えた。

**結果**: 横書き（cfi-sample）では範囲（幅 52pt × 高さ 18pt）の中央に幅 51.5pt × 高さ 3pt の線、縦書き（草枕）では範囲（幅 17pt ×
高さ 96pt）の中央に幅 3pt × 高さ 96pt の線が描かれた。当てる前は赤い画素は 0。§10.2 の表のとおり `::highlight()` で描ける。

### 12.3 重ね描きレイヤー

**方法**: §10.3 のとおり `<html>` の最後の子に `position: absolute` の要素を置き、`Range.getClientRects()` にスクロール量を
足した位置に 2px の枠（`box-sizing: border-box`）を描いた。スナップショットの枠の色の外接矩形を範囲の矩形と比べた。

**結果**:

- 枠の位置: 横書き（moby-dick の 3 ページ目）、縦書き（草枕の 3 ページ目）、横書きの 2 段見開き（右の段）、縦書きの見開き
  ラッパー（2 つの iframe）、FXL（links-sample の 600×800 のページを 0.75 倍に縮めた iframe）のすべてで、範囲の矩形と ±0.5pt で一致した。
- ページ数への影響: 枠があってもページ数、`scrollWidth` / `scrollHeight`、ページ先頭の CFI（`cfiForPage`）は変わらなかった。
  最終ページの先頭の単語に枠を描いても同じ。枠は `caretRangeFromPoint` の判定にも入らない（`pointer-events: none`）。
- 再レイアウト: フォントサイズの変更（1.3 倍）では文書を読み直さないので要素は残るが、枠の位置は古いまま。描き直すと
  新しい位置に一致し、ページ数も変わらない。§10.3 の「再レイアウトのたびに矩形を取り直す」が必要なことを確認した。
- 見開きラッパーの中のページ数は、ラッパーの外からは測っていない（枠は iframe の文書に描くので、単ページの結果と同じと見なした）。

## 13. 既存の設計から変わる点

- `Highlight` / `Bookmark` を削除し、`Annotation` に統合する（03-api §2.5）。`ReaderColor` の任意色によるハイライトは無くなり、
  色ラベルとパレットになる。
- `ReaderSession.highlights` → `annotations`、`ReaderEvent.highlightTapped` → `annotationTapped`（03-api §3、§5）。
- `setHighlights` のスタイルが 4 種になり、重ね描きレイヤーが加わる（02-rendering §4.1、§10）。
- EPUBCore に `ZIPWriter`、`AnnotationCodec`、`AnnotationResolver`（セレクタの生成と解決）、`AnnotationArchive` が加わる（01-core）。
- 00-overview の非目標「ハイライト・しおり・読書位置の永続化」は変えない。ライブラリは符号化と解決までで、保存はアプリが行う。
- `Examples/ReaderDemo` の保存ファイル（`Highlight` の JSON）は、デモ側で `Annotation` に移す。RGBA は最も近い色ラベルに、
  `note` に入れていた選択テキストは捨てる（TextQuoteSelector が持つ）。

## 14. テスト

- **ベクタ**: `Tests/Fixtures/annotation-vectors.json` に CFI → CssSelector / TextPositionSelector / TextQuoteSelector の期待値を置く。
  `cfi-sample.epub` のサロゲートペア（コードポイント変換）、ruby（`rt` を `textContent` に含める）、`id` の無い文書（`body` 起点）、
  一意でない引用（prefix / suffix の伸長）を含める。
- **解決**: 同じベクタを逆向きに解く。文書を少し編集した複製で、CFI と標準セレクタが食い違う場合に標準を採ること、
  TextQuoteSelector で位置を補正することを確かめる。
- **往復**: storage と export の符号化 → 復号で値が保たれる。未知のプロパティと原本セレクタがそのまま戻る。
  `timestampPrecision` と `includesCreator` が効く。
- **仕様の例**: 仕様の例（CssSelector + refinedBy、TextualBody、Audio body、AnnotationSet、言語付き文字列）と同じ形の JSON を
  読める。
- **寛容さと上限**: `motivation` 欠落、`refinedBy` の単一・配列、`body` の配列、壊れた注釈 1 件の除外、各上限、パス走査の拒否。
- **ZIP**: `ZIPWriter` で書いたものを `ZIPArchive` で読める（stored / deflate / ZIP64 境界）。
- **Renderer**（macOS の実 WKWebView）: 4 つのスタイルの描画（色を数える）、outline の再レイアウト追従、`annotationTapped`、
  同梱注釈の表示切り替え。
