import Foundation

/// Locates `Tests/Fixtures/` relative to this source file so the fixtures are shared by all test targets
/// without copying them into each target's resource bundle.
enum Fixtures {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // EPUBCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func url(_ relativePath: String) -> URL {
        directory.appendingPathComponent(relativePath)
    }

    static let mobyDick = url("moby-dick.epub")
    static let childrensLiterature = url("childrens-literature.epub")
    static let kusamakura = url("kusamakura-japanese-vertical-writing.epub")
    static let wasteland = url("wasteland-otf-obf.epub")

    static func malformed(_ name: String) throws -> Data {
        try Data(contentsOf: url("malformed/\(name).xhtml"))
    }
}
