# Spike results (iOS 27.2 Simulator, iPhone 17, screen (402.0, 874.0) @3.0x, 2026-11-13T20:10:47Z)

## Spike 9: 連続スクロール: 慣性スクロール中に上へ章を足す（iOS Simulator、外からスワイプを入れる）
判定: 条件付き
- mode=runway、高さ既知=false、先読み 2000 px、上の余白 400000 px、開始 spine 60、初期の窓 [59, 60, 61]
- 標本 6404（106.7 /秒）、指またはその慣性で動いた標本 1304、上に足した章 2、スクロール位置を書き換えた補正 0 回、余白で吸収した補正 4 回
- 終了時の窓 [58, 59, 60, 61]、記録 spike9-runway-unknown.json（scripts/analyse-fling.py で読む）

