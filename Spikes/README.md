# Spikes

`docs/design/04-roadmap.md` §2 の検証項目を確かめるための使い捨てコード。本体の `Package.swift` からは参照しない。
結果は `docs/design/05-spike-results.md` にまとめてある。

```bash
cd Spikes
swift run spike-run                 # 7 項目すべて（macOS、小さなウィンドウが一瞬出る）
swift run spike-run 3 7             # 項目を選んで実行
scripts/run-ios.sh 3 7              # iOS Simulator（iPhone 17 Pro / iOS 27）で最小アプリとして実行
swift test                          # SpikeKitTests: 同じスパイクを XCTest から実行（macOS）
```

- `Sources/SpikeKit/WebHost.swift`: ウィンドウ + クリップ用親ビュー + WKWebView、`epub://` スキームハンドラ、スナップショット
- `Sources/SpikeKit/Fixtures.swift`: 検証用の最小 HTML（自前）
- `Sources/SpikeKit/Spike1..7*.swift`: 各項目
- `Sources/spike-ios-app/main.swift`, `scripts/run-ios.sh`: iOS Simulator 用の最小 UIScene アプリと、swiftc で `.app` を組んで `simctl` で起動するスクリプト
- `output/`: 実行結果（`results-macos.md`、`ios/results-ios.md`、スクリーンショット、DOM ダンプ）
