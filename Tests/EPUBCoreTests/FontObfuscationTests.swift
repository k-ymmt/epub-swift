import CryptoKit
import Foundation
import Testing
@testable import EPUBCore

/// Font obfuscation (docs/design/01-core.md §2.4): IDPF with the `wasteland-otf-obf` sample, Adobe with a font
/// obfuscated in the test, and an unsupported algorithm.
@Suite struct FontObfuscationTests {
    static let otfMagic = Data("OTTO".utf8)

    @Test func idpfKeyIsSHA1OfTheIdentifierWithoutWhitespace() {
        let key = ObfuscationAlgorithm.idpf.key(uniqueIdentifier: " urn:uuid:1234 \n\tabc ")
        let expected = Array(Insecure.SHA1.hash(data: Data("urn:uuid:1234abc".utf8)))
        #expect(key == expected)
        #expect(key?.count == 20)
    }

    @Test func adobeKeyIsTheUUIDBytes() {
        let key = ObfuscationAlgorithm.adobe.key(uniqueIdentifier: "urn:uuid:12345678-1234-1234-1234-123456789abc")
        #expect(key == [0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x12, 0x34, 0x12, 0x34, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc])
        #expect(ObfuscationAlgorithm.adobe.key(uniqueIdentifier: "not-a-uuid") == nil)
    }

    @Test func deobfuscatesTheWastelandFontsWithIDPF() async throws {
        let container = try await EPUBContainer(url: Fixtures.wasteland)
        let pub = container.publication
        #expect(pub.metadata.title == "The Waste Land")
        #expect(pub.metadata.identifier == "code.google.com.epub-samples.wasteland-otf-obfuscated")
        #expect(!pub.warnings.contains { if case .unsupportedEncryption = $0 { return true }; return false })
        for name in ["OldStandard-Regular", "OldStandard-Italic", "OldStandard-Bold"] {
            let font = try await container.data(at: "EPUB/\(name).obf.otf")
            #expect(font.prefix(4) == Self.otfMagic, "\(name) does not start with OTTO")
            #expect(font.count > 100_000)
        }
        // Non-obfuscated resources are untouched.
        let css = try await container.data(at: "EPUB/fonts.css")
        #expect(String(decoding: css, as: UTF8.self).contains("@font-face"))
    }

    @Test func deobfuscatesAnAdobeObfuscatedFontAndAppliesTheFullPrefix() async throws {
        // A fake TrueType font: a recognisable header followed by a byte ramp, longer than the 1024-byte prefix.
        var font = Data([0x00, 0x01, 0x00, 0x00])
        font.append(contentsOf: (0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let identifier = "urn:uuid:12345678-1234-1234-1234-123456789abc" // MiniEPUB's dc:identifier
        let scheme = try #require(FontObfuscation(algorithm: .adobe, uniqueIdentifier: identifier))
        let obfuscated = scheme.apply(to: font)
        #expect(obfuscated != font)
        #expect(obfuscated.suffix(from: 1024) == font.suffix(from: 1024)) // only the first 1024 bytes change
        #expect(obfuscated.prefix(1024) != font.prefix(1024))

        let encryption = """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://ns.adobe.com/pdf/enc#RC"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/fake%20font.ttf"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        let data = MiniEPUB.build(
            withNav: true,
            extraManifest: #"<item id="f" href="fonts/fake%20font.ttf" media-type="font/ttf"/>"#,
            extraFiles: [("OEBPS/fonts/fake font.ttf", obfuscated)],
            encryptionXML: encryption
        )
        let container = try await EPUBContainer(data: data)
        #expect(container.publication.warnings.filter { if case .unsupportedEncryption = $0 { return true }; return false }.isEmpty)
        let served = try await container.data(at: "OEBPS/fonts/fake font.ttf")
        #expect(served == font)
    }

    @Test func idpfRoundTripCoversExactly1040Bytes() throws {
        let scheme = try #require(FontObfuscation(algorithm: .idpf, uniqueIdentifier: "id"))
        let data = Data((0..<2000).map { UInt8(truncatingIfNeeded: $0) })
        let once = scheme.apply(to: data)
        #expect(once.suffix(from: 1040) == data.suffix(from: 1040))
        #expect(once.prefix(1040) != data.prefix(1040))
        #expect(scheme.apply(to: once) == data)
        // Shorter than the prefix: the whole resource is transformed and still round-trips.
        let short = Data(repeating: 0xAB, count: 100)
        #expect(scheme.apply(to: scheme.apply(to: short)) == short)
    }

    @Test func unsupportedAlgorithmsWarnAndRefuseToServe() async throws {
        let encryption = """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/text/c1.xhtml"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        let container = try await EPUBContainer(data: MiniEPUB.build(withNav: true, encryptionXML: encryption))
        #expect(container.publication.warnings.contains(.unsupportedEncryption(path: "OEBPS/text/c1.xhtml", algorithm: "http://www.w3.org/2001/04/xmlenc#aes128-cbc")))
        await #expect(throws: EPUBError.self) { try await container.data(at: "OEBPS/text/c1.xhtml") }
        // Other resources still work.
        _ = try await container.data(at: "OEBPS/text/c2.xhtml")
    }

    @Test func malformedEncryptionXMLIsAWarningOnly() async throws {
        let container = try await EPUBContainer(data: MiniEPUB.build(withNav: true, encryptionXML: "<encryption><broken"))
        #expect(container.publication.warnings.contains(.malformedEncryptionXML))
        _ = try await container.data(at: "OEBPS/text/c1.xhtml")
    }
}
