import Foundation
import Testing
@testable import EPUBCore

@Suite struct ZIPArchiveTests {
    @Test func readsStoredAndDeflatedEntriesFromMobyDick() throws {
        let archive = try ZIPArchive(url: Fixtures.mobyDick)
        let mimetype = try #require(archive.firstEntry)
        #expect(mimetype.path == "mimetype")
        #expect(mimetype.method == 0)
        #expect(String(decoding: try archive.data(for: mimetype), as: UTF8.self) == "application/epub+zip")

        let opf = try #require(archive.entry(at: "OPS/package.opf"))
        #expect(opf.method == 8)
        let data = try archive.data(for: opf)
        #expect(data.count == Int(opf.uncompressedSize))
        #expect(String(decoding: data.prefix(5), as: UTF8.self) == "<?xml")
        #expect(archive.entries.count == 154) // packed with zip -D: no directory entries
    }

    @Test func normalizesPaths() throws {
        let archive = try ZIPArchive(url: Fixtures.mobyDick)
        #expect(archive.contains("./OPS//chapter_001.xhtml"))
        #expect(archive.contains("OPS/css/../chapter_001.xhtml"))
        #expect(!archive.contains("OPS/nope.xhtml"))
    }

    @Test func detectsCorruptEntries() throws {
        var w = ZIPWriter()
        w.add("a.txt", "hello world", deflate: true)
        var bytes = w.build()
        // Flip a byte inside the deflated payload (after the 30-byte local header + 5-byte name).
        bytes[36] ^= 0xFF
        let archive = try ZIPArchive(data: bytes)
        #expect(throws: EPUBError.self) { try archive.data(at: "a.txt") }
    }

    @Test func readsZIP64Structures() throws {
        var w = ZIPWriter()
        w.zip64 = true
        w.add("mimetype", "application/epub+zip")
        w.add("dir/b.txt", "zip64 payload", deflate: true)
        let archive = try ZIPArchive(data: w.build())
        #expect(archive.entries.count == 2)
        #expect(archive.firstEntry?.path == "mimetype")
        let entry = try #require(archive.entry(at: "dir/b.txt"))
        #expect(entry.uncompressedSize == 13)
        #expect(String(decoding: try archive.data(for: entry), as: UTF8.self) == "zip64 payload")
    }

    @Test func rejectsNonZIPData() {
        #expect(throws: EPUBError.self) { try ZIPArchive(data: Data("not a zip file at all, really".utf8)) }
    }

    @Test func rejectsUnsupportedCompressionMethod() throws {
        var w = ZIPWriter()
        w.add("a.txt", "hello")
        var bytes = w.build()
        // Method field of the local header (offset 8) and central directory header (offset +10).
        bytes[8] = 12
        let cdOffset = bytes.count - 22 - 46 - 5
        bytes[cdOffset + 10] = 12
        let archive = try ZIPArchive(data: bytes)
        #expect(throws: EPUBError.self) { try archive.data(at: "a.txt") }
    }

    // Archive-controlled 64-bit values must be rejected, not converted with a trapping `Int(...)`.

    @Test func rejectsZIP64LocatorOffsetBeyondInt() throws {
        var w = ZIPWriter()
        w.zip64 = true
        w.add("a.txt", "hello")
        var bytes = w.build()
        // The locator's 8-byte "offset of the ZIP64 EOCD record" sits 12 bytes before the 22-byte EOCD.
        let field = bytes.count - 22 - 12
        bytes.replaceSubrange(field..<(field + 8), with: [UInt8](repeating: 0xFF, count: 8))
        #expect(throws: EPUBError.self) { try ZIPArchive(data: bytes) }
    }

    @Test func rejectsZIP64CentralDirectoryBoundsThatOverflow() throws {
        var w = ZIPWriter()
        w.zip64 = true
        w.add("a.txt", "hello")
        var bytes = w.build()
        // ZIP64 EOCD record: 56 bytes, directly before the 20-byte locator. Size at +40, offset at +48.
        let record = bytes.count - 22 - 20 - 56
        bytes.replaceSubrange((record + 40)..<(record + 48), with: [UInt8](repeating: 0xFF, count: 8))
        bytes.replaceSubrange((record + 48)..<(record + 56), with: [0x02, 0, 0, 0, 0, 0, 0, 0])
        #expect(throws: EPUBError.self) { try ZIPArchive(data: bytes) }
    }

    @Test func rejectsEntryOffsetsAndSizesBeyondTheArchive() throws {
        var w = ZIPWriter()
        w.zip64 = true
        w.add("a.txt", "hello", deflate: true)
        let good = w.build()
        // Central directory header for the single entry starts right after the local header + name + extra + payload.
        let payload = ZIPWriter.deflate(Data("hello".utf8)).count
        let cdHeader = 30 + 5 + 32 + payload
        #expect(good[cdHeader] == 0x50 && good[cdHeader + 1] == 0x4B && good[cdHeader + 2] == 0x01)
        // ZIP64 extra field follows the 46-byte header and the 5-byte name: 4-byte header, then
        // uncompressed size (+4), compressed size (+12), local header offset (+20).
        let extra = cdHeader + 46 + 5
        let allOnes = [UInt8](repeating: 0xFF, count: 8)

        var badOffset = good
        badOffset.replaceSubrange((extra + 20)..<(extra + 28), with: allOnes)
        let archive1 = try ZIPArchive(data: badOffset)
        #expect(throws: EPUBError.self) { try archive1.data(at: "a.txt") }

        var badCompressed = good
        badCompressed.replaceSubrange((extra + 12)..<(extra + 20), with: allOnes)
        let archive2 = try ZIPArchive(data: badCompressed)
        #expect(throws: EPUBError.self) { try archive2.data(at: "a.txt") }

        var badUncompressed = good
        badUncompressed.replaceSubrange((extra + 4)..<(extra + 12), with: allOnes)
        let archive3 = try ZIPArchive(data: badUncompressed)
        #expect(throws: EPUBError.self) { try archive3.data(at: "a.txt") }

        // Sanity: the untouched archive still reads.
        #expect(String(decoding: try ZIPArchive(data: good).data(at: "a.txt"), as: UTF8.self) == "hello")
    }

    @Test func crc32MatchesKnownVector() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }
}

@Suite struct InflateTests {
    @Test func decodesEntriesLargerThanTheStreamBlock() throws {
        // 338 KB entry: the Compression stream pauses every 256 KB, so decoding must loop.
        let archive = try ZIPArchive(url: Fixtures.childrensLiterature)
        let entry = try #require(archive.entry(at: "EPUB/s04.xhtml"))
        #expect(entry.uncompressedSize > 262_144)
        let data = try archive.data(for: entry)
        #expect(data.count == Int(entry.uncompressedSize))
        #expect(String(decoding: data.suffix(8), as: UTF8.self).contains("</html>"))
    }

    @Test func roundTripsRandomPayload() throws {
        var payload = Data(count: 700_000)
        payload.withUnsafeMutableBytes { buffer in
            for i in buffer.indices { buffer[i] = UInt8((i * 31 + i / 7919) & 0xFF) }
        }
        let compressed = ZIPWriter.deflate(payload)
        let restored = try Inflate.decode(compressed, expectedSize: payload.count)
        #expect(restored == payload)
    }
}
