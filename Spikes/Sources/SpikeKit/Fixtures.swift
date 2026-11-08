import Foundation

/// Minimal hand-written documents. No external samples are used.
public enum Fixtures {
    public static let xhtmlMIME = "application/xhtml+xml"
    public static let htmlMIME = "text/html"

    public static let pageColors: [(name: String, hex: String, rgb: (Int, Int, Int))] = [
        ("red", "#c0392b", (192, 57, 43)),
        ("green", "#27ae60", (39, 174, 96)),
        ("blue", "#2980b9", (41, 128, 185)),
        ("orange", "#e67e22", (230, 126, 34)),
        ("purple", "#8e44ad", (142, 68, 173)),
        ("teal", "#16a085", (22, 160, 133)),
    ]

    /// Horizontal paged document: html is one page wide, columns stack horizontally. Each page is a solid color block.
    public static func pagedHorizontal(pageWidth: Int, pageHeight: Int) -> String {
        let pages = pageColors.enumerated().map { i, c in
            #"<div class="pg" style="background:\#(c.hex)">\#(i)</div>"#
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>paged</title><meta name="viewport" content="width=device-width, initial-scale=1"/>
        <style>
        html { width: \(pageWidth)px; height: \(pageHeight)px; overflow: hidden; margin: 0;
               column-width: \(pageWidth)px; column-gap: 0; column-fill: auto; }
        body { margin: 0; }
        .pg { width: \(pageWidth)px; height: \(pageHeight)px; display: flex; align-items: center; justify-content: center;
              font: bold 64px -apple-system, sans-serif; color: #fff; box-sizing: border-box; }
        </style></head>
        <body>
        \(pages)
        </body></html>
        """
    }

    /// Japanese vertical-writing prose (original text written for this spike), with ruby.
    public static let japaneseParagraphs: [String] = [
        "山道を登りながら、こう考えた。智に働けば角が立つというが、この坂の<ruby>勾配<rt>こうばい</rt></ruby>はそれよりも急である。",
        "谷の底から<ruby>靄<rt>もや</rt></ruby>が立ちのぼり、杉の梢を白く染めていく。鳥の声は遠く、足元の落ち葉だけが乾いた音を返した。",
        "茶屋の<ruby>婆<rt>ばあ</rt></ruby>さんは、客が来るのを今日も待っていた。炉の火は小さく、鉄瓶の湯はまだ沸かない。旅人は腰を下ろして、ただ黙って山を見ていた。",
        "峠を越えると海が見えた。<ruby>蒼<rt>あお</rt></ruby>い水面に、二艘の舟が浮かんでいる。風はなく、帆は垂れたままだった。",
        "村の入口には古い<ruby>石碑<rt>せきひ</rt></ruby>があった。文字は風雨に削られ、ほとんど読めない。それでも人々は、春になると花を供えた。",
        "夜になると、宿の二階から三味線の音が聞こえた。誰が弾いているのかは分からない。障子の向こうの灯りが、ゆっくりと揺れていた。",
        "翌朝、霧は晴れていた。昨日の道を振り返ると、来た方向がまるで別の国のように見えた。旅はまだ、始まったばかりである。",
        "宿の主人は、この辺りの昔話を語りはじめた。昔、この山には大きな<ruby>鏡<rt>かがみ</rt></ruby>があり、月の夜には谷全体を照らしたという。",
        "二〇二五年の春、一二三四段の石段を数えながら登った。縦中横で書けば「<span class=\"tcy\">25</span>年」である。",
        "海沿いの道は長く、昼を過ぎても町は見えなかった。潮の匂いと、遠くの汽笛。旅人は歩みをゆるめ、しばらく波を眺めた。",
    ]

    public static func verticalJapanese(pageWidth: Int, pageHeight: Int, repeatCount: Int = 3) -> String {
        var body = ""
        for _ in 0..<repeatCount {
            for p in japaneseParagraphs { body += "<p>\(p)</p>\n" }
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="ja">
        <head><title>vertical</title><meta name="viewport" content="width=device-width, initial-scale=1"/>
        <style>
        html { writing-mode: vertical-rl; width: \(pageWidth)px; height: \(pageHeight)px; overflow: hidden; margin: 0;
               column-width: \(pageHeight)px; column-gap: 0; column-fill: auto; }
        body { margin: 0; padding: 0; font-family: "Hiragino Mincho ProN", serif; font-size: 16px; line-height: 1.8; }
        p { margin: 0 0 0 1em; text-indent: 1em; }
        .tcy { text-combine-upright: all; }
        </style></head>
        <body>
        <h1 id="title">山路</h1>
        \(body)
        </body></html>
        """
    }

    /// Document for the JS bridge spike. Contains content scripts that must NOT run.
    public static let bridgeXHTML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>bridge</title><meta name="viewport" content="width=device-width, initial-scale=1"/>
    <script>window.__contentRan = true; document.title = "content-js-ran";</script>
    </head>
    <body>
    <p id="p1">Hello bridge</p>
    <script>document.body.setAttribute("data-content-js", "ran");</script>
    <img src="x.png" onerror="document.body.setAttribute('data-inline-handler','ran')" alt=""/>
    </body></html>
    """

    /// WKUserScript body for the bridge spike (runs in the `reader` content world).
    public static let readerUserScript = """
    (function () {
      window.__epubReader = {
        ping(x) {
          return { ok: true, echo: x, title: document.title, readyState: document.readyState,
                   contentJS: document.body.getAttribute("data-content-js"),
                   inlineHandler: document.body.getAttribute("data-inline-handler"),
                   startReadyState: window.__startReadyState || null };
        },
        lastReply: null, lastError: null
      };
      const p = window.webkit.messageHandlers.reader.postMessage({ type: "ready", payload: { readyState: document.readyState, href: location.href } });
      p.then(r => { window.__epubReader.lastReply = r; }).catch(e => { window.__epubReader.lastError = String(e); });
    })();
    """
    public static let readerStartScript = "window.__startReadyState = document.readyState;"

    public static let highlightXHTML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>highlight</title><meta name="viewport" content="width=device-width, initial-scale=1"/>
    <style> body { margin: 20px; font: 24px -apple-system, sans-serif; } </style>
    </head>
    <body>
    <p id="t">Hello highlighted world of CSS</p>
    </body></html>
    """

    /// Wrapper for the two-iframe spread (vertical writing). Right iframe shows page i, left shows page i+1.
    public static func spreadWrapper(pageWidth: Int, pageHeight: Int, src: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>spread</title>
        <style>
        html, body { margin: 0; overflow: hidden; }
        body { display: flex; flex-direction: row; }
        iframe { width: \(pageWidth)px; height: \(pageHeight)px; border: 0; display: block; }
        </style></head>
        <body><iframe id="left" src="\(src)"></iframe><iframe id="right" src="\(src)"></iframe></body></html>
        """
    }

    /// Broken-as-XML XHTML documents for the DOM comparison spike.
    public static let brokenDocs: [(name: String, source: String)] = [
        ("unclosed-and-entities", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>broken</title><link rel="stylesheet" href="s.css"></head>
        <body>
        <section id="s1">
        <h1>Title&nbsp;with nbsp</h1>
        <p id="p1">First paragraph<br>with br and &copy; entity
        <p id="p2">Second paragraph <b>bold <i>both</b> italic only</i> tail
        <p id="p3">Nested <p>paragraph</p> text
        <div>stray close</span> text</div>
        <img src="a.png" alt=x>
        <!-- a comment -->
        <ul><li>one<li>two</ul>
        <table><tr><td>cell</td></tr></table>
        <ruby>漢<rt>かん</rt></ruby>字
        </section>
        </body></html>
        """),
        ("single-missing-close", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>almost fine</title></head>
        <body>
        <div class="chapter" id="c1">
          <h2 id="h">Chapter</h2>
          <p id="a">Alpha <span class="x">beta</span> gamma.</p>
          <p id="b">Delta <em>epsilon <span>zeta</em> eta.</p>
          <p id="c">Theta <a href="#h">link</a>.</p>
        </div>
        </body></html>
        """),
        ("html5-elements-and-svg", """
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>t</title></head>
        <body>
        <article><header><h1>H</h1></header>
        <figure><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg><figcaption>cap</figcaption></figure>
        <p>text<span>a</span>b
        <aside>side</aside>
        </article>
        </body></html>
        """),
    ]
}
