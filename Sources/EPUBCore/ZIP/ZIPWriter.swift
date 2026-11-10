import Compression
import Foundation

/// Writes ZIP archives (docs/design/06-annotations.md §9.2): Stored and Deflate entries, UTF-8 names (flag bit 11),
/// and ZIP64 structures only when an entry, an offset or the entry count needs them. Entries go to the file as they
/// are added, so the archive is never held in memory as a whole (one entry is, while it is compressed).
///
/// The `.annotations` export uses it; EPUB embedding (§9.4, not built yet) is meant to share it.
public final class ZIPWriter {
    public enum Method: Sendable {
        case stored
        /// Deflate, falling back to Stored when compression does not make the entry smaller.
        case deflate
    }

    public enum Failure: Error, Sendable {
        case finished
        case duplicateName(String)
        case invalidName(String)
        case compressionFailed
        case nameTooLong(String)
    }

    private enum Sink {
        case file(FileHandle)
        case memory
    }

    private struct CentralRecord {
        var name: Data
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var offset: UInt64
        var dosTime: UInt16
        var dosDate: UInt16
    }

    private let sink: Sink
    private var buffer = Data()
    private var offset: UInt64 = 0
    private var records: [CentralRecord] = []
    private var names: Set<String> = []
    private var isFinished = false
    private let dosTime: UInt16
    private let dosDate: UInt16
    /// Writes ZIP64 structures for every entry and the end record (tests exercise the ZIP64 path without 4 GiB).
    var forcesZIP64 = false

