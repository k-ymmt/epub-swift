import CryptoKit
import Foundation

/// Font obfuscation schemes recognised in `META-INF/encryption.xml` (docs/design/01-core.md §2.4).
public enum ObfuscationAlgorithm: String, Sendable, Hashable, CaseIterable {
    /// OCF 3 font obfuscation: SHA-1 of the unique identifier, first 1040 bytes XORed.
    case idpf = "http://www.idpf.org/2008/embedding"
    /// Adobe: the 16 bytes of the identifier's UUID, first 1024 bytes XORed.
    case adobe = "http://ns.adobe.com/pdf/enc#RC"

    /// Number of leading bytes that are obfuscated.
    public var obfuscatedPrefixLength: Int {
        switch self {
        case .idpf: return 1040
        case .adobe: return 1024
        }
    }

    /// Derives the XOR key from the package's unique identifier, or nil when the identifier cannot be used
    /// (Adobe needs a UUID).
    public func key(uniqueIdentifier: String) -> [UInt8]? {
        switch self {
        case .idpf:
            // All occurrences of U+0020, U+0009, U+000D and U+000A are removed before hashing (OCF §4.2.1).
            let stripped = uniqueIdentifier.unicodeScalars.filter { !["\u{20}", "\u{09}", "\u{0D}", "\u{0A}"].contains($0) }
            let digest = Insecure.SHA1.hash(data: Data(String(String.UnicodeScalarView(stripped)).utf8))
            return Array(digest)
        case .adobe:
            var text = uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = text.range(of: "urn:uuid:", options: [.caseInsensitive, .anchored]) {
                text.removeSubrange(range)
            }
            text = text.replacingOccurrences(of: "-", with: "")
            guard text.count == 32 else { return nil }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(16)
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return bytes
        }
    }
}

/// How one container path is obfuscated. The transform is its own inverse.
public struct FontObfuscation: Sendable, Hashable {
    public let algorithm: ObfuscationAlgorithm
    public let key: [UInt8]

    public init(algorithm: ObfuscationAlgorithm, key: [UInt8]) {
        self.algorithm = algorithm
        self.key = key
    }

    public init?(algorithm: ObfuscationAlgorithm, uniqueIdentifier: String) {
        guard let key = algorithm.key(uniqueIdentifier: uniqueIdentifier), !key.isEmpty else { return nil }
        self.init(algorithm: algorithm, key: key)
    }

    /// XORs the obfuscated prefix with the repeating key. Applying it twice gives the original bytes.
    public func apply(to data: Data) -> Data {
        guard !key.isEmpty, !data.isEmpty else { return data }
        var out = data
        let count = min(algorithm.obfuscatedPrefixLength, out.count)
        out.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for i in 0..<count {
                buffer[i] ^= key[i % key.count]
            }
        }
        return out
    }
}

/// Parses `META-INF/encryption.xml` (docs/design/01-core.md §2.4).
enum EncryptionParser {
    struct Result {
        /// Container path → obfuscation to undo when serving the resource.
        var obfuscations: [String: FontObfuscation] = [:]
        /// Container paths encrypted with an algorithm this library does not handle (DRM). Reading them fails.
        var unsupported: Set<String> = []
        var warnings: [PublicationWarning] = []
    }

    static func parse(_ data: Data, uniqueIdentifier: String?) -> Result {
        var result = Result()
        guard let document = try? XMLDocument(data: data) else {
            result.warnings.append(.malformedEncryptionXML)
            return result
        }
        for encrypted in document.root.descendants(where: { $0.name == "EncryptedData" }) {
            guard let algorithm = encrypted.firstDescendant(where: { $0.name == "EncryptionMethod" })?.attribute("Algorithm") else { continue }
            let references = encrypted.descendants { $0.name == "CipherReference" }
            for reference in references {
                guard let uri = reference.attribute("URI"), !uri.isEmpty else { continue }
                // URIs are relative to the container root.
                let path = ContainerPath.normalize(uri.removingPercentEncoding ?? uri)
                if let scheme = ObfuscationAlgorithm(rawValue: algorithm),
                   let identifier = uniqueIdentifier,
                   let obfuscation = FontObfuscation(algorithm: scheme, uniqueIdentifier: identifier) {
                    result.obfuscations[path] = obfuscation
                } else {
                    result.unsupported.insert(path)
                    result.warnings.append(.unsupportedEncryption(path: path, algorithm: algorithm))
                }
            }
        }
        return result
    }
}
