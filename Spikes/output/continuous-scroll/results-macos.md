# Spike results (macOS Version 27.0.1 (Build 26A434), 2026-11-13T20:21:03Z)

## Spike 8: 連続スクロール: 1 つの WebView に章ごとの iframe を縦に並べる（メモリ・追加コスト・位置の安定）
判定: 条件付き
- 本: moby-dick、線形 spine 142 項目、ビューポート 390x760
- ページの可視状態: hidden、requestAnimationFrame が来る=false
- 画面に出ていないので、スクロールと位置の安定のフェーズは実行しない（メモリと読み込み時間だけ）
- overflow-anchor 対応=true、WebContent pid=33952、GPU pid=33917
- [窓] 空のラッパー: WebContent 20.9 MB、GPU 63.5 MB
- [窓] 1 章（合計の高さ 10922 px）: WebContent 32.0 MB（+11.0）、GPU 65.5 MB（+1.9）、1 章あたり WebContent +11.03 MB
- [窓] 3 章（合計の高さ 14625 px）: WebContent 32.2 MB（+11.3）、GPU 65.2 MB（+1.6）、1 章あたり WebContent +3.77 MB
- [窓] 7 章（合計の高さ 50964 px）: WebContent 35.9 MB（+15.0）、GPU 65.2 MB（+1.6）、1 章あたり WebContent +2.14 MB
- [窓] 15 章（合計の高さ 103918 px）: WebContent 33.7 MB（+12.8）、GPU 65.1 MB（+1.5）、1 章あたり WebContent +0.85 MB
- [窓] 31 章（合計の高さ 208153 px）: WebContent 39.3 MB（+18.3）、GPU 65.1 MB（+1.5）、1 章あたり WebContent +0.59 MB
- [窓] 63 章（合計の高さ 388676 px）: WebContent 70.9 MB（+50.0）、GPU 65.1 MB（+1.5）、1 章あたり WebContent +0.79 MB
- [全章] 142 章を順に追加: 0.95 秒、文書の高さ 840588 px（ビューポート 1106 枚分）
- [全章] 1 章の読み込み（src 設定 → load）ms: 中央 1.0 / 95% 4.0 / 最大 100.0
- [全章] 1 章の高さの計測（強制レイアウト）ms: 中央 1.0 / 95% 3.0 / 最大 39.0
- [全章] 章の高さ px: 中央 4662.0 / 95% 16223.0 / 最大 30116.0、最小 380
- [全章] フォント適用後の文書の高さ 767482 px（load 時点の 91.3%）、高さが変わった章 140/142
- [全章] 読み込み後: WebContent 159.6 MB（+138.6）、GPU 66.1 MB（+0.8）
- [巨大章] 908 KB（OPS/chapter_054.xhtml × 20）: 読み込み 7.0 ms、計測 50.0 ms、高さ 601552 px
- [巨大章] WebContent 56.1 MB（+35.0）、GPU 66.3 MB（+0.1）

