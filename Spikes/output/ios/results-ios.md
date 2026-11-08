# Spike results (iOS 27.0 Simulator, iPhone 17 Pro, screen (402.0, 874.0) @3.0x, 2026-11-08T10:02:14Z)

## Spike 1: allowsContentJavaScript = false と WKUserScript / callAsyncJavaScript / replyHandler
判定: 成立
- allowsContentJavaScript=false: `ready` 受信 payload=["href": epub://spike/bridge.xhtml, "readyState": interactive]
- allowsContentJavaScript=false: callAsyncJavaScript(reader world) → ["readyState": complete, "startReadyState": loading, "title": bridge, "ok": 1, "inlineHandler": <null>, "contentJS": <null>, "echo": 42]
- allowsContentJavaScript=false: postMessage の reply → {
    echoType = ready;
    pong = 1;
}
- allowsContentJavaScript=false: page world → ["title": bridge, "readerVisibleInPageWorld": undefined, "contentRan": 0]
- 判定根拠: contentBlocked=true bridgeOK=true
- allowsContentJavaScript=true: `ready` 受信 payload=["href": epub://spike/bridge.xhtml, "readyState": interactive]
- allowsContentJavaScript=true: callAsyncJavaScript(reader world) → ["title": content-js-ran, "inlineHandler": ran, "ok": 1, "contentJS": ran, "readyState": complete, "echo": 42, "startReadyState": loading]
- allowsContentJavaScript=true: postMessage の reply → {
    echoType = ready;
    pong = 1;
}
- allowsContentJavaScript=true: page world → ["readerVisibleInPageWorld": undefined, "title": content-js-ran, "contentRan": 1]
- 対照（content JS 有効）: コンテンツ JS が動いた=true（スイッチが効いている証拠）

## Spike 2: CSS Custom Highlight API
判定: 成立
- API: ["text": highlighted, "size": 1, "supportsSelector": 1, "highlights": object, "Highlight": function, "rect": {
    h = 29;
    w = 117;
    x = 78;
    y = 24;
}]
- range rect=(78.0, 24.0, 117.0, 29.0) 内の黄色ピクセル=23148 赤ピクセル=1178、画像全体の黄色=23148（範囲外=0）
- 画像 1200x600px (3.0x)、rect のピクセル面積=30537
- スクリーンショット: Spikes/output/spike2-highlight.png

## Spike 3: 3 ページ幅フレームと takeSnapshot(with:) の rect 指定
判定: 条件付き
- 3 ページ幅ビューポートでの計測: ["clientWidth": 900, "pages": 6, "scrollWidth": 1800, "innerWidth": 900, "htmlWidth": 300]
- rect=(0.0, 0.0, 300.0, 400.0) クリップ外（不可視）: 画像 900x1200px (3.0x) 主色=#28ae60 期待=page1(#27ae60) 一致=true
- rect=(300.0, 0.0, 300.0, 400.0) クリップ内（可視）: 画像 900x1200px (3.0x) 主色=#2a81b8 期待=page2(#2980b9) 一致=true
- rect=(600.0, 0.0, 300.0, 400.0) クリップ外（不可視）: 画像 900x1200px (3.0x) 主色=#e87f22 期待=page3(#e67e22) 一致=true
- フレーム全体のスナップショット: 2700x1200 → Spikes/output/spike3-whole-frame.png
- クリップ外ページの takeSnapshot 所要時間 (ms, 10 回): min=5.5 median=9.4 max=26.7（初回 3 回: ["10.4", "23.6", "4.4"])
- 2x スナップショット: 1800x2400 所要=11.4 ms
- 2 ページ文書を 3 ページ幅ビューポートで: ["pagesBySentinel": 1, "endRight": 300, "pagesByScrollWidth": 3, "clientWidth": 900, "scrollWidth": 900] → scrollWidth ベースの pageCount はビューポート幅で下限が付く

## Spike 4: 縦書き多段組（vertical-rl + column-width）と scrollHeight からのページ数
判定: 成立
- 計測: ["writingMode": vertical-rl, "scrollHeight": 4400, "clientWidth": 300, "remainder": 0, "chars": 1637, "clientHeight": 400, "bodyRect": {"x":0,"y":0,"width":300,"height":4400,"top":0,"right":300,"bottom":4400,"left":0}, "scrollWidth": 300, "pageCount": 11]
- ページ 0,1,2,last のインク率（非白ピクセル比）: ["0.062", "0.084", "0.093", "0.034"]
- 各ページ右上のテキスト先頭 12 文字: (
    "\U5c71\U8def",
    "\U8336\U5c4b\U306e",
    "\U591c\U306b\U306a\U308b\U3068\U3001\U5bbf\U306e\U4e8c\U968e\U304b\U3089",
    "\U4e8c\U3007\U4e8c\U4e94\U5e74\U306e\U6625\U3001\U4e00\U4e8c\U4e09\U56db"
)
- 3 ページ高フレーム（300x1200）での計測: ["pageCount": 11, "clientHeight": 1200, "htmlBox": {"x":0,"y":0,"width":300,"height":400,"top":0,"right":300,"bottom":400,"left":0}, "scrollHeight": 4400]
- 判定根拠: writingMode=vertical-rl scrollHeight が 400 の倍数=true 横方向のあふれなし=true pageCount=11

## Spike 7: 多段組 + overflow:hidden（iOS では isScrollEnabled=false）での JS scrollLeft/scrollTop 追従
判定: 成立
- iOS: scrollView.isScrollEnabled=false bounces=false
- scrollingElement.scrollLeft = 300: ["bodyScrollLeft": 0, "scrollX": 300, "maxScroll": 1500, "scrollLeft": 300] 描画主色=#28ae60 期待 page1=#27ae60 一致=true
- window.scrollTo(600, 0): ["bodyScrollLeft": 0, "scrollX": 600, "maxScroll": 1500, "scrollLeft": 600] 描画主色=#2a81b8 期待 page2=#2980b9 一致=true
- scrollTo({left:900, behavior:'instant'}): ["scrollLeft": 900, "scrollX": 900, "bodyScrollLeft": 0, "maxScroll": 1500] 描画主色=#e87f22 期待 page3=#e67e22 一致=true
- documentElement.scrollLeft = 1200: ["scrollX": 1200, "bodyScrollLeft": 0, "maxScroll": 1500, "scrollLeft": 1200] 描画主色=#8f44ac 期待 page4=#8e44ad 一致=true
- scrollLeft = 99999 (末尾にクランプ): ["scrollLeft": 1500, "scrollX": 1500, "bodyScrollLeft": 0, "maxScroll": 1500] 描画主色=#16a184 期待 page5=#16a085 一致=true
- scrollLeft = 0 (先頭へ戻す): ["bodyScrollLeft": 0, "scrollX": 0, "maxScroll": 1500, "scrollLeft": 0] 描画主色=#c0392a 期待 page0=#c0392b 一致=true
- 縦書き scrollTop=400: ["scrollTop": 400, "scrollY": 400] 描画変化ピクセル(1/16 サンプル)=15597 追従=true
- iOS: JS スクロール後の scrollView.contentOffset=(0.0, 400.0)

