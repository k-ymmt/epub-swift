import Foundation
import Synchronization
import Testing
@testable import EPUBCore

/// `ZIPWriter`, the `.annotations` archive and EPUB-embedded annotations (docs/design/06-annotations.md §9).
struct AnnotationArchiveTests {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let text = Data(String(repeating: "Call me Ishmael. Some years ago—never mind how long precisely. ", count: 200).utf8)

    // MARK: ZIPWriter

    @Test func writerRoundTripsThroughTheReader() throws {
        let writer = ZIPWriter(date: Date(timeIntervalSince1970: 1_790_000_000))
        try writer.add("annotations.json", data: Self.text, method: .deflate)
        try writer.add("media/画像.png", data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), method: .deflate)
        try writer.add("empty", data: Data(), method: .deflate)
        try writer.add("stored.txt", data: Self.text, method: .stored)
        let data = try writer.finish()

        let archive = try ZIPArchive(data: data)
        #expect(archive.entryOrder.map(\.path) == ["annotations.json", "media/画像.png", "empty", "stored.txt"])
        #expect(try archive.data(at: "annotations.json") == Self.text)
        #expect(archive.entry(at: "annotations.json")?.method == 8)
        // Deflate that does not shrink the entry falls back to Stored.
        #expect(archive.entry(at: "media/画像.png")?.method == 0)
        #expect(try archive.data(at: "media/画像.png") == Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
        #expect(try archive.data(at: "empty") == Data())
        #expect(archive.entry(at: "stored.txt")?.method == 0)
        #expect(try archive.data(at: "stored.txt") == Self.text)
        #expect(archive.directoryWarnings.isEmpty)
    }

    @Test func forcedZIP64IsReadBack() throws {
        let writer = ZIPWriter()
        writer.forcesZIP64 = true
        try writer.add("a.txt", data: Self.text, method: .deflate)
        try writer.add("b.txt", data: Data("b".utf8), method: .stored)
        let archive = try ZIPArchive(data: try writer.finish())
        #expect(archive.entryOrder.map(\.path) == ["a.txt", "b.txt"])
        #expect(try archive.data(at: "a.txt") == Self.text)
        #expect(try archive.data(at: "b.txt") == Data("b".utf8))
    }

    @Test func writesToAFile() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.zip")
        let writer = try ZIPWriter(url: url)
        try writer.add("a.txt", data: Self.text)
        #expect(try writer.finish().isEmpty)
        let archive = try ZIPArchive(url: url)
        #expect(try archive.data(at: "a.txt") == Self.text)
    }

    @Test func refusesBadNames() throws {
        let writer = ZIPWriter()
        try writer.add("a.txt", data: Data())
        #expect(throws: ZIPWriter.Failure.self) { try writer.add("a.txt", data: Data()) }
        #expect(throws: ZIPWriter.Failure.self) { try writer.add("../x", data: Data()) }
        #expect(throws: ZIPWriter.Failure.self) { try writer.add("/x", data: Data()) }
        #expect(throws: ZIPWriter.Failure.self) { try writer.add("", data: Data()) }
        try writer.finish()
        #expect(throws: ZIPWriter.Failure.self) { try writer.add("b.txt", data: Data()) }
    }

    // MARK: .annotations

    static func sampleSet() async throws -> (AnnotationSet, Publication) {
        let container = try await EPUBContainer(url: Fixtures.url("cfi-sample.epub"))
        var set = AnnotationSet(id: "urn:uuid:00000000-0000-4000-8000-000000000001")
        set.about = AnnotationSet.About(publication: container.publication)
        var highlight = Annotation.highlight(
            try #require(CFIRange("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:8,/1:15)")),
            in: container.publication, color: .blue, style: .underline
        )
        highlight.body?.tags = ["name"]
        var image = Annotation.highlight(try #require(CFIRange("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:0,/1:4)")), in: container.publication)
        image.body?.content = .image("media/sketch.png")
        var external = Annotation.bookmark(at: try #require(CFI("epubcfi(/6/2[c1]!/4[body]/4[p1]/1:0)")), in: container.publication)
        external.body = Body(content: .audio("https://example.com/a.mp3"))
        set.items = [highlight, image, external]
        let resolved = await AnnotationResolver(container: container).generatingSelectors(for: set)
        return (resolved, container.publication)
    }

    @Test func writesAndReadsAnArchive() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.annotations")
        let (set, _) = try await Self.sampleSet()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 9, 9, 9])
        let asked = Mutex<[String]>([])
        try await AnnotationArchive.write(set, resources: { url in
            asked.withLock { $0.append(url) }
            return png
        }, to: url)
        // Only the relative URL is fetched.
        #expect(asked.withLock { $0 } == ["media/sketch.png"])
        // Writing again replaces the file.
        try await AnnotationArchive.write(set, resources: { _ in png }, to: url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["notes.annotations"])

        let archive = try await AnnotationArchive.read(from: url)
        #expect(archive.warnings.isEmpty)
        #expect(archive.annotationSet.id == set.id)
        #expect(archive.annotationSet.items.map(\.id) == set.items.map(\.id))
        #expect(archive.annotationSet.items[0].color == .blue)
        #expect(archive.annotationSet.items[0].style == .underline)
        #expect(archive.annotationSet.items[0].range == set.items[0].range)
        #expect(archive.annotationSet.items[0].target.originalSelectors?.contains { !$0.isCFI } == true)
        #expect(try await archive.resource(at: "media/sketch.png") == png)
        #expect(try await archive.resource(at: "media/sketch%2Epng") == png)
        await #expect(throws: AnnotationArchive.Failure.pathOutsideArchive("../annotations.json")) {
            try await archive.resource(at: "../annotations.json")
        }
        await #expect(throws: AnnotationArchive.Failure.externalResource("https://example.com/a.mp3")) {
            try await archive.resource(at: "https://example.com/a.mp3")
        }
        await #expect(throws: AnnotationArchive.Failure.missingResource("media/none.png")) {
            try await archive.resource(at: "media/none.png")
        }

        // The in-memory form holds the same entries.
        let data = try await AnnotationArchive.data(set, resources: { _ in png })
        let fromData = try await AnnotationArchive.read(data: data)
        #expect(fromData.annotationSet.items.map(\.id) == set.items.map(\.id))
    }

    @Test func refusesArchivesItCannotUse() async throws {
        await #expect(throws: AnnotationArchive.Failure.notAZIPArchive) {
            try await AnnotationArchive.read(data: Data("{}".utf8))
        }
        let other = ZIPWriter()
        try other.add("notes.json", data: Data("{}".utf8))
        let otherData = try other.finish()
        await #expect(throws: AnnotationArchive.Failure.missingAnnotationSet) {
            try await AnnotationArchive.read(data: otherData)
        }
        let big = ZIPWriter()
        try big.add("annotations.json", data: Self.text)
        let bigData = try big.finish()
        var limits = AnnotationImportLimits.default
        limits.maxArchiveUncompressedBytes = 100
        await #expect(throws: AnnotationArchive.Failure.self) {
            try await AnnotationArchive.read(data: bigData, limits: limits)
        }
    }

    // MARK: Embedded

    static let embeddedJSON = """
    {
      "@context": "https://www.w3.org/ns/epub-anno.jsonld",
      "type": "AnnotationSet",
      "id": "urn:x:embedded",
      "items": [{
        "id": "urn:x:embedded:1",
        "type": "Annotation",
        "motivation": "highlighting",
        "created": "2026-01-01",
        "target": {
          "source": "OPS/c1.xhtml",
          "selector": {"type": "TextQuoteSelector", "exact": "Ishmael", "prefix": "Call me ", "suffix": ". Some"}
        },
        "body": {"type": "TextualBody", "value": "Publisher note", "color": "green"}
      }]
    }
    """

    @Test func readsEmbeddedAnnotationsOnRequest() async throws {
        let data = try AnnotationResolverTests.editedSample(
            { $0 },
            adding: ["META-INF/annotations.json": Data(Self.embeddedJSON.utf8)]
        )
        let container = try await EPUBContainer(data: data)
        #expect(container.publication.hasEmbeddedAnnotations)
        let set = try #require(try await container.embeddedAnnotations())
        #expect(set.items.count == 1)
        let item = set.items[0]
        #expect(item.origin == .publication)
        #expect(item.color == .green)
        #expect(AnnotationResolverTests.samePosition(item.target.position, .range(CFIRange("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:8,/1:15)")!)))
        // Cached.
        #expect(try await container.embeddedAnnotations()?.id == set.id)

        let plain = try await EPUBContainer(url: Fixtures.url("cfi-sample.epub"))
        #expect(!plain.publication.hasEmbeddedAnnotations)
        #expect(try await plain.embeddedAnnotations() == nil)
    }
}
