import Compression
import Foundation

/// Raw DEFLATE decoding through the Compression framework. `COMPRESSION_ZLIB` in this framework is the raw
/// deflate stream (no zlib header), which is exactly what ZIP stores (docs/design/01-core.md §1.1).
enum Inflate {
    enum Failure: Error {
        case streamInitFailed
        case corruptStream
        case sizeMismatch(expected: Int, actual: Int)
    }

    /// Decodes `compressed` into exactly `expectedSize` bytes.
    static func decode(_ compressed: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let produced = try output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            try compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let srcBase = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw Failure.corruptStream
                }
                let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
                defer { streamPointer.deallocate() }
                guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                    throw Failure.streamInitFailed
                }
                defer { compression_stream_destroy(streamPointer) }
                streamPointer.pointee.src_ptr = srcBase
                streamPointer.pointee.src_size = src.count
                streamPointer.pointee.dst_ptr = dstBase
                streamPointer.pointee.dst_size = dst.count
                // The stream may stop after an internal block (e.g. 256 KB); keep going until it reports END
                // or makes no progress.
                while true {
                    let before = streamPointer.pointee.dst_size
                    let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    switch status {
                    case COMPRESSION_STATUS_END:
                        return dst.count - streamPointer.pointee.dst_size
                    case COMPRESSION_STATUS_OK:
                        if streamPointer.pointee.dst_size == 0 || (streamPointer.pointee.dst_size == before && streamPointer.pointee.src_size == 0) {
                            return dst.count - streamPointer.pointee.dst_size
                        }
                    default:
                        throw Failure.corruptStream
                    }
                }
            }
        }
        guard produced == expectedSize else {
            throw Failure.sizeMismatch(expected: expectedSize, actual: produced)
        }
        return output
    }
}
