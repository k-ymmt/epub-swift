import SwiftUI
import WebKit
import ImageIO
import EPUB
@_spi(Diagnostics) import EPUBRenderer

/// Recording mode (docs/design/08-continuous-scroll.md §13): while somebody scrolls the scrolled layout of a real
/// `ReaderSession`, takes a picture of the reader as often as it can and writes what spike 9 wrote for its own
/// controller, so that `Spikes/scripts/analyse-fling.py` reads it: per sample the scroll position, whether the
/// reader's hands were on the document, and how far the picture moved since the previous sample (measured from the
/// pixels); and the scroll controller's log (chapters added and removed, heights, corrections).
///
/// The scrolling comes from outside: a person, a tool that injects touches into the Simulator, or on macOS the
/// trackpad events of `TrackpadFling`.
///
/// Start it from the Debug menu, or from the environment (`ScrollRecorder.Launch`): `READERDEMO_BOOK` (a bundled
/// book's name, or a path), `READERDEMO_LAYOUT=scrolled`, `READERDEMO_START` (spine index), `READERDEMO_RECORD`
/// (seconds), `READERDEMO_FLING=1` (macOS: scroll by itself), `READERDEMO_RECORD_DIR` (where the file goes; default
/// the app's Documents).
@MainActor
enum ScrollRecorder {
    struct Launch {
        var book: String?
        var layout: ReaderLayout?
        var start: Int?
        var seconds: Double?
        var fling = false

        static let current: Launch = {
            let env = ProcessInfo.processInfo.environment
            var launch = Launch()
            launch.book = env["READERDEMO_BOOK"]
            launch.layout = env["READERDEMO_LAYOUT"].flatMap { $0 == "scrolled" ? .scrolled : $0 == "paged" ? .paged : nil }
            launch.start = env["READERDEMO_START"].flatMap(Int.init)
            launch.seconds = env["READERDEMO_RECORD"].flatMap(Double.init)
            launch.fling = env["READERDEMO_FLING"] == "1"
            return launch
        }()
    }

    struct Result {
        var url: URL
        var samples: Int
        var moving: Int
        var seconds: Double
    }

    enum Failure: Error, CustomStringConvertible {
        case notScrolled
        var description: String { "the book is not in the scrolled layout" }
    }

    private struct Sample {
        var ms: Double
        var offset: Double
        var flags: Int
        /// Ink per row of the picture, left half then right half.
        var signature: [Int32]
        /// Rows of the picture nothing was painted on (tiles that were not there yet).
        var unpainted: Int
        /// Longest run of rows without ink.
        var blankRun: Int
    }

    private struct Diagnostics {
        var now: Double
        var events: [[String: Any]]
        var views: [Int]
        /// The controller's state without the chapters' frames.
        var state: [String: Any] = [:]
    }

