import Foundation
@testable import EPUBCore

/// Minimal ZIP writer for tests. Writes Stored entries, optionally with ZIP64 structures
/// (ZIP64 extra fields on every entry plus the ZIP64 EOCD record and locator), so the reader's ZIP64 path can be
/// exercised without a 4 GB file.
struct TestZIPWriter {
    struct Entry {
        var name: String
        var data: Data
        var deflate: Bool = false
    }

    var entries: [Entry] = []
    var zip64: Bool = false

    mutating func add(_ name: String, _ text: String, deflate: Bool = false) {
        entries.append(Entry(name: name, data: Data(text.utf8), deflate: deflate))
    }

    mutating func add(_ name: String, data: Data, deflate: Bool = false) {
        entries.append(Entry(name: name, data: data, deflate: deflate))
    }

    func build() -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let payload = entry.deflate ? Self.deflate(entry.data) : entry.data
            let method: UInt16 = entry.deflate ? 8 : 0
            let localOffset = UInt64(out.count)

            var extra = Data()
            if zip64 {
                extra.append(u16(0x0001))
                extra.append(u16(28))
                extra.append(u64(UInt64(entry.data.count)))
                extra.append(u64(UInt64(payload.count)))
                extra.append(u64(localOffset))
                extra.append(u32(0))
            }

            // Local file header
            out.append(u32(0x0403_4B50))
            out.append(u16(zip64 ? 45 : 20))
            out.append(u16(0x0800)) // UTF-8 names
            out.append(u16(method))
            out.append(u16(0)); out.append(u16(0)) // time, date
            out.append(u32(crc))
            out.append(u32(zip64 ? 0xFFFF_FFFF : UInt32(payload.count)))
            out.append(u32(zip64 ? 0xFFFF_FFFF : UInt32(entry.data.count)))
            out.append(u16(UInt16(nameBytes.count)))
            out.append(u16(UInt16(extra.count)))
            out.append(nameBytes)
            out.append(extra)
            out.append(payload)

            // Central directory header
            central.append(u32(0x0201_4B50))
            central.append(u16(zip64 ? 45 : 20)) // version made by
            central.append(u16(zip64 ? 45 : 20)) // version needed
            central.append(u16(0x0800))
            central.append(u16(method))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(crc))
            central.append(u32(zip64 ? 0xFFFF_FFFF : UInt32(payload.count)))
            central.append(u32(zip64 ? 0xFFFF_FFFF : UInt32(entry.data.count)))
            central.append(u16(UInt16(nameBytes.count)))
            central.append(u16(UInt16(extra.count)))
            central.append(u16(0)) // comment length
            central.append(u16(0)) // disk number start
            central.append(u16(0)) // internal attributes
            central.append(u32(0)) // external attributes
            central.append(u32(zip64 ? 0xFFFF_FFFF : UInt32(localOffset)))
            central.append(nameBytes)
            central.append(extra)
        }
        let centralOffset = UInt64(out.count)
        out.append(central)
        let centralSize = UInt64(central.count)
        if zip64 {
            let zip64EOCDOffset = UInt64(out.count)
            out.append(u32(0x0606_4B50))
            out.append(u64(44)) // size of the remaining record
            out.append(u16(45)); out.append(u16(45))
            out.append(u32(0)); out.append(u32(0))
            out.append(u64(UInt64(entries.count)))
            out.append(u64(UInt64(entries.count)))
            out.append(u64(centralSize))
            out.append(u64(centralOffset))
            // locator
            out.append(u32(0x0706_4B50))
            out.append(u32(0))
            out.append(u64(zip64EOCDOffset))
            out.append(u32(1))
        }
        out.append(u32(0x0605_4B50))
        out.append(u16(0)); out.append(u16(0))
        out.append(u16(zip64 ? 0xFFFF : UInt16(entries.count)))
        out.append(u16(zip64 ? 0xFFFF : UInt16(entries.count)))
        out.append(u32(zip64 ? 0xFFFF_FFFF : UInt32(centralSize)))
        out.append(u32(zip64 ? 0xFFFF_FFFF : UInt32(centralOffset)))
        out.append(u16(0))
        return out
    }

    private func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func u64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// Raw deflate via the Compression framework (encode side of `Inflate`).
    static func deflate(_ data: Data) -> Data {
        var dst = Data(count: max(64, data.count * 2 + 64))
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(
                    d.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count,
                    s.baseAddress!.assumingMemoryBound(to: UInt8.self), s.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return dst.prefix(written)
    }
}

import Compression

/// Builds a tiny EPUB in memory.
enum MiniEPUB {
    static let xhtml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>c</title></head><body><p id="p1">Hello</p></body></html>
    """

    static func build(
        withNav: Bool,
        zip64: Bool = false,
        deflate: Bool = true,
        extraManifest: String = "",
        extraSpine: String = "",
        extraMetadata: String = "",
        spineItemProperties: [String] = ["", ""],
        extraFiles: [(name: String, data: Data)] = [],
        encryptionXML: String? = nil
    ) -> Data {
        let props = spineItemProperties.map { $0.isEmpty ? "" : " properties=\"\($0)\"" }
        var w = TestZIPWriter()
        w.zip64 = zip64
        w.add("mimetype", "application/epub+zip")
        if let encryptionXML { w.add("META-INF/encryption.xml", encryptionXML, deflate: deflate) }
        for file in extraFiles { w.add(file.name, data: file.data, deflate: deflate) }
        w.add("META-INF/container.xml", """
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """, deflate: deflate)
        let navItem = withNav ? #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"# : ""
        w.add("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier>
            <dc:title>Mini</dc:title>
            <dc:creator>Tester</dc:creator>
            <dc:language>ja</dc:language>
            <meta property="dcterms:modified">2026-01-02T03:04:05Z</meta>
            \(extraMetadata)
          </metadata>
          <manifest>
            \(navItem)
            <item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/>
            \(extraManifest)
          </manifest>
          <spine page-progression-direction="rtl">
            <itemref idref="c1"\(props[0])/>
            <itemref idref="c2" linear="no"\(props[1])/>
            \(extraSpine)
          </spine>
        </package>
        """, deflate: deflate)
        if withNav {
            w.add("OEBPS/nav.xhtml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>nav</title></head>
            <body><nav epub:type="toc"><ol><li><a href="text/c1.xhtml">One</a><ol><li><a href="text/c2.xhtml#p1">Two</a></li></ol></li></ol></nav></body></html>
            """, deflate: deflate)
        }
        w.add("OEBPS/text/c1.xhtml", xhtml, deflate: deflate)
        w.add("OEBPS/text/c2.xhtml", xhtml, deflate: deflate)
        return w.build()
    }
}
