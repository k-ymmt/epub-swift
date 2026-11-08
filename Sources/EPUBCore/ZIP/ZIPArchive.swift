import Foundation

/// One entry of the central directory.
public struct ZIPEntry: Sendable, Hashable {
    /// Normalized container path (see `ContainerPath.normalize`).
    public let path: String
    /// File name exactly as stored in the central directory.
    public let rawName: String
    /// 0 = Stored, 8 = Deflate.
    public let method: UInt16
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    public let crc32: UInt32
    public let localHeaderOffset: UInt64
    public let isDirectory: Bool
    /// General purpose bit flag. Bit 0 = encrypted, bit 3 = data descriptor, bit 11 = UTF-8 names.
    public let flags: UInt16

    public var isEncrypted: Bool { flags & 0x1 != 0 }
}

/// Read-only ZIP reader for the OCF subset: Stored and Deflate, ZIP64, no encryption
/// (docs/design/01-core.md §1.1). The file is memory-mapped; entries are read on demand.
public final class ZIPArchive: Sendable {
    public let url: URL?
    private let data: Data
    /// Entries by normalized path. Directory entries are excluded.
    public let entries: [String: ZIPEntry]
    /// All entries (including directories) in central directory order.
    public let entryOrder: [ZIPEntry]
    /// Warnings found while reading the directory (e.g. local header mismatch), keyed by path.
    public let directoryWarnings: [String]