    static func record(_ session: ReaderSession, seconds: Double, name: String, fling: Bool = false) async throws -> Result {
        guard session.layout == .scrolled, let webView = session.diagnosticsWebView else { throw Failure.notScrolled }
        await session.setScrollLogging(true)
        // The log's `t` is the page's clock: where it is when the recording starts. (This also empties the log.)
        let opening = await diagnostics(session)
        let clock = ContinuousClock()
        let t0 = clock.now
        var samples: [Sample] = []
        // READERDEMO_RECORD_FRAMES=1: the pictures around a sample that does not match its scroll go to `frames/`.
        let framesDirectory: URL? = ProcessInfo.processInfo.environment["READERDEMO_RECORD_FRAMES"] == "1" ? outputDirectory().appendingPathComponent("frames", isDirectory: true) : nil
        if let framesDirectory {
            try? FileManager.default.removeItem(at: framesDirectory)
            try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        }
        var lastPicture: Pixels?
        var savedFrames = 0
        print("RECORD READY \(Int(seconds))s window \(opening.views)")
        #if os(macOS)
        let flinging = fling ? Task { @MainActor in await TrackpadFling(view: webView).run(for: seconds - 2) } : nil
        #endif
        while clock.now - t0 < .seconds(seconds) {
            var offset = 0.0, flags = 0
            #if os(iOS)
            let scrollView = webView.scrollView
            offset = Double(scrollView.contentOffset.y)
            flags = (scrollView.isTracking ? 1 : 0) | (scrollView.isDragging ? 2 : 0) | (scrollView.isDecelerating ? 4 : 0)
            #else
            if let sample = await session.scrollSample() {
                offset = sample.scrollY
                flags = sample.isInteracting ? 4 : 0
            }
            #endif
            guard let picture = await picture(of: webView) else { continue }
            let elapsed = clock.now - t0
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            let (signature, unpainted, blankRun) = rowSignature(picture)
            if let framesDirectory, let last = samples.last, let lastPicture, savedFrames < 80 {
                // A picture that is not the one before it moved by the scroll: keep both, to look at them.
                let delta = Int((last.offset - offset).rounded())
                if abs(delta) <= 600, residualAt(last.signature, signature, shift: delta) > 0.1 {
                    save(lastPicture, to: framesDirectory.appendingPathComponent(String(format: "%05d.png", samples.count - 1)))
                    save(picture, to: framesDirectory.appendingPathComponent(String(format: "%05d.png", samples.count)))
                    savedFrames += 1
                }
            }
            lastPicture = picture
            samples.append(Sample(ms: ms, offset: offset, flags: flags, signature: signature, unpainted: unpainted, blankRun: blankRun))
            try await Task.sleep(for: .milliseconds(2))
        }
        #if os(macOS)
        await flinging?.value
        #endif
        print("RECORD DONE, analysing \(samples.count) samples")
        let closing = await diagnostics(session)
        await session.setScrollLogging(false)

        // How far the picture moved between two samples, and whether that is what the scroll position says: as in
        // Spikes/Sources/SpikeKit/Spike9Fling.swift. `correct` events are scroll positions the controller wrote (the
        // settlement at rest): the position jumps by that much and the picture must not.
        let corrections: [(ms: Double, by: Double)] = closing.events.filter { ($0["ev"] as? String) == "correct" }.compactMap { event in
            guard let t = (event["t"] as? NSNumber)?.doubleValue, let by = (event["by"] as? NSNumber)?.doubleValue else { return nil }
            return (t - opening.now, by)
        }
        var rows: [[String: Any]] = []
        var owed = 0.0
        for i in samples.indices {
            var row: [String: Any] = ["ms": samples[i].ms, "offset": samples[i].offset, "flags": samples[i].flags, "blankRun": samples[i].blankRun, "unpainted": samples[i].unpainted]
            if i > 0 {
                let (shift, residual) = bestShift(samples[i - 1].signature, samples[i].signature, range: 600)
                row["shift"] = shift
                row["residual"] = residual
                let delta = samples[i].offset - samples[i - 1].offset
                // The corrections written around this sample (the page's clock and this one start a few ms apart).
                let near = corrections.filter { $0.ms >= samples[i - 1].ms - 150 && $0.ms <= samples[i].ms + 150 }.map(\.by)
                var jumps: [Double] = [0] + near
                for k in near.indices.dropLast() { jumps.append(near[k] + near[k + 1]) }
                var best = (expected: 0, residual: 9.0, jump: 0.0)
                for jump in jumps {
                    let expected = Int((owed - (delta - jump)).rounded())
                    guard abs(expected) <= 600 else { continue }
                    let r = residualAt(samples[i - 1].signature, samples[i].signature, shift: expected)
                    if r < best.residual - (jump == 0 ? 0 : 0.05) { best = (expected, r, jump) }
                }
                if best.residual >= 0.45, residual < 0.005, shift == 0, abs(delta) <= 600, abs(owed - delta) >= 1 {
                    // The two pictures are identical while the position moved: the picture is late.
                    row["late"] = true
                    row["expected"] = 0
                    row["residualExpected"] = residual
                    owed -= delta
                } else {
                    row["expected"] = best.expected
                    row["residualExpected"] = best.residual
                    if best.jump != 0 { row["jump"] = best.jump }
                    owed = 0
                }
            }
            rows.append(row)
        }
        let events = closing.events.compactMap { event -> [String: Any]? in
            guard let t = (event["t"] as? NSNumber)?.doubleValue else { return nil }
            var out = event
            out["ms"] = t - opening.now
            out.removeValue(forKey: "t")
            return out
        }
        let size = webView.bounds.size
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        let recording: [String: Any] = [
            "mode": "product-\(platform)", "preset": true, "margin": 2 * Double(size.height), "viewport": [Double(size.width), Double(size.height)],
            "book": name, "windowAtStart": opening.views, "windowAtEnd": closing.views, "stateAtEnd": closing.state, "samples": rows, "events": events,
        ]
        let directory = outputDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("scroll-recording-\(platform).json")
        try JSONSerialization.data(withJSONObject: recording, options: [.sortedKeys]).write(to: url)
        let moving = samples.filter { $0.flags != 0 }.count
        print("RECORD WRITTEN \(url.path) samples=\(samples.count) moving=\(moving)")
        return Result(url: url, samples: samples.count, moving: moving, seconds: seconds)
    }

