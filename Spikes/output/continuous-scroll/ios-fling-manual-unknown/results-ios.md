# Spike results (iOS 27.2 Simulator, iPhone 17, screen (402.0, 874.0) @3.0x, 2026-11-13T20:12:08Z)

## Spike 9: 連続スクロール: 慣性スクロール中に上へ章を足す（iOS Simulator、外からスワイプを入れる）
判定: 条件付き
- mode=manual、高さ既知=false、先読み 2000 px、上の余白 0 px、開始 spine 60、初期の窓 [59, 60, 61]
- 標本 6413（106.9 /秒）、指またはその慣性で動いた標本 1262、上に足した章 3、スクロール位置を書き換えた補正 5 回、余白で吸収した補正 0 回
- 終了時の窓 [57, 58, 59, 60, 61]、記録 spike9-manual-unknown.json（scripts/analyse-fling.py で読む）