    public convenience init(url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw EPUBError.notAZIPArchive
        }
        try self.init(data: data, url: url)
    }

    public init(data: Data, url: URL? = nil) throws {
        self.url = url
        self.data = data
        let reader = ByteReader(data)
        let eocd = try Self.locateEndOfCentralDirectory(reader)
        var entries: [String: ZIPEntry] = [:]
        var order: [ZIPEntry] = []
        var warnings: [String] = []
        // Both values were checked against the archive size in locateEndOfCentralDirectory, so they fit in Int.
        var offset = Int(eocd.centralDirectoryOffset)
        let end = Int(eocd.centralDirectoryOffset + eocd.centralDirectorySize)
        guard end <= reader.count else { throw EPUBError.notAZIPArchive }
        for _ in 0..<eocd.entryCount {
            guard offset + 46 <= end, reader.u32(offset) == 0x0201_4B50 else {
                // Fewer records than announced: stop at what we have.
                warnings.append("central directory ended early")
                break
            }
            let flags = reader.u16(offset + 8)
            let method = reader.u16(offset + 10)
            let crc = reader.u32(offset + 16)
            var compressedSize = UInt64(reader.u32(offset + 20))
            var uncompressedSize = UInt64(reader.u32(offset + 24))
            let nameLength = Int(reader.u16(offset + 28))
            let extraLength = Int(reader.u16(offset + 30))
            let commentLength = Int(reader.u16(offset + 32))
            var localHeaderOffset = UInt64(reader.u32(offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLength + extraLength + commentLength <= end else { throw EPUBError.notAZIPArchive }
            let rawName = reader.string(nameStart, length: nameLength, utf8Flag: flags & 0x800 != 0)
            // ZIP64 extended information extra field (0x0001): present fields follow the order
            // uncompressed size, compressed size, local header offset, disk number, and only for values that are
            // 0xFFFFFFFF in the fixed record.
            var extraOffset = nameStart + nameLength
            let extraEnd = extraOffset + extraLength
            while extraOffset + 4 <= extraEnd {
                let headerID = reader.u16(extraOffset)
                let size = Int(reader.u16(extraOffset + 2))
                var fieldOffset = extraOffset + 4
                let fieldEnd = min(fieldOffset + size, extraEnd)
                if headerID == 0x0001 {
                    if uncompressedSize == 0xFFFF_FFFF, fieldOffset + 8 <= fieldEnd {
                        uncompressedSize = reader.u64(fieldOffset); fieldOffset += 8
                    }
                    if compressedSize == 0xFFFF_FFFF, fieldOffset + 8 <= fieldEnd {
                        compressedSize = reader.u64(fieldOffset); fieldOffset += 8
                    }
                    if localHeaderOffset == 0xFFFF_FFFF, fieldOffset + 8 <= fieldEnd {
                        localHeaderOffset = reader.u64(fieldOffset); fieldOffset += 8
                    }
                }
                extraOffset += 4 + size
            }
            let isDirectory = rawName.hasSuffix("/")
            let entry = ZIPEntry(
                path: ContainerPath.normalize(rawName),
                rawName: rawName,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                crc32: crc,
                localHeaderOffset: localHeaderOffset,
                isDirectory: isDirectory,
                flags: flags
            )
            order.append(entry)
            if !isDirectory, entries[entry.path] == nil {
                entries[entry.path] = entry
            }
            offset = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = entries
        self.entryOrder = order
        self.directoryWarnings = warnings
    }

    /// The first entry in central directory order (OCF requires it to be `mimetype`, stored).
    public var firstEntry: ZIPEntry? { entryOrder.first }

    public func contains(_ path: String) -> Bool {
        entries[ContainerPath.normalize(path)] != nil
    }

    public func entry(at path: String) -> ZIPEntry? {
        entries[ContainerPath.normalize(path)]
    }

    public func data(at path: String) throws -> Data {
        guard let entry = entry(at: path) else { throw EPUBError.missingResource(path: path) }
        return try data(for: entry)
    }

    /// Decompressed contents of `entry`, CRC-checked. The central directory sizes are trusted; the local header
    /// is only used to locate the data (docs/design/01-core.md §1.1).
    public func data(for entry: ZIPEntry) throws -> Data {
        if entry.isEncrypted { throw EPUBError.encryptedResource(path: entry.path) }
        let reader = ByteReader(data)
        // All offsets and sizes come from the archive: convert without trapping and bound them by the archive size
        // before they are used in arithmetic.
        guard let local = Int(exactly: entry.localHeaderOffset), local <= reader.count - 30,
              reader.u32(local) == 0x0403_4B50 else {
            throw EPUBError.corruptEntry(path: entry.path)
        }
        let nameLength = Int(reader.u16(local + 26))
        let extraLength = Int(reader.u16(local + 28))
        let dataStart = local + 30 + nameLength + extraLength
        guard dataStart <= reader.count,
              let compressedSize = Int(exactly: entry.compressedSize), compressedSize <= reader.count - dataStart,
              let uncompressedSize = Int(exactly: entry.uncompressedSize), uncompressedSize <= Self.maxEntrySize else {
            throw EPUBError.corruptEntry(path: entry.path)
        }
        let compressed = data.subdata(in: (data.startIndex + dataStart)..<(data.startIndex + dataStart + compressedSize))
        let result: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw EPUBError.corruptEntry(path: entry.path) }
            result = compressed
        case 8:
            do {
                result = try Inflate.decode(compressed, expectedSize: uncompressedSize)
            } catch {
                throw EPUBError.corruptEntry(path: entry.path)
            }
        default:
            throw EPUBError.unsupportedCompression(path: entry.path, method: Int(entry.method))
        }
        guard CRC32.checksum(result) == entry.crc32 else { throw EPUBError.corruptEntry(path: entry.path) }
        return result
    }

    /// Largest entry this reader will decompress. An EPUB resource beyond this is treated as corrupt rather than
    /// letting an archive-controlled size drive the output allocation.
    static let maxEntrySize = 1 << 30

    // MARK: - End of central directory

    private struct EndOfCentralDirectory {
        var entryCount: UInt64
        var centralDirectorySize: UInt64
        var centralDirectoryOffset: UInt64
    }

    private static func locateEndOfCentralDirectory(_ reader: ByteReader) throws -> EndOfCentralDirectory {
        let count = reader.count
        guard count >= 22 else { throw EPUBError.notAZIPArchive }
        // Search backwards over the maximum comment length for the EOCD signature.
        let minOffset = max(0, count - 22 - 0xFFFF)
        var eocdOffset = -1
        var offset = count - 22
        while offset >= minOffset {
            if reader.u32(offset) == 0x0605_4B50 {
                let commentLength = Int(reader.u16(offset + 20))
                if offset + 22 + commentLength == count || commentLength == 0 {
                    eocdOffset = offset
                    break
                }
            }
            offset -= 1
        }
        guard eocdOffset >= 0 else { throw EPUBError.notAZIPArchive }
        var entryCount = UInt64(reader.u16(eocdOffset + 10))
        var cdSize = UInt64(reader.u32(eocdOffset + 12))
        var cdOffset = UInt64(reader.u32(eocdOffset + 16))
        let needsZip64 = entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF
        if needsZip64 {
            // ZIP64 end of central directory locator sits directly before the EOCD record.
            let locator = eocdOffset - 20
            guard locator >= 0, reader.u32(locator) == 0x0706_4B50 else { throw EPUBError.notAZIPArchive }
            guard let zip64EOCDOffset = Int(exactly: reader.u64(locator + 8)), zip64EOCDOffset <= count - 56,
                  reader.u32(zip64EOCDOffset) == 0x0606_4B50 else {
                throw EPUBError.notAZIPArchive
            }
            entryCount = reader.u64(zip64EOCDOffset + 32)
            cdSize = reader.u64(zip64EOCDOffset + 40)
            cdOffset = reader.u64(zip64EOCDOffset + 48)
        }
        let (cdEnd, overflow) = cdOffset.addingReportingOverflow(cdSize)
        guard !overflow, cdEnd <= UInt64(count) else { throw EPUBError.notAZIPArchive }
        return EndOfCentralDirectory(entryCount: entryCount, centralDirectorySize: cdSize, centralDirectoryOffset: cdOffset)
    }
}

/// Little-endian reads at absolute offsets within a `Data`.
struct ByteReader {
    let data: Data
    let count: Int

    init(_ data: Data) {
        self.data = data
        self.count = data.count
    }

    func u16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    func u64(_ offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
    }

    func string(_ offset: Int, length: Int, utf8Flag: Bool) -> String {
        guard length > 0, offset + length <= count else { return "" }
        let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + length))
        // OCF requires UTF-8 names; the flag is often not set even for ASCII/UTF-8 names, so try UTF-8 first.
        if let s = String(data: slice, encoding: .utf8) { return s }
        _ = utf8Flag
        return String(data: slice, encoding: .isoLatin1) ?? ""
    }
}