    /// Where the recording goes: `READERDEMO_RECORD_DIR`, or the app's Documents.
    private static func outputDirectory() -> URL {
        ProcessInfo.processInfo.environment["READERDEMO_RECORD_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    private static func save(_ picture: Pixels, to url: URL) {
        guard let provider = CGDataProvider(data: Data(picture.bytes) as CFData),
              let image = CGImage(width: picture.width, height: picture.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: picture.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func diagnostics(_ session: ReaderSession) async -> Diagnostics {
        guard let data = await session.scrollDiagnostics(), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Diagnostics(now: 0, events: [], views: [])
        }
        var state = object["state"] as? [String: Any] ?? [:]
        let views = (state["views"] as? [[String: Any]] ?? []).compactMap { $0["spineIndex"] as? Int }
        state.removeValue(forKey: "views")
        return Diagnostics(now: (object["now"] as? NSNumber)?.doubleValue ?? 0, events: object["events"] as? [[String: Any]] ?? [], views: views, state: state)
    }

    /// The web view as it is on screen now (a column in its middle), one pixel per point.
    private static func picture(of webView: WKWebView) async -> Pixels? {
        let configuration = WKSnapshotConfiguration()
        #if os(iOS)
        let scale = Double(webView.window?.screen.scale ?? 2)
        #else
        let scale = Double(webView.window?.backingScaleFactor ?? 2)
        #endif
        // A column in the middle is enough to see the text move, and a wide window would make the pictures slow.
        let bounds = webView.bounds
        let width = min(bounds.width, 400)
        configuration.rect = CGRect(x: ((bounds.width - width) / 2).rounded(), y: 0, width: width, height: bounds.height)
        configuration.snapshotWidth = NSNumber(value: Double(width) / scale)
        configuration.afterScreenUpdates = false
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return nil }
        #if os(iOS)
        guard let cgImage = image.cgImage else { return nil }
        #else
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        return Pixels(cgImage)
    }

    struct Pixels {
        let width: Int, height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            let w = image.width, h = image.height
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            buffer.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            width = w
            height = h
            bytes = buffer
        }
    }

    /// Darkness summed along each row, separately for the left and the right half: lines of text of different
    /// lengths give rows that differ, which makes the vertical shift between two pictures recoverable.
    /// Also counts the rows nothing was painted on.
    private static func rowSignature(_ picture: Pixels) -> (signature: [Int32], unpainted: Int, blankRun: Int) {
        var out = [Int32](repeating: 0, count: picture.height * 2)
        var unpaintedRows = 0
        let half = picture.width / 2
        picture.bytes.withUnsafeBufferPointer { p in
            for y in 0..<picture.height {
                var left: Int32 = 0, right: Int32 = 0
                var unpainted = 0
                var i = y * picture.width * 4
                for x in 0..<picture.width {
                    // Premultiplied: a pixel nothing was painted on (alpha 0, a tile that is not there yet) has no ink.
                    let dark = Int32(p[i + 3]) - (Int32(p[i]) + Int32(p[i + 1]) + Int32(p[i + 2])) / 3
                    if p[i + 3] < 128 { unpainted += 1 }
                    if x < half { left += dark } else { right += dark }
                    i += 4
                }
                out[y * 2] = left
                out[y * 2 + 1] = right
                if unpainted * 2 > picture.width { unpaintedRows += 1 }
            }
        }
        let blankRun = longestBlankRun(out)
        // The scroll position moves by thirds of a point on a 3x screen and the picture has one row per point: a line
        // of text a third of a point further down gives different rows. Averaged over three rows the two agree, and
        // the best match is no longer a toss-up between the true shift and a multiple of the line height.
        var smooth = out
        if picture.height >= 3 {
            for y in 1..<(picture.height - 1) {
                smooth[y * 2] = (out[(y - 1) * 2] + out[y * 2] + out[(y + 1) * 2]) / 3
                smooth[y * 2 + 1] = (out[(y - 1) * 2 + 1] + out[y * 2 + 1] + out[(y + 1) * 2 + 1]) / 3
            }
        }
        return (smooth, unpaintedRows, blankRun)
    }

