import Foundation

/// A detached annotation file: a ZIP holding `annotations.json` at its root and the files of audio, image and video
/// notes (docs/design/06-annotations.md §9.2). Reading looks at the contents, not the file extension.
public struct AnnotationArchive: Sendable {
    public static let mediaType = #"application/zip;profile="https://www.w3.org/TR/epub-anno-10/""#
    public static let pathExtension = "annotations"
    /// The name of the set inside the archive.
    public static let setPath = "annotations.json"

    public enum Failure: Error, Hashable, Sendable {
        case notAZIPArchive
        /// No `annotations.json` at the root.
        case missingAnnotationSet
        case tooLarge(bytes: Int64, limit: Int64)
        /// A body URL outside the archive (`..`, an absolute path).
        case pathOutsideArchive(String)
        /// An absolute URL. The library does not fetch external resources (§11).
        case externalResource(String)
        case missingResource(String)
    }

    /// The set as read. Positions are unresolved until `AnnotationResolver` resolves them (or come from the CFI
    /// selector when there is one).
    public var annotationSet: AnnotationSet
    /// Annotations the read skipped.
    public var warnings: [AnnotationImportWarning]
    private let archive: ZIPArchive?

    public init(annotationSet: AnnotationSet, warnings: [AnnotationImportWarning] = []) {
        self.annotationSet = annotationSet
        self.warnings = warnings
        self.archive = nil
    }

    private init(annotationSet: AnnotationSet, warnings: [AnnotationImportWarning], archive: ZIPArchive) {
        self.annotationSet = annotationSet
        self.warnings = warnings
        self.archive = archive
    }

    // MARK: Reading

    @concurrent
    public static func read(from url: URL, limits: AnnotationImportLimits = .default) async throws -> AnnotationArchive {
        let archive: ZIPArchive
        do {
            archive = try ZIPArchive(url: url)
        } catch {
            throw Failure.notAZIPArchive
        }
        return try read(archive, limits: limits)
    }

    @concurrent
    public static func read(data: Data, limits: AnnotationImportLimits = .default) async throws -> AnnotationArchive {
        let archive: ZIPArchive
        do {
            archive = try ZIPArchive(data: data)
        } catch {
            throw Failure.notAZIPArchive
        }
        return try read(archive, limits: limits)
    }

    private static func read(_ archive: ZIPArchive, limits: AnnotationImportLimits) throws -> AnnotationArchive {
        var total: Int64 = 0
        for entry in archive.entryOrder {
            total += Int64(clamping: entry.uncompressedSize)
            if total > limits.maxArchiveUncompressedBytes {
                throw Failure.tooLarge(bytes: total, limit: limits.maxArchiveUncompressedBytes)
            }
        }
        // `annotations.json` at the root, as stored (no leading `/`); a `./` or `/` prefix is tolerated.
        guard let entry = archive.entryOrder.first(where: { !$0.isDirectory && $0.rawName == setPath })
                ?? archive.entryOrder.first(where: { !$0.isDirectory && $0.path == setPath }) else {
            throw Failure.missingAnnotationSet
        }
        guard entry.uncompressedSize <= UInt64(limits.maxJSONBytes) else {
            throw AnnotationCodecError.tooLarge(bytes: Int(clamping: entry.uncompressedSize), limit: limits.maxJSONBytes)
        }
        let data = try archive.data(for: entry)
        let (set, warnings) = try AnnotationCodec.decode(data, limits: limits)
        return AnnotationArchive(annotationSet: set, warnings: warnings, archive: archive)
    }

    /// The bytes of an audio, image or video note (`Body.Content` URL, relative to the archive's root). Throws for
    /// absolute URLs (never fetched) and paths outside the archive.
    public func resource(at relativeURL: String) async throws -> Data {
        guard !AnnotationPath.isAbsoluteURL(relativeURL) else { throw Failure.externalResource(relativeURL) }
        let decoded = relativeURL.removingPercentEncoding ?? relativeURL
        guard let path = AnnotationPath.resolveContained(decoded) else { throw Failure.pathOutsideArchive(relativeURL) }
        guard let archive, archive.contains(path) else { throw Failure.missingResource(relativeURL) }
        return try archive.data(at: path)
    }

    // MARK: Writing

    /// Writes `set` as a `.annotations` file in the export form (`options`). The files of audio, image and video
    /// notes with relative URLs are asked from `resources` (one at a time) and stored at those URLs; absolute URLs
    /// are written as they are and not fetched. The file is written next to `url` and moved into place.
    @concurrent
    public static func write(_ set: AnnotationSet, options: ExportOptions = ExportOptions(), resources: @Sendable (String) async throws -> Data, to url: URL) async throws {
        let json = try AnnotationCodec.encode(set, mode: .export(options))
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).annotations-partial")
        do {
            let writer = try ZIPWriter(url: temporary)
            try writer.add(setPath, data: json, method: .deflate)
            var written: Set<String> = [setPath]
            for annotation in set.items where options.filter.includes(annotation) {
                guard let url = annotation.body?.resourceURL, !AnnotationPath.isAbsoluteURL(url) else { continue }
                let decoded = url.removingPercentEncoding ?? url
                guard let path = AnnotationPath.resolveContained(decoded) else { throw Failure.pathOutsideArchive(url) }
                guard written.insert(path).inserted else { continue }
                let data = try await resources(url)
                // Media files are compressed already.
                try writer.add(path, data: data, method: .stored)
            }
            try writer.finish()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// The archive bytes (export form), for apps that hand the file to a share sheet without a URL.
    @concurrent
    public static func data(_ set: AnnotationSet, options: ExportOptions = ExportOptions(), resources: @Sendable (String) async throws -> Data) async throws -> Data {
        let json = try AnnotationCodec.encode(set, mode: .export(options))
        let writer = ZIPWriter()
        try writer.add(setPath, data: json, method: .deflate)
        var written: Set<String> = [setPath]
        for annotation in set.items where options.filter.includes(annotation) {
            guard let url = annotation.body?.resourceURL, !AnnotationPath.isAbsoluteURL(url) else { continue }
            let decoded = url.removingPercentEncoding ?? url
            guard let path = AnnotationPath.resolveContained(decoded) else { throw Failure.pathOutsideArchive(url) }
            guard written.insert(path).inserted else { continue }
            try writer.add(path, data: try await resources(url), method: .stored)
        }
        return try writer.finish()
    }
}

extension Body {
    /// The URL of an audio, image or video note.
    var resourceURL: String? {
        switch content {
        case .image(let url)?, .audio(let url)?, .video(let url)?: return url
        case .text?, nil: return nil
        }
    }
}