    /// Writes to a new file at `url` (an existing file is replaced). `date` is the modification time of every entry.
    public init(url: URL, date: Date = Date()) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        sink = .file(try FileHandle(forWritingTo: url))
        (dosTime, dosDate) = Self.dosDateTime(date)
    }

    /// Writes into memory; `finish()` returns the archive.
    public init(date: Date = Date()) {
        sink = .memory
        (dosTime, dosDate) = Self.dosDateTime(date)
    }

    deinit {
        if case .file(let handle) = sink { try? handle.close() }
    }

    /// Adds an entry. `name` is the path inside the archive (`/`-separated, no leading `/`, no `..`).
    public func add(_ name: String, data: Data, method: Method = .deflate) throws {
        guard !isFinished else { throw Failure.finished }
        guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), !name.contains("\\") else {
            throw Failure.invalidName(name)
        }
        guard names.insert(name).inserted else { throw Failure.duplicateName(name) }
        let nameBytes = Data(name.utf8)
        guard nameBytes.count <= 0xFFFF else { throw Failure.nameTooLong(name) }
        let crc = CRC32.checksum(data)
        var payload = data
        var methodCode: UInt16 = 0
        if method == .deflate, !data.isEmpty {
            let compressed = try Self.deflate(data)
            if compressed.count < data.count {
                payload = compressed
                methodCode = 8
            }
        }
        let uncompressedSize = UInt64(data.count)
        let compressedSize = UInt64(payload.count)
        let entryOffset = offset
        let sizesNeedZIP64 = forcesZIP64 || uncompressedSize >= 0xFFFF_FFFF || compressedSize >= 0xFFFF_FFFF

        var extra = Data()
        if sizesNeedZIP64 {
            extra.append(le16(0x0001))
            extra.append(le16(16))
            extra.append(le64(uncompressedSize))
            extra.append(le64(compressedSize))
        }
        var header = Data()
        header.append(le32(0x0403_4B50))
        header.append(le16(sizesNeedZIP64 ? 45 : 20))
        header.append(le16(0x0800))
        header.append(le16(methodCode))
        header.append(le16(dosTime))
        header.append(le16(dosDate))
        header.append(le32(crc))
        header.append(le32(sizesNeedZIP64 ? 0xFFFF_FFFF : UInt32(compressedSize)))
        header.append(le32(sizesNeedZIP64 ? 0xFFFF_FFFF : UInt32(uncompressedSize)))
        header.append(le16(UInt16(nameBytes.count)))
        header.append(le16(UInt16(extra.count)))
        header.append(nameBytes)
        header.append(extra)
        try write(header)
        try write(payload)
        records.append(CentralRecord(name: nameBytes, method: methodCode, crc: crc, compressedSize: compressedSize, uncompressedSize: uncompressedSize, offset: entryOffset, dosTime: dosTime, dosDate: dosDate))
    }

    /// Writes the central directory and closes the file. Returns the archive when writing into memory (empty for a
    /// file).
    @discardableResult
    public func finish() throws -> Data {
        guard !isFinished else { throw Failure.finished }
        isFinished = true
        let centralOffset = offset
        var central = Data()
        for record in records {
            let sizes = forcesZIP64 || record.uncompressedSize >= 0xFFFF_FFFF || record.compressedSize >= 0xFFFF_FFFF
            let offsetNeeds = forcesZIP64 || record.offset >= 0xFFFF_FFFF
            var extra = Data()
            if sizes || offsetNeeds {
                var fields = Data()
                if sizes {
                    fields.append(le64(record.uncompressedSize))
                    fields.append(le64(record.compressedSize))
                }
                if offsetNeeds { fields.append(le64(record.offset)) }
                extra.append(le16(0x0001))
                extra.append(le16(UInt16(fields.count)))
                extra.append(fields)
            }
            let version: UInt16 = (sizes || offsetNeeds) ? 45 : 20
            central.append(le32(0x0201_4B50))
            central.append(le16(version | 0x0300)) // made by: Unix
            central.append(le16(version))
            central.append(le16(0x0800))
            central.append(le16(record.method))
            central.append(le16(record.dosTime))
            central.append(le16(record.dosDate))
            central.append(le32(record.crc))
            central.append(le32(sizes ? 0xFFFF_FFFF : UInt32(record.compressedSize)))
            central.append(le32(sizes ? 0xFFFF_FFFF : UInt32(record.uncompressedSize)))
            central.append(le16(UInt16(record.name.count)))
            central.append(le16(UInt16(extra.count)))
            central.append(le16(0)) // comment
            central.append(le16(0)) // disk
            central.append(le16(0)) // internal attributes
            central.append(le32(0o100644 << 16)) // external attributes: a regular file, rw-r--r--
            central.append(le32(offsetNeeds ? 0xFFFF_FFFF : UInt32(record.offset)))
            central.append(record.name)
            central.append(extra)
        }
        try write(central)
        let centralSize = UInt64(central.count)
        let count = UInt64(records.count)
        let needsZIP64 = forcesZIP64 || count >= 0xFFFF || centralSize >= 0xFFFF_FFFF || centralOffset >= 0xFFFF_FFFF
        var end = Data()
        if needsZIP64 {
            let zip64EndOffset = offset
            end.append(le32(0x0606_4B50))
            end.append(le64(44))
            end.append(le16(45 | 0x0300))
            end.append(le16(45))
            end.append(le32(0))
            end.append(le32(0))
            end.append(le64(count))
            end.append(le64(count))
            end.append(le64(centralSize))
            end.append(le64(centralOffset))
            end.append(le32(0x0706_4B50))
            end.append(le32(0))
            end.append(le64(zip64EndOffset))
            end.append(le32(1))
        }
        end.append(le32(0x0605_4B50))
        end.append(le16(0))
        end.append(le16(0))
        end.append(le16(needsZIP64 ? 0xFFFF : UInt16(count)))
        end.append(le16(needsZIP64 ? 0xFFFF : UInt16(count)))
        end.append(le32(needsZIP64 ? 0xFFFF_FFFF : UInt32(centralSize)))
        end.append(le32(needsZIP64 ? 0xFFFF_FFFF : UInt32(centralOffset)))
        end.append(le16(0))
        try write(end)
        switch sink {
        case .file(let handle):
            try handle.synchronize()
            try handle.close()
            return Data()
        case .memory:
            return buffer
        }
    }

    private func write(_ data: Data) throws {
        switch sink {
        case .file(let handle): try handle.write(contentsOf: data)
        case .memory: buffer.append(data)
        }
        offset += UInt64(data.count)
    }

    /// Raw DEFLATE (the Compression framework's `COMPRESSION_ZLIB` stream has no zlib header, as ZIP wants).
    static func deflate(_ data: Data) throws -> Data {
        var output = Data()
        let chunk = 64 * 1024
        var destination = [UInt8](repeating: 0, count: chunk)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.compressionFailed
        }
        defer { compression_stream_destroy(stream) }
        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw Failure.compressionFailed }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
            while true {
                let status = destination.withUnsafeMutableBufferPointer { buffer -> compression_status in
                    stream.pointee.dst_ptr = buffer.baseAddress!
                    stream.pointee.dst_size = chunk
                    return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = chunk - stream.pointee.dst_size
                output.append(contentsOf: destination[0..<produced])
                switch status {
                case COMPRESSION_STATUS_END: return
                case COMPRESSION_STATUS_OK: continue
                default: throw Failure.compressionFailed
                }
            }
        }
        return output
    }

    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 1980))
        let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        let day = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        return (time, day)
    }
}

private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
private func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