    /// The shift (rows, positive = the picture moved down) that best maps `a` onto `b`, and the mean difference per
    /// row at that shift relative to the mean ink per row (0 = identical, around 1 = unrelated pictures).
    private static func bestShift(_ a: [Int32], _ b: [Int32], range: Int) -> (shift: Int, residual: Double) {
        let rows = min(a.count, b.count) / 2
        guard rows > 0 else { return (0, 1) }
        var mean = 0.0
        for v in a { mean += Double(v) }
        mean = max(1, mean / Double(a.count))
        var best = (shift: 0, residual: Double.infinity)
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for d in -range...range {
                    let lo = max(0, -d), hi = min(rows, rows - d)
                    guard hi - lo >= rows / 3 else { continue }
                    var sum: Int64 = 0
                    for y in lo..<hi {
                        sum += Int64(abs(pa[y * 2] - pb[(y + d) * 2])) + Int64(abs(pa[y * 2 + 1] - pb[(y + d) * 2 + 1]))
                    }
                    let residual = Double(sum) / Double((hi - lo) * 2) / mean
                    if residual < best.residual - 1e-9 || (abs(residual - best.residual) <= 1e-9 && abs(d) < abs(best.shift)) {
                        best = (d, residual)
                    }
                }
            }
        }
        return best
    }

    private static func residualAt(_ a: [Int32], _ b: [Int32], shift d: Int) -> Double {
        let rows = min(a.count, b.count) / 2
        var mean = 0.0
        for v in a { mean += Double(v) }
        mean = max(1, mean / Double(max(1, a.count)))
        let lo = max(0, -d), hi = min(rows, rows - d)
        guard hi > lo else { return 9 }
        var sum: Int64 = 0
        for y in lo..<hi { sum += Int64(abs(a[y * 2] - b[(y + d) * 2])) + Int64(abs(a[y * 2 + 1] - b[(y + d) * 2 + 1])) }
        return Double(sum) / Double((hi - lo) * 2) / mean
    }

    /// Longest run of rows with (almost) no ink: a band of unpainted tiles shows as a long one.
    private static func longestBlankRun(_ signature: [Int32]) -> Int {
        var longest = 0, run = 0
        for y in 0..<(signature.count / 2) {
            if signature[y * 2] + signature[y * 2 + 1] < 200 { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        return longest
    }
}

#if os(macOS)
/// Scrolls the reader as a trackpad does, from inside the app: gestures with their momentum, down and back up, fast
/// and slow. The events go to the web view the way AppKit hands them over, so they pass the session's handler and
/// scroll the page as WebKit scrolls for a real trackpad. (The system's own momentum curve and a real finger are
/// not reproduced: that is what trying it by hand is for.)
@MainActor
struct TrackpadFling {
    let view: NSView

    private func send(dy: Int, phase: Int64 = 0, momentum: Int64 = 0) {
        guard let window = view.window,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-dy), wheel2: 0, wheel3: 0),
              let windowUnderPointer = CGEventField(rawValue: 91), let windowThatHandles = CGEventField(rawValue: 92) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(-dy))
        let inWindow = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        event.location = CGPoint(x: onScreen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - onScreen.y)
        event.setIntegerValueField(windowUnderPointer, value: Int64(window.windowNumber))
        event.setIntegerValueField(windowThatHandles, value: Int64(window.windowNumber))
        if let nsEvent = NSEvent(cgEvent: event) { view.scrollWheel(with: nsEvent) }
    }

    /// One swipe: the fingers move at `speed` px per frame for a few frames, lift, and the momentum decays.
    private func fling(speed: Int, decay: Double) async {
        send(dy: 0, phase: 128)
        send(dy: speed, phase: 1)
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(16))
            send(dy: speed, phase: 2)
        }
        send(dy: 0, phase: 4)
        send(dy: speed, momentum: 1)
        var velocity = Double(speed)
        while abs(velocity) >= 1 {
            try? await Task.sleep(for: .milliseconds(16))
            velocity *= decay
            send(dy: Int(velocity.rounded()), momentum: 2)
        }
        send(dy: 0, momentum: 3)
    }

    func run(for seconds: Double) async {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(seconds)
        try? await Task.sleep(for: .milliseconds(500))
        // Up first (chapters join above the reading line), then down, slower and faster.
        let plan: [(speed: Int, decay: Double)] = [(-40, 0.97), (-90, 0.975), (-160, 0.98), (60, 0.97), (-220, 0.98), (-120, 0.975), (200, 0.98), (-300, 0.98)]
        var index = 0
        while clock.now < end {
            let step = plan[index % plan.count]
            await fling(speed: step.speed, decay: step.decay)
            index += 1
            try? await Task.sleep(for: .milliseconds(350))
        }
    }
}
#endif
