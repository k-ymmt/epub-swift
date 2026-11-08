# Spike results (macOS Version 27.0.1 (Build 26A434), 2026-11-08T09:57:13Z)

## Spike 1: allowsContentJavaScript = false と WKUserScript / callAsyncJavaScript / replyHandler
判定: 成立
- allowsContentJavaScript=false: `ready` 受信 payload=["readyState": interactive, "href": epub://spike/bridge.xhtml]
- allowsContentJavaScript=false: callAsyncJavaScript(reader world) → ["inlineHandler": <null>, "contentJS": <null>, "startReadyState": loading, "readyState": complete, "echo": 42, "title": bridge, "ok": 1]
- allowsContentJavaScript=false: postMessage の reply → {
    echoType = ready;
    pong = 1;
}
- allowsContentJavaScript=false: page world → ["readerVisibleInPageWorld": undefined, "title": bridge, "contentRan": 0]
- 判定根拠: contentBlocked=true bridgeOK=true
- allowsContentJavaScript=true: `ready` 受信 payload=["readyState": interactive, "href": epub://spike/bridge.xhtml]
- allowsContentJavaScript=true: callAsyncJavaScript(reader world) → ["readyState": complete, "echo": 42, "title": content-js-ran, "startReadyState": loading, "ok": 1, "contentJS": ran, "inlineHandler": ran]
- allowsContentJavaScript=true: postMessage の reply → {
    echoType = ready;
    pong = 1;
}
- allowsContentJavaScript=true: page world → ["contentRan": 1, "readerVisibleInPageWorld": undefined, "title": content-js-ran]
- 対照（content JS 有効）: コンテンツ JS が動いた=true（スイッチが効いている証拠）

## Spike 2: CSS Custom Highlight API
判定: 成立
- API: ["rect": {
    h = "28.265625";
    w = 117;
    x = 78;
    y = "23.875";
}, "size": 1, "text": highlighted, "supportsSelector": 1, "Highlight": function, "highlights": object]
- range rect=(78.0, 23.875, 117.0, 28.265625) 内の黄色ピクセル=9065 赤ピクセル=2964、画像全体の黄色=9065（範囲外=0）
- 画像 800x400px (2.0x)、rect のピクセル面積=13228
- スクリーンショット: Spikes/output/spike2-highlight.png

## Spike 3: 3 ページ幅フレームと takeSnapshot(with:) の rect 指定
判定: 条件付き
- 3 ページ幅ビューポートでの計測: ["pages": 6, "scrollWidth": 1800, "htmlWidth": 300, "clientWidth": 900, "innerWidth": 900]
- rect=(0.0, 0.0, 300.0, 400.0) クリップ外（不可視）: 画像 600x800px (2.0x) 主色=#27ae60 期待=page1(#27ae60) 一致=true
- rect=(300.0, 0.0, 300.0, 400.0) クリップ内（可視）: 画像 600x800px (2.0x) 主色=#2980b9 期待=page2(#2980b9) 一致=true
- rect=(600.0, 0.0, 300.0, 400.0) クリップ外（不可視）: 画像 600x800px (2.0x) 主色=#e67e22 期待=page3(#e67e22) 一致=true
- フレーム全体のスナップショット: 1800x800 → Spikes/output/spike3-whole-frame.png
- クリップ外ページの takeSnapshot 所要時間 (ms, 10 回): min=0.3 median=0.4 max=0.6（初回 3 回: ["0.8", "0.6", "0.6"])
- 2x スナップショット: 1200x1600 所要=1.6 ms
- 2 ページ文書を 3 ページ幅ビューポートで: ["pagesByScrollWidth": 3, "scrollWidth": 900, "pagesBySentinel": 1, "clientWidth": 900, "endRight": 300] → scrollWidth ベースの pageCount はビューポート幅で下限が付く

## Spike 4: 縦書き多段組（vertical-rl + column-width）と scrollHeight からのページ数
判定: 成立
- 計測: ["pageCount": 11, "clientHeight": 400, "bodyRect": {"x":0,"y":0,"width":300,"height":4400,"top":0,"right":300,"bottom":4400,"left":0}, "writingMode": vertical-rl, "chars": 1637, "clientWidth": 300, "scrollWidth": 300, "remainder": 0, "scrollHeight": 4400]
- ページ 0,1,2,last のインク率（非白ピクセル比）: ["0.060", "0.088", "0.092", "0.031"]
- 各ページ右上のテキスト先頭 12 文字: (
    "\U5c71\U8def",
    "\U8336\U5c4b\U306e",
    "\U591c\U306b\U306a\U308b\U3068\U3001\U5bbf\U306e\U4e8c\U968e\U304b\U3089",
    "\U4e8c\U3007\U4e8c\U4e94\U5e74\U306e\U6625\U3001\U4e00\U4e8c\U4e09\U56db"
)
- 3 ページ高フレーム（300x1200）での計測: ["scrollHeight": 4400, "pageCount": 11, "clientHeight": 1200, "htmlBox": {"x":0,"y":0,"width":300,"height":400,"top":0,"right":300,"bottom":400,"left":0}]
- 判定根拠: writingMode=vertical-rl scrollHeight が 400 の倍数=true 横方向のあふれなし=true pageCount=11

## Spike 5: 壊れた XHTML の text/html 配信: WebKit DOM と libxml2 HTML パーサ DOM の CFI インデックス一致
判定: 不成立
- libxml2 runtime version: 20913 (compile-time 2.9.13)
- [unclosed-and-entities] WebKit contentType=text/html ノード行数 WebKit=53 libxml2=51 厳密一致=false 空白無視一致=false
-     WebKit のみ: /4/2/6/4 i
-     WebKit のみ: /4/2/6/4/1 "italic only"
-     WebKit のみ: /4/2/6/5 "tail"
-     WebKit のみ: /4/2/18/2 tbody
-     WebKit のみ: /4/2/18/2/2 tr
-     WebKit のみ: /4/2/18/2/2/2 td
-     WebKit のみ: /4/2/18/2/2/2/1 "cell"
-     libxml2 のみ: /4/2/6/3 "italic only tail"
-     libxml2 のみ: /4/2/18/2 tr
-     libxml2 のみ: /4/2/18/2/2 td
-     libxml2 のみ: /4/2/18/2/2/1 "cell"
- [single-missing-close] WebKit contentType=text/html ノード行数 WebKit=32 libxml2=33 厳密一致=false 空白無視一致=true
-     (空白差) libxml2 のみ: /1 "\n"
- [html5-elements-and-svg] WebKit contentType=text/html ノード行数 WebKit=26 libxml2=27 厳密一致=false 空白無視一致=false
-     WebKit のみ: /4/2/8 aside
-     WebKit のみ: /4/2/8/1 "side"
-     libxml2 のみ: /4/2/6/4 aside
-     libxml2 のみ: /4/2/6/4/1 "side"
- 対照: 同じ文書を application/xhtml+xml で配信 → ["bodyStart": Chapter
  Alpha beta gamma.
  Delta epsilon, "contentType": application/xhtml+xml, "title": almost fine, "hasParserError": 1]
- 判定根拠: 全文書で厳密一致=false 空白無視一致=false。ダンプは Spikes/output/spike5-*.txt

## Spike 6: 縦書き見開き: 同一文書を 2 つの iframe に読み込み隣接ページを並べる（メモリ記録）
判定: 成立
- 既存 WebContent プロセス数=9、_webProcessIdentifier 応答=true
- 空文書: WebContent pid=82961 RSS=24.6 MB
- 単独読み込み: ["pageCount": 21, "htmlBox": {"x":300,"y":0,"width":300,"height":400,"top":0,"right":600,"bottom":400,"left":300}, "heads": <__NSArrayM 0x7a962e63a0>(
山路,
茶屋の,
夜になると、宿の二階,
二〇二五年の春、一二
)
]
- 単独文書（1 レイアウト）: WebContent pid=82961 RSS=29.3 MB
- 見開き（右=page1, 左=page2）: ["rightScrollTop": 400, "leftPageCount": 21, "writingMode": vertical-rl, "sameOrigin": 1, "rightHead": 茶屋の, "leftHead": 夜になると、宿の二階, "leftScrollTop": 800, "rightPageCount": 21]
- スナップショット 1200x800 インク率 左=0.092 右=0.088 → Spikes/output/spike6-spread.png
- ラッパー + iframe x2（2 レイアウト）: WebContent pid=82961 RSS=31.9 MB
- メモリ増分: 単独 4.7 MB、iframe x2 7.3 MB（比 1.56 倍）
- 判定根拠: scrollTop 反映=true 単独読み込みと同じページ数=true ページ先頭テキスト一致=true 両面に描画あり=true

## Spike 7: 多段組 + overflow:hidden（iOS では isScrollEnabled=false）での JS scrollLeft/scrollTop 追従
判定: 成立
- macOS: WKWebView に scrollView はないため isScrollEnabled の検証は iOS シミュレータのテスト（SpikeKitTests）で行う
- scrollingElement.scrollLeft = 300: ["scrollX": 300, "scrollLeft": 300, "maxScroll": 1500, "bodyScrollLeft": 0] 描画主色=#27ae60 期待 page1=#27ae60 一致=true
- window.scrollTo(600, 0): ["scrollX": 600, "scrollLeft": 600, "maxScroll": 1500, "bodyScrollLeft": 0] 描画主色=#2980b9 期待 page2=#2980b9 一致=true
- scrollTo({left:900, behavior:'instant'}): ["scrollX": 900, "scrollLeft": 900, "maxScroll": 1500, "bodyScrollLeft": 0] 描画主色=#e67e22 期待 page3=#e67e22 一致=true
- documentElement.scrollLeft = 1200: ["scrollX": 1200, "scrollLeft": 1200, "maxScroll": 1500, "bodyScrollLeft": 0] 描画主色=#8e44ad 期待 page4=#8e44ad 一致=true
- scrollLeft = 99999 (末尾にクランプ): ["scrollX": 1500, "scrollLeft": 1500, "maxScroll": 1500, "bodyScrollLeft": 0] 描画主色=#16a085 期待 page5=#16a085 一致=true
- scrollLeft = 0 (先頭へ戻す): ["scrollX": 0, "scrollLeft": 0, "maxScroll": 1500, "bodyScrollLeft": 0] 描画主色=#c0392b 期待 page0=#c0392b 一致=true
- 縦書き scrollTop=400: ["scrollTop": 400, "scrollY": 400] 描画変化ピクセル(1/16 サンプル)=4771 追従=true

