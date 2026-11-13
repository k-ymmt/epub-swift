# Spike results (iOS 27.2 Simulator, iPhone 17, screen (402.0, 874.0) @3.0x, 2026-11-13T20:03:20Z)

## Spike 9: 連続スクロール: 慣性スクロール中に上へ章を足す（iOS Simulator、外からスワイプを入れる）
判定: 条件付き
- mode=manual、高さ既知=true、先読み 2000 px、開始 spine 60、初期の窓 [59, 60, 61]
- 標本 4172（104.3 /秒）、指またはその慣性で動いた標本 820、上に足した章 3、位置補正 6 回
- 終了時の窓 [57, 58, 59, 60, 61]、記録 spike9-manual-known.json（scripts/analyse-fling.py で読む）

