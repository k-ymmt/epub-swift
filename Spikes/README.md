# Spikes

`docs/design/04-roadmap.md` §2 の検証項目を確かめるための使い捨てコード。本体の `Package.swift` からは参照しない。
結果は `docs/design/05-spike-results.md` にまとめてある。

```bash
cd Spikes
swift run spike-run                 # 7 項目すべて（macOS、小さなウィンドウが一瞬出る）
swift run spike-run 3 7             # 項目を選んで実行
scripts/run-ios.sh 3 7              # iOS Simulator（iPhone 17 Pro / iOS 27）で最小アプリとして実行
swift test                          # SpikeKitTests: 同じスパイクを XCTest から実行（macOS）

# 連続スクロール（項目 8・9）。既定の実行には含めない。結果は docs/design/07-continuous-scroll-spike.md
swift run -c release spike-run --out output/continuous-scroll 8          # macOS（画面に出ていないとメモリと読み込み時間だけ）
OUT=$PWD/output/continuous-scroll/ios scripts/run-ios.sh 8               # iOS Simulator。SPIKE8_PHASES="window all giant stability" で絞れる
OUT=$PWD/output/continuous-scroll/ios-fling-runway-unknown \
  SPIKE9_MODE=runway SPIKE9_PRESET=0 SPIKE9_SECONDS=60 scripts/run-ios.sh 9   # "SPIKE9 READY" の後、記録中に外からスワイプを入れる
scripts/analyse-fling.py output/continuous-scroll/ios-fling-runway-unknown/spike9-runway-unknown.json
```

- `Sources/SpikeKit/WebHost.swift`: ウィンドウ + クリップ用親ビュー + WKWebView、`epub://` スキームハンドラ、スナップショット
- `Sources/SpikeKit/Fixtures.swift`: 検証用の最小 HTML（自前）
- `Sources/SpikeKit/Spike1..7*.swift`: 各項目
- `Sources/SpikeKit/BookFixture.swift`, `ContinuousScrollJS.swift`, `Spike8ContinuousScroll.swift`, `Spike9Fling.swift`:
  連続スクロール。展開した EPUB（`Tests/Fixtures/moby-dick.epub`）を配信し、章ごとの iframe を並べたラッパー文書で、
  メモリ・読み込み時間・上で章が増減したときの位置の安定（8）と、指でスクロール中の同じこと（9）を測る
- `scripts/analyse-fling.py`: 項目 9 の記録（`spike9-*.json`、管理外）を読んで、空白の画面・位置の飛び・補正の抜けを数える
- `Sources/spike-ios-app/main.swift`, `scripts/run-ios.sh`: iOS Simulator 用の最小 UIScene アプリと、swiftc で `.app` を組んで `simctl` で起動するスクリプト
- `output/`: 実行結果（`results-macos.md`、`ios/results-ios.md`、スクリーンショット、DOM ダンプ）。`output/continuous-scroll/` は項目 8・9
